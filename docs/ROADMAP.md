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

- App-level window manager: ⌘N, drag a tab out, Move Tab to New Window, Merge All Windows,
  popup windows, a closed-window stack. **Built on `feat/stage-2` (windows slice):** the
  window manager, ⌘N with cascade, every window saved and restored with its frame
  (session version 2 with `windows[]`; version 1 migrates), one recently-closed stack of
  tabs and windows (⇧⌘T, History ▸ Recently Closed), multicast store observers, the
  app-level download manager, per-tab `attachTab`/`detachTab`, and `browser windows` /
  `--window` / `new-window` / `close-window`. **Built on `feat/stage-2` (tab-move
  slice):** Window ▸ Move Tab to New Window (also in the tab menu and on Vimium
  `W`), dragging a tab out of the strip or rail onto another window's tabs or into
  a new window under the pointer, Window ▸ Merge All Windows, pop-up windows for
  `window.open` with a size (compact chrome, `window.opener`, `window.close()`,
  not saved in the session) and `browser move-to-window <k|new>`. Left: trying a
  real-mouse drag between two on-screen windows (the harness calls the same drop
  and drag-out handlers but can't drive a system drag session).
- Split `BrowserWindowController` (1,696 lines, every delegate) into per-feature tab
  responders as these features land, the way DuckDuckGo's tab extensions do.
- Private windows: one `WKWebsiteDataStore.nonPersistent()` per window, kept out of history,
  favicons, session, closed tabs, snapshots, suggestions and the `browser` CLI. **Built on
  `feat/stage-2` (private slice):** File ▸ New Private Window (`⇧⌘N`, Dock menu) with one
  non-persistent store shared by the window, its pop-ups and the windows its tabs move into
  (`BrowserDataContext`); no history, typed flags, session entry, favicon files, saved site
  decisions (an in-memory overlay over the saved ones) or saved download records; its own
  closed-tab stack and in-memory certificate exceptions; suggestions from bookmarks, its tabs
  and search only; tabs never move between private and normal windows; links from other apps
  and the CLI never reach it; Folio Ink with a "Private" mark in both tab layouts. "Snapshots"
  (tab-sleep images) arrive with the sleep slice, which must keep a private tab's snapshot in
  memory.
- Profiles: `WKWebsiteDataStore(forIdentifier:)` (macOS 14) per profile, each with its own
  history, permissions and (later) extension controller. **Built on `feat/stage-2`
  (profiles slice):** `profiles.json` (Default always first, renamable, never deletable);
  Default keeps `WKWebsiteDataStore.default()`, `History.sqlite` and
  `site-permissions.json` in the support folder, every other profile gets
  `WKWebsiteDataStore(forIdentifier: <id>)` and `Profiles/<id>/` with its own History and
  site decisions; one data context per profile shared by its windows; bookmarks,
  downloads, favicons, settings and Recently Closed shared (entries reopen in their
  profile); ⌘N in the current window's profile, File ▸ New Window With Profile and the
  Dock menu; private windows layer over the profile they were opened from ("Private ·
  Work"); session v2 stores each window's profile (a deleted one restores in Default);
  History sidebar, suggestions, start page, Settings ▸ Websites and Website Data (with a
  picker), Clear Browsing Data and the daily retention pass follow the profile; Settings ▸
  Profiles adds, renames, recolors and deletes (closing its windows, dropping its closed
  entries, `WKWebsiteDataStore.remove(forIdentifier:)` once its web views are gone, and
  its folder); the color mark and name in the rail header or before the address field;
  tabs move and merge only within a profile; `browser windows` shows profiles and
  `new-window --profile <name>`. Left: Arc's Space→profile mapping (stage 3) and
  per-profile extension controllers (stage 4).
- Tab suspension: after idle time or memory pressure, keep a snapshot and `interactionState`
  and release the web view; skip tabs playing audio, capturing, or on a keep-alive list.
  **Built on `feat/stage-2` (sleep slice):** Settings ▸ Put inactive tabs to sleep (never,
  15 min, 1 h default, 4 h) and a `DispatchSource` memory pressure source (warning: idle
  30 min, critical: 5 min; "never" also holds under pressure); a sleeping tab keeps title,
  URL, favicon, back/forward (`interactionState`) and a JPEG snapshot in memory, its web
  view is swapped for an empty one (no WebContent process until it loads) and the old one
  and its process go away; it looks dimmed in both layouts and wakes through the lazy
  restore path on selection, a CLI command or a move to another window, showing the
  snapshot while it reloads. Exempt: each window's selected tab, audio, camera/mic/screen
  capture, loading, open dialogs/sheets/sign-in/permission prompts, `beforeunload`
  listeners or edited fields (page-world `sleepGuard` script), pop-up windows and their
  openers, and Keep This Site Awake (tab menu, per host, in Settings ▸ Websites). Measured:
  a hidden attached web view already runs timers at 1/s with no rAF and 0.1% WebContent
  CPU, the same as a detached one (`.suspend` did not suspend within 60 s; audio and page
  state survived both), so background tabs stay attached.
- History in SQLite with frecency for suggestions; Arc and Chrome history imports exceed the
  5,000-entry JSON cap by an order of magnitude. Bookmark folders. **Built on `feat/stage-2`
  (history slice):** `History.sqlite` through the system SQLite (WAL, one database per
  folder, so per profile once profiles land) with one row per address and one per visit
  and how it was reached; `history.json` migrates once and stays as
  `history.json.migrated`; no entry cap; frecency (recency buckets × visit-kind weights,
  typed visits ×3) ranks address-bar suggestions from indexed queries (address prefix,
  FTS5 word starts, FTS5 trigram substrings) — under 20 ms per keystroke with 100,000
  visits; Settings ▸ Remove history items (one day … one year, the default, or manually),
  pruned at launch and daily; the History sidebar grouped by day, paged as it scrolls,
  searching titles and addresses; Clear Browsing Data deletes through SQL; same-document
  (`pushState`) URL changes become visits after a second. `BrowserHistoryImport` and
  `importVisits` are the entry point for the stage 3 Arc/Chrome importers. **Built on
  `feat/stage-2` (bookmarks slice):** bookmark folders — `bookmarks.json` version 2 is
  one tree (folders with ordered children, bookmarks) shared by every profile; the flat
  version 1 list migrates into the top level once and stays as `bookmarks.json.migrated`;
  tolerant decoding (bad nodes skipped, repeated ids dropped). The Bookmarks sidebar is
  an outline (disclosure triangles, favicons, open folders remembered in `UserDefaults`,
  drag to reorder and move into or out of folders, New Folder, Rename, Edit Bookmark,
  Delete asking first for a folder with contents, Open / Open in New Tab / Open All in
  Tabs / Copy Link) whose search lists matches with their folder path; `⌘D` and the
  star add to the last-used folder and open a Folio popover (name, folder picker, Done,
  Remove); the Bookmarks menu lists the tree with a submenu per folder; the start page
  shows top-level folders as cards that expand in place; suggestions, the frecency boost
  and Vimium `b`/`B` see every folder (Vimium shows the path).
  `BrowserBookmarkStore.insert(_:into:at:)` is the entry point for the stage 3 Chrome,
  Safari and HTML bookmark importers. Left: whether bookmarks stay next to stage 3's
  pinned tabs and Favorites (open decision below); a bookmarks bar was out of this
  slice's scope.
- Content blocking: uBlock Origin Lite through `WKWebExtension` (loads and blocks on
  macOS 27), or `WKContentRuleList`s built from EasyList (150,000 rules per list).
- Zoom remembered per site, plus a default zoom. **Built on `feat/stage-2` (sleep slice):**
  per host (not eTLD+1, as Safari and Chrome do) in the profile's `site-permissions.json`
  (a private window's overlay keeps changes in memory); ⌘+/⌘- in Safari's steps (50–300%)
  change every open tab of the host in the profile; ⌘0 forgets the site; Settings ▸
  Default page zoom; a page applies its host's zoom on commit; a percentage chip in the
  address field resets; Settings ▸ Websites lists zoom per site. The session's per-tab zoom
  is ignored.

## 3. Arc's organization model and import

- Spaces: name, emoji or SF Symbol, theme color, a profile per Space; Pinned and Today
  sections; switch with ⌃1…⌃9, ⌥⌘←/→ and a two-finger swipe.
- Favorites: icon grid per profile above the Space title (Arc caps it at 12).
- Pinned tabs: remember the pinned URL, mark a tab that navigated away, reset on icon click,
  ⌘-click the icon to reset and keep the current page in a new tab, Replace Pin with
  Current Page.
- Folders: nested, never archived, searchable preview on hover.
- Today tabs archive after idle time (per profile: never, 30 days, 7 days, 24 h, 12 h, 6 h,
  1 h; Arc defaults to 12 h). Archive view: searchable, restores into the original Space.
- Command Bar on ⌘T (tabs, history, Spaces, actions behind `/`, settings, site search on
  Tab); ⌘L edits the current URL in the same bar. One command registry feeds the menu bar,
  remappable shortcuts (with a site-wins / app-wins / press-twice priority) and the Command
  Bar, as Arc's menu-item metadata does.
- ⌃Tab switches between recent tabs; ⌥⌘↑/↓ walks the sidebar; ⇧⌘C copies the URL, ⌥⇧⌘C
  as Markdown; ⇧⌘K clears Today; ⇧⌘D toggles the toolbar.
- Custom search engines with `%s` templates and keywords.
- Import from Arc: `StorableSidebar.json` (Spaces with their profiles, Favorites per
  profile, pinned trees, Today tabs), `StorableArchiveItems.json`, the favicon caches,
  each profile's Chromium `History`, `StorableLinkRouting.json`. Read Arc's folder in
  place and read-only (SQLite with `immutable=1`); the files stay on disk after Arc stops
  opening on 2026-12-22. Cookies and passwords don't transfer; Easels, Notes and Boosts
  aren't on disk. `Arc Data Export.md` as a lossy fallback.
- Import from Chrome (`Bookmarks`, `History`) and Safari (Export Browsing Data ZIP);
  bookmarks HTML import and export.

## 4. Arc extras

- Little Arc: links from other apps, ⌥⌘N and a global hotkey open a small window; ⌘O moves
  the page into a Space; archived after 6 h.
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
- Web extensions on `WKWebExtension` (macOS 15.4): tab and window protocols, Chrome Web Store
  install with CRX3 signature check, per-site access, `hasAccessToPrivateData` for private
  windows, and shims for Chrome APIs WebKit lacks (`notifications`, `storage.managed`,
  `webNavigation` events), which 1Password needs.
- Page translation with Apple's Translation framework (`TranslationSession` outside SwiftUI
  from macOS 26); Reader view with Readability.js (Apache-2.0).
- GitHub pull requests as a live folder through `gh`, as Soprano Git already does.
- AppleScript (windows, tabs, Spaces, URL, JavaScript behind an opt-in) and a Dock menu.

## Needs a decision

- **1Password route.** Without an Apple Developer team, 1Password's desktop app won't pair
  with Soprano Web. (a) Universal Autofill only: free, fills by Accessibility, matching per
  site untested. (b) Run the 1Password extension on `WKWebExtension` with Chrome-API shims,
  signed in to the account inside the extension: fails today at `chrome.notifications`, can
  break with each 1Password update, but its in-page passkey hook needs no Apple
  entitlement. (c) Soprano Web's own Keychain vault with CSV import, local to this Mac.
- **macOS floor for extensions.** Keep macOS 14 and gate `WKWebExtension` at 15.4, or raise
  the minimum.
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
