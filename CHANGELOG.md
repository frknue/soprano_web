# Changelog

All notable changes to Soprano Web are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The version in a released heading matches `CFBundleShortVersionString` in
`Support/Info.plist`, the single source of truth for the version shown in the
app.

## [Unreleased]

### Added
- File ▸ Import Browser Data… imports from Brave, Edge, Vivaldi and Chromium like
  Chrome: each profile's bookmarks as a pinned folder named after the browser and its
  History into the chosen Space. The sheet lists them when they're on this Mac; when
  macOS doesn't let Soprano Web read one, it says where to allow it.
- AppleScript: Soprano Web has a scripting dictionary (open it in Script Editor). Scripts
  see the windows (the most recently active first; private windows never), the tabs of
  each window's current Space (name, URL — set it to load an address or search —,
  loading, index, selected) and the Spaces, and can `new window` (with a URL, in a
  Space), `new tab`, `select` a tab or a Space, `close` a tab (to the Archive, like ⌘W)
  or a window, and `reload`. `execute javascript "…" in tab 1 of window 1` returns the
  result as JSON and may await promises; it runs only with Settings ▸ "Allow JavaScript
  from Apple Events" on (off by default).
- Dock menu: New Little Arc and every Space (the one the most recent window with Spaces
  shows is checked; choosing one shows it there) next to New Window and New Private Window.
- Live folders for GitHub pull requests: right-click the rail's pinned tabs ▸ New Live
  Folder…, give it `owner/repo` (or a github.com repository link) for that repository's
  open pull requests, or any GitHub search such as `review-requested:@me is:open`. The
  folder lists the pull requests through the GitHub CLI (`gh`, signed in with `gh auth
  login`), refreshes every 5 minutes and when you open it, and a click opens the pull
  request in a Today tab. The folder is read-only (nothing can be dropped into it); its
  menu has Refresh, Open All in Tabs and Edit Live Folder…, and its tooltip says when
  `gh` is missing or signed out. CLI `browser live-folders`, `browser live-folder add
  <owner/repo|query>` and `browser live-folder refresh`.
- Reader (⇧⌘R, View ▸ Show Reader): pages with an article get a Reader chip in the address
  field; Reader shows the article in a clean Folio page in the same tab, and toggling back
  restores the page as it was (no reload, no new history entry). Its colors follow the theme.
- Translate Page: a page in a language you don't use gets a Translate chip in the address
  field (Translate to …, Show Original, Never Offer for …), translated on this Mac by
  macOS's Translation; for a language pair not yet downloaded it asks to open System
  Settings ▸ General ▸ Language & Region (Translation Languages). A translated page stays
  translated in Reader. Settings ▸ "Never offer to translate" lists the languages you
  turned off (choose one to get the offer back);
  private windows translate too and remember nothing. CLI `browser reader [on|off]` and
  `browser translate [to <lang>|off]`; harness `--reader`, `--translate <lang>`.
- Mini Player: leave a tab whose video plays and is in view (another tab, another Space)
  and the video keeps playing in a small floating panel above every window and Space;
  hover it for Back to Tab, play/pause and Close (which pauses). Selecting the tab again
  puts the page back as it was (same page, same history). The panel remembers where you
  put it (never from a private window). Split panes on screen and Peeks never move.
  Settings ▸ "Mini Player for videos" turns it off. The playing tab (audio too) shows at
  the bottom of the rail — or in the toolbar without a rail — with its artwork, title,
  play/pause, next track (sites with Media Session) and mute; a click goes to the tab.
  CLI `browser media [info|play|pause|next|previous|mute]`.
- Capture (⇧⌘2, remappable; File ▸ Capture…, `/capture`): an overlay over the page you
  look at (a Peek's, the focused pane's) — drag an area, click for the visible page, or
  "Full Page" for the whole document (taller than 16,384 px it renders at a lower scale,
  then is cut there); Esc cancels. The PNG goes on the clipboard and into the download
  folder as `Soprano Capture <date> at <time>.png` (never overwriting), and a toast with
  its thumbnail shows it; click the toast to reveal the file in Finder. Private windows
  capture the same way. CLI `browser screenshot --full <path>`; harness
  `--capture-area x,y,w,h`, `--capture-visible`, `--capture-full`, `--capture-drag`,
  `--capture-overlay`.
