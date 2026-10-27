# Roadmap

Soprano Web's goal is to replace Arc as a daily browser. Arc stops working on 2026-12-22,
so the order below first fixes what breaks real sites, then adds the window and profile
architecture, then Arc's organization model with an importer for Arc's local data.
`docs/ARC-PARITY.md` has the evidence behind every item: Arc's behavior, the current code
(file:line), the WebKit API with its macOS version, and prior art. The native Vimium layer
and the `browser` CLI stay; Arc has neither.

## 1. Daily-driver blockers

Built on `feat/stage-1` (see `CHANGELOG.md`): pop-up blocking and `window.close()`,
modifier clicks, external-app prompts, Safari user agent; HTTP sign-in, client
certificates, TLS interstitial and a real security indicator; address-bar suggestions and
inline completion; lazy restore with back/forward history, persisted closed tabs, crash
recovery; favicons, tab drag/menu/indicators, navigation buttons, link status; print, PDF,
Save As, web-view context menu, text and Services menus, Share; Clear Browsing Data,
Website Data, resumable downloads, Make Default; per-site camera/mic/notification/pop-up
decisions, autoplay, notification shim, robust mute; the `browser` CLI over a user-only
socket; robust settings and stores.

Left over, all needing a real window or device rather than the offscreen harness:
- Check that 1Password's Universal Autofill (⌘\) fills sign-in forms in Soprano Web; it is
  the only 1Password route that needs no work (see Needs a decision).
- Try camera and microphone prompts with a real camera, notification delivery from the
  installed app, the Ask Where to Save panel, and real-mouse tab dragging, long-press
  history menus and context menus.

Known limits: notifications only while their tab is open (no Web Push), tab mute and the
audio indicator don't cover WebAudio, `window.print()` inside iframes does nothing, and
geolocation stays denied until the toolchain can use the macOS 27 SDK (see Needs a
decision).

## 2. Windows, private browsing, profiles, memory

Built on `feat/stage-2` (see `CHANGELOG.md`): an app-level window manager (⌘N, every window
saved and restored, one recently-closed stack of tabs and windows, `browser windows` /
`--window`); moving tabs between windows (menu, drag, Vimium `W`, Merge All Windows) and
sized pop-up windows; private windows (⇧⌘N) on one in-memory data store each; profiles
with their own data store, history and site decisions; history in SQLite with frecency
suggestions, retention and a day-grouped sidebar; bookmark folders; tab sleep and
per-site zoom; a built-in ad and tracker blocker compiling EasyList and EasyPrivacy into
`WKContentRuleList`s.

Decided along the way:
- Content blocking is built in on `WKContentRuleList`s (macOS 14, no extension runtime);
  uBlock Origin Lite stays a stage 4 option. Switching a site off removes the lists from
  its tabs instead of compiling an exceptions list, which would recompile every list
  (5–7 s each) per switch.
- Zoom is per host, as in Safari and Chrome. Bookmarks are shared by all profiles.
- Background tabs stay in the window: a hidden web view already runs timers at 1/s with no
  animation frames and ~0.1% CPU, the same as a detached one.
- "Never" in Put inactive tabs to sleep also holds under memory pressure.
- Private windows deny web notifications (Notification Center keeps its own copies);
  bookmarks and settings changed in them are saved, as in Safari and Chrome.

Measured: suggestions under 20 ms per keystroke with 100,000 visits; EasyList (85,952
filters → 66,956 rules) and EasyPrivacy (56,408 → 56,330) download, convert and compile in
6.7 s and 5.2 s, 72.9 MB on disk.

Left:
- Try a real-mouse drag between two on-screen windows (the harness drives the same drop
  handlers, not a system drag session).
- Prove generic element hiding with the real EasyList: a selector WebKit rejects drops its
  whole batch of 250 without a compile error.
- A blocked-request count (WebKit has no public callback) and the filter types WebKit
  can't express (`$csp`, `$redirect`, `$removeparam`, `$rewrite`, scriptlets, procedural
  CSS) — uBlock Origin Lite in stage 4.
- Arc's Space→profile mapping (stage 3) and per-profile extensions (stage 4).

## 3. Arc's organization model and import

