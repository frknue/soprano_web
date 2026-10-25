# Soprano Web

A native WebKit browser for macOS in the Soprano family: Swift 6 + programmatic
AppKit (no storyboards/xibs/SwiftUI), SPM, macOS 14+, `WKWebView`, shipped as a
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

The `ld: warning: building for macOS-14.0 …` link warnings are expected. There is
no linter or formatter; match surrounding style.

## Verification

- Verify source changes with `swift build` and `swift test`. Run
  `swift test -c release` before installing; a delegate signature can compile in
  debug and fail in release. `scripts/install.sh` and `scripts/dev.sh` build
  through `scripts/build-with-guard.sh`, which refuses to package a build that
  printed "nearly matches optional requirement".
- The user works on this Mac while agents run: prefix every build, test,
  harness and local test server with `taskpolicy -b`, pass `-j 2` (or `-j 1`) to
  Swift, run one heavy process at a time, and run at most one agent that builds.
  Nothing an agent runs may take focus, show a window or trigger a system prompt.
- Verify UI with the offscreen snapshot command and read the PNG:

  ```bash
  taskpolicy -b .build/debug/SopranoWeb snapshot --out /tmp/sw.png --size 1440x900 \
      --theme folio-paper [--url <url>] [--sidebar history|bookmarks|downloads] \
      [--find] [--settings] [--vertical-tabs] [--collapsed] [--print-tabs] …
  ```

  It builds the real windows with volatile stores through the window manager,
  captures the chrome with AppKit and the page with WebKit, and writes a PNG.
  History is a fresh `History.sqlite` in a temporary folder: `--sidebar` seeds
  visits over several days (the day headers), `--address <text>` seeds visits
  and typed visits and prints `address-history` (pages and visits in the
  database), `address-rows` and `address-history-candidates` (what the
  database returned, with frecency).
  Every window it opens stays off every display and never becomes key or front.
  Run it without `--out` for every flag: clicks and modifier clicks, sign-in
  sheets, session restore and crashes, address-bar typing, tab audio and hover,
  site permissions, print/PDF/save and context menus, Clear Browsing Data and
  downloads. Window flags run in order on the active window:
  `--session <file>` restores a version 1 or 2 session (every window),
  `--add-profile <name>` (repeatable) creates a profile before any window
  opens, `--new-window <url|start>` (repeatable) opens another window,
  cascaded, in the active window's profile or, after `--profile <name>`, in
  that one, `--new-private-window <url|start>` (repeatable) a private one
  over the active window's profile, `--delete-profile <name>` (Settings ▸
  Profiles ▸ Delete, confirmed; prints the confirmation and whether the
  data store left `WKWebsiteDataStore.allDataStoreIdentifiers` and the
  folder is gone), `--profiles-sheet` (captures Settings ▸ Profiles),
  `--activate-window n`, `--close-window` (⇧⌘W), `--reopen-closed` (⇧⌘T: the
  active private window's own stack, else the app-wide one),
  `--move-tab w:t:w2` (the move a dragged tab makes, selected in w2),
  `--move-to-new-window` (Window ▸ Move Tab to New Window), `--drop-tab
  w:t:w2:gap` (the tab list's drop handler; gap 0 is before the first tab),
  `--drop-outside w:t:x,y` (the drag source's handler for a drop no window
  takes, x,y on the harness screen as printed frames), `--merge-windows`,
  `--click-page [cmd-|shift-cmd-|middle-]X,Y` (a real click into the active
  window's page, e.g. to open a pop-up window or a background tab),
  `--find-text <text>`, `--cli "<browser arguments>"` (one CLI request
  through the router), `--start-download <url>` / `--wait-downloads`, and
  `--print-windows` prints every window (kind `normal`/`private`, profile
  and the mark its chrome shows, CLI number, frame, page size, pop-up flag,
  find query, tabs with back/forward lists and zoom, its own closed tabs, the
  cookies and website data records of its data store and the store's
  identifier), the default store's cookies and records, Default's history
  visit count and newest 50 visits' URLs, every profile (folder, History
  database, visits, saved site decisions), `allDataStoreIdentifiers`, the
  `Profiles/` folders, the favicon files, the windows the session would save,
  how many data stores and web views of closed private windows are still
  alive, the recently-closed stack (with each entry's profile) and the
  downloads (with a `private` flag) as one JSON line with a `printedAt` time
  to match a test server's log;
  `--capture-window n` picks the window for the PNG (default: the active
  one; numbers count private windows, unlike the CLI's). The harness's
  support folder is a temporary one, so profile folders go with it; it
  deletes every profile it made before exiting, so no WebKit data store is
  left behind. Pin flags (every one works on the window's current Space,
  for now its profile's first Space): `--sidebar` seeds a pinned tree
  (nested folders, an empty one) when the Space has no pins, `--pins-tree`
  seeds Default's Space before the first window (the start page's folder
  cards), `--bookmarks-file <json>` starts from that stage 2
  `bookmarks.json` (version 1 or 2; it migrates into Default's Space),
  `--expand-folder <name|all>` (repeatable) opens outline folders,
  `--pin-drop <title>:on|above:<row>` (repeatable) runs the outline's drop
  handler (`performBookmarkDrop`, what a real drop calls; rows as
  `--print-pins` numbers them; prints moved or refused), `--pin-search
  <text>` types into the sidebar search, `--pin-folder <name>` sets ⌘D's
  last-used folder in the Space, `--pin-popover` runs ⌘D on the selected
  page and draws its popover into the capture (built in the offscreen
  window, never a shown panel) and `--print-pins` prints every Space
  (`space:` with profile, color, icon and pin count), each profile's
  favorites count and archive time, the current Space's tree, the outline
  rows, Vimium's `b` lines, `spaces.json`'s version and the migrated
  `bookmarks.json` copy, and the Bookmarks menu as text. Sleep and zoom flags:
  `--sleep-after <seconds>` (a test threshold; the idle pass runs on the
  real timer four times per threshold), `--tab-sleep <setting>`,
  `--default-zoom <percent>`, `--support-dir <dir>` (a support folder kept
  after the run, so a second run sees saved zoom), and the actions
  `--advance-clock <seconds>` (the injectable sleep clock, then the idle
  pass), `--sleep-pass`, `--memory-pressure warning|critical` (the pressure
  source's path), `--zoom-in` / `--zoom-out` / `--zoom-reset` (⌘+ ⌘- ⌘0) and
  `--keep-awake <n>` (the tab menu item). `--print-windows` then shows per
  tab `asleep`, `awakeBecause` (the exemption or `idle`), `snapshotBytes`,
  `webContentPID`, `siteZoom`, per profile `savedSites`, and `webViews`
  (replaced web views still alive, their WebContent processes still
  running). Tabs made before the action loop (the first window's start tab)
  sit in the harness's undrained top-level autorelease pool, so their
  replaced web views stay alive; open tabs to sleep with `--cli "new-tab
  <url>"`. Content blocker flags: `--filter-list <url>` (repeatable; the
  lists instead of EasyList and EasyPrivacy, named after the file — without
  it the harness has no lists and never reaches the network), and the
  actions `--blocker-update` (Update Now, waiting for the download and
  compile; launch already starts one for lists never downloaded),
  `--blocking on|off` (the Settings switch), `--site-blocking on|off` (opens
  the lock's connection sheet on the selected tab and presses its "Block
  ads on this site" switch) and `--print-blocker` (one JSON line: setting,
  status, each list's validators, check/update times, filter and rule
  counts, skipped filters by reason, compile seconds and list names, the
  compiled files' size, and every tab of every window with its kind, pop-up
  flag, lists attached, whether `.ad-banner` is hidden and whether an ad
  script set `window.adBannerLoaded`). With `--support-dir` a second run
  looks up the compiled lists and checks them with their `ETag`. Layer
  backgrounds
  on views unhidden after first display may not appear in the cached AppKit
  pass; that is a harness limitation, not the app.
- Verify real navigation and the agent surface against a running dev app:

  ```bash
  open -n ".build/debug/Soprano Web Dev.app"
  APP=".build/debug/Soprano Web Dev.app/Contents/MacOS/SopranoWeb"
  "$APP" browser goto https://example.com
  "$APP" browser wait-for-load
  "$APP" browser snapshot
  "$APP" browser vimium "gg"       # drive normal-mode keys without the keyboard
  ```

- Do not launch the GUI or run `./scripts/dev.sh` without `--build-only` unless
  the user asks. After a verified change to the app or packaging, run
  `./scripts/install.sh` as the last step: it replaces
  `/Applications/Soprano Web.app` without restarting a running instance, and the
  update lands on next launch. Report the result.
- WebKit delegate conformance is runtime-checked in
  `BrowserDelegateSelectorTests`. Keep that test green: a delegate method with a
  nearly matching Swift signature compiles but WebKit never calls it. Confirmed
  with `class_getInstanceMethod`; do not "fix" it by silencing the warning.

## Architecture

- `Browser/BrowserWindowManager.swift` — owned by `AppDelegate` (or the
  harness): creates and tracks every `BrowserWindowController` (key and most
  recently active window, ⌘N with cascade in the active window's profile,
  ⇧⌘N private windows over it, close onto the stack), owns the app-wide
  stores, profiles, `BrowserDownloadManager`, Settings and its Websites,
  Website Data and Profiles sheets, the recently-closed stack (entries reopen
  in their profile's windows), Vimium's global marks, notification-click
  routing, links from other apps (`outsideTabbedController`: never a private
  window) and the debounced `session.json` (restore every normal window in
  its profile, frames clamped to today's screens). It runs every profile's
  History retention pass (Settings ▸ Remove history items) at launch, once a
  day and when the setting changes. `BrowserWindowPlacement`
  keeps harness windows off-screen. `BrowserAutomationRouter` (in
  `BrowserAutomationCommand.swift`) picks the CLI's window from
  `automationControllers` (private windows excluded), opens `new-window
  --profile` and runs `move-to-window`. `BrowserWindowManager+TabMove.swift`
  moves live tabs: `moveTab(_:from:to:at:select:)`, `moveTabToNewWindow`,
  `mergeAllWindows`, `openPopupWindow`; `canMoveTab(from:to:)`
  (`BrowserTabMoveRule`) is the one rule for which windows may exchange tabs:
  the same data context (so the same profile), never into a pop-up.
  `tabbedController` is the window menu commands' new tabs go to (never a
  pop-up window); `windowForNewTabs(from:)` the window a pop-up's tabs go to
  (same data context). `BrowserWindowManager+Profiles.swift` —
  `context(for:)` (a profile's data context, made on first use; Default's or
  a deleted profile's is `defaultContext`), `history(for:)`,
  `windowMark(for:)` and `deleteProfile(_:completion:)` (closes the
  profile's windows without Recently Closed, drops its closed entries,
  deletes its Spaces and favorites, removes it from `profiles.json`, then
  retries `WKWebsiteDataStore.remove(forIdentifier:)` until its web views
  are released and deletes its folder). The manager reconciles `spaces`
  with the profile list at launch and on every profile change, so a new
  profile gets its Space.
- `Browser/BrowserProfiles.swift` — `BrowserProfile` (fixed Default id; its
  folder, `<support>/Profiles/<id>/` for the others, data-store
  identifier and `archiveAfter`), `BrowserProfileColor` (Folio tokens),
  `BrowserProfileList` (`profiles.json`, tolerant decoding, unique names,
  next color),
  `BrowserProfileStore` and `BrowserWindowMark` ("Private", the profile
  when there are several, or "Private · Work"). `BrowserWindowMarkView` draws
  the mark (color dot and eyebrow) in the rail header and before the address
  field; `BrowserProfilePicker` is the Websites and Website Data sheets'
  profile picker; `App/BrowserProfilesSheet.swift` is Settings ▸ Profiles.
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
  `currentSpaceID` is the Space whose pins every bookmark surface reads and
  writes (for now the first Space of the window's profile; `currentPinTree`
  its tree).
  Its behavior lives in extension files
  by concern: `+Tabs` (`attachTab`/`detachTab`: everything that binds a tab to a
  window), `+TabMove` (Move Tab to New Window, the drop and drag-out handlers
  the tab lists call, the find query a moved tab carries), `+Navigation`
  (`WKNavigationDelegate`), `+UIDelegate`
  (`WKUIDelegate`), `+Downloads` (hand-off to the download manager), `+Sidebar`,
  `+Bookmarks` (⌘D and the star's popover, the sidebar's Open All in Tabs,
  New Folder, Edit/Rename and Delete with its confirmation, all on the
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
  — tab state, settings (decoded key by key), address resolution, the version 2
  session (`windows[]` with frames, `recentlyClosed`; a version 1 file migrates
  to one window and is kept as `session.json.migrated`), the recently-closed
  stack of tabs and windows, and window frame clamping/cascading (and where a
  dragged-out tab's window opens). `BrowserTabMove.swift` — the tab-move rule,
  Merge All Windows ordering and pop-up window frames from `WKWindowFeatures`.
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
  `BrowserSpace` (name, `BrowserSpaceIcon`, color mark, profile, pinned
  tree, `importedFrom`), `BrowserFavorites` (per profile, at most 12),
  `BrowserArchiveAfter`, `BrowserSpaceList` (the pure operations: a
  profile's last Space can't be deleted or moved away, `reconcile(with:)`
  gives every profile a Space and drops orphans) and `BrowserSpacesFile`
  (`spaces.json`, tolerant decoding). `BrowserSpaceStore.swift` —
  `BrowserSpaceStore`, the only way in or out of `spaces.json` (Space
  operations, per-Space pin operations with `inSpace:`, favorites with
  `ofProfile:`; `insert(_:into:at:inSpace:)`, `createSpace(…importedFrom:)`
  and `insertFavorite` are the importers' entry points; a missing file
  starts with one Space per profile and migrates `bookmarks.json` into
  Default's, kept as `bookmarks.json.migrated`; an unreadable one is kept
  as `.corrupt`) and `BrowserPinUIState` (expanded folders and ⌘D's last
  folder per Space in `UserDefaults`). `BrowserPinEditor.swift` is the
  Folio popover (⌘D, Edit Bookmark, Rename, New Folder) and its child
  panel; `BrowserPinOutlineCell.swift` an outline row;
  `BrowserBookmarksMenu.swift` the Bookmarks menu's tree of the active
  window's Space, rebuilt on every change (`dump` prints it).
- `Browser/BrowserDataStores.swift` — downloads JSON
  (`{version, entries}` envelopes, lossy decoding; a private window's download
  rows carry `privateContextID` and stay in memory);
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
  idle timer and memory pressure source (`now` and `thresholdOverride` are
  the harness's clock and test threshold). `BrowserWindowController+Sleep`
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
  site's tabs) and the lock sheet's "Block ads on this site" accessory.
  `BrowserContentBlockingPolicy` documents why a switched-off site loses
  the lists per tab instead of getting a compiled exceptions list.
- `Browser/BrowserPageScripts.swift` — every injected page script and the
  `sopranoWeb` message channel; messages are accepted only from the world (page or
  isolated) their type was written for.
- `Browser/BrowserToolbarView.swift`, `BrowserAddressBarController.swift`,
  `BrowserAddressSuggestions.swift`, `BrowserTabStripView.swift`,
  `BrowserVerticalTabsView.swift`, `BrowserTabButton.swift`,
  `BrowserTabDragSession.swift` (a tab's system drag session and drop marker),
  `BrowserTabReorder.swift` (drag and drop index math),
  `BrowserSidebarView.swift`, `BrowserFindBar.swift`, `BrowserStartPage.swift`,
  `BrowserErrorPage.swift` — chrome and local pages.
- `Browser/BrowserAutomationCommand.swift`, `BrowserAutomationSocket.swift`,
  `BrowserAutomation.swift` — the `browser` CLI over a user-only Unix socket and
  the `@e1` snapshot/action scripts. `browser vimium <keys>` feeds the selected
  tab's Vimium controller for verification.
- `Browser/VimiumController.swift`, `VimiumKeyMap.swift`, `VimiumPageScripts.swift`,
  `VimiumPanels.swift`, `BrowserWebView.swift` — the native Vimium mode layer.
- `Browser/SnapshotCommand*.swift`, `SnapshotPageTools.swift` — offscreen UI harness.
- `App/` — app delegate, menu, settings window, resources.
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

- Swift 6, macOS 14+, programmatic AppKit, Folio tokens and components only.
  Fonts by role through `ChromeFont`, radii from `Chrome.Radius`, accent only for
  keyboard focus, one hairline between regions.
- Tests use swift-testing (`import Testing`, `@Test`, `#expect`), one
  `struct …Tests` per file. Never `import Foundation` next to `import Testing` in
  a test file; import `AppKit` instead and get Foundation types through it.
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
- Releases: rename `[Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, add a fresh
  `[Unreleased]`, set `CFBundleShortVersionString` and `CFBundleVersion` in
  `Support/Info.plist` (the only version source), `swift test`, install, commit
  `release: vX.Y.Z`.
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
refuses unknown pseudo-classes up front.
