# Changelog

All notable changes to Soprano Web are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The version in a released heading matches `CFBundleShortVersionString` in
`Support/Info.plist`, the single source of truth for the version shown in the
app.

## [Unreleased]

### Added
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
  has its own. It records no history, no session and no favicon files; new
  camera, microphone, notification, pop-up and external-app answers last only
  for the window; its downloads are listed there while it is open but not
  saved; certificate exceptions and client certificates chosen there stay in
  it. Files you download are kept.
- A private window always uses Folio Ink, whatever the theme, and shows
  **Private** in the tab rail header (or before the address field with
  horizontal tabs); its title starts with "Private — ".
- In a private window, `⇧⌘T` reopens that window's own closed tabs, and
  closing the window is final: nothing goes onto History ▸ Recently Closed.
  Its address bar suggests bookmarks, its tabs and searches, never history.

### Changed
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

### Fixed
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
- Muting a tab also mutes media that starts later and stays muted after
  navigating.
