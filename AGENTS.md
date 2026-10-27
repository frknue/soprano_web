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
  Nothing an agent runs may take focus or trigger a system prompt; the dev app
  (below) is the one window an agent shows.
- Verify UI with the offscreen snapshot command and read the PNG:

  ```bash
  taskpolicy -b .build/debug/SopranoWeb snapshot --out /tmp/sw.png --size 1440x900 \
      --theme folio-paper [--url <url>] [--sidebar history|archive|downloads] \
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
  `--session <file>` restores a version 1, 2 or 3 session (every window),
  `--new-window <url|start>` (repeatable) opens another window,
  cascaded, in the active window's Space (switch it first with `--space`
  for another one), `--new-private-window <url|start>` (repeatable) a
  private one over the active window's Space, `--delete-space <name>`
  (Delete Space on the switcher, confirmed; prints the confirmation and
  whether the Space's data store left
  `WKWebsiteDataStore.allDataStoreIdentifiers` and its folder is gone; the
  Default Space is refused),
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
  through the router), `--start-download <url>` / `--wait-downloads`,
  `--create-space <name>` (repeatable; a Space with its own profile, made
  before the first window), `--space <n|name>` (what `browser space`
  runs), `--swipe-rail next|previous` (a two-finger swipe's scroll events
  fed to the rail), `--print-spaces` (one JSON line: every Space with its
  profile id, archive time, color, icon, pin count and each window's tabs
  and selection in it), and
  `--print-windows` prints every window (kind `normal`/`private`, the
  Space whose data it uses (`dataSpace`) and the mark its chrome shows,
  current Space and each Space's remembered
  selection, CLI number, frame, page size, pop-up flag,
  find query, tabs with back/forward lists, zoom and `dataSpace`, its own
  closed tabs, the cookies and website data records of its data store and
  the store's identifier), the default store's cookies and records,
  Default's history visit count and newest 50 visits' URLs, every Space's
  data (`spaceData`: folder, History database, visits, saved site
  decisions, data store cookies), `allDataStoreIdentifiers`, the
  `Profiles/` folders, the favicon files, the windows the session would save,
  how many data stores and web views of closed private windows are still
  alive,
  the recently-closed stack (with each entry's Space) and the
  downloads (with a `private` flag) as one JSON line with a `printedAt` time
  to match a test server's log;
  `--capture-window n` picks the window for the PNG (default: the active
  one; numbers count private windows, unlike the CLI's). The harness's
  support folder is a temporary one, so Space folders go with it; it
  deletes every Space it made before exiting, so no WebKit data store is
  left behind (a `--support-dir` run keeps its Spaces and removes only
  their data stores). Spaces that shared a profile in a `--support-dir`'s
  files print `spaces: separated …` lines. Pin flags (every one works on the active window's current
  Space and the rail's pinned outline; a private window's is its Space's
  ): `--pins-tree` seeds a pinned tree (nested folders, an empty one)
  into Default's Space before the first window (the start page's folder
  cards), `--bookmarks-file <json>` starts from that stage 2
  `bookmarks.json` (version 1 or 2; it migrates into Default's Space),
  `--expand-folder <name|all>` (repeatable) opens the rail's outline folders,
  `--pin-drop <title>:on|above:<row>` (repeatable) runs the outline's drop
  handler (`performBookmarkDrop`, what a real drop on the rail calls; rows
  as `--print-pins` numbers them; prints moved or refused), `--pin-preview
  <folder>` opens the rail's hover preview of that folder and draws it into
  the capture, `--pin-search <text>` types into the preview's search (the
  first folder's without `--pin-preview`) and prints a `pin-search:` line
  per match it shows (at most 10), `--pin-folder <name>` sets ⌘D's
  last-used folder in the Space, `--pin-popover` runs ⌘D on the selected
  page and draws its popover into the capture (built in the offscreen
  window, never a shown panel), `--space-sheet new|<space>[=<name>|<icon>|<color>|<archive after>]`
  captures the New Space (or that Space's Edit Space, with "Archive Today
  tabs after") sheet, filled but not saved, and `--print-pins` prints every Space
  (`space:` with profile, color, icon and pin count), each Space's
  favorites count and archive time, the current Space's tree, the rail's
  outline rows, Vimium's `b` lines, `spaces.json`'s version and the migrated
  `bookmarks.json` copy, and the Spaces menu as text. Rail actions (in order
  with the window actions, through the handlers a real click calls):
  `--click-pin <title>[:icon|:cmd-icon]` (the pin's row, its icon — reset —
  or ⌘ on its icon — reset, keeping the page in a new Today tab; a folder's
  title opens or closes it; prints the selected tab with its id and the
  tab count before and after),
  `--click-favorite <n|title>[:cmd]`, the selected tab's menu items
  `--pin-tab`, `--unpin-tab`, `--add-favorite`, `--remove-favorite`,
  `--replace-pin`, `--new-space "<name>|<icon>|<color>"` (the
  switcher's "+" sheet, filled, Create Space pressed; empty parts keep its
  defaults), `--edit-space "<space>=<name>|<icon>|<color>|<archive after>"`,
  `--hover-folder <name>` (the folder preview resting on its row opens),
  `--toggle-rail` (⌘S) and `--print-rail` (one `rail:` JSON line: header,
  favorites, pinned rows and Today tabs with live, selected and "/" state,
  the switcher and the Spaces in its More Spaces menu, every tab of the
  Space with its link, the open folder preview and the Recently Closed
  count). `--close-tab`
  (⌘W) on a pinned or favorite tab unloads it to its pin; on a Today tab
  it also archives it. Archive flags (actions, in order): `--archive-today`
  (⇧⌘K), `--restore-archived <n|title>` (a click on Archive row n of the
  active window's Space, or the one titled so; prints the window's Space
  before and after and the selected tab), `--archive-search <text>` (shows
  the sidebar's Archive and types into its search; prints each row with
  its Space), `--archive-after <choice>[:<space>]` (Edit Space ▸
  "Archive Today tabs after", picked and saved; `never`, `days30`,
  `days7`, `hours24`, `hours12`, `hours6`, `hour1`) and `--print-archive`
  (one `archive:` JSON line: every entry with Space, `dataSpace`, reason, time
  and favicon key, newest first, and `archive.json`'s version and count);
  `--archive-seed <n>` (n entries through the importers' `insert`) and
  `--archive-batch <n>` (n more in one `archive(_:)` call, ⇧⌘K's and the
  idle pass's single write) print their time; `--archive-today` prints
  its time too.
  `--sidebar archive` seeds sample entries over several days into
  Default's Spaces when the Archive is empty. Sleep and zoom flags:
  `--sleep-after <seconds>` (a test threshold; the idle pass runs on the
  real timer four times per threshold), `--tab-sleep <setting>`,
  `--default-zoom <percent>`, `--support-dir <dir>` (a support folder kept
  after the run, so a second run sees saved zoom), and the actions
  `--advance-clock <seconds>` (the injectable idle clock, then the idle
  pass: `archive:` lists the Today tabs archived with their times, then
  `sleep:` the tabs falling asleep), `--sleep-pass` (the same pass now),
  `--memory-pressure warning|critical` (the pressure
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
  Search engine flags (before the first window): `--search-engine
  "<name>|<keyword>|<url with %s>"` (repeatable; saved like Settings ▸
  Search engine ▸ Manage… saves one, or `search-engine: refused` with the
  reason), `--search-engine-keyword <name|id>=<keyword>` (repeatable; a
  built-in's keyword), `--default-search-engine <keyword|name>` and
  `--search-engines-sheet` (captures Manage…); each prints
  `search-engines:` (every engine, `*` before the default). `--address
  "w cats"` with an engine keyed `w` shows the keyword row first in
  `address-rows`.
  Import flags (run after the first window opens, before every other
  action; sources are only read, Chromium History opens `immutable`):
  `--import-arc [dir]` (default `~/Library/Application Support/Arc`),
  `--import-chrome <dir>`, `--import-safari <zip>`, `--import-html <file>`
  (repeatable) print `import-plan:` (one JSON line: each Arc profile's home
  Space, Spaces with counts and create/skip/take-over, favorites, Archive,
  History per home with
  `sourceVisits`, `visits` imported and `olderThanRetention`, rules,
  totals), apply the plan as checked by default and print
  `import-result:` and one `import-history:` line per Space (added,
  skipped, seconds); `--import-space <name>` points a Chrome, Safari or
  bookmarks-file import at that Space (the sheet's Space menu); `--import-plan` plans only; `--import-sheet
  [checklist|progress|result]` captures File ▸ Import Browser Data… (on the
  first source flag, else the first source found) with its checklist, at
  30% of History or finished; `--export-pins <file>` /
  `--export-all-pins <file>` run File ▸ Export Pinned Tabs… and print what
  the file reads back as; `--open-link <url>` (repeatable) is a link from
  another app through the routing rules; `--link-routing-sheet` captures
  Settings ▸ Links from other apps. With `--support-dir` an import keeps
  its Spaces for the next run (only their WebKit data stores are
  removed), so a second run shows what a re-import skips.
  `--import-from-private` runs the import from a new private window;
  `import-today:` lines show where each Space's Today tabs went (a normal
  window, which shows the first imported Space).
  Command Bar and shortcut flags (actions, in order with the window flags,
  on the active window): `--command-bar [text]` (⌘T, then types `text`;
  the value is any next argument that isn't a flag), `--command-bar-location`
  (⌘L), `--command-bar-actions` (⇧⌘P, `/`), `--command-bar-type <text>`,
  `--command-bar-key <key>` (repeatable: `down`, `up`, `tab`, `enter`,
  `esc`, `backspace`, `ctrl-n`, `ctrl-p`; `enter` prints the chosen row and
  the selected tab), `--print-command-bar` (one `command-bar:` JSON line:
  mode, text, site-search chip, selection, groups and rows with targets),
  `--set-shortcut <command id>=<shortcut>[:app|site|twice]` (recorded in
  Settings ▸ Keyboard shortcuts; prints the answer and `settings.json`'s
  `shortcuts`; a conflict stays open, `--shortcut-swap` / `--shortcut-cancel`
  press its buttons; with `--support-dir` a second run reads the saved
  shortcuts), `--shortcuts-sheet` (captures the sheet and prints every row),
  `--page-key "<shortcut>[ x2]"` (a key-down into the selected tab's focused
  page as AppKit sends a key equivalent; with ` x2` the second press
  follows 0.05 s later, before the page answers the first; prints the
  tab count before and after,
  the command, its priority, the page's `window.__keyLog` and the
  pasteboard — the proof for Site wins and Press twice), `--recent-tabs <n>`
  (⌃Tab n times, then ⌃ released) and `--recent-tabs-hold <n>` (overlay left
  open for the capture), `--walk-rail down|up` (⌥⌘↓/↑), `--toggle-toolbar`
  (⇧⌘D), `--copy-url` / `--copy-markdown` (print the pasteboard: the
  harness's own named one, never the general pasteboard). The Command Bar
  and the ⌃Tab overlay are drawn over the page in the capture.
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
  executable has the same name). After a verified change to the app or packaging, run
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
  `+Bookmarks` (⌘D and the star's popover, the rail's Open All in Tabs,
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
  `BrowserChromeBookmarksReader`, `BrowserSafariExportReader`,
  `BrowserNetscapeBookmarks` (parse and write), the neutral model in
  `BrowserImportModel.swift`. `BrowserImportLoader` reads a source off the
  main thread; `BrowserImportPlan.swift` is the pure plan step
  (`BrowserImportPlanner`: each Arc Space a Space of its own; each Arc
  profile's home Space for its History and favorites — Arc `Default` →
  the Default Space, `Profile N` → the Space whose profile an import
  marked (`importedFrom` `arc:Profile N`), else its first new Space, else
  a new one named after its first Space —; an untouched home (no pins,
  never imported) is taken over by the profile's first new Space;
  Spaces skipped by `importedFrom`, `retarget` for the Chrome/Safari/HTML
  Space menu, favorites past 12, Archive ids from Arc's item ids, History counts within
  Settings ▸ Remove history items; `BrowserImportColorMatch`, OKLab hue to
  the nearest Folio color); `BrowserImportChecklist` the sheet's rows and
  result lines; `BrowserImporter` the apply step (store writes on the main
  actor, every new Space with its own profile,
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
  (and `keyDown` for ⌃/⌥ keys) calls `routePageShortcut` while the page has
  focus — AppKit offers key equivalents to the window's views before the
  menu. App wins runs the command there. Site wins and Press twice let
  WebKit send the key to the page; WebKit hands back a key the page left
  unhandled by sending the same `NSEvent` again (`forwardedKey`), and the
  isolated-world `BrowserShortcutScripts.keyReport` posts each modified
  `keydown`'s `defaultPrevented` on the `sopranoWeb` channel; the first
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
  walk, ⌃Tab's switcher with `BrowserRecentTabsOverlay`, key routing).
  A private context keeps its pages in `BrowserSessionVisits` (memory
  only) for its Command Bar.
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
  site's tabs) and the lock sheet's "Block ads on this site" accessory.
  `BrowserContentBlockingPolicy` documents why a switched-off site loses
  the lists per tab instead of getting a compiled exceptions list.
- `Browser/BrowserPageScripts.swift` — every injected page script and the
  `sopranoWeb` message channel; messages are accepted only from the world (page or
  isolated) their type was written for.
- `Browser/BrowserToolbarView.swift`, `BrowserAddressBarController.swift`,
  `BrowserAddressSuggestions.swift`, `BrowserTabStripView.swift` (favorite
  and pinned tabs first, icon-only), `BrowserVerticalTabsView.swift` (the
  rail: Space header, Favorites, the pinned outline, Today with "+ New
  Tab", the switcher), `BrowserRailPinsView.swift` (the Favorites grid and
  the pinned outline with its drag and drop), `BrowserRailSpaceSwitcher.swift`
  (the switcher, the "Today" head, `BrowserSpaceIconDrawing`),
  `BrowserPinFolderPreview.swift` (a folder's hover preview with search),
  `BrowserSpaceSheet.swift` (New Space / Edit Space), `BrowserTabButton.swift`,
  `BrowserTabDragSession.swift` (a tab's system drag session and drop marker),
  `BrowserTabReorder.swift` (drag and drop index math),
  `BrowserSidebarView.swift` (History, Archive and Downloads), `BrowserFindBar.swift`,
  `BrowserStartPage.swift`, `BrowserErrorPage.swift` — chrome and local pages.
- `Browser/BrowserAutomationCommand.swift`, `BrowserAutomationSocket.swift`,
  `BrowserAutomation.swift` — the `browser` CLI over a user-only Unix socket and
  the `@e1` snapshot/action scripts. `browser vimium <keys>` feeds the selected
  tab's Vimium controller for verification.
- `Browser/VimiumController.swift`, `VimiumKeyMap.swift`, `VimiumPageScripts.swift`,
  `VimiumPanels.swift`, `BrowserWebView.swift` — the native Vimium mode layer.
- `Browser/SnapshotCommand*.swift`, `SnapshotPageTools.swift` — offscreen UI harness.
- `App/` — app delegate, menu, settings window (`BrowserSearchEnginesSheet`
  is Settings ▸ Search engine ▸ Manage…), resources.
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
