# Stage 3 — Arc's organization model and import (design contract)

The design every stage 3 phase builds against. Status, branches and the next step are in
`docs/STATUS.md`. Read the repo `AGENTS.md` first (build env, `taskpolicy -b`, `-j 2`,
swift-testing rules, harness, CHANGELOG, conventions), then `docs/ROADMAP.md` §3 and
`docs/ARC-PARITY.md` ("Arc's model in brief", "Importing from Arc").

## User decisions (final, do not re-ask)
- **Pinned tabs replace bookmarks** ("do it just like Arc"). There is no separate bookmark
  model any more: the stage-2 bookmark tree becomes each Space's pinned tree. ⌘D pins the
  current tab into the current Space. Chrome/Safari/HTML bookmark imports become pinned
  folders. The right sidebar loses its Bookmarks section; the Bookmarks menu becomes a
  Spaces menu. Vimium `b`, start-page folder cards and address suggestions read pins.
- **Space color = mark only**: a Folio token (`BrowserProfileColor`) shown as a dot next
  to the Space's emoji/SF Symbol and name in the rail header, the Space switcher and the
  toolbar mark. No window tint; accent stays keyboard-focus only.
- **Search keywords**: built-in engines (DuckDuckGo, Google, Bing) have no keyword by
  default, so "g string" or "b tree" never jump to another engine; the user can give any
  engine a keyword.

