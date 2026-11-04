# Architecture

Where each part of Soprano Web lives and how it fits together. Paths are
relative to `Sources/SopranoWeb/`. Read the entries for the files a task
touches; `AGENTS.md` holds the rules.

- `Browser/BrowserWindowManager.swift` — owned by `AppDelegate` (or the
  harness): creates and tracks every `BrowserWindowController` (key and most
  recently active window, ⌘N with cascade in the active window's Space,
  ⇧⌘N private windows over it, close onto the stack), owns the app-wide
  stores (the Archive among them), the Spaces' profiles, `BrowserDownloadManager`, Settings and its Websites
  and Website Data sheets, the recently-closed stack (entries reopen
  in their Space, else their profile's), Vimium's global marks, notification-click
  routing, links from other apps (`outsideTabbedController`: never a private
  window) and the debounced `session.json` (restore every normal window on
  its current Space, frames clamped to today's screens). It runs every Space's
  History retention pass (Settings ▸ Remove history items) at launch, once a
  day and when the setting changes. `BrowserWindowPlacement`
  keeps harness windows off-screen. `BrowserAutomationRouter` (in
  `BrowserAutomationCommand.swift`) picks the CLI's window from
  `automationControllers` (private windows excluded), opens `new-window
  --space`, runs `move-to-window` and `spaces` / `space <n|name>`. `BrowserWindowManager+TabMove.swift`
  moves live tabs: `moveTab(_:from:to:at:select:)`, `moveTabToNewWindow`,
  `mergeAllWindows` (tabs keep their Space), `openPopupWindow`; `canMoveTab(from:to:)`
  (`BrowserTabMoveRule`) is the one rule for which windows may exchange tabs:
  the tab's data context is the target's current Space's (every Space has
  its own, so: the tab's own Space), never into a pop-up; a moved tab lands in the target's current
  Space and keeps its pin or favorite link only while that is the Space's
  and the target has no live tab for it (`linkAfterMove`), else as a Today
  tab.
  `tabbedController` is the window menu commands' new tabs go to (never a
  pop-up window); `windowForNewTabs(from:)` the window a pop-up's tabs go to
  (same data context). `BrowserWindowManager+Profiles.swift` — Spaces and
  their data: `context(for:)` (a Space's profile's data context, made on
  first use; Default's or a deleted profile's is `defaultContext`),
  `history(for:)`, `space(of:)`, `windowMark(for:)` (the window's Space
  when there are several), `createSpace` (the switcher's "+": a Space
  with a profile of its own), `canDeleteSpace` (never the Default Space),
  `deleteSpace` → `deleteProfile(_:completion:)` (closes the
  Space's tabs in every window — a window holding only its tabs
  closes whole — without Recently Closed, drops its closed entries and
  Archive, deletes its Space and favorites, removes the profile from
  `profiles.json`, then retries `WKWebsiteDataStore.remove(forIdentifier:)`
  until its web views are released and deletes its folder). At launch the
  manager adds the profiles of Spaces the Space store separated
  (`separatedProfiles`), moves Archive entries to their Space's profile
  (`moveEntries(toProfileOfSpace:)`), and keeps `spaces` reconciled with
  the profile list and every profile's name and color following its
  Space (`BrowserProfileStore.follow`).
- `Browser/BrowserProfiles.swift` — `BrowserProfile`, a Space's data
  container, never shown (fixed Default id; its folder,
  `<support>/Profiles/<id>/` for the others, data-store identifier and
  `archiveAfter`), `BrowserProfileColor` (Folio tokens),
  `BrowserProfileList` (`profiles.json`, tolerant decoding, `follow`),
  `BrowserProfileStore` and `BrowserWindowMark` (the Space; "Private" or
  "Private · Work" in a private window). `BrowserWindowMarkView` draws
  the mark (color dot and eyebrow) in the rail header and before the address
  field; `BrowserSpacePicker` is the Websites and Website Data sheets'
  Space picker (its selection is the Space's profile id).
- `Browser/BrowserDataContext.swift` — `BrowserWindowKind` (normal or
  private: every place a private window must not write asks it) and
  `BrowserDataContext`, what a window's tabs read and write: its
  `profileID`, the profile's `WKWebsiteDataStore`, History and site
  decisions, favicons and connection decisions. The normal windows of a
  profile share the manager's context for it (`defaultContext` for
  Default); a private window gets `makePrivate(over:)` the context of the
  window it was opened from (non-persistent store, in-memory site-decision
  overlay and favicon store, its own certificate exceptions; the profile's
  History is never written), shared with its pop-ups and the windows its
  tabs move into and released with the last of them.
- `Browser/BrowserWindowController.swift` — one window: per-window stored state
  (its `dataContext` and `kind`, a private window's own `closedTabs`), init,
  layout, wiring, settings and theme (Folio Ink always for a private window).
  A normal window shows one Space at a time: `currentSpaceID` (nil in
  private and pop-up windows, `hasSpaces`), `tabs` holds every live tab of
  every Space, `visibleTabs` the current Space's — favorite tabs, then
  pinned tabs, then Today tabs (`BrowserPinLinks.order`; what
  `selectedIndex`, ⌘1…⌘9, Vimium `gt`/`gT`/`<<`/`>>`, the strip and the
  CLI's tab numbers count; `refreshVisibleTabs` keeps the selection),
  `spaceSelections` each Space's selected tab. The
  window's `dataContext` is the current Space's profile's; every per-tab
  operation and WebKit callback uses the tab's own `BrowserTab.dataContext`
  (history, site decisions, favicons, connection security and sign-in
  answers, downloads, zoom, content blocking, sleep), so a tab of a hidden
  Space in another profile never writes into the shown one.
  `syncContextObservations` observes the stores of every context in use.
  `pinSpaceID` is the Space whose pins every pin surface reads and writes
  (the current Space; a private window's profile's first; `currentPinTree`
  its tree).
  `+Pins` — live pinned and favorite tabs: `liveTab(for:)`, `openPin` /
  `openFavorite` (select the live tab, else open one linked to it; a
  favorite's tab follows the window into another Space of its profile),
  `pinIconPressed` / `resetLinkedTab` (back to the pinned address; ⌘ keeps
  the page in a new Today tab), `unloadLinkedTab` (⌘W: no Recently
  Closed), `isAway` (the "/" mark: the page is neither the pin's address
  nor `BrowserTab.linkLanding`, where the pin's last load landed after
  redirects — set on that load's commit, saved in the session), `tabItem`,
  `replaceLink`, `pinTab` /
  `unpinTab`, `addTabToFavorites` / `removeTabFromFavorites`; ⌘D makes the
  tab the new pin's live tab. `+Rail` —
  what the rail shows (`railMark`, `railOutlineRows`: the expanded
  folders; opening a pin expands its folders once, `updateRail`,
  `syncFolderPreview`) and its handlers: favorites, the
  outline's clicks, menus and drops (`bookmarkDestination` /
  `performBookmarkDrop`), the folder preview, the Today index mapping, and
  the switcher's New Space / Edit Space sheet (`makeSpaceSheet`) and
  Delete Space. `BrowserPinLinks.swift` is the pure part: link validation,
  `originAfterMove`, `isAway`, the tab order and the icon field's parsing.
  `+Spaces` — `switchToSpace` (⌃1…⌃9 via the Spaces menu, ⌥⌘←/⌥⌘→, the
  rail's swipe, CLI; an empty Space opens a start-page Today tab, and ⌘W
  doesn't close a Space's lone start tab), `spacesChanged` (deleted Space,
  Space moved to another profile: its tabs reopen there; a tab whose pin
  or favorite is gone becomes a Today tab) and
  `closeTabs(ofProfile:)`. `BrowserSpaceSwitching.swift` is the pure
  index/wrap and selection math and `BrowserSpaceSwipe`. `+Archive` —
  `archiveCandidate` (what `BrowserArchivePolicy` reads, the sleep
  candidate included), `recordArchive` (⌘W's: `closeTab(id:archive:)`
  passes `archive: true` from the user's close paths only — ⌘W, close
  buttons, Close Tab menus, the CLI; a page's `window.close()` and a
  deleted Space's tabs don't archive), `archiveTab` (into the Archive and
  out of the window, never closing it), `archiveTodayTabs` (⇧⌘K) and the
  sidebar's restore and Space mark.
  Its behavior lives in extension files
  by concern: `+Tabs` (`attachTab`/`detachTab`: everything that binds a tab to a
  window; `detachTabs` removes many with the strip, rail, selection and
  session work done once — each rail or strip update rebuilds its rows, so
  ⇧⌘K, the idle pass, Close Other Tabs and Close Tabs Below go through it),
  `+TabMove` (Move Tab to New Window, the drop and drag-out handlers
  the tab lists call, the find query a moved tab carries), `+Navigation`
  (`WKNavigationDelegate`), `+UIDelegate`
  (`WKUIDelegate`), `+Downloads` (hand-off to the download manager), `+Sidebar`,
  `+Bookmarks` (⌘D's popover under the address field, the rail's Open All in Tabs,
  New Folder, Edit/Rename, Ungroup Folder — its items take its place,
  `BrowserPinTree.ungroup` — and Delete with its confirmation, all on the
  current Space's pins),
  `+Vimium`, `+Session` (window state, lazy restore, crash recovery,
  `NSWindowDelegate`), `+PageMessages`, `+Links` (pop-ups, pop-up windows,
  modifier clicks, external apps), `+SignIn` (auth challenges, TLS
  interstitial, connection security), `+Permissions` (camera/mic, notifications,
  audio), `+TabChrome` / `+TabActions` (favicons, link status, tab menu),
  `+AddressBar` (suggestions dropdown), `+PageTools` (print, PDF, save, web-view
  context menu) and `+Privacy` (Clear Browsing Data, Website Data, default
  browser). Each WebKit protocol conformance sits on the extension that holds its
  methods.
- `Browser/BrowserTab.swift`, `BrowserModel.swift`, `BrowserSessionRestore.swift`
  — tab state (`dataContext`, `spaceID`, `origin`: today, pinned or
  favorite pin id), settings (decoded key by key), address resolution, the version 3
  session (`windows[]` with frames, `currentSpaceID`, tabs with `spaceID`
  and origin and `lastActiveAt` (idle time survives a relaunch; missing in
  older files, then it counts from the restore), per-Space selection, `recentlyClosed` with `spaceID`; a
  version 1 or 2 file migrates — tabs into the first Space of the
  window's profile — and is kept as `session.json.migrated`), the recently-closed
  stack of tabs and windows, and window frame clamping/cascading (and where a
  dragged-out tab's window opens). `BrowserTabMove.swift` — the tab-move rule,
  Merge All Windows ordering and pop-up window frames from `WKWindowFeatures`.
- `Browser/BrowserArchive.swift` — the Archive, pure: `BrowserArchiveEntry`
  (id, url, title, spaceID, profileID, archivedAt, reason
  `manual`/`auto`/`imported`, faviconKey; tolerant decoding),
  `BrowserArchiveFile` (`archive.json`, bad entries skipped, repeated ids
  dropped), `BrowserArchiveSearch` (every word in the folded title or
  address, case and diacritics ignored) and `BrowserArchivePolicy` (which
  Today tabs auto-archive: idle `archiveAfter` from `lastActiveAt`, never
  in a private or pop-up window, never linked tabs or start pages, the
  sleep policy's selection, pop-up, audio, capture and prompt exemptions).
  `BrowserArchiveStore.swift` — the only way in or out of
  `<support>/archive.json` (synchronous, atomic, `changes`; an unreadable
  file is kept as `.corrupt`): `archive(_:)` (a batch with one write and
  one `changes`; one entry per profile and address; the search index
  changes only for added and replaced entries — ⇧⌘K and the idle pass
  write through it), `archive(url:…)`, `insert(_:reason:)` (the importers'
  entry point), `removeEntry(url:profileID:)` (⇧⌘T brought the tab back),
  `search(_:inProfile:)` over an in-memory index, `remove(id:)`,
  `removeEntries(ofProfile:)` (profile deletion) and
  `removeEntries(ofProfile:archivedIn:)` (Clear Browsing Data ▸ History).
  `BrowserWindowManager+Archive.swift` — `archiveIdleTabs(now:)` (the idle
  pass's archive half) and `restoreArchived(_:preferring:)` (a Today tab in
  the entry's Space, else the profile's first; the window switches to it;
  a private window restores into a normal one).
- `Browser/BrowserSearchEngines.swift` — search engines, pure:
  `BrowserSearchEngine` (id, name, keyword, template with `%s` replaced by
  the percent-encoded query; the built-ins DuckDuckGo, Google and Bing keep
  their old ids, so `searchEngine` in `settings.json` still reads, and have
  no keyword unless the user gives one — `searchEngineKeywords`, by id —
  so "b tree" stays an ordinary search; `searchForm` is the start page's
  GET form) and `BrowserSearchEngines`, the one API the address field,
  Settings and the Command Bar share: built-ins plus `customSearchEngines`
  (bad entries, repeated ids and keywords dropped), the default (unknown
  falls back to DuckDuckGo), `engine(forKeyword:)`, `resolve(_:)` ("keyword
  query": a keyword followed by a query, never a bare word),
  `searchURL(engine:query:)` and the editing rules (`problem`, `save` — a
  built-in's keyword only —, `remove`, `setDefault`).
  `BrowserAddressResolver.resolve` tries a keyword first, then
  `address(for:)`, then the default engine; the dropdown's first row for a
  keyword is "Search <Engine> for …" (`.keywordSearch`).
- `Browser/BrowserHistoryStore.swift` — History, the only way in or out of it:
  `BrowserHistoryStore(directory:)` opens `<directory>/History.sqlite` (WAL;
  a damaged file is kept as `.corrupt`), migrates `history.json` once
  (`history.json.migrated`), records visits (`record(url:title:at:kind:)`, a
  repeat of the newest visit within 5 minutes merges), answers bounded,
  indexed reads (`suggestionCandidates(for:)`, `recentPages(limit:)`,
  `visits(matching:before:limit:)`, `visitCount(matching:)`), removes
  (`removePage(url:)`, `removeVisits(since:now:)`) and runs
  `runMaintenance(retention:)` (pruning plus a frecency refresh) on its own
  connection off the main thread. `BrowserHistoryDatabase.swift` holds the
  schema and SQL (`urls`, `visits`, FTS5 `urls_words` for word starts and
  `urls_trigram` for substrings), `BrowserSQLite.swift` the thin wrapper over
  the system `SQLite3` module, and `BrowserHistoryModel.swift` the pure parts:
  `BrowserVisitKind`, `BrowserFrecency`, `BrowserHistoryRetention`,
  `BrowserHistoryDays` (the sidebar's day headers) and
  `BrowserSameDocumentVisits` (when a `pushState` URL change becomes a visit).
- `Browser/BrowserPins.swift` — the pin model (stage 2's bookmarks):
  `BrowserPin`, `BrowserPinFolder`, `BrowserPinNode`, `BrowserPinTree` (one
  root with the fixed `rootID` per Space; pure insert, move — never into
  itself or a descendant, the index is the drop gap counted before the item
  leaves —, rename, edit, remove, `pins(url:)`, `entries()` with folder
  paths, `folderEntries`, `folderForNewPin(lastUsed:)`), the node coding
  (`"type": "pin"`; stage 2's `"bookmark"` reads too),
  `BrowserBookmarksFile` (stage 2's `bookmarks.json`, read once for the
  migration: version 2 `root`, version 1 lists newest first, bad nodes
  skipped, repeated ids dropped) and `BrowserPinOutline` (an outline's
  visible rows and where a drop lands). `BrowserSpaces.swift` —
  `BrowserSpace` (name, `BrowserSpaceIcon`, color mark, its own profile,
  pinned tree, `importedFrom`), `BrowserFavorites` (per Space, kept by its
  profile, at most 12), `BrowserArchiveAfter`, `BrowserSpaceList` (the
  pure operations: `create` refuses a profile another Space has,
  `isolate(known:)` separates Spaces that share a profile — the first
  keeps it, every other one moves to a new profile whose id is its own,
  a missing such profile is reported again —, `reconcile(with:)` gives
  every profile a Space and drops orphans) and `BrowserSpacesFile`
  (`spaces.json`, tolerant decoding). `BrowserSpaceStore.swift` —
  `BrowserSpaceStore`, the only way in or out of `spaces.json` (Space
  operations, per-Space pin operations with `inSpace:`, favorites with
  `ofProfile:`; `createSpace(…profiles:)` writes the Space, then its
  profile (id = the Space's); `insert(_:into:at:inSpace:)`, `adoptSpace`
  and `insertFavorite` are the importers' entry points; a missing file
  starts with one Space per profile and migrates `bookmarks.json` into
  Default's, kept as `bookmarks.json.migrated`; an unreadable one is kept
  as `.corrupt`; on load it isolates shared profiles once and lists
  `separations` / `separatedProfiles`) and `BrowserPinUIState` (expanded folders and ⌘D's last
  folder per Space in `UserDefaults`). `BrowserPinEditor.swift` is the
  Folio popover (⌘D, Edit Pin, Rename, New Folder) and its child
  panel; `BrowserPinOutlineCell.swift` a row of the rail's outline;
  `BrowserSpacesMenu.swift` the Spaces menu (stage 2's Bookmarks menu):
  every Space on ⌃1…⌃9 with the active window's checked, Next/Previous
  Space on ⌥⌘→/⌥⌘←, then the active window's Space's pin tree, rebuilt on
  every change (`dump` prints it). ⌃1…⌃9 and ⌥⌘←/⌥⌘→ are Arc's Space
  shortcuts; ⌘1…⌘9 stay tabs of the current Space.
- `Browser/Import/` — File ▸ Import Browser Data…. Readers, pure:
  `BrowserArcImportReader` (Arc's support folder; profiles a Space or
  favorites use, then History-only ones, never `__ARC_SYSTEM_PROFILE`),
  `BrowserChromiumHistoryReader` (`read`, `counts`),
  `BrowserChromiumCookieReader` (a profile's `Network/Cookies` or `Cookies`,
  `immutable`; unexpired, unpartitioned rows; `BrowserChromiumCookieCrypto`:
  `v10` AES-128-CBC under PBKDF2 of the "Safe Storage" password, the
  `host_key` SHA-256 prefix from meta version 24; `BrowserChromiumSafeStorage`
  reads that password from the login keychain — macOS asks the user —, only
  when an import with cookies runs, off the main thread),
  `BrowserChromeBookmarksReader` (the bookmarks bar's contents as the top
  level, Other/Mobile as folders, which the plan pins without a wrapper
  folder — `Folder.wrapsInFolder` false; `BrowserImportPlanner.merge`
  skips addresses the Space pins and puts a folder into the same-named one
  at its level, which keeps its id —; every Chromium browser:
  `BrowserImportSourceKind.chromiumFolder` names Chrome's, Brave's, Edge's,
  Vivaldi's, Chromium's and Aside's folder under `~/Library/Application Support`,
  `safeStorageService` its keychain item; the
  sheet lists Brave, Edge, Vivaldi, Chromium and Aside only when found, and a
  folder macOS won't let the app list is found after the readable ones and
  says why when chosen), `BrowserSafariExportReader`,
  `BrowserNetscapeBookmarks` (parse and write), the neutral model in
  `BrowserImportModel.swift`. `BrowserImportLoader` reads a source off the
  main thread; `BrowserImportPlan.swift` is the pure plan step
  (`BrowserImportPlanner`: each Arc Space a Space of its own; each Arc
  profile's home Space for its History and favorites — Arc `Default` →
  the Default Space, `Profile N` → the Space whose profile an import
  marked (`importedFrom` `arc:Profile N`, `profileSource`), else its first new Space, else
  a new one named after its first Space —; an untouched home (no pins,
  never imported) is taken over by the profile's first new Space;
  a Chromium browser with one profile goes into the target Space, one
  with several (or one an earlier import gave a home) gives each profile
  a home of its own, claimed in passes so profile order doesn't matter:
  the Space an import marked (`aside:Profile N`), then the Space named
  like the profile, then `Default` → the Default Space, else a new Space;
  a home found by name or as Default is marked when the import uses it
  (`BrowserProfileStore.markImported`). Its bookmarks folder, History
  and cookies go there, empty History is unchecked, and it has no Space
  menu;
  Spaces skipped by `importedFrom`, `retarget` for the Chrome/Safari/HTML
  Space menu, favorites past 12, Archive ids from Arc's item ids, History counts within
  Settings ▸ Remove history items; `BrowserImportColorMatch`, OKLab hue to
  the nearest Folio color); `BrowserImportChecklist` the sheet's rows and
  result lines; `BrowserImporter` the apply step (store writes on the main
  actor, every new Space with its own profile, then cookies through
  `Stores.setCookies` — `WKHTTPCookieStore.setCookies` of the home's data
  store, replacing same name/domain/path —,
  then History per home Space through `BrowserHistoryStore.importInBackground`:
  batches on a second connection, duplicates — same address and time —
  skipped, cancel between batches, frecency refreshed after).
  `BrowserWindowManager+Import.swift` plans and runs imports for a window
  (Today tabs unloaded, switch to the first imported Space), shows the
  sheets and holds `BrowserPinExport` (File ▸ Export Pinned Tabs…).
  `App/BrowserImportSheet.swift` is the sheet. `BrowserLinkRouting.swift`
  — the rules for links from other apps (`link-routing.json`, contains /
  equals / prefix → a Space or the most recent one), applied in
  `BrowserWindowManager.open(_:)` via `windowForOutsideLink`;
  `App/BrowserLinkRoutingSheet.swift` is Settings ▸ Links from other apps.
- `Browser/BrowserCommands.swift` — the command registry: `BrowserCommandID`
  (the stable ids `settings.json`, menu item identifiers and the harness
  use) and `BrowserAppCommand.all`, one row per command in menu order
  (title, menu and section, default shortcut, synonyms, symbol, state and
  action closures over `BrowserCommandContext`; standard AppKit commands
  carry their responder-chain selector and a fixed shortcut).
  `App/MainMenu.swift` builds every menu item from it (identifier = id,
  `runCommand:`), re-applies the keymap when settings change and validates
  through the row's state; the Spaces menu takes its Space items' shortcuts
  from `space-1`…`space-9`. `BrowserShortcuts.swift` is the pure part:
  `BrowserShortcut` (`"shift+cmd+c"` / `⇧⌘C`, from an `NSEvent` or a page's
  `KeyboardEvent.code`), `BrowserShortcutPriority`, `BrowserShortcutSettings`
  (`shortcuts` in `settings.json`, decoded entry by entry, only differences
  saved; a decoded remap onto a fixed or reserved key is dropped and of
  two commands on one key the later gets none), `BrowserKeymap` (effective
  shortcuts, conflicts, swap, reset; `BrowserShortcut.reservedOwner` refuses
  the Edit menu's Spelling keys, ⌘`, ⌃⌘Space, ⇧⌘/, the Cocoa text-editing
  bindings and Vimium's ⌃E/⌃Y/⌃[),
  `BrowserShortcutGate`, `BrowserRecentTabs` / `BrowserRecentTabSwitcher`
  and `BrowserRailWalk`. Priority mechanism: `BrowserWebView.performKeyEquivalent`
  (and `keyDown` for ⌃/⌥ keys and F1–F12) calls `routePageShortcut` while the page has
  focus — AppKit offers key equivalents to the window's views before the
  menu. App wins runs the command there. Site wins and Press twice let
  WebKit send the key to the page; WebKit hands back a key the page left
  unhandled by sending the same `NSEvent` again (`forwardedKey`), and the
  isolated-world `BrowserShortcutScripts.keyReport` posts each modified
  or function-key `keydown`'s `defaultPrevented` on the `sopranoWeb` channel; the first
  answer decides, the late one is swallowed. Forwarded presses are
  tracked per event (a token each), so key repeat and Press twice races
  never run a command twice; `BrowserWindow.performKeyEquivalent` checks a
  handed-back event before any view or the menu, wherever focus went. A
  hand-back runs a Site wins press however late; the report matches by
  `KeyboardEvent.code` (the physical key), so on another layout it may not
  match and the hand-back decides. `App/BrowserShortcutsSheet.swift`
  is Settings ▸ Keyboard shortcuts.
  `BrowserCommandBar.swift` — the Command Bar's pure results
  (`BrowserCommandBarEngine`: the default row — keyword search, address or
  default-engine search —, open tabs, pins and favorites and History
  ranked by `AddressSuggestionEngine.rankedPages` (the address bar's tiers
  and frecency), Spaces, `/` actions and settings pages by prefix >
  word start > substring; site search's engine for Tab).
  `BrowserCommandBarView.swift` — `BrowserCommandBarController` (state and
  keys) and the Folio panel, a view over the window's content (never a
  window of its own). `BrowserWindowController+CommandBar` (sources,
  choosing a row) and `+Shortcuts` (copy URL / Markdown on
  `manager.pasteboard`, ⇧⌘D's `toolbarHidden` in `UserDefaults`, the rail
  walk, ⌃Tab's switcher with `BrowserRecentTabsOverlay`: cards with
  `BrowserTab.preview` (`BrowserTabPreview`, a JPEG at the widest card's
  width, 220 pt, taken by `captureTabPreview` while a page is on screen —
  wherever a page leaves it: `applyPaneLayout` before it hides a web view,
  `leavePage`, `detachTab`/`detachTabs`, `openMiniPlayer` — and for the
  shown pages when the switcher opens; a capture answering after the next
  main-frame commit (`previewDocument`) or after the tab slept is dropped,
  and a commit drops the preview; a tab never shown falls back to its
  sleep snapshot, else its favicon; closing the switcher drops its cards),
  key routing).
  A private context keeps its pages in `BrowserSessionVisits` (memory
  only) for its Command Bar.
- `Browser/BrowserDataStores.swift` — downloads JSON
  (`{version, entries}` envelopes, lossy decoding; a private window's download
  rows carry `privateContextID` and stay in memory; a row's bytes, size and
  speed are in memory only, from `BrowserDownloadManager`'s 0.25 s progress
  timer through `updateProgress`, which notifies on half a percent, a new
  size or new bytes after a second); `BrowserDownloadProgress.swift` (pure:
  `BrowserDownloadRate`, a running average of samples ≥ 0.5 s apart, and
  `BrowserDownloadProgressText`, "12 MB of 45 MB · 2 min left" for the
  sidebar's rows and the rail's);
  `BrowserSitePermissionStore.swift` — per-host decisions and values
  (`site-permissions.json` in each profile's folder; `init(overlaying:)` is a
  private window's in-memory layer, `forget` shadows a saved value there);
  `BrowserZoom.swift` — zoom steps, `siteKey(for:)` (http(s) host or
  `file`), per-host `zoom`/`setZoom` and `keepsAwake`; `BrowserFavicon.swift` — favicon
  selection, fetch and shared cache (`init(inMemoryOver:)` writes no files).
- `Browser/BrowserTabSleep.swift` — `BrowserTabSleepAfter` (the setting),
  `BrowserMemoryPressure`, `BrowserTabSleepPolicy` (exemptions and idle
  thresholds, pure) and the page-world `sleepGuard` script (`beforeunload`,
  edited fields, screen capture). `BrowserTabSleeper.swift` — the manager's
  idle timer (`idlePass`: archive idle Today tabs, then sleep) and memory
  pressure source (`now` and `thresholdOverride` are the harness's clock
  and test sleep threshold). `BrowserWindowController+Sleep`
  — `sleepCandidate`, `sleepTab` (snapshot, then `finishSleeping`: state into
  `lifecycle.pendingRestore`, `replaceWebView(of:)` swaps in an empty web
  view), wake snapshot overlay, `promptBegan(for:)` (dialogs keep a tab
  awake), `tabWasUsed`, Keep This Site Awake. Waking is
  `loadRestoredTabIfNeeded` (selection, CLI, `attachTab` into another
  window, `navigate`). `BrowserWindowController+Zoom` — ⌘+/⌘-/⌘0 per site,
  `siteZoom(for:)` (applied on commit), `applySiteZooms` (store or default
  changed) and the address-field chip.
- `Browser/BrowserFilterConverter.swift` — Adblock Plus / EasyList filters
  to WebKit content rules (pure, our own MIT code): network filters and
  options, `@@` exceptions (`$document`/`$elemhide`/`$generichide` become
  `ignore-previous-rules` with `if-top-url` in the lists they apply to),
  element hiding (generic selectors batched into `css-display-none` rules,
  `domain##` with `if-domain`, `#@#`), and `BrowserFilterSkipReason` for
  what WebKit can't express. Each network list ends with a rule that lets
  top-level pages through. `BrowserContentRule.swift` — the rule, its JSON
  and `BrowserRuleChunker` (≤150,000 rules per list, exceptions copied into
  each list). `BrowserContentRuleRegex.swift` — the check every emitted
  `url-filter`/`if-top-url` passes (WebKit's `URLFilterParser` subset).
  `BrowserFilterLists.swift` — the sources (EasyList, EasyPrivacy), the
  conditional fetcher and `content-blocking.json`.
  `BrowserContentBlocker.swift` — the manager-owned blocker: launch looks
  up the last compiled lists (`WKContentRuleListStore(url:)` in
  `<support>/ContentBlocking/`), downloads when on and stale (7 days;
  checked at launch and daily), recompiles only changed text under new
  identifiers, bisects a list WebKit rejects (`compileBisecting`), and
  publishes `activeLists` through `changes`. `BrowserWindowController+ContentBlocking`
  — `applyContentBlocking(to:pageURL:)` (every new web view, then each
  main-frame navigation, redirect and commit), `applyContentBlockingToTabs`
  (setting and list changes: no reload; the site switch: reloads the
  site's tabs) and the Site Control Center's "Block ads on this site" row
  (`BrowserSiteBlockingAccessory`).
  `BrowserContentBlockingPolicy` documents why a switched-off site loses
  the lists per tab instead of getting a compiled exceptions list.
- Site Control Center (stage 4 P6): `BrowserSiteControl.swift` (pure:
  `BrowserSiteDataTarget` — "Clear site data" removes WebKit's records whose
  name is the host or a domain above it, minus cookies, plus the cookies of
  exactly that host; IPs and `localhost` match only themselves —,
  `BrowserSiteChoice` Ask/Allow/Block, `BrowserSiteControlState` and its
  `lines`), `BrowserSiteControlView.swift` (the Folio popover body and its
  borderless child panel), `BrowserWindowController+SiteControl.swift`
  (`siteControlTab` = `pageTab`: the Peek's, else the focused pane;
  `siteControlState(for:)`, the lock's `toggleSiteControl`,
  `setSitePermission` into the tab profile's `sitePermissions` — a private
  window's overlay —, zoom through `zoomIn/zoomOut/resetZoom`, extension
  site access through `BrowserExtensions.setSiteAccess/setSite`,
  `clearSiteData(of:)`, and `browser site`). The Connection row opens
  `showConnectionDetails(for:)` (`+SignIn`: the old lock sheet). No per-site
  autoplay: WebKit fixes it per web view. Harness: `--site-control` puts the
  popover under the lock offscreen, captures it and prints `site-control:`
  lines; `--security-info` presses its Connection row (`--sheet` prints
  the sheet). CLI: `browser [--tab n] site [info|clear|permission
  <camera|microphone|notifications|popups> allow|deny|ask]` (`clear` asks
  nothing). Actions resolve the host at action time
  (`siteControlHost(of:)`, which also covers a certificate interstitial),
  zoom acts on the popover's own tab, and `updateChrome` closes the popover
  when its tab stops being `pageTab` (`updateSiteControlPanel`). Harness
  helpers that press a popover control keep the view alive
  (`withExtendedLifetime`): the controls' targets are weak.
- Boosts (stage 4 P7): `BrowserBoosts.swift` (`BrowserBoost`: host, name,
  enabled, css, js, zaps; `key(_:)` lowercases, drops trailing dots and one
  leading `www.` — a host matches itself and its `www.` form, never other
  subdomains; `BrowserBoostStore`, manager-owned `manager.boosts`,
  app-wide `<support>/boosts.json` as a `JSONList`, a bad entry skipped,
  an unreadable file kept as `.corrupt`, `changes` →
  `BrowserWindowController.boostsChanged()` in every window).
  `BrowserBoostScripts.swift`: user scripts marked `/* soprano-web:boost */`
  in the `SopranoWebBoost` content world — deliberately not a
  `BrowserPageScript.World`, so it has no `sopranoWeb` handler and user
  code can't post as ours. Every script starts with `hostGuard` (user
  scripts can't be host-scoped; it declares no name, so Boost code may use
  any). CSS and zaps go into one constructed `CSSStyleSheet` (the Boost
  world's `window.__sopranoWebBoostSheet`) in `document.adoptedStyleSheets`
  at document start: a page's CSP `style-src` blocks an added `<style>`
  even from an isolated world, not a constructed sheet; adopted sheets
  cascade after the page's own; `replaceSync` drops `@import`; each zap is
  its own `insertRule` (`hidingRule`), so a bad selector drops only
  itself; a page that assigns `document.adoptedStyleSheets` without
  keeping the old ones gets the sheet back at DOMContentLoaded, load and
  pageshow (`__sopranoWebBoostSheetEnsure`).
  JS runs at document end, main frame only.
  `refreshStateScripts` swaps state and Boost scripts together (both
  `removeAllUserScripts`), so every tab — private, Peek, panes, Little Arc —
  gets them; `applyBoostStyle(to:)` re-runs the style script on open pages
  (CSS/zaps live; JS waits for the next load, the editor says so). Zap mode
  (`startZap`, `zapStart` in the trusted isolated world, listeners on
  `window` in the capture phase) posts `zapPick` with the element's
  ancestor path and `zapEnd` on Esc; a commit in its tab
  (`zapPageCommitted`) or another page tab (`updateZapSession`) ends the
  session, and `recordZap` only records for the session's host.
  `BrowserZapSelector` builds the selector (nearest stable id, else
  `body >`; tag, up to two stable classes, `:nth-of-type` when needed;
  `escape` follows `CSS.escape`).
  `BrowserBoostEditor.swift`: the sheet (`showBoostEditor`, from the Site
  Control Center's Boost row and `/boost` = `edit-boost`; `zap-elements`
  too; Save is ⌘↩ so ↩ stays a newline). CLI `browser boost list|show
  <host>|css <host> <file|->|js <host> <file|->|zap <host>
  <selector>|enable|disable|remove <host>`, routed at manager level
  (`BrowserBoostCommands`); `parseBoost` reads the file (relative to `PWD`)
  or the CLI's own stdin for `-` and sends the text (refused client-side
  above the socket's 16 MB; hosts ASCII/punycode only).
  Harness: `--boost-css`, `--boost-js`, `--boost-zap` (repeatable) seed a
  Boost for the `--url` host before it loads and print `boost:` lines
  (the sheet's rule bytes and whether the document adopted it, title, body
  background); `--boost-editor` opens the editor (`--sheet` draws it).
- Capture (stage 4 P8): `BrowserCapture.swift` (pure:
  `BrowserCaptureGeometry.areaRect` — the drag in the web view's own
  points, normalized, clipped, snapped outward, nil for a click; `fullPage`
  — the PDF rect is the document from its top in CSS px × `pageZoom`, the
  scroll offset plays no part, a page over `maxPixelLength` (16,384 px)
  drops toward 1× and is then cut; `BrowserCaptureFile` — `Soprano Capture
  <yyyy-MM-dd> at <HH.mm.ss>.png`, ` (2)`… when taken).
  `BrowserCaptureRenderer`: an area or the viewport through `takeSnapshot`
  (its rect must stay inside the view) drawn into a bitmap at the window's
  backing scale; the full page through `createPDF` with the rect set to the
  document size (read in `.defaultClient`), rasterized off the main actor
  (`rasterize`, pages stacked) and encoded with ImageIO.
  `BrowserCaptureOverlay` (flipped, pinned to `pageTab`'s web view, so its
  points are the web view's): scrim, the drag undimmed with a size badge,
  a Folio hint bar with Full Page and Cancel; Esc / right click cancel.
  `BrowserWindowController+Capture.swift`: `toggleCaptureOverlay` (⇧⌘2 =
  `capture`, File ▸ Capture…, `/capture`), `updateCaptureOverlay` from
  `updateChrome` and the Peek's page-tab refresh (another tab, pane, Space
  or Peek closes it), `capture(_:of:)` → `deliverCapture` (the manager's
  pasteboard as PNG, then a unique file in `downloadDirectoryURL`) →
  `BrowserCaptureToast` (ImageIO thumbnail; click → Finder). Private
  windows capture too. CLI `browser screenshot [--full] [--] <path>`
  (`parseScreenshot` pulls options out before resolving the path; `--full`
  gets a 60 s timeout). Harness (`SnapshotCommand+Capture.swift`, after the
  other flags, on the captured window's page tab): `--capture-area
  x,y,w,h`, `--capture-visible`, `--capture-full` capture as the overlay
  would and print one `capture:` JSON line (file and its pixel size read
  back, pasteboard PNG bytes, toast text, scale); `--capture-drag x,y,w,h`
  drags into the overlay with mouse events; `--capture-overlay [x,y,w,h]`
  leaves the overlay open (that selection drawn) for the PNG. Files land in
  the harness's download folder (its temporary support folder; use
  `--support-dir` to keep them).
- Mini Player and media controls (stage 4 P9): `BrowserMedia.swift` (pure:
  `BrowserMediaReport` — one frame's `mediaInfo`, capped text, artwork only
  http(s) or `data:image/` —, `BrowserTabMediaInfo` — the main frame's report
  wins, else the latest playing frame; only a main-frame video counts as
  visible —, `BrowserMiniPlayerRule` — open only for a playing visible video
  leaving the screen, never a Peek's, a pane still shown, a pop-up window or
  with Settings ▸ "Mini Player for videos" (`miniPlayer`) off; private
  windows may —, `BrowserMiniPlayerFrame`, `BrowserMediaTabChoice`,
  `BrowserMediaAction`). `BrowserMediaScripts.reporter` (isolated world,
  every frame) posts `mediaInfo` debounced on media events, scroll and resize
  and each second while playing (Media Session metadata has no event); it
  reads `navigator.mediaSession` and calls the page's handlers with WebKit's
  `callActionHandler` from the isolated world (verified: the harness's
  `next` reaches the page's handler) and defines `__sopranoMediaControl`
  and `__sopranoMiniPlayer` (the fill style: a constructed sheet + an
  attribute on the video). `BrowserMiniPlayer.swift` (manager-owned
  `manager.miniPlayer`, one app-wide; `BrowserMiniPlayerPanel`: titled,
  hidden-titlebar, non-activating floating panel on every Space;
  `miniPlayerFrame` in the manager's defaults, saved on user moves only and
  never for a private tab), `BrowserMiniPlayerView.swift` (hover controls:
  Back to Tab, title, Close = pause + return, play/pause),
  `BrowserMediaControlsView.swift` (`.rail` bar above the switcher in the
  rail's footer stack, `.toolbar` chip before the capture mark when there is
  no rail). `BrowserWindowController+Media`: `handleMediaInfo`,
  `mediaControlTab` (an off-screen or Mini Player tab with media, playing
  first), `performMediaAction` (every media frame), `miniPlayerLeaving`
  (from `showSelectedTab` and `leavePage`), `openMiniPlayer` /
  `returnMiniPlayer` (back into the page area via `installWebView`) /
  `releaseMiniPlayer` (from `unbindTab`: close, move, replace, window
  close). Only the `NSView` moves; the tab stays bound. `applyPaneLayout`
  touches only web views in `webArea`, `leavePage` skips the panel's,
  sleep and archive exempt it (`.miniPlayer`). CLI `browser [--tab n] media
  [info|play|pause|next|previous|mute]` (the controls' tab, else a selected
  tab with media). Harness (`SnapshotCommand+Media.swift`): `--media-seed
  [file|url]` (before the window flags; without a value a built-in page with
  ffmpeg's test pattern MP4 when ffmpeg is installed — WebKit draws no
  canvas `captureStream` frames off screen — Media Session metadata,
  artwork and next/previous counters `window.__next`/`__previous`), then
  e.g. `--cli "select-tab 1"`; `--mini-player [return|close]` presses the
  panel's buttons and prints `mini-player:`; `--print-media` prints one
  `media:` JSON line (each tab's state, exemptions, back list, fill size,
  page counters, rail/toolbar items, the panel's delegates); the capture
  draws an open panel with its controls where it sits over the window.
- Reader and Translate (stage 4 P10): `Resources/Readability/` vendors
  Readability.js and Readability-readerable.js 0.6.0 unmodified with their
  Apache-2.0 `LICENSE`, `NOTICE` (from upstream main; added after 0.6.0),
  `LICENSE-2.0.txt` and `VERSION`; `Package.swift` copies the folder into
  the resource bundle (`AppResources.bundle`, subdirectory `Readability`)
  and `scripts/package-app.sh` refuses a bundle without the two scripts,
  `LICENSE` and `NOTICE`. `BrowserReader.swift`: `BrowserTabReader`
  (`isReaderable`, the shown article), `BrowserReaderScripts.pageInfo`
  (isolated world, main frame, document end + `load`: posts `pageInfo
  {readerable, lang, sample}` with `isProbablyReaderable` and 3,000
  characters of text), `enterSource` (Readability on
  `document.cloneNode(true)` with an element serializer; the article,
  cleaned of scripts, `on*` attributes and `javascript:` links, goes into
  a new `<html class="soprano-reader">` swapped in for the page's root,
  styled by a constructed sheet in Folio tokens — `css(theme:)` — that
  replaces `adoptedStyleSheets`), `leaveSource` (puts the page's own
  root, sheets and scroll back: no reload, no history entry),
  `themeSource`, `commitSource` (every main-frame commit: a page from the
  back-forward cache comes back as itself and reports again).
  `BrowserTranslation.swift`: `BrowserTabTranslation` (language, phase,
  generation), `BrowserLanguageDetector` (`NLLanguageRecognizer`,
  confidence ≥ 0.5 and ≥ 40 letters, else `<html lang>`),
  `BrowserTranslationOffer` (offered when the language code isn't one of
  `Locale.preferredLanguages` nor on Never Offer; target = the first
  preferred language), `BrowserTranslationBatches` (≤ 40 strings, ≤ 4,000
  characters), `BrowserTranslationService` (`BrowserSystemTranslationService`:
  `LanguageAvailability` and `TranslationSession(installedSource:target:)`
  only — a pair not downloaded opens System Settings ▸ General ▸ Language &
  Region, whose Translation Languages… downloads it; tests set
  `controller.translationService`). `BrowserTranslationScripts`: collect
  rendered text nodes (no code, form fields, editable, `translate="no"`,
  `.notranslate`, hidden), apply (keeps edge white space, skips nodes the
  page changed), restore. `+Reader` / `+Translate`: commands `reader`
  (⇧⌘R, View, "Show/Hide Reader", enabled only with an article) and
  `translate-page` ("Translate Page"/"Show Original"), the address field's
  Reader and Translate chips (Translate's menu: Translate to …, Show
  Original, Never Offer for …), `neverTranslateLanguages` in Settings
  ("Never offer to translate"; a private window keeps its own in memory,
  `savesTranslationChoices`). A translated page shown in Reader is
  translated again there. CLI `browser [--tab n] reader [on|off]` and
  `translate [to <lang>|off]` (the page tab, a Peek's too; `to` may take
  120 s). Harness (`SnapshotCommand+Reader.swift`, after the wait):
  `--reader` shows Reader before the capture and prints `reader:` lines
  and its DOM; `--translate <lang>` prints `translate: before/after` text
  and the result (a missing pair names System Settings).
- Live folders (stage 4 P11): `BrowserLiveFolders.swift` —
  `BrowserLiveFolderSource` (`githubPullRequests(repo:)` → `gh pr list
  --repo … --state open`, `githubSearch(query:)` → `gh search prs`, the
  query split into words with `--` before them when one starts with "-";
  `parse` reads `owner/repo`, a github.com link or a search),
  `BrowserPullRequest.decode` (`gh`'s JSON, https URLs only),
  `BrowserLiveFolderError` (missing `gh`, signed out, timeout, `gh`'s
  first stderr line), `BrowserGitHubCLI` (finds `gh` in the Homebrew and
  user tool folders a GUI app's PATH lacks, runs it off the main thread
  with a 30 s limit, after Soprano Git's `GitRunner`) and
  `BrowserLiveFolders` (manager-owned, `manager.liveFolders`: a state per
  live folder of every Space, reconciled on `spaces.changes`; fetched
  every 5 minutes and when a folder opens or its preview shows, unless
  the last fetch is under 30 s old; a failure keeps what was shown;
  memory only; `display(_:)` puts the pull requests, with ids derived
  from folder and address, before the folder's own children). A live
  folder is a `BrowserPinFolder` with `source` (saved as `"type":
  "folder"` plus `source`, so older builds read a plain folder); nothing
  moves into it (`canMove`, `folderEntries`, `folderForNewPin`).
  `BrowserWindowController+LiveFolders`: `displayPinTree` (the rail, its
  folder preview, Open All in Tabs; edits use `currentPinTree`),
  `openLiveItem` (a Today tab, the one already on it if any, via
  `openPin`), New / Edit Live Folder… in the pin editor. The Spaces menu
  and the start page show `display(_:)` too. The harness and tests never
  run `gh` unless asked: the harness puts its own fetch in (`--live-fetch
  gh` uses the real one), the tests inject one, and only an on-screen
  manager starts the 5-minute timer. CLI `browser
  live-folders` (every Space's live folders with state and pull
  requests), `browser [--window n] live-folder add <owner/repo|link|query>`
  (in the window's Space, answers after the fetch) and `live-folder
  refresh`. Harness (`SnapshotCommand+LiveFolders.swift`): `--live-folder
  "<name>|<source>"` (repeatable, Default's Space, before the first
  window), `--live-fetch <file|gh|signed-out|no-gh>` (what a fetch
  answers: `gh`'s JSON from a file, the real `gh`, or a failure; without
  it nothing is fetched), `--live-refresh`, `--live-open <title>`,
  `--live-folder-editor new|<name>` (drawn) and `--print-live-folders`
  (`live-folders:` and `live-row:` lines); `--expand-folder` opens live
  folders too.
- `Browser/Extensions/` — Chrome extensions on `WKWebExtension`.
  `BrowserExtensions.swift` (manager-owned, `manager.extensions`): the one
  app-wide `WKWebExtensionController` (fixed storage identifier; the
  harness's is a throwaway one emptied at exit — on macOS 26 a
  `.nonPersistent()` controller's extensions get no events),
  `makeTabConfiguration` puts it on every tab, private ones too (WebKit
  runs an extension in a private tab only with `hasAccessToPrivateData`);
  contexts load with `chrome-extension://<id>/` and `uniqueIdentifier` =
  id, saved grants restored first, background started at once; install
  (Web Store id or link, or an unpacked folder, copied first, its id read
  from the copy), enable, private access, site access, remove (with its
  data), the hourly-timer daily update check, extension commands. Grants:
  a new extension gets what it asks for (Settings shows the list first
  through an `InstallConfirmation`; the CLI prints it), an update nothing
  new (`applyUpdate`; what it newly asks for is `pendingAdditions`, asked
  in the permission sheet once it loads), `file:` patterns never
  (`isFilePattern`; WebKit on macOS 26 runs no content script on `file:`
  pages even with `file:///*` granted). The same id from another source
  (a folder with a store extension's `key`) is refused without
  confirmation and otherwise starts over with its data deleted.
  `BrowserExtensionStore.swift` — the
  only way in or out of `extensions.json` (tolerant, atomic, `.corrupt`)
  and `<support>/Extensions/<id>/`. `BrowserCRX.swift` — extension ids,
  CRX3 parsing and Chrome's store-install verification (every RSA/ECDSA
  proof over the signed message, a key hashing to the id, the Web Store
  publisher key). `BrowserExtensionArchive.swift` — the ZIP read once
  (one end record at the very end, local headers matching the central
  directory, no overlaps, symlinks, escapes, duplicates, file/folder
  clashes, encryption, ZIP64) and unpacked in process from that reading
  (`openat`/`mkdirat` without following links, deflate through the
  Compression framework under a running 256 MB cap, CRC checked), the
  result walked again, manifest checks. `BrowserWebStore.swift` — inputs,
  download/update-check URLs, allowed hosts, downloads streamed under the
  size cap, the `gupdate` answer. `BrowserExtensionAdapters.swift` —
  `WKWebExtensionTab`/`WKWebExtensionWindow` over real tabs and windows
  (a window's tabs of every Space) and the lifecycle calls the windows
  make (`tabAttached`/`tabDetached`/`tabClosed`, activation, properties,
  `windowOpened`/`windowClosing`/`windowFocused`).
  `BrowserExtensions+Delegate.swift` — the controller delegate (new tabs and
  windows, options page, permission prompts, action, native messaging
  hosts: each `NativeHost` has an allowlist of extension ids checked before
  its handler; anything else answers as Chrome does, "host not found"),
  and the gates: `pageLoad` decides every load an extension starts
  (`tabs.create`/`update`, `windows.create`, its popup's links, its page in
  a tab navigating away: web, `about:`, `data:` and its own pages load,
  another app's link asks through `openExternalLink(_:fromExtension:in:)`,
  `file:`, scripts and other extensions' pages never), `mayShowPage` which
  page navigations may swap a tab into an extension's web view (only that
  extension's own frames; `allowsExtensionNavigation` in
  `+Extensions` applies both in `decidePolicyFor`). `BrowserExtensionShims.swift` — the stand-ins for Chrome APIs
  WebKit lacks or gets wrong: a data-driven table (stand-in name → the
  manifest permission or key that asks for it) decides which extensions get
  `soprano-shim.js` (`BrowserExtensionShimScript.swift`), put first in the
  installed copy's worker (`import` for a module, `importScripts` after "use
  strict" for a classic one), background scripts and every HTML page,
  after the CRX3 check, at install, update and (when the stamp
  `.soprano-shim` differs) load; `nativeMessaging` is added when missing
  (`.soprano-added`). The record's `standIns` lists what the copy carries:
  `BrowserExtensionNativeHost.swift` answers the shim's
  `sendNativeMessage("soprano", { api, args })` only for those (notifications
  through `BrowserNotificationCenter`, `clients.pages`) and sends events over
  the background's `soprano.events` port (held, and the worker woken, while
  it is closed); `BrowserExtensionSocket.swift` runs a worker's WebSocket
  (`soprano.socket` port; WebKit's never returns in an extension worker)
  under `BrowserExtensionSocketPolicy`: the manifest's `connect-src`,
  local and private hosts only with host access, 64 per extension.
  Add a stand-in only for a failure `browser extension errors` names, with
  its trigger in the table. `BrowserExtensionPopup.swift` (popups in our own
  popover, sized to the page's max-content), `BrowserExtensionPermissionSheet.swift`,
  `BrowserExtensionCommands.swift` (the CLI). `BrowserWindowController+Extensions`
  — the toolbar's one Extensions button (`updateExtensionsButton`, shown
  while an extension runs in the window) and its menu (`extensionsMenu`:
  a row per extension with icon and badge runs its action, an Options
  section with each extension's own menu items and options page, Manage
  Extensions…; every popup hangs from the button, `extensionsAnchor`), the
  Command Bar's extension rows and which web view an extension page needs
  (`webViewFits`: a tab swaps its web view going to or from one). WebKit
  puts extensions' context-menu items into the page menu itself.
  `App/BrowserExtensionsSheet.swift` is Settings ▸ Extensions; the
  Extensions menu is built in `MainMenu.swift`.
- `Browser/BrowserPageScripts.swift` — every injected page script and the
  `sopranoWeb` message channel; messages are accepted only from the world (page or
  isolated) their type was written for.
- `Browser/BrowserToolbarView.swift`, `BrowserAddressBarController.swift`,
  `BrowserAddressSuggestions.swift`, `BrowserTabStripView.swift` (favorite
  and pinned tabs first, icon-only), `BrowserVerticalTabsView.swift` (the
  rail: Space header, Favorites, the pinned outline, Today with "+ New
  Tab", the switcher), `BrowserRailPinsView.swift` (the Favorites grid and
  the pinned outline with its drag and drop), `BrowserRailSpaceSwitcher.swift`
  (the switcher — Downloads at its leading edge, as in Arc; the toolbar's
  Downloads button hides while the rail shows the switcher
  (`updateDownloadsButtonPlacement`) and stays in windows without one:
  horizontal tabs, a collapsed rail, private windows —, the "Today" head,
  `BrowserSpaceIconDrawing`), `BrowserRailDownloadsView.swift` (downloads in
  progress at the rail's bottom, over the switcher, as in Arc: the newest
  three, a click shows the Downloads sidebar, × cancels),
  `BrowserPinFolderPreview.swift` (a folder's hover preview with search),
  `BrowserSpaceSheet.swift` (New Space / Edit Space), `BrowserTabButton.swift`,
  `BrowserTabDragSession.swift` (a tab's system drag session and drop marker),
  `BrowserTabReorder.swift` (drag and drop index math),
  `BrowserSidebarView.swift` (History, Archive and Downloads), `BrowserFindBar.swift`,
  `BrowserStartPage.swift`, `BrowserErrorPage.swift` — chrome and local pages.
- `Browser/BrowserAutomationCommand.swift`, `BrowserAutomationSocket.swift`,
  `BrowserAutomation.swift` — the `browser` CLI over a user-only Unix socket and
  the `@e1` snapshot/action scripts. `browser vimium <keys>` feeds the selected
  tab's Vimium controller for verification. `browser extensions` lists the
  installed extensions (state, private, site access, source, error count);
  `browser extension install <store link|id|folder>` (waits until it runs,
  up to 120 s; prints a `can:` line with what the extension may do and,
  for an update that asks for more, what waits for the user's answer in
  the app; refuses an id installed from another source),
  `enable|disable|remove|errors <id>`, `update` (check the
  Web Store now) and `action <id> [png]` (runs its Extensions-menu row in the
  default window; prints the popup's address, size and text and saves its
  capture, or "no popup") drive them. `errors` includes the background's
  uncaught exceptions and the console errors WebKit records.
- `Browser/BrowserWebInspector.swift` — WebKit's Web Inspector in the app
  (View ▸ Show Web Inspector, F12; WebKit's own "Inspect Element" in the
  page's context menu). Private WebKit API, each selector checked before
  it is called so a macOS without it hides the command instead of
  crashing: `makePreferences` turns on `_developerExtrasEnabled` for every
  tab, and the command shows or closes `_inspector` (`_WKInspector`) of
  the page the user looks at (a Peek's). Docked, WebKit adds the
  inspector's web view to the page's superview and sets both frames from
  the superview's bounds, again on every change of the page's frame
  (window resize, the inspector's divider, its dock side). The page area
  and the Peek's panel are `BrowserInspectorHostView`s: when WebKit adds
  the inspector there, the page (`BrowserWebView.inspectorDidDock`) sets
  its constraints to the superview aside and is laid out by frame,
  resizing with the superview so WebKit lays both out again; when WebKit
  takes it out (closed, its own window) the constraints come back. A split
  pane can't dock (WebKit would span the whole page area): its inspector
  goes to its own window, also when a docked page becomes a pane. WebKit
  saves "own window" whenever it is detached, so after the app moved a
  pane's inspector the next F12 on a whole page docks it again
  (`redockOnNextShow`; `attach` docks at the bottom). The docked inspector
  hides and shows with its page (and docks hidden beside a hidden one),
  leaves visible, and closes when the page moves to another superview
  (another window, a Peek, the Mini Player). Bare function keys are
  in-app shortcuts only: the global New Little Arc shortcut still needs
  ⌘, ⌃ or ⌥ (`BrowserGlobalShortcut.isAcceptable`).
  `browser devtools [show|hide|toggle|dock|window]` drives it and prints
  `docked`, `window` or `hidden`; the snapshot harness draws a docked
  inspector beside its page or the Peek's (`--page-key f12`). `isInspectable` stays on,
  so Safari ▸ Develop still reaches every tab, extension popup and
  background page.
- `Browser/VimiumController.swift`, `VimiumKeyMap.swift`, `VimiumPageScripts.swift`,
  `VimiumPanels.swift`, `BrowserWebView.swift` — the native Vimium mode layer.
- `Browser/BrowserSettingsWebPage.swift` — Settings as a page in a tab
  (`soprano-web://settings`, Chrome's model; the window is gone): the HTML
  (sidebar of sections, Search settings, cards of rows; `data-switch`,
  `select[data-key]`, `data-open` sheets, `data-command` actions), its
  state (`state`: values, menus, facts, the theme as CSS variables) and
  its boundary: `acceptsMessage` (only the page's own main frame),
  `Message` (the `{type: "settings", action}` messages) and `apply` (every
  key and value checked; a value a setting doesn't offer changes
  nothing). `BrowserStartPageSchemeHandler` serves it beside the start
  page; `BrowserAddressResolver.isStartPage` is false for it, so it is a
  normal tab (address, title, session, Command Bar; History and the
  Archive keep only web pages; `<html translate="no">` keeps Translate
  off). A web page can't reach any `soprano-web:` page: `createLinkWebView`
  refuses one as a new tab or window, and `decidePolicyFor`
  (`allowsAppPageNavigation`) lets a main-frame navigation to one through
  only when the app asked for exactly that address (`BrowserTab.appPageLoad`,
  set by `navigate`, `loadStartPage` and a history restore), on back,
  forward or reload, or from such a page itself — never a frame, a page's
  link or script, or a window a page opened and then navigates. `BrowserWindowManager+Settings.swift` —
  `showSettings(page:)` (the current Space's Settings tab of the most
  recently active normal window, else a new one; a page other than General
  opens its sheet over it), `handleSettingsMessage` (the page gets the
  whole state back after each message), `refreshSettingsPages` (settings,
  content blocker and theme changes), `openSettingsSheet` (search engines,
  shortcuts, websites, website data, links from other apps, extensions,
  Clear Browsing Data, Import; in the harness only recorded in
  `settingsSheetRequests`), the download folder panel and the New Little
  Arc shortcut recorder (`shortcutRecorder`, a key monitor bound to its
  Settings tab: it ends, and the old hotkey comes back, once that page
  isn't the window's page — another tab, a navigation, the tab or window
  closing, the window losing focus; `updateChrome` checks it). Harness: `--settings` opens the tab, `--click-element` clicks
  its controls (`'[data-switch=restoreSession]'`, `'[data-open=extensions]'`),
  `--settings-search <text>` types into its search, `--print-settings`
  prints `settings-page:` (what the page renders: switches, menus, facts,
  visible sections and rows, the sidebar's current section),
  `settings:` (`settings.json`), `settings-sheets:` and `settings-recorder:
  on|off`; `--url
  'soprano-web://settings#privacy'` opens a section.
- `Browser/SnapshotCommand*.swift`, `SnapshotPageTools.swift` — offscreen UI harness.
- `App/` — app delegate (the Dock menu: New Window, New Private Window, New
  Little Arc, the Spaces), menu, the sheets Settings opens
  (`BrowserSearchEnginesSheet` is Settings ▸ Manage search engines; its rows
  scroll), resources.
  `App/BrowserScripting.swift` with `Support/SopranoWeb.sdef` (copied into
  `Contents/Resources` by `scripts/package-app.sh`, named by `Info.plist`'s
  `OSAScriptingDefinition`) — AppleScript (stage 4 P12): `BrowserScripting`
  (`manager`, set by the app delegate; the windows a script sees =
  `mostRecentlyActiveFirst` of the CLI's windows, private ones never),
  `@objc` classes `SopranoWebScriptWindow` / `Tab` / `Space` holding ids
  only (a closed one reads as gone, `errAENoSuchObject`; specifiers are
  `NSUniqueIDSpecifier`s), the application's `new window` / `new tab`
  handlers, `select` / `close` / `reload` on tabs (close archives like
  ⌘W), windows and Spaces, and `execute javascript`
  (`BrowserScripting.executeJavaScript`: the CLI's `eval`, only with
  `allowsJavaScriptFromAppleEvents` — Settings ▸ "Allow JavaScript from
  Apple Events", off by default —, `errAEEventNotPermitted` otherwise; the
  command suspends until the page answers). The dictionary loads only in a
  bundle: the harness's `--applescript <file|text>` (repeatable, in its
  own process, `tell current application`, no Automation prompt),
  `--allow-applescript-javascript` and `--print-dock-menu` work when the
  harness runs as `"Soprano Web Dev.app/Contents/MacOS/SopranoWeb"
  snapshot …` (`SnapshotCommand+AppleScript.swift`). `execute javascript`
  can't answer there (an event to the own process waits on the main
  thread): check it with `osascript` against the dev app. A harness run
  from the dev app's binary uses its WebKit container: a `--create-space`
  there can leave a data store in `~/Library/WebKit/com.soprano.web.dev/`.
