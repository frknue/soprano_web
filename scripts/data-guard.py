#!/usr/bin/env python3
"""Keeps the daily driver's data safe across installs.

Soprano Web (/Applications/Soprano Web.app) is the user's everyday browser.
Before an install replaces it, `scripts/install.sh` runs:

  backup  Copies the installed app's data (Application Support folder,
          settings.json, WebKit container, cookies) and the installed app
          into ~/Library/Application Support/Soprano Web Backups/<time>-<label>/.
          SQLite files are copied with SQLite's online backup, so the copy
          is consistent while the app runs; unchanged files are hard links
          to the previous backup. The newest 15 backups are kept.
  check   On copies of that backup: the new build's `data-check` must see
          everything the installed build's sees (settings, profiles, Spaces
          and pins, session windows and tabs, Archive, History, site
          decisions, extensions, …) and at least what the raw files hold;
          no store may move a file aside. Then the new build's harness
          restores the copied session, loads the copied extensions and
          shows Settings: every saved tab comes back and every enabled
          extension runs. Any failure stops the install.

Only `restore` and `rollback-app` write to the real data or app, never
deleting anything (what they replace is kept under Backups/replaced-<time>/);
they refuse while the app runs and need --yes (the user's go).

  data-guard.py backup [--label L] [--with-app]
  data-guard.py check --binary <new SopranoWeb> [--baseline-app <installed .app>] [--backup NAME]
  data-guard.py list
  data-guard.py restore NAME --yes
  data-guard.py rollback-app NAME --yes
"""

import argparse
import datetime
import hashlib
import json
import os
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from contextlib import closing
from pathlib import Path

HOME = Path.home()
SUPPORT = HOME / "Library/Application Support/Soprano Web"
SETTINGS = HOME / ".config/soprano-web/settings.json"
WEBKIT = HOME / "Library/WebKit/com.soprano.web"
HTTP_STORAGES = HOME / "Library/HTTPStorages"
COOKIE_NAMES = ["com.soprano.web", "com.soprano.web.binarycookies"]
BACKUPS = HOME / "Library/Application Support/Soprano Web Backups"
APP = Path(os.environ.get("SOPRANO_WEB_INSTALL_DIR", "/Applications")) / "Soprano Web.app"
APP_EXECUTABLE = "Contents/MacOS/SopranoWeb"
MARKER = b"soprano-web-data-check/1"
KEEP = 15
# Rebuilt by the app (content-blocker lists), or not data.
SKIP_NAMES = {"ContentBlocking", "ContentRuleLists", "automation.sock", ".DS_Store"}
SQLITE_HEADER = b"SQLite format 3\x00"


def fail(message):
    print(f"data-guard: {message}", file=sys.stderr)
    sys.exit(1)


def app_running():
    found = subprocess.run(["pgrep", "-f", str(APP / APP_EXECUTABLE)], capture_output=True)
    return found.returncode == 0


def is_sqlite(path):
    try:
        with open(path, "rb") as handle:
            return handle.read(16) == SQLITE_HEADER
    except OSError:
        return False


def read_only_uri(path):
    """A SQLite URI that opens `path` (spaces and all) without writing it."""
    return Path(path).absolute().as_uri() + "?mode=ro"


def digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(block)
    return hasher.hexdigest()


class BackupError(Exception):
    pass


def copy_file(source, target, previous):
    """Copies one file (SQLite through its backup API); a file equal to the
    previous backup's becomes a hard link to it. A database SQLite can't
    back up stops the whole backup: copying only its main file would drop
    what its WAL holds."""
    target.parent.mkdir(parents=True, exist_ok=True)
    if is_sqlite(source):
        for attempt in range(3):
            try:
                # `with` on a connection only commits; closing() closes it,
                # so the copy is left without -wal or -shm next to it.
                with closing(sqlite3.connect(read_only_uri(source), uri=True, timeout=10)) as reader, \
                        closing(sqlite3.connect(target)) as writer:
                    reader.backup(writer)
                    writer.execute("PRAGMA journal_mode=DELETE")
                for suffix in ("-wal", "-shm"):
                    Path(f"{target}{suffix}").unlink(missing_ok=True)
                break
            except sqlite3.Error as error:
                target.unlink(missing_ok=True)
                if attempt == 2:
                    raise BackupError(f"{source}: SQLite could not back it up ({error})")
                time.sleep(1)
    else:
        shutil.copy2(source, target, follow_symlinks=False)
    if previous is not None and previous.is_file() and not target.is_symlink():
        if previous.stat().st_size == target.stat().st_size and digest(previous) == digest(target):
            target.unlink()
            os.link(previous, target)