## Model
- `BrowserSpace { id: UUID, name: String, icon: BrowserSpaceIcon (.none | .emoji(String) |
  .symbol(String)), color: BrowserProfileColor, profileID: UUID, pinned: <pin root folder>,
  importedFrom: String? }`. Several Spaces may share a profile. Every profile has ≥1 Space
  (creating a profile creates one; deleting a profile deletes its Spaces; deleting a
  profile's last Space is refused). Order = display order.
- Pins: the stage-2 `BrowserBookmarkTree` operations (insert/move/rename/edit/remove,
  outline, drop math) are kept and renamed to pin vocabulary (`BrowserPin`,
  `BrowserPinFolder`, `BrowserPinNode`, `BrowserPinTree`, `BrowserPinOutline`, …).
  One tree per Space. Pin = `{id, url, title, addedAt}`; title is user-editable.
- Favorites: per profile, ordered list of pins, max 12 (`BrowserFavorites`).
- Archive timing per profile: `BrowserProfile.archiveAfter` (`never, days30, days7, hours24,
  hours12 (default), hours6, hour1`), tolerant decoding in `profiles.json`.
- Store: `BrowserSpaceStore` (MainActor, `changes` observable, synchronous atomic JSON
  writes like the other stores) owns `<support>/spaces.json`:
  `{ "version": 1, "spaces": [...], "favorites": [{ "profileID", "items": [pins] }] }`.
  Tolerant decoding (bad Space/pin skipped, repeated ids dropped), unreadable file kept as
  `.corrupt`. Replaces `BrowserBookmarkStore`.
- Migration when `spaces.json` is missing: one Space per existing profile (name = profile
  name, color = profile color, icon none); `bookmarks.json` (v1 or v2) becomes the Default
  profile's Space's pinned tree and is kept as `bookmarks.json.migrated`.
- UI state in UserDefaults (`BrowserPinUIState`): expanded pin folders, ⌘D's last folder
  per Space.

## Windows and tabs
- A normal window shows one Space at a time: `currentSpaceID`. Private and pop-up windows
  have no Spaces (rail shows plain tabs, as today).
- `tabs` stays = ALL live tabs of the window (every Space), each tab has `spaceID: UUID?`
  and `pinID: UUID?` / favorite link (origin: today | pinned(pinID) | favorite(pinID)).
  Views, index-based commands (⌘1…9, Vimium gt/gT/<</>>, CLI tab numbers, tab strip) work on
  the current Space's visible tabs. Selection is remembered per Space.
- Per-tab data context: `BrowserTab.dataContext` (its Space's profile context; private:
  the window's). The window's `dataContext` = current Space's context (private/pop-up:
  fixed). Every WebKit delegate callback / per-tab operation uses the TAB's context
  (history recording, site permissions, favicons, connection security, downloads), never
  the window's current one: a background Space's tab of another profile must never write
  into the visible Space's profile. Store observations re-bind on Space switch.
- Switching Space: ⌃1…⌃9, ⌥⌘←/⌥⌘→, two-finger horizontal swipe on the rail, Spaces menu,
  rail switcher, CLI. Tabs of hidden Spaces stay alive (sleep policy unchanged).
- Tab move rule: a tab may move into a window iff the target window's current Space uses
  the same data context; it lands in that window's current Space as a Today tab.
- Pinned/favorite live tabs are per window: clicking a pin selects its live tab in this
  window or opens one linked to the pin. ⌘W on a pinned tab unloads it back to the pin
  (Arc). A pinned tab that navigated to another URL shows a "/" mark; clicking the pin's
  icon resets it to the pinned URL; ⌘-click on the icon resets and keeps the current page
  in a new Today tab; "Replace Pin with Current Page" in the tab/pin menu.
- Session `session.json` version 3: per window `currentSpaceID`, tabs with `spaceID`,
  `pinID`/favorite link, per-Space selection; version 2 migrates (tabs → the first Space of
  the window's profile). Recently-closed entries carry `spaceID`.

## Rail (vertical tabs) layout, top to bottom
Space header (icon + name + color dot; private: the existing mark) · Favorites grid
(icons, live/selected state) · Pinned outline (folders expand/collapse, drag reorder/
drop using the existing outline drop math, hover preview on folders with search) ·
"Today" header with "+ New Tab" and Today tabs · bottom Space switcher (one icon per
Space, current one marked, "+" → New Space sheet). Horizontal mode: the strip shows the
current Space's live tabs, pinned ones first and compact.

## Archive
Today tabs (never pinned/favorites/folders) auto-archive after the profile's
`archiveAfter` idle time (last selected/used). ⌘W on a Today tab archives it ("manual")
and still pushes Recently Closed. ⇧⌘K archives all Today tabs of the current Space.
Archive: `<support>/archive.json` (entries: id, url, title, spaceID, profileID,
archivedAt, reason manual|auto|imported, favicon key); private windows never archive.
Right sidebar section "Archive": searchable, restore opens the tab in its original Space
(switching the window to it). Sidebar sections become History · Archive · Downloads.

## Command Bar and shortcuts
One command registry (id, title, default shortcut, synonyms, enabled-state) feeds the main
menu, Settings ▸ Shortcuts (remapping saved in settings.json, conflict priority per
shortcut: app wins / site wins / press twice) and the Command Bar. ⌘T opens the Command
Bar (open tabs, history, pins, Spaces, `/` actions, settings, site search on Tab);
Enter on a query opens a new Today tab. ⌘L edits the current URL in the same bar.
⌃Tab = recent-tab switcher (5 most recent, hold ⌃), ⌥⌘↑/↓ walk the sidebar items,
⇧⌘C copy URL, ⌥⇧⌘C copy as Markdown `[title](url)`, ⇧⌘K clear Today, ⇧⌘D toggle toolbar.

## Search engines
Custom engines `{name, keyword, template with %s}` in settings, default engine choice
(built-ins remain), "keyword query" in the address/Command Bar searches that engine;
Tab after a keyword enters site-search mode in the Command Bar.

## Import (File ▸ Import Browser Data…)
Readers (pure, no AppKit/WebKit): Arc (`StorableSidebar.json`, `StorableArchiveItems.json`,
favicon caches, `User Data/<profile>/History`, `StorableLinkRouting.json`), Chrome
(`Bookmarks` JSON, `History`), Safari export ZIP (`Bookmarks.html`, `History.json`),
Netscape bookmarks HTML import and export. Chromium SQLite opened read-only with
`file:…?immutable=1`. Arc mapping: Arc profile default → Default, `Profile N` → a new
Soprano profile named after its first Space; Spaces → Spaces (emoji, nearest Folio color);
pinned trees → pinned (splitView flattened); favorites → profile favorites (first 12, rest
appended to the first Space's pinned); Today tabs → unloaded Today tabs of that Space in
the importing window; archive → archive (reason imported); history → that profile's
History (off main thread, bulk); link routing → Air Traffic Control rules applied to links
from other apps. Re-import skips Spaces already imported (`importedFrom`). Creating a
profile already gives it a Space (the manager reconciles on every profile change), so the
importer renames or reuses that Space instead of adding another.

Real Arc data (checked 2026-10-25, Arc 1.169): the archive is `StorableArchiveItems.json`
(`StorableArchive.<date>.json` files only hold `autoArchiveStartTime`); Space color is
`customInfo.windowTheme.primaryColorPalette.midTone` (extended sRGB); icons are
`customInfo.iconType` `{emoji_v2}` or `{icon: <Arc name, not an SF Symbol>}`; only `tab`,
`list` and `itemContainer` items occur; favicon files are `md5(<uppercase item UUID>)`.
