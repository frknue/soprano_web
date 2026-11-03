# Soprano Web

A native WebKit browser for macOS in the Soprano family: Swift 6 + programmatic
AppKit (no storyboards/xibs/SwiftUI), SPM, macOS 26+, `WKWebView`, shipped as a
hand-packaged `.app` via `scripts/package-app.sh`. Folio chrome is vendored from
Soprano.

## Commands

Homebrew Swift with the Command Line Tools SDK. Xcode's newer SDK breaks
Homebrew Swift, so pin `DEVELOPER_DIR` and `SDKROOT` on every Swift command:

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

swift build
swift test
swift test --filter BrowserDelegateSelectorTests
./scripts/dev.sh --build-only        # packages .build/debug/Soprano Web Dev.app
./scripts/dev.sh                     # builds, packages and launches (user-driven only)
./scripts/install.sh                 # release build → /Applications/Soprano Web.app
```

SwiftPM may print one `warning: 'soprano-web': ld: warning: building for
macOS-13.0 …` line before "Planning build": it links the `Package.swift`
manifest for macOS 13, and the line is expected. The app and the tests build
for macOS 26 without link warnings. There is no linter or formatter; match
surrounding style.

## Daily driver: the user's data

Since 2026-11-02 the installed app (`/Applications/Soprano Web.app`) is
Furkan's everyday browser. Its data is real and must survive every feature
and fix: `~/Library/Application Support/Soprano Web/` (session, Spaces and
pins, Archive, History, extensions, site decisions), `~/.config/soprano-web/settings.json`,
the WebKit container `~/Library/WebKit/com.soprano.web/` (logins, cookies,
site storage, the extensions' own storage, 1Password's sign-in) and
`~/Library/HTTPStorages/com.soprano.web*`.

- Agents never write, move or delete those, and never point the dev app,
  the harness, tests or the installed app's `browser` CLI at them. The
  harness's `--support-dir` and `data-check` refuse the real folder and
  `Soprano Web Backups` (`BrowserProtectedData`): files in a backup are
  hard links shared by several backups, so even opening a database there
  can change all of them. To look at the data, copy a backup first
  (`cp -R`, `ditto`) and work on the copy.
- Every install goes through `./scripts/install.sh`, which runs
  `scripts/data-guard.py` before replacing the app: `backup --with-app`
  (the data and the installed app, into `~/Library/Application
  Support/Soprano Web Backups/<time>-install-<commit>/`, the newest 15
  kept; SQLite through its online backup, so it is consistent while the app
  runs; a database it can't copy, or a folder it can't read, aborts the
  backup with nothing kept) and `check` on copies of that backup: the new
  build's `data-check` (`BrowserDataCheck`, one JSON summary of every store
  as the app reads it, the profiles' WebKit data stores and the
  extensions' storage included) must equal the installed build's, see at
  least what the raw files hold (every store's entries, every value in
  `settings.json`), and move no file aside (`.corrupt`, `.unreadable`,
  `.migrated`); the new build's harness must restore exactly the saved
  tabs, run every enabled extension and move nothing aside on launch, and
  render Settings in a run of its own. A failure stops the
  install with the installed app untouched: report it to Furkan with the
  `check-report.json` it names; never bypass or weaken the check.
- A change to anything stored (a file format, a migration, a new store)
  decodes tolerantly, keeps the old file (`.migrated`) and never drops what
  it can't read. A new store gets a field in `BrowserDataCheck.summary`. A
  change the check reports on purpose (a migration) needs Furkan's ok
  before the guard is changed to expect it.
- `data-guard.py restore <backup> --yes` (data) and `rollback-app <backup>
  --yes` (the app) run only on Furkan's go, with the app quit; what they
  replace goes to `Backups/replaced-<time>-<random>/` first (the app as a
  zip), never deleted, and a restore that stops part-way names that folder.
  `data-guard.py list` shows the backups and their check results.

## Verification

- While iterating, review-fix rounds included, verify with `swift build` and
  the affected suites (`swift test --filter <Suite>`); run the full `swift
  test` (about 15 s) once before each commit.
- A task that changed the app or its packaging installs once, as its very
  last step: after every commit and every review round, never after an
  individual fix. Docs-only tasks and tasks with no change don't install.
  Subagents never install; the parent does, once, after integrating. `./scripts/install.sh`
  builds for release through `scripts/build-with-guard.sh` (`-j 2`; it
  refuses to package a build that printed "nearly matches optional
  requirement", so a delegate signature that breaks only in release stops
  the install), then runs the data guard (about a minute). There is no
  separate release `swift test`.
- The user works on this Mac while agents run: pass `-j 2` to Swift, run one
  heavy process at a time, and run at most one agent that builds. Don't
  prefix commands with `taskpolicy -b`: background priority keeps builds on
  the efficiency cores (a one-file rebuild took 22 s instead of 4 s).
  Nothing an agent runs may take focus or trigger a system prompt; the dev
  app (below) is the one window an agent shows.
- Verify UI with the offscreen snapshot command and read the PNG:

  ```bash
  .build/debug/SopranoWeb snapshot --out /tmp/sw.png --size 1440x900 \
      --theme folio-paper [--url <url>] [--sidebar history|archive|downloads] \
      [--find] [--settings] [--vertical-tabs] [--collapsed] [--print-tabs] …
  ```

  It builds the real windows with volatile stores through the window
  manager, captures the chrome with AppKit and the page with WebKit, and
  writes a PNG; its windows stay off every display and never become key or
  front. Every flag (windows, tabs, Spaces, pins, Archive, sleep, content
  blocker, search engines, import, Command Bar, shortcuts, extensions, …)
  is in `docs/HARNESS.md`; the stage 4 features' flags sit with their entry
  in `docs/ARCHITECTURE.md`. Read the part you need before running it.

- Verify real navigation, Spaces and the agent surface in the dev app. Agents
  launch it on their own, in the background (`open -g` leaves focus with the
  user). It has its own support folder (`Soprano Web Dev`), settings
  (`~/.config/soprano-web-dev`) and WebKit container, so the installed app's
  data stays untouched. The CLI has no Space create/delete: make Spaces first
  with the harness on the dev app's folder while it isn't running (`snapshot --support-dir
  "$HOME/Library/Application Support/Soprano Web Dev" --new-space "Work||"`).

  ```bash
  open -g -n ".build/debug/Soprano Web Dev.app"
  APP=".build/debug/Soprano Web Dev.app/Contents/MacOS/SopranoWeb"
  "$APP" browser goto https://example.com
  "$APP" browser wait-for-load
  "$APP" browser snapshot
  "$APP" browser vimium "gg"       # drive normal-mode keys without the keyboard
  ```

- Launch only the dev app, only with `open -g -n` (`./scripts/dev.sh` without
  `--build-only` activates it), and quit it when done with `pkill -f
  'Soprano Web Dev.app/Contents/MacOS/SopranoWeb'` (the installed app's
  executable has the same name). `./scripts/install.sh` (see above)
  replaces `/Applications/Soprano Web.app` without restarting a running
  instance, and the update lands on next launch. Report the result.
- WebKit delegate conformance is runtime-checked in
  `BrowserDelegateSelectorTests`. Keep that test green: a delegate method with a
  nearly matching Swift signature compiles but WebKit never calls it. Confirmed
  with `class_getInstanceMethod`; do not "fix" it by silencing the warning.

## Architecture

Every source file's role, the stores, and how windows, tabs, Spaces,
extensions and the stage 4 features fit together are in
`docs/ARCHITECTURE.md`. Read the entries for the files you touch before
editing them.

- `Vendored/` — Folio design system from Soprano. Never edit these files here.

`SOPRANO_COMMIT` records the Soprano commit the vendored files came from. Refresh
them with `scripts/sync-soprano-chrome.sh [checkout] [ref]`; it stages every file
before replacing anything, so a missing source leaves the repo untouched.
`scripts/render-app-icon.swift` is local here until the `web` glyph moves into
Soprano's design source; do not sync that file blindly.

## Engine decision

WebKit, not Chromium or Gecko:

- Gecko has no supported embeddable macOS view (GeckoView is Android-only), so
  "Firefox-based" means forking Firefox, not a family app.
- Chromium/CEF is viable but makes the app a C++/Swift hybrid with nested
  framework and helper bundles, hundreds of MB, and responsibility for shipping
  every Chromium security update. It buys CDP and Chrome extension/site parity.
- WebKit is an OS framework, matches Soprano's existing browser pane and
  automation surface, signs like the rest of the family, and inherits engine
  security fixes from macOS. The cost is no CDP, and Chrome extensions only
  through `WKWebExtension` (macOS 15.4), which lacks some `chrome.*` APIs.

Do not add a second engine without a concrete product requirement (a Chrome-only
site or a CDP flow that cannot use the CLI).

## Conventions

- Swift 6, macOS 26+, programmatic AppKit, Folio tokens and components only.
  Fonts by role through `ChromeFont`, radii from `Chrome.Radius`, accent only for
  keyboard focus, one hairline between regions.
- Tests use swift-testing (`import Testing`, `@Test`, `#expect`), one
  `struct …Tests` per file. Never `import Foundation` next to `import Testing` in
  a test file; import `AppKit` instead and get Foundation types through it.
  Never call `performClick` (or anything that spins a nested run loop) in a
  test: the runner can see the nested loop and end the process silently with
  exit 0 and no summary; send the action (`NSApp.sendAction`) instead.