def copy_tree(source, target, previous):
    """`source` into `target`, skipping rebuilt folders and the SQLite side
    files the backup API already folded in."""
    if not source.exists():
        return 0
    # The folder or file itself may be a link (a dotfiles settings.json):
    # its contents are what's backed up.
    source = source.resolve()
    # A link out of the data (a profile folder kept elsewhere) can't be
    # backed up as a link: a check of the copy would open the live target.
    leaving = escaping_links(source)
    if leaving:
        raise BackupError(f"links out of {source}: {', '.join(leaving)}")
    if source.is_file():
        copy_file(source, target, previous)
        return 1
    count = 0
    def unreadable(error):
        raise BackupError(f"can't read {error.filename}: {error.strerror}")

    for root, folders, files in os.walk(source, onerror=unreadable):
        # A linked folder is copied as the link, not skipped.
        for name in [name for name in folders if (Path(root) / name).is_symlink()]:
            folders.remove(name)
            files.append(name)
        folders[:] = [name for name in folders if name not in SKIP_NAMES]
        root_path = Path(root)
        relative = root_path.relative_to(source)
        databases = {name for name in files if is_sqlite(root_path / name)}
        for name in files:
            if name in SKIP_NAMES:
                continue
            if any(name == f"{db}{suffix}" for db in databases for suffix in ("-wal", "-shm", "-journal")):
                continue
            path = root_path / name
            if path.is_socket() or not (path.is_file() or path.is_symlink()):
                continue
            earlier = previous / relative / name if previous else None
            copy_file(path, target / relative / name, earlier)
            count += 1
    return count


def backups():
    if not BACKUPS.exists():
        return []
    return sorted(path for path in BACKUPS.iterdir()
                  if path.is_dir() and not path.name.startswith(".") and (path / "manifest.json").exists())


def git_commit():
    found = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True,
                           cwd=Path(__file__).resolve().parent.parent)
    return found.stdout.strip() if found.returncode == 0 else ""


def app_version(app):
    try:
        with open(app / "Contents/Info.plist", "rb") as handle:
            info = plistlib.load(handle)
        return f"{info.get('CFBundleShortVersionString', '?')} ({info.get('CFBundleVersion', '?')})"
    except OSError:
        return None