- Boosts: your own CSS, JavaScript and hidden elements per site (the host and its
  `www.` form; other subdomains have their own), app-wide in `boosts.json`, running in
  every tab — normal, private, Peek, split panes, Little Arc. CSS goes into the page as a
  constructed stylesheet at document start (it wins ties with the page's own CSS and
  works under a strict `style-src` Content Security Policy; `@import` isn't supported)
  and JavaScript runs in a content world of its own (no Soprano Web message handler).
  CSS and hidden elements change open pages at once; a selector that isn't valid hides
  nothing and leaves the others working; JavaScript runs from the next load. The editor
  sheet (monospace CSS / JavaScript / zapped selectors, enabled switch, name; ⌘↩ saves,
  ↩ is a new line) opens from the Site Control Center's new Boost row and the Command Bar
  (`/boost`, "Boost This Site…"); "Zap Elements" outlines what the pointer is over, a
  click hides it and records a stable selector, Esc, a new page or another tab ends it.
  CLI `browser boost list|show|css|js|zap|enable|disable|remove` (`css`/`js` read a file
  or `-` for stdin in the CLI, up to 16 MB; hosts in punycode); harness `--boost-css`,
  `--boost-js`, `--boost-zap`, `--boost-editor`.
- Site Control Center: the lock / site chip opens a Folio popover for the page you look at
  (a Peek's, the focused pane's) in its Space's profile: the connection (the details
  sheet with Show Certificate behind its row), camera, microphone, notifications and
  pop-ups as Ask / Allow / Block (a private window keeps its answers in its own layer;
  notifications stay blocked there), zoom −/+/Reset, "Block ads on this site", each
  extension's site access (its mode and "Allow on <host>") and "Clear site data…", which
  asks, removes the website data WebKit keeps for the site's domain and the cookies of
  that exact host, then reloads. Replaces the lock's sheet. Autoplay stays a global
  setting (WebKit fixes it per web view). CLI `browser site [info|clear|permission <name>
  allow|deny|ask]`; harness `--site-control` captures the popover, `--security-info` and
  `--site-blocking` go through it.
- Split View: 2–4 tabs of one Space side by side with resizable dividers (ratios saved),
  one rail row (every pane's favicon) and one strip item. ⌃⇧= adds a pane (a new tab with
  the Command Bar), ⌃⇧- closes the focused pane, ⌃⇧1…4 focus a pane, ⌥-click on a web link
  opens it in a new pane, a tab dragged onto a pane's left or right edge joins there, and a
  tab's menu has "Open in Split View"; a split row's menu separates or closes it. The
  focused pane (accent ring) is the selected tab for every command, Vimium and the CLI;
  clicking a pane focuses it. Panes keep their origin; visible panes never sleep or
  archive (`visiblePane`), Today panes archive like any Today tab. A Peek covers the whole
  page area and belongs to the focused pane. Session version 5 saves splits (older files
  migrate with none); Arc's Today split views import as splits (pinned ones stay pins).
  CLI `browser split [url]|close|focus <n>`, `tabs` marks panes; harness `--split`,
  `--split-command`, `--split-focus`, `--split-resize`, `--split-drop`,
  `--split-separate`, `--print-splits`.
- Peek: a link from a pinned or favorite tab to another site (host with `www.` dropped;
  equal or a subdomain is the same site, ports never count) and any ⇧-click open over the
  page in a rounded panel with its own web view in the tab's data context (History,
  downloads, sign-in, permissions, content blocking, extensions and Vimium work in it;
  private windows keep nothing). Title bar with back/forward, "Open as Tab" (⌘O: a Today
  tab after the opener, history kept) and close (Esc, ⌘W, a click on the dimmed page).
  One per window; a second replaces it. CLI `browser peek <url>|close|open-as-tab`;
  harness `--peek`, `--peek-open-as-tab`, `--peek-close`, `--print-peek`, and `shift-`
  and `opt-` clicks.
- Peek (P4 review): menu titles return to "Close Tab" / "Open in Space Window" after a
  Peek closes; ⌘[ / ⌘] / ⌘. state, the zoom chip, the capture indicator and extension
  actions (`activeTab`, toolbar buttons) follow the Peek's page; Esc in a Peek ends the
  find bar or element fullscreen first and closing a Peek closes its find bar; a scripted
  `window.open` with ⇧ held never becomes a Peek; the extension navigation gate uses the
  link disposition WebKit's click really gets. The global Little Arc chord is reserved in
  Keyboard Shortcuts while on, and a stored chord that is taken falls back to ⌥⌘N or turns
  the hotkey off.
- Little Arc review fixes: Settings' global-shortcut recorder handles only its own
  window's keys, refuses system, text-editing and in-app chords (also when decoding
  settings), lets the registered hotkey go while recording and stops when Settings
  resigns or closes; a refused hotkey shows "(unavailable)" and is retried; the hotkey
  finds its key on the ASCII-capable layout when the current one (Russian, Greek) has
  none; duplicating in a Little Arc copies into its Space's window; Command Bar rows fit
  a narrow bar and a long ⌘L address no longer widens it; a link rule whose Space is gone
  no longer overrides "Open links from other apps in"; `windows` help names `popup`.
