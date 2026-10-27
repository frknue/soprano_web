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
- **Every Space is isolated**: its own cookies, website data, History, site decisions,
  favicons decisions, certificate exceptions, Archive and Favorites. There is no option to
  share a profile between Spaces; Settings ▸ Profiles is gone and the profile is only the
  internal data container behind a Space (deviates from Arc, which shares a Profile across
  Spaces).

## Model
- `BrowserSpace { id: UUID, name: String, icon: BrowserSpaceIcon (.none | .emoji(String) |
  .symbol(String)), color: BrowserProfileColor, profileID: UUID, pinned: <pin root folder>,
  importedFrom: String? }`. The Space is the isolation unit: every Space has a profile of its
  own (creating a Space creates its profile, id = the Space's id; its name and color follow
  the Space). The Default profile (default data store) belongs to the Default Space, which
  can't be deleted; deleting any other Space deletes its profile and all its data. Order =
  display order. Spaces that shared a profile (files written before this rule) are separated
  on load: the first keeps the profile, every other one gets a new one (signed out; its open
  tabs reopen there, its Archive entries move with it, Favorites stay with the first).
- Pins: the stage-2 `BrowserBookmarkTree` operations (insert/move/rename/edit/remove,
  outline, drop math) are kept and renamed to pin vocabulary (`BrowserPin`,
  `BrowserPinFolder`, `BrowserPinNode`, `BrowserPinTree`, `BrowserPinOutline`, …).
  One tree per Space. Pin = `{id, url, title, addedAt}`; title is user-editable.
- Favorites: per Space (kept by its profile), ordered list of pins, max 12 (`BrowserFavorites`).
- Archive timing per Space: `BrowserProfile.archiveAfter` of its profile (`never, days30,
  days7, hours24, hours12 (default), hours6, hour1`), set in Edit Space, tolerant decoding in
  `profiles.json`.
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
  the same data context — with one profile per Space, that means the tab's own Space; it
  lands there. It keeps its pin or favorite link only when that pin is in the target's
  current Space and the target window has no live tab for it yet; otherwise it lands as a
  Today tab (drops, Move Tab to New Window, restore). Merge All Windows keeps every tab in
  its Space.
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
`file:…?immutable=1`. Arc mapping: every Arc Space → its own Space with its own profile
(emoji, nearest Folio color); an Arc profile's History and favorites go to its home Space:
Arc Default → the Default Space (taken over by Default's first Space while it is untouched),
`Profile N` → the first of its Spaces (its profile marked `arc:Profile N`), or a new Space
named after it when only its History or favorites come in (History-only profiles unchecked);
pinned trees → pinned (splitView flattened); favorites → the home's favorites (first 12, rest
appended to the home's pinned); Today tabs → unloaded Today tabs of that Space in the
importing window; archive → archive (reason imported; Spaceless → the Default Space);
history → the home's History (off main thread, bulk); link routing → Air Traffic Control
rules applied to links from other apps. Re-import skips Spaces already imported
(`importedFrom`). Chrome, Safari and bookmark files go into the Space chosen in the sheet.

Real Arc data (checked 2026-10-25, Arc 1.169): the archive is `StorableArchiveItems.json`
(`StorableArchive.<date>.json` files only hold `autoArchiveStartTime`); Space color is
`customInfo.windowTheme.primaryColorPalette.midTone` (extended sRGB); icons are
`customInfo.iconType` `{emoji_v2}` or `{icon: <Arc name, not an SF Symbol>}`; only `tab`,
`list` and `itemContainer` items occur; favicon files are `md5(<uppercase item UUID>)`.