def backup(label, with_app):
    stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S")
    name = f"{stamp}-{label}" if label else stamp
    target = BACKUPS / name
    previous = backups()[-1] if backups() else None
    BACKUPS.mkdir(parents=True, exist_ok=True)
    # Its own folder, so two backups at once never share one.
    partial = Path(tempfile.mkdtemp(prefix=f".{name}.", suffix=".partial", dir=BACKUPS))
    try:
        files = {
            "support": copy_tree(SUPPORT, partial / "support", previous / "support" if previous else None),
            "settings": copy_tree(SETTINGS, partial / "config/settings.json",
                                  previous / "config/settings.json" if previous else None),
            "webkit": copy_tree(WEBKIT, partial / "webkit", previous / "webkit" if previous else None),
            "cookies": sum(copy_tree(HTTP_STORAGES / cookie, partial / "httpstorages" / cookie,
                                     previous / "httpstorages" / cookie if previous else None)
                           for cookie in COOKIE_NAMES),
        }
        if with_app and APP.exists():
            (partial / "app").mkdir()
            subprocess.run(["ditto", "-c", "-k", "--keepParent", str(APP), str(partial / "app/Soprano Web.app.zip")],
                           check=True)
    except (BackupError, OSError, subprocess.CalledProcessError) as error:
        # Nothing incomplete is ever published as a backup.
        shutil.rmtree(partial, ignore_errors=True)
        fail(f"backup failed, nothing kept: {error}")
    manifest = {
        "created": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "label": label,
        "commit": git_commit(),
        "installedApp": app_version(APP) if APP.exists() else None,
        "appKept": (partial / "app").exists(),
        "appWasRunning": app_running(),
        "files": files,
    }
    (partial / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    partial.rename(target)
    for old in backups()[:-KEEP]:
        shutil.rmtree(old)
    size = subprocess.run(["du", "-sh", str(target)], capture_output=True, text=True).stdout.split("\t")[0]
    print(f"data-guard: backup {target.name} ({size}, {sum(files.values())} files"
          f"{', app kept' if manifest['appKept'] else ''})")
    return target


# MARK: check

def working_copy(source, root, name):
    folder = root / name
    shutil.copytree(source / "support", folder / "support", symlinks=True) if (source / "support").exists() \
        else (folder / "support").mkdir(parents=True)
    settings = folder / "settings.json"
    if (source / "config/settings.json").exists():
        shutil.copy2(source / "config/settings.json", settings)
    # Nothing the builds open may lead out of the copy.
    leaving = escaping_links(folder)
    if leaving:
        fail(f"the backup has links out of it, nothing was run on it: {', '.join(leaving)}")
    return folder / "support", settings


def escaping_links(root):
    """Links under `root` whose target is outside it (or missing)."""
    if root.is_symlink():
        return [str(root)]
    if not root.is_dir():
        return []
    base = root.resolve()
    found = []
    for folder, folders, files in os.walk(root):
        for name in folders + files:
            path = Path(folder) / name
            if not path.is_symlink():
                continue
            target = path.resolve()
            if not target.exists() or (target != base and base not in target.parents):
                found.append(str(path.relative_to(root)))
    return sorted(found)


def has_data_check(binary):
    try:
        return MARKER in Path(binary).read_bytes()
    except OSError:
        return False


def data_check(binary, support, settings):
    run = subprocess.run([str(binary), "data-check", str(support), str(settings)],
                         capture_output=True, text=True, timeout=120)
    if run.returncode != 0:
        fail(f"{binary} data-check exited {run.returncode}: {run.stderr.strip()}")
    return json.loads(run.stdout)


def differences(before, after, path=""):
    """Every value the installed build reported that the new build reports
    differently. New keys are fine (new settings, new stores), in nested
    objects too; a list must keep its length and each element compares
    the same way."""
    found = []
    if isinstance(before, dict) and isinstance(after, dict):
        for key, value in before.items():
            if key not in after:
                found.append(f"{path}/{key}: gone (was {json.dumps(value)[:120]})")
            else:
                found += differences(value, after[key], f"{path}/{key}")
    elif isinstance(before, list) and isinstance(after, list) and len(before) == len(after):
        for index, (old, new) in enumerate(zip(before, after)):
            found += differences(old, new, f"{path}[{index}]")
    elif before != after:
        found.append(f"{path}: {json.dumps(before)[:160]} -> {json.dumps(after)[:160]}")
    return found


def raw_counts(source):
    """What the files hold, read without the app's decoders."""
    def load(name):
        try:
            return json.loads((source / "support" / name).read_text())
        except (OSError, ValueError):
            return None

    def pins(node):
        if node.get("type") in ("pin", "bookmark"):
            return 1
        return sum(pins(child) for child in node.get("children", []))

    counts = {}
    session = load("session.json")
    if session is not None:
        windows = session.get("windows")
        counts["session tabs"] = sum(len(w.get("tabs", [])) for w in windows) if windows is not None \
            else len(session.get("tabs", []))
    spaces = load("spaces.json")
    if spaces is not None:
        counts["spaces"] = len(spaces.get("spaces", []))
        counts["pins"] = sum(pins(space.get("pinned", {})) for space in spaces.get("spaces", []))
        counts["favorites"] = sum(len(f.get("items", [])) for f in spaces.get("favorites", []))
    archive = load("archive.json")
    if archive is not None:
        counts["archive"] = len(archive.get("entries", []))
    extensions = load("extensions.json")
    if extensions is not None:
        counts["extensions"] = len(extensions.get("extensions", []))
    visits = 0
    for database in (source / "support").rglob("History.sqlite"):
        with closing(sqlite3.connect(read_only_uri(database), uri=True)) as reader:
            visits += reader.execute("select count(*) from visits").fetchone()[0]
    counts["visits"] = visits
    profiles = load("profiles.json")
    if profiles is not None:
        counts["profiles"] = len(profiles.get("profiles", []))
    sites = 0
    for path in (source / "support").rglob("site-permissions.json"):
        try:
            sites += len(json.loads(path.read_text()).get("sites", {}))
        except (OSError, ValueError):
            pass
    counts["site decisions"] = sites
    for name, key, label in (("link-routing.json", "rules", "link rules"), ("boosts.json", "entries", "boosts"),
                             ("downloads.json", "entries", "downloads")):
        stored = load(name)
        if stored is not None:
            counts[label] = len(stored.get(key, []))
    return counts


def raw_settings(source):
    """settings.json's own values, read without the app's decoder."""
    try:
        return json.loads((source / "config/settings.json").read_text())
    except (OSError, ValueError):
        return None


def aside_files(folder):
    """Files a store keeps when it can't read or migrates one."""
    return {str(path.relative_to(folder)) for path in folder.rglob("*")
            if path.name.endswith((".corrupt", ".unreadable", ".migrated"))}


def summary_counts(summary):
    spaces = summary.get("spaces", [])
    return {
        "session tabs": sum(len(window) for window in summary.get("session", {}).get("tabs", [])),
        "spaces": len(spaces),
        "pins": sum(len(space.get("pins", [])) for space in spaces),
        "favorites": sum(len(space.get("favorites", [])) for space in
                         {space["profile"]: space for space in spaces}.values()),
        "archive": summary.get("archive", 0),
        "extensions": len(summary.get("extensions", [])),
        "visits": sum(entry.get("visits", 0) for entry in summary.get("history", {}).values()),
        "profiles": len(summary.get("profiles", [])),
        "site decisions": sum(summary.get("sitePermissions", {}).values()),
        "link rules": summary.get("linkRouting", 0),
        "boosts": summary.get("boosts", 0),
        "downloads": summary.get("downloads", 0),
    }


def harness_run(binary, support, root, flags):
    """The new build off screen, on a copy of the user's support folder."""
    run = subprocess.run(
        [str(binary), "snapshot", "--out", str(root / "check.png"),
         "--support-dir", str(support), "--wait", "6"] + flags,
        capture_output=True, text=True, timeout=300)
    lines = {}
    for line in run.stdout.splitlines():
        for prefix in ("settings-page: ", "extensions: "):
            if line.startswith(prefix):
                lines[prefix.strip(": ")] = line[len(prefix):]
        if '"printedAt"' in line and "{" in line:
            lines["windows"] = line[line.index("{"):]
    return run, lines


def check(binary, baseline_app, backup_name):
    found = backups()
    if not found:
        fail("no backup to check against; run `data-guard.py backup` first")
    source = BACKUPS / backup_name if backup_name else found[-1]
    if not (source / "manifest.json").exists():
        fail(f"no backup {source.name}")
    if not has_data_check(binary):
        fail(f"{binary} has no data-check")
    problems = []
    report = {"backup": source.name, "binary": str(binary)}
    root = Path(tempfile.mkdtemp(prefix="soprano-web-data-guard-"))
    try:
        support, settings = working_copy(source, root, "new")
        new = data_check(binary, support, settings)
        report["new"] = new
        baseline = Path(baseline_app) / APP_EXECUTABLE if baseline_app else None
        if baseline and baseline.exists() and has_data_check(baseline):
            support_b, settings_b = working_copy(source, root, "baseline")
            old = data_check(baseline, support_b, settings_b)
            report["baseline"] = old
            changed = differences(old, new)
            problems += [f"installed build vs new build: {line}" for line in changed]
        else:
            report["baseline"] = None
            print("data-guard: the installed build has no data-check; comparing with the raw files only")
        raw = raw_counts(source)
        seen = summary_counts(new)
        report["raw"], report["counts"] = raw, seen
        problems += [f"{key}: the files hold {value}, the new build sees {seen.get(key)}"
                     for key, value in raw.items() if seen.get(key, 0) < value]
        # Every value settings.json holds must reach the app as it is.
        stored = raw_settings(source)
        if stored is not None:
            problems += [f"settings: {line}" for line in differences(stored, new["settings"]["values"])]
        if not new["settings"]["readable"]:
            problems.append("settings.json does not decode")
        if not new["session"]["readable"]:
            problems.append("session.json does not decode")
        problems += [f"moved aside by the new build: {path}" for path in new.get("movedAside", [])]
        problems += [f"History of profile {key} not persistent" for key, entry in new["history"].items()
                     if not entry["persistent"]]

        # The real launch path on another copy: the saved session comes
        # back tab for tab, every enabled extension runs, and no store
        # moves a file aside.
        support_c, _ = working_copy(source, root, "harness")
        aside_before = aside_files(support_c)
        run, lines = harness_run(binary, support_c, root, [
            "--session", str(support_c / "session.json"), "--print-windows", "--print-extensions"])
        if run.returncode != 0:
            problems.append(f"harness exited {run.returncode}: {run.stderr.strip()[-400:]}")
        problems += [f"moved aside when the new build launched: {path}"
                     for path in aside_files(support_c) - aside_before]
        windows = json.loads(lines["windows"]) if "windows" in lines else None
        restored = sum(len(w.get("tabs", [])) for w in windows.get("windows", [])
                       if w.get("kind") == "normal") if windows else 0
        report["restoredTabs"] = restored
        if raw.get("session tabs") and restored != raw["session tabs"]:
            problems.append(f"session: {raw['session tabs']} tabs saved, {restored} restored")
        extensions = json.loads(lines["extensions"]) if "extensions" in lines else {"extensions": []}
        states = {e["id"]: e.get("state") for e in extensions.get("extensions", [])}
        report["extensionStates"] = states
        for record in new.get("extensions", []):
            if record["enabled"] and states.get(record["id"]) != "on":
                problems.append(f"extension {record['name']}: {states.get(record['id'], 'not loaded')}")
        # Settings renders (its own run: its tab would count as restored).
        support_d, _ = working_copy(source, root, "settings")
        run, lines = harness_run(binary, support_d, root, ["--settings", "--print-settings"])
        page = json.loads(lines["settings-page"]) if lines.get("settings-page", "").startswith("{") else None
        if run.returncode != 0 or not page or page.get("address") != "soprano-web://settings":
            problems.append("the Settings page did not render")
    finally:
        shutil.rmtree(root, ignore_errors=True)
    report["problems"] = problems
    (source / "check-report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"data-guard: checked backup {source.name}: {seen['session tabs']} tabs ({restored} restored), "
          f"{seen['spaces']} Spaces, {seen['pins']} pins, {seen['favorites']} favorites, {seen['archive']} archived, "
          f"{seen['visits']} visits, {seen['extensions']} extensions"
          f"{'; installed build compared' if report['baseline'] else ''}")
    if problems:
        for problem in problems:
            print(f"data-guard: FAIL {problem}", file=sys.stderr)
        fail(f"{len(problems)} problem(s); the installed app was not replaced "
             f"(report: {source / 'check-report.json'})")
    print("data-guard: OK")


# MARK: restore

def require_quit():
    if app_running():
        fail("quit Soprano Web first")


def move_aside(path, replaced, name):
    if path.exists():
        (replaced / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(path), str(replaced / name))


def replaced_folder():
    """A new folder for what a restore or rollback replaces."""
    BACKUPS.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix=f"replaced-{datetime.datetime.now():%Y-%m-%d_%H%M%S}-", dir=BACKUPS))