- Settings are plain JSON at `~/.config/soprano-web/settings.json`; session and
  list data live in `~/Library/Application Support/Soprano Web/`. The
  vertical-vs-horizontal choice is configuration (`verticalTabs`); whether the
  rail is collapsed is UI state in `UserDefaults`. Tests always inject temporary
  URLs/defaults and never touch the real files.
- Every WebKit action that changes the page runs on the main actor; JSON stores
  are synchronous and atomic. History is SQLite through `import SQLite3` (no
  packages): every read is an indexed, `LIMIT`ed query on the main actor
  (never load the whole table), and anything that touches every row runs on a
  second connection off the main thread.
- Commit only paths changed in the session. Short imperative subjects,
  `feat:` / `fix:` / `docs:` / `test:` / `chore:` prefixes.
- After a user-visible change, add a line under `## [Unreleased]` in
  `CHANGELOG.md` in the matching Keep a Changelog group, written for the user and
  naming the shortcut or setting.
- A new file, store or feature gets its entry in `docs/ARCHITECTURE.md`; a
  new harness flag goes into `docs/HARNESS.md` (or the feature's
  architecture entry). Keep `AGENTS.md` to rules and commands.
- Releases: rename `[Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, add a fresh
  `[Unreleased]`, set `CFBundleShortVersionString` and `CFBundleVersion` in
  `Support/Info.plist` (the only version source), `swift test`, commit
  `release: vX.Y.Z`, then install (see Verification).
- Push, open PRs, tags and merges only when the user asks for that action.

## Known gaps

`docs/ROADMAP.md` lists what is not built yet, in build order, and
`docs/ARC-PARITY.md` the evidence behind each item: Arc's behavior, file:line,
the WebKit API with its macOS version, and prior art. Read both before adding a
browser feature; move or delete the roadmap item when it ships.

`BrowserAutomationScripts.swift` is a copy of the JavaScript in Soprano's browser
pane. Extract the scripts into a Foundation-only file in Soprano and add that
file to `scripts/sync-soprano-chrome.sh`; until then the two copies can drift.

Vimium's `gf`/`gF` frame commands and `⌥P` pin are unavailable (pins not
modeled); the help sheet says so.

The harness drives tab drags through the same drop and drag-out handlers the
drag session calls; a real-mouse drag between windows still needs a person at
the Mac. A window whose address field was edited stays in memory after it
closes (AppKit's `SPSafariPlatformSupport` keeps the last autofill control), so
`--print-windows` reports it in `closedWindowsStillAlive`; its tabs are gone.

The content blocker skips filters WebKit can't express (`$csp`,
`$redirect`, `$removeparam`, `$rewrite`, scriptlets, procedural and extended
CSS, snippets, HTML filters, `example.*` domains, regular expressions outside
WebKit's subset; `content-blocking.json` counts them by reason) and shows no
blocked-request count: WebKit has no public callback for blocked loads. A
generic selector WebKit's CSS parser rejects drops its whole
`css-display-none` batch silently (no compile error), so the converter
refuses unknown pseudo-classes and `:has()` inside `:has()` up front.
Checked against the real EasyList (2026-10-30): every one of its 5,746
`css-display-none` batches parses in WebKit, and a probe element for each of
the 301 generic batches with a plain class or id selector is hidden. EasyList
turns generic hiding off on `127.0.0.1`, `192.168.*` and `localhost`
(`$generichide`): probe such rules on another host name, e.g.
`probe.localhost`.
