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
  `--session <file>` restores a version 1–5 session (every window),
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
  `--click-page [cmd-|shift-cmd-|shift-|opt-|middle-]X,Y` (a real click into the active
  window's page, the Peek's when one is open, e.g. to open a pop-up window, a
  background tab or a Peek; `--click` takes the same kinds),
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
  downloads (with a `private` flag and the `profile` they started in) as one JSON line with a `printedAt` time
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
  `--blocking on|off` (the Settings switch), `--site-blocking on|off` (builds
  the Site Control Center for the selected page and presses its "Block
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
  another app (a matching rule, else "Open links from other apps in"; prints
  the window, its role and the route); `--outside-links little|recent` sets
  that choice first; `--link-routing-sheet` captures
  Settings ▸ Links from other apps. Little Arc (`BrowserWindowRole.little`,
  `BrowserLittleArc.swift`, `BrowserWindowManager+LittleArc.swift`,
  `SnapshotCommand+LittleArc.swift`): `--little-arc <url|start>` opens one
  (`start`: ⌥⌘N with the Command Bar) and makes it the captured window,
  `--little-to-window` runs ⌘O, `--little-open-in <n|name>` its "Open in"
  menu; `--print-windows` shows `role` and `littleSpace`. CLI: `browser
  little [url] [--space]`, `browser little to-window`; `browser windows`
  lines are `* n<TAB>kind<TAB>Space<TAB>tabs<TAB>title<TAB>per-Space` (kind
  `normal`, `little` or `popup`).
  Peek (`BrowserPeek.swift`, `BrowserWindowController+Peek.swift`,
  `SnapshotCommand+Peek.swift`; rule and trigger in `BrowserLinkPolicy.swift`):
  a link from a pinned or favorite tab to another site (host with `www.`
  dropped, equal or a subdomain is the same site; ports never count) or
  any ⇧-click opens it; its tab is bound to the window but in no tab list,
  and `tab(for:)` finds it, so every WebKit callback resolves it. Harness:
  `--click-page shift-X,Y` (or a plain click after `--pin-tab` on a page
  whose link leaves the site; serve one page on `127.0.0.1` linking to
  `localhost`, which count as two sites) opens one through WebKit,
  `--peek <url>` opens one over the selected tab, `--peek-open-as-tab` runs
  ⌘O (prints the new tab's place and back list), `--peek-close
  esc|cmd-w|backdrop|button` closes it that way, `--print-peek` prints one
  JSON line (address, title bar, back/forward, opener, data Space, private,
  panel frame, focus, the profile's newest visits, the window's tabs); the
  capture draws the Peek over the page. CLI: `browser peek <url>`, `browser
  peek` (status: address, title, back/forward counts, the tab it is over),
  `browser peek close`, `browser peek open-as-tab`; page commands (`eval`,
  `click`, `back`) keep acting on the selected tab, so `browser eval` can
  click a pinned page's link and `browser back` checks the history Open as
  Tab kept.
  Split View (`BrowserSplit`, `BrowserWindowController+Split.swift`): 2–4
  tabs of one Space side by side; the focused pane is `selectedTab`, the
  other panes are `isVisiblePane` (never sleep or archive). Harness:
  `--split <url|start>` (repeatable) adds a pane right of the focused one,
  `--split-command add|close|1…4` runs ⌃⇧= (with the Command Bar), ⌃⇧- or
  ⌃⇧n through the registry, `--split-focus n`, `--split-resize d:x` drags
  divider d to x points of the page area (its drag handler),
  `--split-drop [w:]t:<x|left|right>` runs the page area's drop handler
  for tab t (of window w) at x (prints the pane the edge math gave),
  `--split-separate`, `--print-splits` (per window: splits with panes, tab
  numbers, origins, ratios, frames, dividers, sleep exemptions, the rail's
  Today rows, the strip's items, `tabs` lines and the session's split
  state); `--click-page opt-X,Y` ⌥-clicks a link into a new pane; the
  capture draws every pane and the focus ring. CLI: `browser split [url]`,
  `browser split close`, `browser split focus n`; `browser tabs` marks
  panes `split s, pane p of k`, and `eval` & co. act on the focused pane.
  With `--support-dir` an import keeps
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
  Extension flags (the harness's controller is its own, emptied at exit,
  and never checks for updates; `--support-dir` loads the extensions
  installed there — copy the dev app's `extensions.json` and `Extensions/`
  into a temporary folder rather than pointing at its folder):
  `--extension <folder|id|store link>` (repeatable; installs through
  Settings' path after the first window opens and waits until it runs),
  `--extension-private <id>`, `--extension-site-access
  <id>=all|click|<host>`, `--extension-action <id>` (clicks its toolbar
  button in the captured window; prints `extension-popup:` with address
  and size and draws the popup under the button), `--extensions-sheet`
  (captures Settings ▸ Extensions, prints `extensions-sheet:` rows) and
  `--print-extensions` (one `extensions:` JSON line: each extension's
  state, version, private access, site access, errors, stand-ins, what an
  update newly asked for and waits for the user (`pending`), commands,
  granted match patterns, the windows and tabs WebKit tracks for it, and
  the captured window's toolbar buttons with label and badge).
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
  `BrowserExtensionActionButton.swift` (toolbar button with badge),
  `BrowserExtensionCommands.swift` (the CLI). `BrowserWindowController+Extensions`
  — toolbar buttons for the selected tab, clicks and button menus, the
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
  tab's Vimium controller for verification. `browser extensions` lists the
  installed extensions (state, private, site access, source, error count);
  `browser extension install <store link|id|folder>` (waits until it runs,
  up to 120 s; prints a `can:` line with what the extension may do and,
  for an update that asks for more, what waits for the user's answer in
  the app; refuses an id installed from another source),
  `enable|disable|remove|errors <id>`, `update` (check the
  Web Store now) and `action <id> [png]` (clicks the toolbar button in the
  default window; prints the popup's address, size and text and saves its
  capture, or "no popup") drive them. `errors` includes the background's
  uncaught exceptions and the console errors WebKit records.
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