def restore(name, yes):
    if not yes:
        fail("restore replaces the app's data with the backup's; pass --yes")
    require_quit()
    source = BACKUPS / name
    if not (source / "manifest.json").exists():
        fail(f"no backup {name}")
    replaced = replaced_folder()
    try:
        move_aside(SUPPORT, replaced, "support")
        move_aside(SETTINGS, replaced, "config/settings.json")
        move_aside(WEBKIT, replaced, "webkit")
        for cookie in COOKIE_NAMES:
            move_aside(HTTP_STORAGES / cookie, replaced, f"httpstorages/{cookie}")
        if (source / "support").exists():
            shutil.copytree(source / "support", SUPPORT, symlinks=True)
        # The content-blocker lists aren't backed up; the current ones stay.
        if (replaced / "support/ContentBlocking").exists():
            shutil.copytree(replaced / "support/ContentBlocking", SUPPORT / "ContentBlocking", symlinks=True)
        if (source / "config/settings.json").exists():
            SETTINGS.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / "config/settings.json", SETTINGS)
        if (source / "webkit").exists():
            shutil.copytree(source / "webkit", WEBKIT, symlinks=True)
        for cookie in COOKIE_NAMES:
            saved = source / "httpstorages" / cookie
            if saved.is_dir():
                shutil.copytree(saved, HTTP_STORAGES / cookie, symlinks=True)
            elif saved.exists():
                shutil.copy2(saved, HTTP_STORAGES / cookie)
    except (OSError, shutil.Error) as error:
        fail(f"restore stopped part-way ({error}); the data it replaced is in {replaced}")
    print(f"data-guard: restored {name}; what it replaced is in {replaced}")