- Little Arc: a small one-tab window of one Space (compact toolbar with editable address,
  Space mark, "Open in" Space menu, ⌘O "Open in Space Window"), cascaded from the screen's
  top right. Links from other apps open in it unless a link rule matches (Settings ▸ Links
  from other apps ▸ "Open links from other apps in": Little Arc or the most recent window;
  an Arc import takes Arc's `defaultDestination`). ⌥⌘N opens one with the Command Bar;
  Settings ▸ Keyboard shortcuts has an optional global shortcut (off by default). Its new
  tabs go to its Space's window; 6 h idle closes it with its tab in the Archive; session
  version 4 saves it. CLI `browser little [url]`, `browser little to-window`; `browser
  windows` gains a kind column.
- Extension review fixes: an update sheet decides only what it showed; every worker whose
  policy could permit a socket gets the WebSocket stand-in; an update re-reads the record
  after its sheet; notifications ask once per extension (no window is no refusal); a
  download whose Space is deleted while its save panel is open is dropped.
- A native Vimium keyboard layer for pages: counts, scrolling, link hints
  (open, new tab, copy, queue), find, omnibar, bookmarks, tab search, history,
  tab manipulation, marks, visual mode, zoom, mute, source view and a full
  `?` help sheet. Text inputs enter insert mode automatically.
- An Arc-style vertical tab rail on the left, with a `+` header button. `⌘S`
  collapses or expands the rail; Settings switches between the rail and
  horizontal tabs.
- Soprano Web 0.1: a native WebKit browser in Folio chrome with tabs, an address
  bar with search fallback, back/forward/reload, zoom, find in page and session
  restore.
- History, bookmarks and downloads in a right sidebar, with search and context
  menus; downloads use `WKDownload`, show live progress, use unique filenames and
  reveal in Finder.
- A local start page showing bookmarks and recent pages, and a themed error page
  with the failed address and a reload hint. The start page has a real URL, so
  back/forward returns to it instead of `about:blank`.
- `browser` CLI automation: `goto`, `wait-for-load`, `snapshot` with `@e1` refs,
  click/fill/press, `get`/`is`, `eval`, `screenshot`, tab listing/selection/close
  and `--tab`.
- Settings for search engine, homepage, theme, appearance, session restore and
  download folder, stored in `~/.config/soprano-web/settings.json`.
- Offscreen `snapshot` harness for the chrome, sidebar, find bar and settings
  window.
- The address bar suggests open tabs (Switch to Tab), bookmarks and history,
  ranked by how often and how recently you visited or typed them, and completes
  the site name as you type. `↑`/`↓` choose, `Return` opens, `⌘Return` opens in a
  new tab. Settings ▸ Include search engine suggestions (on by default) adds
  DuckDuckGo, Google or Bing suggestions; those requests carry no cookies.
- Back, Forward and Reload buttons left of the address field; hold or right-click
  Back or Forward for the tab's history. Hovering or focusing a link shows its
  address at the bottom left of the page.
- Tabs show the site's favicon, a spinner while loading and a speaker while
  playing or muted (click it to mute). Drag tabs to reorder them; right-click a
  tab for Reload, Duplicate, Mute Tab, Copy Link, Close Tab, Close Other Tabs,
  Close Tabs Below / to the Right and Reopen Closed Tab. History and bookmark
  rows show favicons.
- Pop-ups a page opens without a click are blocked; the Pop-up blocked button in
  the address field opens them or always allows pop-ups on that site. Pages can
  close the windows they opened (sign-in and payment pop-ups), returning you to
  the page that opened them.
- `⌘`-click and middle-click open links in a background tab, `⇧⌘`-click in a front
  tab; tabs opened from a page appear right after it.
- Soprano Web asks before a page opens a link in another app (Mail, Zoom,
  Slack, …), with Always allow per site.
- Sites that ask for a password (HTTP Basic, Digest, NTLM) show a sign-in sheet;
  sites that ask for a client certificate let you pick one from your keychain.
- Certificate errors show a "This connection is not private" page with the
  reason, Go Back, Show Certificate and, under Details, Visit Website (until you
  quit, for that certificate only). The address bar's lock shows whether the
  connection is secure, partly secure, not secure or excepted; click it for
  details and the certificate.
- Camera and microphone prompts offer Remember for <site>; an indicator next to
  the address field shows when the page uses them, with Stop Camera, Mute
  Microphone and Stop.
- Web notifications appear in Notification Center while their tab is open;
  clicking one opens the tab. Settings ▸ Notifications stops sites from asking.
- Settings ▸ Autoplay (Allow All, Stop Media with Sound, Never Autoplay) and
  Settings ▸ Websites, which lists your camera, microphone, notification,
  pop-up and external-app decisions per site with Remove and Remove All.
- File ▸ Print… (`⌘P`), also for pages that call `window.print()`; File ▸ Export
  as PDF…; File ▸ Save As… (`⇧⌘S`) as a Web Archive or the page's original HTML.
- The page's context menu opens links in a new tab or a background tab, opens
  images in a new tab, and searches selected text with your search engine.
- Edit ▸ Spelling and Grammar, Substitutions, Transformations and Speech;
  Soprano Web ▸ Services; File ▸ Share….
- History ▸ Clear Browsing Data… (`⇧⌘⌫`) removes history, cookies and website
  data, cached files and the download list for the last hour, today, today and
  yesterday, or all time. Settings ▸ Website data ▸ Manage… lists the sites that
  store data, with Remove and Remove All.
- Cancelled, failed and interrupted downloads resume or retry from the Downloads
  sidebar; downloads running when you quit continue after relaunch. Settings ▸
  Ask where to save picks a location for each download.
- Settings ▸ Default browser shows the current default and makes Soprano Web the
  default for web links.
- Restored tabs keep their back and forward history, and only the selected tab
  loads at launch; the others load when you first select them. `⇧⌘T` remembers
  the last 20 closed tabs, with their history, across relaunches.
- A crashed page reloads once with a notice; if it crashes again right away, a
  crash page with Reload (`⌘R`) appears. Background tabs that crash reload when
  selected.
- `browser wait-for selector|url|text <value>` and `--timeout` (up to 120 s) on
  `wait-for` and `wait-for-load`.
- Multiple windows: File ▸ New Window (`⌘N`) opens a window with a start tab,
  one step down and right of the current one; the Dock icon's menu has New
  Window, and clicking the Dock icon with no window open opens one. Every
  window is restored at launch where it was (moved onto a screen that is still
  connected), each loading only its selected tab. Window titles follow the
  selected tab, so Window, Mission Control and `` ⌘` `` show them.
- History ▸ Recently Closed lists the last 20 closed tabs and windows, newest
  first, and reopens any of them. `⇧⌘T` reopens the most recent one: a tab goes
  back into its window at its old place (or into the current window when that
  one is closed), a window comes back with all its tabs and their history.
- `browser windows` lists the open windows; `--window n` works on window n
  (with `--tab n` counting inside it) without bringing it forward;
  `browser new-window [url]` and `browser close-window [n]`.
- Window ▸ Move Tab to New Window, also in the tab's context menu and on
  Vimium `W`: the tab moves as it is (page, back/forward history, playing
  audio, zoom and an open find query) into a new window one step down and
  right; the old window closes when it was its last tab.
- Drag a tab out of the tab strip or the vertical rail: drop it on another
  window's tabs to move it there at that spot, or anywhere else to open it in
  a new window under the pointer. Dragging a window's only tab out leaves no
  empty window behind.
- Window ▸ Merge All Windows moves every tab of the other windows into the
  current window, after its own tabs, and closes the emptied windows.
- Sign-in and payment pop-ups a page opens with a size (`window.open` with
  `width`/`height`) open in a small window of that size, at the requested
  position, with back/forward/reload and the address; the page that opened it
  can talk to it, and it closes itself when done. Pop-up windows are not
  restored at launch or listed in Recently Closed. Links without a size still
  open as tabs next to the page.
- `browser [--window n] [--tab m] move-to-window <k|new>` moves a tab to window
  k or a new window without selecting it or bringing anything forward.
- File ▸ New Private Window (`⇧⌘N`, also in the Dock menu). A private window
  and every tab and pop-up it opens share one cookie and site-data store that
  is never written to disk and goes away with the window; each private window
  has its own. It records no history, no session and no favicon files; sites
  in it can't send notifications; new camera, microphone, pop-up and
  external-app answers last only for the window; its downloads are listed there
  while it is open but not saved; certificate exceptions and client
  certificates chosen there stay in it. Files you download are kept.
- A private window always uses Folio Ink, whatever the theme, and shows
  **Private** in the tab rail header (or before the address field with
  horizontal tabs); its title starts with "Private — ".
- In a private window, `⇧⌘T` reopens that window's own closed tabs, and
  closing the window is final: nothing goes onto History ▸ Recently Closed.
  Its address bar suggests bookmarks, its tabs and searches, never history.
- Settings ▸ Remove history items: after one day, one week, two weeks, one
  month, one year (the default) or manually. Older visits are removed at launch
  and once a day.
- The History sidebar (`⌘Y`) groups visits under Today, Yesterday, the weekday
  for the rest of the week, then the date, shows each visit's time, and loads
  older days as you scroll.
- Profiles: Settings ▸ Profiles lists your profiles with their color and
  name, and adds, renames, recolors and deletes them (Default can be renamed
  but not deleted). Each profile keeps its own cookies and website data,
  History and per-site decisions; bookmarks, downloads, favicons, settings and
  Recently Closed are shared, and a closed tab or window reopens in its
  profile. File ▸ New Window (`⌘N`) opens in the current window's profile;
  File ▸ New Window With Profile and the Dock menu pick one. Deleting a
  profile asks first, closes its windows (they don't go onto Recently
  Closed) and removes its history, cookies, website data and site decisions
  from this Mac.
- With more than one profile, every window shows its profile's color and name
  in the tab rail header, or before the address field with horizontal tabs. A
  private window opened from a profile's window layers over that profile and
  says "Private · Work"; its cookies stay apart from every profile's.
- Settings ▸ Websites and Settings ▸ Website Data show the current window's
  profile and have a profile picker when there are several. History ▸ Clear
  Browsing Data… (`⇧⌘⌫`) clears the current window's profile and says which.
- `browser new-window [url] --profile <name>` opens a window in that profile;
  an unknown name is an error.
- Bookmark folders. Sidebar ▸ Bookmarks (`⌥⌘B`) is an outline: click the
  triangle (or double-click a folder) to open it, and drag bookmarks and
  folders to reorder them or move them into and out of folders. Folders
  stay open as you left them. Right-click for Open, Open in New Tab, Open All
  in Tabs, Copy Link, Edit Bookmark… (name and address), Rename…, New Folder
  and Delete (a folder with bookmarks asks first); New Folder also sits at
  the bottom of the sidebar. Searching lists matching bookmarks with the
  folder they're in.
- `⌘D` and the star open a small popover: a new bookmark goes into the folder
  you used last, and the popover lets you rename it, pick another folder or
  remove it (Return or Done saves, Esc closes). On a bookmarked page the
  same popover edits the bookmark.
- The Bookmarks menu lists your bookmarks, with a submenu per folder that
  ends in Open All in Tabs; Show Bookmarks (`⌥⌘B`) moved there from History.
- The start page shows top-level folders as cards that open in place to
  list their bookmarks.
- Tab sleep: Settings ▸ Put inactive tabs to sleep (never, after 15 minutes,
  after 1 hour — the default — or after 4 hours). A sleeping tab keeps its
  title, favicon, address and back/forward history, shows dimmed in the strip
  and the rail, and reloads when you select it (showing its last picture while
  it loads), when a `browser` command targets it or when it moves to another
  window. Under memory pressure, tabs idle 30 minutes (warning) or 5 minutes
  (critical) sleep early. The selected tab of each window, tabs playing audio,
  using the camera, microphone or screen, loading, showing a dialog, sheet or
  sign-in prompt, pages with unsaved input, pop-up windows and sites you keep
  awake never sleep.
- Right-click a tab ▸ Keep This Site Awake; Settings ▸ Websites lists the
  sites you keep awake, with Remove.
- Zoom is remembered per site: `⌘+` / `⌘-` change the current site's zoom and
  every open tab of that site in the same profile follows; `⌘0` resets the
  site. Settings ▸ Default page zoom (50–300%). A percentage in the address
  field shows a site's zoom when it differs from the default; click it to
  reset. Settings ▸ Websites lists each site's zoom with Remove. Private
  windows keep zoom changes until they close.
- A built-in ad and tracker blocker: Settings ▸ Block ads and trackers (on by
  default) downloads EasyList and EasyPrivacy, keeps them up to date (checked
  at launch and daily, downloaded again when a week old) and blocks their ads
  and trackers in every tab of every window, private windows and pop-ups
  included. The row shows the rule count and when the lists were last
  updated, and Update Now checks right away. Turning it off or on applies to
  new page loads; open pages don't reload.
- Click the lock in the address bar ▸ Block ads on this site turns the blocker
  off (or back on) for that site and reloads its open tabs. Settings ▸ Websites
  lists those sites ("Ad blocking: Off") with Remove; private windows keep the
  switch until they close, and each profile has its own.
- The rail (vertical tabs) shows the current Space from top to bottom: its
  icon, name and color, the profile's Favorites as a grid of icons, the
  Space's pinned tabs and folders, then Today with "+ New Tab" and your other
  tabs, and a Space switcher at the bottom. Click a Space's icon to switch;
  "+" opens New Space (name, an emoji or SF Symbol icon, color and profile);
  right-click an icon ▸ Edit Space… or Delete Space (a profile's last Space
  can't be deleted).
- Pinned tabs and Favorites stay in place: clicking one opens its tab, or
  goes back to the one already open in this window. `⌘W` on a pinned or
  favorite tab closes it back to its pin and does not add it to Recently
  Closed. A pinned tab that moved on to another page shows "/": click its icon
  to go back to the pinned page, `⌘`-click the icon to go back and keep the
  page in a new tab.
- Right-click a tab ▸ Pin Tab / Unpin Tab, Add to Favorites / Remove from
  Favorites (up to 12 per profile), Back to Pinned Page and Replace Pin with
  Current Page; right-click a pin in the rail for Open, Copy Link, Replace
  Pin with Current Page, Edit Pin…, New Folder and Delete, and a favorite for
  Open, Copy Link, Replace Favorite with Current Page and Remove from
  Favorites. `⌘D` pins the page into the current Space and makes its tab the
  pin's tab. In a Space with no pinned tabs, right-click the Pinned area for
  New Folder.
- A pin whose address redirects (to `https`, to a trailing "/", to the site's
  own start page) is home where it lands: no "/" until you move on from there.
- With many Spaces the switcher's icons draw closer together and the rest go
  into a More Spaces menu; with many pinned and favorite tabs in the strip,
  those that don't fit go into the All Tabs menu, and a moved-on one shows
  "/".
- Rest the pointer on a pinned folder to preview its pins and search them.
  Drag pins and folders in the rail to reorder them or move them into folders.
- With horizontal tabs, the Space's favorite and pinned tabs come first in
  the strip, as icons.
- Archive: Today tabs you haven't used for a while archive themselves.
  Settings ▸ Profiles ▸ "Archive Today tabs after" sets the time per profile:
  Never, 30 days, 7 days, 24 hours, 12 hours (the default), 6 hours or 1 hour.
  Pinned and favorite tabs, the selected tab, a tab playing audio or waiting
  on a dialog, and private windows never archive.
- Closing a Today tab (`⌘W`, its close button, Close Tab, Close Other Tabs)
  archives it, and it's still on Recently Closed. Spaces ▸ Archive Today Tabs
  (`⇧⌘K`) archives every Today tab of the current Space.
- The right sidebar has History · Archive · Downloads. Archive lists the
  profile's archived tabs by day with their Space, and its search ignores
  case and accents. Click a tab (or press Return) to bring it back in its
  Space; right-click for Restore, Copy Link and Delete. History ▸ Show
  Archive opens it. Clear Browsing Data ▸ History also clears the profile's
  Archive for the chosen time range, and deleting a profile deletes its
  Archive.
- The Command Bar: `⌘T` opens it inside the window; type an address or a
  search and press Return for a new Today tab in the current Space. `⌘L`
  opens it with the page's address, and Return loads the edit in the same
  tab. Results are grouped: open tabs of every Space (choosing one switches
  Space), pinned tabs and favorites, History, Spaces, actions and settings
  pages; type `/` to list only actions (`⇧⌘P`). A search engine's keyword
  then `Tab` enters site search with the engine's name as a chip. `↑`/`↓`,
  `⌃N`/`⌃P` and `Esc` work as you'd expect. A private window's Command Bar
  remembers its own pages in memory only.
- Settings ▸ Keyboard shortcuts ▸ Customize… (also Help ▸ Keyboard
  Shortcuts): every menu command by menu; click a shortcut and press a new
  one (`⌫` removes it), Reset, Reset All. A shortcut another command has
  offers Swap or Cancel; Quit, Copy and the other system shortcuts can't be
  taken. Each shortcut has a priority for when a page has focus: App wins,
  Site wins (the command runs only if the page doesn't use the key) or Press
  twice (a second press within a second). Saved under `shortcuts` in
  `settings.json`. Keys the system, text editing (`⌥⌫`, `⌥←`, `⌃A`, `⌃E`, `⌃K`…)
  or Vimium use, `⌘;`, `` ⌘` ``, `⌃⌘Space` and `⇧⌘/` can't be taken, and a
  hand-edited `settings.json` that puts two commands on one key keeps the
  first. A quick double press or key repeat runs a Site wins or Press twice
  command once per press, never more.
- `⌘T` then Return on nothing opens a new tab on the start page; `⌘L` then
  Return on the start page does nothing.
- `⌃Tab` shows your five most recent tabs while `⌃` is held; press `Tab`
  again to move on, release to switch (`⌃⇧Tab` goes back). Switching to
  another window or app closes it.
- Edit ▸ Copy URL (`⇧⌘C`) and Copy URL as Markdown (`⌥⇧⌘C`, `[title](url)`).
- View ▸ Hide Toolbar (`⇧⌘D`) hides the address toolbar in every window;
  wherever the address field would get focus (a new tab or window, launch)
  the Command Bar opens instead.
- How long a Today tab has been idle survives quitting, so "Archive Today
  tabs after" counts across relaunches.
- File ▸ Import Browser Data… brings in Arc (found on this Mac): every Space
  with its emoji, nearest color and pinned folders, Favorites (past 12 they
  are pinned in the profile's first Space), Today tabs (unloaded, in their
  Space; the window switches to the first imported Space), archived tabs
  with their favicons, each profile's History and Air Traffic Control
  rules. Arc's Default profile goes into Default; each other Arc profile
  becomes a profile named after its first Space (a profile with only
  History is offered unchecked). Also Chrome (bookmarks as a "Chrome
  Bookmarks" pinned folder, History), Safari's File ▸ Export Browsing Data
  ZIP (bookmarks, History with one visit per page) and a bookmarks `.html`
  file. Check what to bring in; History imports in the background with
  progress and Cancel, and only visits Settings ▸ Remove history items keeps
  (all of them with Manually; the checklist says since when). Today tabs
  open in a normal window even when the import started from a private one.
  Importing again skips what was imported before. Arc, Chrome and Safari
  files are only read.
- File ▸ Export Pinned Tabs… saves the current Space's pinned tabs, or every
  Space as a folder each, as a bookmarks `.html` file other browsers import.
- Settings ▸ Links from other apps ▸ Manage… lists the rules for links other
  apps open (imported from Arc's Air Traffic Control: an address that
  contains, is or starts with some text opens in a chosen Space or the most
  recent window's Space), with Delete.
- Chrome extensions: Settings ▸ Extensions installs one from its Chrome Web
  Store link or id (the package's signatures are checked as Chrome checks a
  store install, including the Web Store's own) or loads an unpacked folder,
  and lists them with an on/off switch, "Allow in private windows", site
  access (on all sites, on specific sites, when you click it) and Remove.
  Store extensions update daily. Extensions run in every Space and see the
  real tabs and windows; their toolbar buttons show badges and open their
  popups, their context-menu items appear in the page menu, their keyboard
  shortcuts work (never over the app's own), and the Extensions menu and
  the Command Bar list their commands. When an extension asks for more
  access, a sheet asks once and remembers the answer. uBlock Origin Lite,
  Wappalyzer and 1Password run.
- 1Password: install it from the Chrome Web Store (Settings ▸ Extensions)
  and sign in from its toolbar button. Soprano Web fills in the Chrome
  features WebKit lacks for it and other extensions: notifications (in
  Notification Center, with their buttons, attributed to the extension;
  the first time an extension posts one, Soprano Web asks whether to
  show its notifications before macOS asks for permission), new-tab
  tracking, managed storage, Chrome's user agent for extensions that
  require a Chrome version, and WebSockets in extension workers whose
  security policy names a WebSocket server.
- `browser extensions` and `browser extension install|enable|disable|remove|errors|update`
  let scripts and agents manage extensions; `browser extension action <id> [png]`
  clicks an extension's toolbar button and prints (and captures) its popup.

### Changed
- Soprano Web requires macOS 26 or later.
- Every Space keeps its own cookies and website data, History, site
  decisions, Archive and Favorites; Spaces never share them. New Space
  makes a Space that starts signed out everywhere, and Delete Space… (right-click
  a Space's icon; the Default Space stays) closes its tabs and removes all of
  its data from this Mac after asking.
- Settings ▸ Profiles, File ▸ New Window With Profile and the Dock's New
  Window With Profile are gone: ⌘N opens in the current window's Space.
  "Archive Today tabs after" moved into the Space's Edit Space… sheet.
- Spaces that shared a profile are separated on first launch: the first keeps
  its cookies, History, site decisions and Favorites, every other one gets
  its own and starts signed out; its open tabs reopen in it and its archived
  tabs move with it.
- Settings ▸ Websites and Website Data pick a Space instead of a profile, History ▸
  Clear Browsing Data… names the Space it clears, and a private window says
  "Private · <Space>".
- `browser new-window --space <n|name>` replaces `--profile`; `browser
  windows` and `spaces` no longer list profiles.
- Import Browser Data… makes every Arc Space a Space of its own; an Arc
  profile's History and favorites go to its first Space (Arc's Default
  profile's to the Default Space, whose name and pins Arc's first Space
  takes over while it's empty). A Chrome, Safari or bookmarks-file import
  goes into the Space chosen at the top of the sheet.
- Tabs move only into a window showing their own Space: dragging and
  `move-to-window` refuse a window on another Space, and Merge All Windows
  keeps every tab in its Space.
- Shortcuts moved for Arc's: Window ▸ Next Tab and Previous Tab are now
  `⌥⌘↓`/`⌥⌘↑` and walk the rail's favorites, pinned tabs and Today tabs
  (they were `⌃Tab`/`⌃⇧Tab`, now the recent-tab switcher); `⌘T` and `⌘L`
  open the Command Bar; View ▸ Command Palette… (`⇧⌘P`) is Search
  Actions… in the Command Bar; Spaces ▸ Bookmark This Page is Pin This
  Page (`⌘D`); Help ▸ Keyboard Shortcuts opens Settings ▸ Keyboard
  shortcuts.
- The start page says Pinned Tabs instead of Bookmarks, and its footer lists
  `⌘T` Command Bar, `⌘L` Edit address and `⌘D` Pin tab.
- Bookmarks are the current Space's pinned tabs in the rail now; the right
  sidebar keeps History, Archive and Downloads. Spaces ▸ Show Pinned Tabs (`⌥⌘B`)
  shows the rail. Close Other Tabs and Close Tabs Below / to the Right leave
  pinned and favorite tabs open.
- History lives in a SQLite database (`History.sqlite`) instead of
  `history.json` and keeps every visit, not just the last 5,000. Your existing
  history moves over on first launch; the old file stays as
  `history.json.migrated`.
- Zoom steps follow Safari (50, 75, 85, 100, 115, 125, 150, 175, 200, 250,
  300%); the per-tab zoom stored in the session is no longer used.
- Address-bar suggestions rank pages by frecency: how often and how recently
  you visited, with visits you typed counting three times and how you reached
  the page (link, typed, reload, back/forward, form) weighed in. Suggestions
  stay instant with a large history.
- Remove from History (right-click a visit in the History sidebar) removes
  every visit to that address; the sidebar search matches every word in titles
  and addresses.
- Closing the last tab now closes the window, like Safari and Chrome. The app
  keeps running in the Dock; reopening it creates a fresh start tab.
- The command palette moved from `⌘P` to `⇧⌘P`; `⌘9` selects the last tab.
- Close Window (`⇧⌘W`), the window's close button and closing a window's last
  tab put the whole window on History ▸ Recently Closed as one entry; `⇧⌘T`
  reopens it with its tabs, selection and frame. Quitting (`⌘Q`) keeps every
  window for the next launch instead.
- Downloads belong to the app, not a window: they keep going when the window
  that started them closes, and every window's Downloads sidebar lists them.
- Links from other apps open in the most recently used normal window, or in a
  new window when none is open; never in a private window.
- Tabs move only between windows of the same kind: dragging, Merge All
  Windows and `move-to-window` never mix private and normal tabs, and Move Tab
  to New Window keeps a private tab private.
- The `browser` CLI no longer sees private windows: `windows`, `--window`,
  `tabs`, `move-to-window`, `open` and `new-tab` work on normal windows only.
- Tabs move only between windows of the same profile: dragging, Merge All
  Windows (which gathers the current profile's windows) and `move-to-window`
  never mix profiles, and Move Tab to New Window keeps the tab's profile.
- `browser windows` lists each window's profile between its tab count and
  title.
- Settings ▸ Remove history items applies to every profile's History.
- `session.json` now holds every window; a session from an earlier version
  opens as one window and is kept as `session.json.migrated`.
- Duplicating a tab keeps its history and places the copy next to the original.
- `Esc` in the address bar first restores the page's address, then returns to
  the page.
- Files a server sends as attachments download instead of opening in the tab.
- The user agent includes Safari's `Version/… Safari/605.1.15` token, so sites
  that check for Safari work.
- The `browser` CLI talks to the app over a socket in its support folder that only
  your user can open; `--tab n` works on tab n without switching to it; `eval`
  awaits Promises, accepts `return`, prints JSON and fails with the JavaScript
  error.
- Address-bar suggestions and Vimium's `b` / `B` include bookmarks in every
  folder; Vimium shows each bookmark's folder. Your bookmarks move into the
  new folder format on first launch; the old file stays as
  `bookmarks.json.migrated`.

### Fixed
- Block ads and trackers: EasyList's few filters with `:has()` inside `:has()` (which
  WebKit rejects) are skipped, so the other hiding rules for those sites, compiled with
  them, work again. Lists compiled before are rebuilt from the saved copy at the next
  launch, without a download.
- Settings: the list scrolls between the header and the footer instead of running under
  the settings path and Done (Links from other apps and Extensions were hidden).
- Capture (P8 review): Full Page no longer includes what a page hides sideways (an
  off-canvas menu) and stays within ~42 million pixels; the file appears whole and never
  replaces one; the overlay closes when another field takes the keyboard, and the page
  shown gets the keyboard back.
- Boosts (P8 review): a page that replaces its adopted stylesheets no longer drops the
  Boost's CSS.
- Site Control Center (P6 review): the open popover closes when its tab stops being the
  page you look at and follows the tab's navigations; its zoom acts on its own tab, and
  "Block ads on this site" and extension access write the tab's current site, not the
  one it opened for; on a certificate interstitial a permission choice is stored for the
  interstitial's host instead of being dropped; unchecking "Allow on <host>" also removes
  a parent site that granted it; the harness's `--security-info` and `--site-blocking`
  keep the popover alive while pressing its controls.
- Split View (P5 review): dragging a divider resized only by the first step (the layout
  rebuilt the dividers mid-drag; now only the widths change); a favorite's live tab
  brought into the current Space leaves its split; Recently Closed windows keep their
  splits aligned when tabs of a deleted Space are dropped; ⌥⌘↓/↑ moves on from a split
  whose focused pane is pinned or a favorite; Vimium `<<`/`>>` on a pane moves the
  split's row; Merge All Windows and a Space's profile change keep splits.
- Resuming or retrying a download uses the cookies and website data of the
  Space it started in, not the Space the window shows now.
- A page that sets its title after it finished loading shows that title in
  History (private windows still write nothing).
- Resume and Retry on a download row of a deleted Space do nothing
  (they used to continue in the Default Space's cookies and data).
  Deleting a Space stops the downloads running in it; their rows stay.
- A page that sets its title after loading never renames the History row
  of an error page.
- Reopening a closed tab (`⇧⌘T`) takes it out of the Archive again.
- A private window's sidebar no longer shows the profile's Archive, and
  Clear Browsing Data ▸ History there also clears its Command Bar pages.
- `⌘L` in a pop-up window edits the pop-up's own address.
- Archiving or closing many tabs at once (`⇧⌘K`, tabs going idle, Close
  Other Tabs, Close Tabs Below) writes the Archive and redraws the tab list
  once instead of once per tab: `⇧⌘K` on 21 tabs went from about 1.9 s to
  0.3 s.
- `⌘L` (File → Open Location…) now focuses and selects the address bar; the
  shortcut was listed in Keyboard Shortcuts but never bound.
- Settings, history, bookmarks and downloads no longer reset when their file has a
  missing or unknown entry; an unreadable `settings.json` is kept as
  `settings.json.unreadable` instead of being overwritten.
- The address bar follows navigation while it is focused but not edited.
- View ▸ Stop (`⌘.`) only stops loading instead of reloading the page, and the
  sidebar button's tooltip says `⇧⌘B`.
- Closing a background tab keeps the selected tab selected.
- A page opened right after the start page is recorded in history, and a page
  without a title no longer keeps the "New Tab" title.
- Single-page apps (pages that change the address with `history.pushState` or a
  `#/` route) now add a History visit for each address they stay on for a
  second; jumping to an anchor on the page does not.
- Muting a tab also mutes media that starts later and stays muted after
  navigating.
- Typing in the sidebar's search field filters the list as you type.

### Security
- A web page can no longer open an extension's own pages (options,
  popup, dashboard) by navigating to their `chrome-extension://` address;
  only the extension's own pages can. An extension not allowed in
  private windows doesn't open its pages there either.
- Extensions can't open local files (`file:`) with `tabs.update`, their
  popup's links or their pages in tabs, can't open other extensions'
  pages, and a link of theirs to another app (`zoommtg:`, `smb:`, …)
  asks first, naming the extension. Extensions are never granted local
  file access; WebKit doesn't run content scripts on `file:` pages.
- Settings ▸ Extensions shows what an extension can do before it is
  added; `browser extension install` prints the list. An update never
  grants anything new: what it newly asks for waits until you allow it
  in the permission sheet.
- An unpacked folder carrying an installed extension's id (its `key`)
  no longer takes it over: Settings asks before replacing it (its
  settings, permissions and stored data reset); `browser extension
  install` refuses.
- Extension packages unpack in the app from the checked archive
  directory (no `ditto`): mismatched or overlapping entries, decoy
  directories, symlinks from any system, a file and a folder of the same
  name, and packages that unpack past 256 MB are refused. Web Store
  downloads stop as soon as they pass 256 MB.
- Native messaging hosts answer only the extensions on their allowlist.
- WebSockets of extension workers follow the extension's
  `connect-src`, reach local, private-network and `.local` hosts only
  with host access to them, refuse redirects and sign-in challenges,
  and are capped at 64 per extension and 16 MB per message.
- Extension notifications show the extension's name, at most 100 per
  extension; an extension that asks for notifications only as optional
  doesn't get them. `clients.matchAll` no longer lists an extension's
  pages in private windows it isn't allowed in.
