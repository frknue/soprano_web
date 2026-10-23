# Roadmap

Soprano Web's goal is to replace Arc as a daily browser. Arc stops working on 2026-12-22,
so the order below first fixes what breaks real sites, then adds the window and profile
architecture, then Arc's organization model with an importer for Arc's local data.
`docs/ARC-PARITY.md` has the evidence behind every item: Arc's behavior, the current code
(file:line), the WebKit API with its macOS version, and prior art. The native Vimium layer
and the `browser` CLI stay; Arc has neither.

## 1. Daily-driver blockers

Sign-in and links
- Popup blocker: `javaScriptCanOpenWindowsAutomatically = false`, open only user-initiated
  windows, show a "popup blocked" control. Implement `webViewDidClose` so `window.close()`
  closes OAuth and payment popups. Popup-sized `windowFeatures` become popup windows once
  §2 lands.
- ⌘-click and middle-click open a background tab, ⇧⌘-click a foreground tab
  (`WKNavigationAction.modifierFlags`; `buttonNumber` is a bitmask, middle = 4).
- `webView(_:didReceive:completionHandler:)`: HTTP Basic/Digest sheet, client certificates
  (`SFChooseIdentityPanel`), a TLS-error interstitial with Show Certificate
  (`SFCertificateTrustPanel`) and a per-host exception.
- Security indicator from `hasOnlySecureContent` and `serverTrust`, not the URL scheme.
- Ask before handing a link to another app (`mailto:`, `zoommtg:`, …); remember per site.
- Add `Version/… Safari/605.1.15` through `applicationNameForUserAgent`; sites that sniff
  Safari reject the bare WKWebView user agent.

Address bar
- Suggestions from history (visit and typed counts), bookmarks and open tabs (Switch to
  Tab), plus search-engine suggestions behind a setting; inline completion; Esc reverts.
- Fix the field keeping stale text while focused (`BrowserToolbarView.setAddress`).

Tabs and session
- Restore each tab's back/forward list (`interactionState`) and load restored tabs on first
  selection instead of all at launch.
- Crash recovery: reload once on `webViewWebContentProcessDidTerminate`, show a crash page
  on a loop, reload background tabs when selected.
- Persist the closed-tab stack across launches.
- Favicons: find `<link rel=icon>` with a content-world script, fetch through a cookie-less
  store, cache by host.
- Drag to reorder; tab context menu (duplicate with history, mute, copy link, close
  others/below); full-title tooltip.
- Back, forward (long-press history) and reload in the sidebar header, as in Arc.
- Link-hover URL status from a content-world `mouseover` script (no public delegate).
- Audio indicator and per-tab mute from media-element events (WebKit's mute is private).

Page tools
- Print (`printOperation(with:)`), Export as PDF (`createPDF`), Save As web archive
  (`createWebArchiveData`). ⌘P becomes Print; the command palette moves to ⇧⌘P until ⌘T
  becomes the Command Bar (§3).
- Context menu through `willOpenMenu(_:with:)`: Open Link in New Tab / Background Tab,
  Download Linked File, Copy Link, Search with <engine>.
- Edit ▸ Spelling and Grammar, Substitutions, Speech; the Services submenu; File ▸ Share.

Privacy, permissions, downloads
- Clear Browsing Data by time range that also removes website data
  (`WKWebsiteDataStore.removeData(ofTypes:modifiedSince:)`), and a per-site data list
  (`fetchDataRecords`). Today "Clear History" only empties `history.json`.
- Remember camera and microphone decisions per site; in-use indicator and stop control from
  `cameraCaptureState`/`microphoneCaptureState`. Autoplay setting
  (`mediaTypesRequiringUserActionForPlayback`).
- Web notifications through a JS `Notification` shim posting `UNUserNotificationCenter`
  notifications (WebKit's permission path is private; works while the tab is open).
- Downloads: keep resume data and in-progress items across launches, Retry, Ask Where to
  Save, honor `Content-Disposition: attachment`.

Robustness
- Settings: decode each key with its default (`decodeIfPresent`) and never overwrite a file
  that failed to decode. Add a `version` field to every JSON store.
- Menu fixes: ⌘. only stops (it calls `reload` today), the sidebar tooltip says ⇧⌘B (it
  says ⇧⌘H, which is Home), ⌘9 selects the last tab, ⇧⌘W closes the window's tabs instead
  of hiding the window with every tab still loaded.
- `browser` CLI: move from distributed notifications to a Unix socket only the user can
  open (today any local process can send `eval` and every reply is broadcast); `--tab`
  without switching the visible tab; `callAsyncJavaScript` so `eval` can await; wait for a
  selector or URL.
- Settings ▸ Make Default Browser (`NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`;
  macOS asks the user to confirm).
- Check that 1Password's Universal Autofill (⌘\) fills sign-in forms in Soprano Web; it is
  the only 1Password route that needs no work (see Needs a decision).

## 2. Windows, private browsing, profiles, memory

- App-level window manager: ⌘N, drag a tab out, Move Tab to New Window, Merge All Windows,
  popup windows, a closed-window stack. Prerequisites: stores notify many observers (each
  has one `onChange` closure today), downloads move to an app-level manager, the session
  file holds `windows[]`.
- Split `BrowserWindowController` (1,696 lines, every delegate) into per-feature tab
  responders as these features land, the way DuckDuckGo's tab extensions do.
- Private windows: one `WKWebsiteDataStore.nonPersistent()` per window, kept out of history,
  favicons, session, closed tabs, snapshots, suggestions and the `browser` CLI.
- Profiles: `WKWebsiteDataStore(forIdentifier:)` (macOS 14) per profile, each with its own
  history, permissions and (later) extension controller.
- Tab suspension: after idle time or memory pressure, keep a snapshot and `interactionState`
  and release the web view; skip tabs playing audio, capturing, or on a keep-alive list.
- History in SQLite with frecency for suggestions; Arc and Chrome history imports exceed the
  5,000-entry JSON cap by an order of magnitude. Bookmark folders.
- Content blocking: uBlock Origin Lite through `WKWebExtension` (loads and blocks on
  macOS 27), or `WKContentRuleList`s built from EasyList (150,000 rules per list).
- Zoom remembered per site (eTLD+1), plus a default zoom.

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