def rollback_app(name, yes):
    if not yes:
        fail("rollback-app replaces the installed app with the backup's; pass --yes")
    require_quit()
    archive = BACKUPS / name / "app/Soprano Web.app.zip"
    if not archive.exists():
        fail(f"backup {name} kept no app")
    replaced = replaced_folder()
    (replaced / "app").mkdir()
    if APP.exists():
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(APP), str(replaced / "app/Soprano Web.app.zip")],
                       check=True)
        shutil.rmtree(APP)
    subprocess.run(["ditto", "-x", "-k", str(archive), str(APP.parent)], check=True)
    print(f"data-guard: {APP} is the app from {name} ({app_version(APP)}); the replaced one is in {replaced}")


def list_backups():
    for path in backups():
        manifest = json.loads((path / "manifest.json").read_text())
        report = path / "check-report.json"
        status = ""
        if report.exists():
            status = "check failed" if json.loads(report.read_text()).get("problems") else "check passed"
        kept = "\tapp kept" if manifest.get("appKept") else ""
        print(f"{path.name}\tcommit {manifest.get('commit') or '-'}\tapp {manifest.get('installedApp') or '-'}"
              f"{kept}\t{status}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("backup")
    make.add_argument("--label", default="manual")
    make.add_argument("--with-app", action="store_true")
    verify = commands.add_parser("check")
    verify.add_argument("--binary", required=True)
    verify.add_argument("--baseline-app")
    verify.add_argument("--backup")
    commands.add_parser("list")
    back = commands.add_parser("restore")
    back.add_argument("name")
    back.add_argument("--yes", action="store_true")
    roll = commands.add_parser("rollback-app")
    roll.add_argument("name")
    roll.add_argument("--yes", action="store_true")
    args = parser.parse_args()
    if args.command == "backup":
        backup(args.label, args.with_app)
    elif args.command == "check":
        check(Path(args.binary), args.baseline_app, args.backup)
    elif args.command == "list":
        list_backups()
    elif args.command == "restore":
        restore(args.name, args.yes)
    elif args.command == "rollback-app":
        rollback_app(args.name, args.yes)


if __name__ == "__main__":
    main()