Built so far on `feat/stage-3` (see `CHANGELOG.md` and `docs/STAGE-3-PLAN.md`): Spaces
(name, emoji or SF Symbol, color mark, a profile per Space; ⌃1…⌃9, ⌥⌘←/→, a two-finger
swipe and the rail's switcher with New Space / Edit Space), per-profile Favorites (12),
pinned trees replacing bookmarks, and live pinned and favorite tabs in the rail (the "/"
mark, reset on icon click, ⌘-click keeps the page, Replace Pin with Current Page, ⌘W
unloads to the pin, searchable folder preview on hover); custom search engines with `%s`
templates and keywords; the Archive (Today tabs archive after idle time per profile:
never, 30 days, 7 days, 24 h, 12 h by default, 6 h, 1 h; ⌘W and ⇧⌘K archive; a searchable
Archive section in the right sidebar restores a tab into its original Space); the
Command Bar on ⌘T (open tabs of every Space, pins and favorites, History, Spaces, `/`
actions, settings pages, site search on Tab after a keyword) and ⌘L (edits the current
URL in the same bar); one command registry feeding the menu bar, Settings ▸ Keyboard
shortcuts (remapping, conflicts with Swap, App wins / Site wins / Press twice) and the
Command Bar; ⌃Tab recent-tab switcher, ⌥⌘↑/↓ rail walk, ⇧⌘C / ⌥⇧⌘C copy URL and
Markdown, ⇧⌘D toggles the toolbar; File ▸ Import Browser Data… from Arc (Spaces with
emoji and nearest Folio color, pinned trees, Favorites with the overflow pinned, Today
tabs unloaded in the importing window, the Archive with its favicons, each profile's
History off the main thread with progress and cancel, Air Traffic Control rules applied
to links from other apps and listed in Settings ▸ Links from other apps; Arc's folder
read in place, SQLite with `immutable=1`; a re-import skips what an earlier one made),
Chrome (`Bookmarks` as a pinned folder, `History`), Safari's Export Browsing Data ZIP
and bookmarks HTML files, and File ▸ Export Pinned Tabs… as bookmarks HTML.

- Not built: Arc's `Arc Data Export.md` as a lossy fallback; Firefox, Brave, Edge and
  Vivaldi as sources; Arc's `defaultDestination` rule (Little Arc, §4). Cookies and
  passwords don't transfer; Easels, Notes and Boosts aren't on disk.

## 4. Arc extras

- Little Arc: built in Stage 4 P3 (links from other apps default to it; ⌥⌘N, global
  shortcut, ⌘O, "Open in", 6 h archive).
- Peek: links to other sites from pinned tabs and Favorites, and ⇧-clicks, open in an
  overlay; ⌘O expands it to a tab.
- Split View: up to 4 panes saved as one sidebar item; ⌃⇧= adds, ⌃⇧- closes, ⌃⇧1…4 focus.
- Air Traffic Control: "URL contains / equals" → Space, plus the default for links from
  other apps.
- Mini Player: when you leave a playing video's tab, its web view moves into a floating
  panel (WebKit's Picture in Picture switch is private on macOS); audio controls in the
  sidebar from Media Session metadata.
- Site Control Center: per-site popover for permissions, zoom, content blocking,
  extensions, Boosts and clearing site data.
- Boosts: per-site CSS and JavaScript in an isolated content world, a Zap element picker.
  An agent can write one through the `browser` CLI.
- Capture: area and full-page screenshots (`takeSnapshot(with:)`).
- Web extensions, what is left: 1Password signed in (stage 4 P2 runs it up to its sign-in
  page; the signed-in popup, inline menu and notifier socket await the user's sign-in,
  see `docs/STATUS.md`). Built in P1/P2: the runtime on `WKWebExtension` (tabs and
  windows, Chrome Web Store install with full CRX3 check, daily updates, unpacked folders,
  site access, private windows, toolbar buttons and popups, commands, Settings ▸
  Extensions, the `browser extension` CLI) and the native stand-ins for Chrome APIs
  WebKit lacks or gets wrong (`BrowserExtensionShims`).
- Page translation with Apple's Translation framework (`TranslationSession` outside SwiftUI
  from macOS 26); Reader view with Readability.js (Apache-2.0).
- GitHub pull requests as a live folder through `gh`.
- AppleScript (windows, tabs, Spaces, URL, JavaScript behind an opt-in) and a Dock menu.

## Needs a decision

Decided on 2026-10-27 (see `docs/STAGE-4-PLAN.md`): macOS 26 is the floor, and passwords
come from the 1Password extension on `WKWebExtension` with native stand-ins for the Chrome
APIs WebKit lacks (Universal Autofill until it runs; no own vault).

- **Toolchain.** The geolocation delegate, `willSubmitForm` (password capture), Global
  Privacy Control and `getCookies(for:)` exist only in the Xcode 27 SDK; Homebrew Swift on
  the Command Line Tools macOS 26 SDK cannot build them. Before macOS 27 APIs, WebKit
  denies geolocation unless the app answers through a JS shim and CoreLocation.
- **Bookmarks or pinned tabs.** Arc has no bookmarks and imports them as pinned tabs.
  Keep both models, or let the pinned tree replace bookmarks.
- **Space colors in Folio.** Arc tints the whole window per Space; Folio reserves the accent
  and fixes palettes per theme.

## Not copied

- Arc account, Arc Sync, shared Space and Folder links, Membership Card, referrals,
  alternate app icons, sound effects: they need Arc's servers or are not browser features.
- Easels and Notes; Arc deprecated Notes itself.
- Arc Max (ChatGPT in the Command Bar, Tidy titles and downloads, 5-Second Previews): AI
  comes from Soprano's agents through the `browser` CLI.
- Calendar and mail previews on hover (0.4% of Arc's daily users used calendar previews).
- Chromium-only surface: DevTools Protocol, Cast, installed web-app shims, `arc://` pages.
- Sparkle updates: the family installs with `scripts/install.sh`.
- Anything that needs an Apple Developer team, which Soprano Web won't have (ad-hoc
  signing): passkeys from iCloud Keychain on arbitrary sites (managed entitlement
  `com.apple.developer.web-browser.public-key-credential`), CloudKit sync, push, Handoff,
  and pairing with 1Password's desktop app ("code signed by Apple in the Applications
  folder").
