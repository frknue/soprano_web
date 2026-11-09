# Snapshot harness

The offscreen UI harness (`.build/debug/SopranoWeb snapshot …`,
`Browser/SnapshotCommand*.swift`, `SnapshotPageTools.swift`). `AGENTS.md`
▸ Verification shows the basic call; this is the flag reference.

  It builds the real windows with volatile stores through the window manager,
  captures the chrome with AppKit and the page with WebKit, and writes a PNG.
  History is a fresh `History.sqlite` in a temporary folder: `--sidebar` seeds
  visits over several days (the day headers), `--address <text>` seeds visits
  and typed visits and prints `address-history` (pages and visits in the
  database), `address-rows` and `address-history-candidates` (what the
  database returned, with frecency). `--focus-page` gives the page focus
  after `--url`, as Return in the address bar does, so the toolbar shows
  the unfocused address (site and title).
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
  `--ungroup-folder <name>` (the folder's Ungroup Folder menu item; prints
  the Space's top level),
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
  `--import-chrome|brave|edge|vivaldi|chromium|aside <dir>` (a Chromium browser's
  user-data folder), `--import-safari <zip>`, `--import-html <file>`
  (repeatable) print `import-plan:` (one JSON line: each source profile's home
  Space, Spaces with counts and create/skip/take-over, favorites, Archive,
  History per home with
  `sourceVisits`, `visits` imported and `olderThanRetention`, cookies,
  rules, totals), apply the plan as checked by default and print
  `import-result:`, one `import-cookies:` line per cookie item and one
  `import-history:` line per Space (added,
  skipped, seconds); `--import-safe-storage <password>` stands in for the
  browser's keychain password (the harness never reads the keychain; without
  it cookie items fail and say so); `--import-space <name>` points any import but Arc's
  at that Space (the sheet's Space menu); `--import-plan` plans only; `--import-sheet
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
  open for the capture; both print the cards, `[preview]` on those showing
  a page, and the card size), `--walk-rail down|up` (⌥⌘↓/↑), `--toggle-toolbar`
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
  <id>=all|click|<host>`, `--extension-action <id>` (runs its row of the
  Extensions menu in the captured window; prints `extension-popup:` with address
  and size and draws the popup under the Extensions button), `--extensions-sheet`
  (captures Settings ▸ Extensions, prints `extensions-sheet:` rows) and
  `--print-extensions` (one `extensions:` JSON line: each extension's
  state, version, private access, site access, errors, stand-ins, what an
  update newly asked for and waits for the user (`pending`), commands,
  granted match patterns, the windows and tabs WebKit tracks for it, and
  the captured window's Extensions button (`button`), its rows with label
  and badge (`rows`) and the whole menu as text (`menu`)).
  Agent panel: `--agent` shows it with a seeded chat (a message, tool calls
  that worked and one that failed, a Markdown answer with a list), fed
  through `BrowserAgentTranscript` as omp's events would be, after the
  page's `--wait`; the chat prints as `agent:` lines. omp never starts.
  `--agent-draft <text>` types text into the composer (implies `--agent`).
  `--agent-steps` (implies `--agent`) shows every run's steps, as a click
  on "Worked for …" does, and prints `agent-steps: <runs> shown`.
  `--agent-button` (repeatable) presses the toolbar's Agent button through
  its accessibility press and prints `agent-button: panel shown|hidden,
  button on|off`; `--agent-gear` (after `--settings-search`) presses the
  composer's model chip, so `--settings --settings-search privacy --agent-gear
  --print-settings` shows the search cleared and Agent current;
  `--url 'soprano-web://settings#agent'` opens Settings ▸ Agent.
  `--agent-chats` saves two chats as omp session files in the run's
  support folder (one pinned, from 9 days ago), opens the chats page at
  the newer one, which reads both from disk, and prints `agent-chats:`
  lines: each listed chat, then `page <title> | <listed chats> | <tool
  steps> | <answers>`.
