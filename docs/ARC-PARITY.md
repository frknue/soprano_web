# Arc parity

What Arc does, what Soprano Web does today, and what the system WebKit allows. Snapshot
taken 2026-10-23 against Arc 1.169.0 (Chromium 155), Soprano Web `main` @3be5e23 and the
macOS 27 SDK; the "Soprano Web" column describes that commit. Stage 1 (roadmap §1) has
since built every row marked 1. `docs/ROADMAP.md` turns this into a build order.
Bracketed tags point to [Sources](#sources).

## Arc's status

- Arc for macOS stops working on **2026-12-22**. New Arc accounts ended on 2026-10-22;
  until the sunset Arc gets only basic fixes [A1].
- After 2026-12-22 Arc no longer opens, so its local data is reachable only through its
  files on disk [A1]. Arc's own export is a Markdown list of links per Space [A3].
- Feature work stopped in 2025 [A5]; every 2025–2026 release is a Chromium bump [A4].
  Atlassian bought The Browser Company (signed 2025-09-04, closed 2025-10-21) for Dia [A6].
- Dia does not carry over Air Traffic Control, Boosts, Easels, Little Arc or Peek [A2].
- Most of the help center is gone. Feature behavior below comes from 2024 Wayback copies of
  the original help articles and from the 1.169.0 bundle (`Base.lproj/MainMenu.nib`,
  strings in `Contents/MacOS/Arc`). Arc was not launched.

## Arc's model in brief

- **Space**: a named sidebar with an emoji or icon, a color theme, its own Pinned and Today
  sections, and optionally its own Profile. Switch with ⌃1…⌃9, ⌥⌘←/→ or a two-finger
  swipe [H-space].
- **Profile**: isolates logins, passwords and autofill, history, cookies and cache,
  extensions, Favorites, archive timing and settings. Several Spaces can share one [H-prof].
  **Soprano Web deviates here (user decision)**: every Space is isolated — its own
  cookies, website data, History, site decisions, Archive and Favorites — and Spaces never
  share a profile; there is no Profiles UI. Importing Arc gives each Arc Space its own Space;
  an Arc Profile's History and Favorites go to the first of its Spaces.
- **Favorites**: up to 12 icons per Profile above the Space title [H-fav].
- **Pinned tabs**: belong to one Space and never archive. They snap back to the pinned URL
  (click the icon; a "/" marks a tab that navigated away), ⌘-clicking the icon also opens
  the current page in a new tab, and links to other sites open in Peek. ⌘D pins. Arc has
  no bookmarks: imported bookmarks become pinned tabs [H-pin].
- **Folders**: nested, never archive, searchable preview on hover [H-fold].
- **Today tabs**: auto-archive when idle. Per Profile: never, 30 days, 7 days, 24 h, 12 h
  (default), 6 h, 1 h. The Archive is searchable and restores a tab into its original
  Space [H-arch; bundle strings].
- **Command Bar** (⌘T): open tabs, history, Spaces, actions (`/` prefix), extensions and
  settings; ⌘L edits the current URL through the same bar [A7]. Each main-menu item carries
  `arcKeyBindingID`, `arcTypeTravelID` and trigger synonyms as nib runtime attributes, so
  one declaration feeds the menu bar, the remappable shortcuts and the Command Bar.
- **Link routing**: links from other apps open in **Little Arc** (also ⌥⌘N; ⌘O moves the
  page into a Space; archived after 6 h) [H-little]. **Air Traffic Control** sends URLs that
  "contain" or "equal" a string to a Space [H-atc]. **Peek** overlays off-site links from
  pinned tabs and Favorites, plus any ⇧-click [H-peek]. **Split View** holds up to 4 panes
  as one sidebar item [H-split].
- Usage from the CEO's 2025 letter: more than one Space 5.52% of daily users, Live Folders
  4.17%, calendar previews 0.4% [A5].

## Feature matrix

Status of Soprano Web: **done**, **partial**, **missing**, **broken**. `BWC` =
`Sources/SopranoWeb/Browser/BrowserWindowController.swift`. Roadmap column = section of
`docs/ROADMAP.md`; "—" = nothing planned, "✗" = not copied.

### Windows and tabs

| Feature | Arc | Soprano Web | WebKit path (min macOS) | Roadmap |
|---|---|---|---|---|
| Multiple windows | ⌘N; ⌃⌘N blank window; drag a tab out | missing: one controller per app (`App/AppDelegate.swift:5,29-37`), `tabbingMode = .disallowed` (`BWC:132`) | AppKit | 2 |
| Private window | ⇧⌘N; no Spaces, no history; extensions opt-in [H-keys] | missing: every tab uses `.default()` (`BWC:437`) | `WKWebsiteDataStore.nonPersistent()` (10.11) | 2 |
| Page-opened windows | Chromium popups | partial: always a foreground tab, `windowFeatures` ignored, no popup blocker (`javaScriptCanOpenWindowsAutomatically = true`, `BWC:440,1387-1400`) | `createWebViewWith…windowFeatures:` (10.10) | 1 |
| `window.close()` | yes | missing: no `webViewDidClose`, so OAuth popups stay open | `webViewDidClose` (10.11) | 1 |
| Modifier clicks | ⌘-click tab, ⇧-click Peek, ⌥-click split, ⌥⌘-click Little Arc | missing: `decidePolicyFor` ignores modifiers (`BWC:1347-1377`) | `WKNavigationAction.modifierFlags`, `buttonNumber` (bitmask: middle = 4) | 1, 4 |
| Reorder, duplicate | drag; ⌥-drag duplicates with history | partial: Vimium `<<`/`>>`; `yt` duplicates the URL only (`BWC:990-999`) | AppKit; `interactionState` | 1 |
| Pinned tabs | per Space, reset to pinned URL | missing (Vimium `⌥P` toast) | app model | 3 |
| Favorites | ≤12 per Profile | missing | app model | 3 |
| Folders | nested | missing: bookmarks are a flat list | app model | 3 |
| Auto-archive and Archive | Today tabs; searchable Archive | missing: 20 closed tabs in memory (`BWC:571-574`) | app model | 1, 3 |
| Tab switcher | ⌃Tab over the 5 most recent tabs | ⌃Tab = next tab | AppKit | 3 |
| Session restore | windows, tabs, back/forward | partial: URL, title and zoom only; every tab loads at launch (`BrowserTab.swift:36-42`, `BWC:448-462`) | `interactionState` (12.0) | 1 |
| Tab suspension | Chromium; 21 web apps never suspended (`web_content_behavior.json`) | missing: hidden web views stay attached (`BWC:414-423`), so `inactiveSchedulingPolicy` never applies | snapshot + `interactionState`, release the view; `inactiveSchedulingPolicy` (14.0) for detached views | 2 |
| Crash recovery | Sad Tab page | partial: unconditional `reload()` (`BWC:1307-1309`) | `webViewWebContentProcessDidTerminate` (10.11) | 1 |
| Audio indicator, mute | badge; mute per tab | partial: Vimium `⌥M` mutes current media elements by script; no indicator | private (`_isPlayingAudio`, `_setPageMuted:`); script on media events | 1 |
| Favicons | yes | missing | no API: content-world `<link rel=icon>` scan + fetch | 1 |
| Title tooltip, nav buttons | sidebar header holds back/forward/reload | missing | AppKit | 1 |
| Split View | ≤4 panes | built (stage 4 P5): 2–4 panes, dividers with saved ratios, one rail row/strip item, ⌃⇧=/⌃⇧-/⌃⇧1…4, ⌥-click, drop on a pane edge, Arc Today split views import (vertical layout shown side by side; pinned split views stay pins) | several `WKWebView`s in the page area | 4 |
| Peek | overlay | done (Stage 4 P4): pinned/favorite links to other sites and ⇧-clicks open a Folio panel over the page with its own web view in the tab's data context; ⌘O "Open as Tab" keeps history; Esc, ⌘W, backdrop close (`BrowserPeek.swift`, `BrowserWindowController+Peek.swift`) | a second `WKWebView` the window's delegates resolve (`tab(for:)`) | 4 |
| Little Arc | small window for external links | done (Stage 4 P3): links from other apps (unless a rule matches), ⌥⌘N, optional global shortcut, ⌘O, "Open in", 6 h archive (`BrowserLittleArc.swift`, `BrowserWindowManager+LittleArc.swift`) | `application(_:open:)`, Carbon `RegisterEventHotKey` | 4 |

### Address bar and commands

| Feature | Arc | Soprano Web | WebKit path | Roadmap |
|---|---|---|---|---|
| Suggestions, inline completion | history, tabs, search suggestions; Tab enters site search | missing: plain `NSTextField`; stale text while focused (`BrowserToolbarView.swift:168-171`) | app; history needs visit/typed counts | 1 |
| Command Bar | ⌘T, actions, Spaces, settings | done: ⌘T/⌘L Command Bar in the window (tabs, pins, History, Spaces, `/` actions, settings, site search) from one registry (`BrowserCommands.swift`) | app; one command registry | — |
| Search engines | Chromium list, custom `%s` engines, site search | partial: 3 fixed engines | app | 3 |
| Copy URL / as Markdown | ⇧⌘C / ⌥⇧⌘C | done | `NSPasteboard` | — |
| Custom shortcuts | Settings › Shortcuts, conflict priority (Arc wins / site wins / press twice) | done: Settings ▸ Keyboard shortcuts; Site wins via WebKit's unhandled-key hand-back plus a page `keydown` report | app | — |

### Page

| Feature | Arc | Soprano Web | WebKit path (min macOS) | Roadmap |
|---|---|---|---|---|
| Print, PDF, Save As | ⌘P, ⇧⌘S | missing; ⌘P opens the palette (`App/MainMenu.swift:77`) | `printOperation(with:)`, `createPDF`, `createWebArchiveData` (11.0) | 1 |
| Find | ⌘F, ⌘G, ⌘J | done (no match count: `WKFindResult` has only `matchFound`) | `find(_:configuration:)` (11.0) | — |
| Zoom | per site | partial: per tab, saved in the session | `pageZoom` (11.0) | 2 |
| Context menu | custom items | missing: WebKit's default menu | override `willOpenMenu(_:with:)`; match identifier strings such as `WKMenuItemIdentifierOpenLinkInNewWindow` | 1 |
| Link-hover status | Chromium status bubble | missing | private (`_mouseDidMoveOverElement`); content-world `mouseover` script | 1 |
| Spelling, Substitutions, Speech, Services, Share | Edit menu, Services | missing menus (`App/MainMenu.swift:61-74`) | NSResponder actions on `WKWebView`; `NSSharingServicePicker` | 1 |
| Translation | Google Translate | missing | Translation framework: `TranslationSession(installedSource:target:)` (26.0), SwiftUI `.translationTask` (15.0) | 4 |
| Reader | none | missing | Readability.js (Apache-2.0) in a `WKContentWorld` | 4 |
| Picture in Picture | automatic when leaving a video tab | missing (WebKit's macOS default is off) | private (`_allowsPictureInPictureMediaPlayback`); floating panel hosting the web view | 4 |
| Capture | ⇧⌘2 area, full page, portrait | missing (CLI viewport screenshot only) | `takeSnapshot(with:)` (10.13) | 4 |
| Boosts | per-site CSS/JS, fonts, Zap | built (stage 4 P7): per host (+ `www.`), app-wide `boosts.json`; CSS as a `<style>` at document start (live), JS in its own content world (next load), Zap picker with stable selectors (live); editor sheet from the Site Control Center and `/boost`; CLI `browser boost`; no font picker (write it as CSS) | `WKUserScript` + `WKContentWorld` (11.0); user style sheets are private, inject `<style>` | 4 |
| Developer tools | ⌥⌘I, ⌥⌘U, Developer Mode on localhost | partial: `isInspectable` (Safari ▸ Develop), Vimium `gs` | in-app inspector is private | — |

### Security, privacy and permissions

| Feature | Arc | Soprano Web | WebKit path (min macOS) | Roadmap |
|---|---|---|---|---|
| HTTP auth, client certificates | Chromium | missing: no `didReceive challenge` | `webView(_:didReceive:completionHandler:)`, `SFChooseIdentityPanel` | 1 |
| TLS errors | interstitial | partial: dead-end error page (`BWC:1311-1345`) | `serverTrust`, `SFCertificateTrustPanel`, own interstitial with per-host exception | 1 |
| Security indicator | Site Control Center | built (stage 4 P6): the lock opens a popover for the page's site in its profile: connection (details sheet, Show Certificate), camera/microphone/notifications/pop-ups Ask/Allow/Block, zoom, "Block ads on this site", extensions' site access, "Clear site data" (the domain's WebKit data + the host's cookies); CLI `browser site` | `hasOnlySecureContent`, `serverTrust`, `WKWebsiteDataStore.removeData(ofTypes:for:)`, `WKHTTPCookieStore` | 1 |
| Camera, mic | per site | done: remembered per site in the tab's profile (a private window's own layer), set from the prompt, Settings ▸ Websites or the Site Control Center (stage 4 P6) | `requestMediaCapturePermissionFor` (12.0), `cameraCaptureState`/`microphoneCaptureState` KVO and setters | 1 |
| Screen sharing | Chromium | works without app code | WebKit shows the ScreenCaptureKit picker | — |
| Geolocation | CoreLocation | missing: WebKit denies without a delegate | `webView(_:requestGeolocationPermissionFor:initiatedBy:)` is **macOS 27 SDK only** | decision |
| Notifications | Chromium alerts helper | missing: requests auto-deny | private; JS `Notification` shim → `UNUserNotificationCenter` while the tab is open | 1 |
| Autoplay | Chromium | global setting only (Settings ▸ Autoplay); no per-site value: WebKit fixes it per web view at creation, so the Site Control Center has no autoplay row | `mediaTypesRequiringUserActionForPlayback` (10.12); per-site policy is private | 1 |
| External app links | prompt | risky: opened without asking (`BWC:1356-1364`) | `NSWorkspace.open` behind a prompt | 1 |
| Content blocking | uBlock Origin extension [A4]; 1.169 also bundles EasyList/EasyPrivacy in a native blocker module | missing | uBO Lite via `WKWebExtension`, or `WKContentRuleList` (≤150,000 rules per list) | 2 |
| Clear browsing data | Chromium; "Clear Cookies and Refresh" | broken: "Clear History" empties `history.json` only (`BWC:904-926`) | `WKWebsiteDataStore.removeData(ofTypes:modifiedSince:)`, `fetchDataRecords` | 1 |
| Downloads | Library | partial: progress and cancel; no resume, retry or ask; in-progress items dropped on relaunch (`BWC:1576-1588`) | `WKDownload` resume data (11.3) | 1 |
| Download quarantine | `LSFileQuarantineEnabled` | done: WebKit's network process applies `com.apple.quarantine` | — | — |
| User agent | Chromium | partial: bare WKWebView UA has no `Version/… Safari/…` token | `applicationNameForUserAgent` (10.11) | 1 |

### Identity and data

| Feature | Arc | Soprano Web | WebKit path (min macOS) | Roadmap |
|---|---|---|---|---|
| Profiles | per Space | missing | `WKWebsiteDataStore(forIdentifier:)` (14.0); history, permissions and extensions stay app-level per profile [W-prof] | 2 |
| Passwords | Chromium manager per Profile; extension managers | missing | no public AutoFill for web forms; own vault + injected autofill, or an extension | decision |
| Passkeys | iCloud Keychain passkeys since 2025-11-06 [A4] | missing | managed entitlement `com.apple.developer.web-browser.public-key-credential` (Developer ID + provisioning profile) [AP-pk] | decision |
| Extensions | Chrome Web Store | missing | `WKWebExtension*` (15.4); see [Extensions](#extensions-under-wkwebextension) | 4 |
| History | Chromium SQLite | partial: JSON capped at 5,000 entries, rewritten on every visit, misses `pushState` | app (SQLite) | 2 |
| Bookmarks | none (pinned tabs instead) | partial: flat list, no edit, no HTML import/export | app | 3 |
| Import | Chrome, Safari, Firefox, Brave, Edge, Opera, Vivaldi [H-import] | missing | file readers; see [Importing from Arc](#importing-from-arc) | 3 |
| Sync | Arc Sync (E2E; Spaces, Folders, tabs) [H-sync] | missing | CloudKit needs a team ID | ✗ |
| Settings robustness | — | broken: synthesized `Decodable`; one unknown or missing key resets every setting and the next write overwrites the file (`BrowserModel.swift:111-122,150,160-167`) | `decodeIfPresent` with defaults | 1 |

### App integration and agents

| Feature | Arc | Soprano Web | WebKit path | Roadmap |
|---|---|---|---|---|
| Default browser | menu item | partial: registered in `Info.plist`, no in-app action | `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` (12.0; system confirms) | 1 |
| AppleScript | windows, tabs, spaces; `execute javascript` behind an opt-in | missing (the `browser` CLI instead) | Cocoa scripting | 4 |
| Handoff | `NSUserActivityTypeBrowsingWeb` | missing | needs a team ID | ✗ |
| Agent automation | AppleScript only | done: `browser` CLI; IPC unauthenticated, replies broadcast to every observer (`BrowserAutomationCommand.swift:136-170,259-321`), `--tab` changes the visible tab (`BrowserAutomation.swift:157`) | Unix socket, `callAsyncJavaScript` | 1 |
| Arc Max (AI) | ChatGPT in Command Bar, Tidy titles, 5-Second Previews; Ask on Page removed 2025-08-28 [A4] | — | — | ✗ (agents instead) |
| Vimium layer | none | done | — | — |

## What WebKit keeps private

Public API covers nearly everything above. These need a workaround because the public
surface stops short (macOS 27 SDK headers, WebKit `main` @37aa2b5):

| Behavior | Private symbol (off-limits) | Workaround |
|---|---|---|
| Picture in Picture on macOS | `_allowsPictureInPictureMediaPlayback` | floating panel that hosts the playing web view |
| Audio-playing indicator, page mute | `_isPlayingAudio`, `_setPageMuted:` | content-world script on media events; mute media elements |
| `beforeunload` prompt | `_webView:runBeforeUnloadConfirmPanel…` | track listeners by script; confirm on close |
| Link-hover URL | `_webView:mouseDidMoveOverElement:…` | content-world `mouseover` script |
| Web notifications, Web Push | `_webView:requestNotificationPermissionForSecurityOrigin:…` | JS `Notification` shim → `UNUserNotificationCenter` |
| Geolocation before macOS 27 | `_webView:requestGeolocationPermissionForOrigin:…` | public delegate on macOS 27; JS shim + CoreLocation before |
| User style sheets | `_WKUserStyleSheet` | inject `<style>` / `adoptedStyleSheets` |
| Save button in the built-in PDF viewer | `_webView:saveDataToFile:…` | own "Download PDF" via `startDownload` |
| `window.print()` from a page, per-frame print | `_printOperationWithPrintInfo:forFrame:` | override `window.print` by script → `printOperation(with:)` |
| In-app Web Inspector | `_inspector` | Safari ▸ Develop (`isInspectable`, 13.3) |

New public API worth adopting, by SDK: macOS 26 `fetchData`/`restoreData` (localStorage
only), macOS 26.4 `securityRestrictionMode`, macOS 27 `globalPrivacyControlEnabled`,
`webView(_:willSubmitForm:)` + `WKFormInfo` (password capture),
`WKContentWorldConfiguration.autofillScriptingEnabled`, `WKHTTPCookieStore.getCookies(for:)`
and the geolocation delegate. The macOS 27 symbols are only in the Xcode 27 SDK; the current
toolchain (Homebrew Swift on the Command Line Tools macOS 26 SDK) cannot compile them.

## Signing constraints

Soprano Web is ad-hoc signed without a team ID, and no Apple Developer team is planned
(decided 2026-10-23). That rules out passkeys for arbitrary sites (managed entitlement plus
provisioning profile, requested by the Account Holder) [AP-pk], CloudKit sync, push and
Handoff. 1Password connects its desktop app only to browsers that are "code signed by Apple
in the Applications folder" [OP-add], which an ad-hoc build very likely fails (untested).
Arc itself ships with Developer ID, hardened runtime, no sandbox, the passkey entitlement
and `LSFileQuarantineEnabled` (`codesign -d --entitlements` on Arc 1.169.0).

## Extensions under WKWebExtension

Load test on 2026-10-23, macOS 27 system WebKit, Chrome MV3 builds, all permissions granted:

| Extension | Result |
|---|---|
| uBlock Origin Lite 2026.930 | loads and blocks (`adsbygoogle.js`, `gtag.js` blocked; jQuery loaded). `userScripts` and `offscreen` are dropped, so custom-filter scriptlets don't run. uBOL's repo has a Safari build (`platform/mv3/safari`) [UB]. |
| Wappalyzer 6.12 | loads cleanly |
| 1Password 8.12 | background fails: `chrome.notifications` sits behind a non-shipping WebKit preference. With stubs it next fails on `webNavigation.onCreatedNavigationTarget`, `storage.managed` and the window model. Its passkey support hooks `navigator.credentials` from a `world: "MAIN"` content script, which WebKit supports, so passkeys from the 1Password vault would need no Apple entitlement once the background runs. **Stage 4 P2 (2026-10-27, macOS 26, 8.12.42.36):** runs with Soprano Web's stand-ins (`BrowserExtensionShims`: notifications, webNavigation, storage.managed, Chrome user agent, port-less `permissions` origins, `.wasm` MIME, `clients.matchAll`, a native WebSocket — a worker's `new WebSocket` never returns in WebKit); background starts without errors, the toolbar button opens its welcome/sign-in page (no account yet: its popup is unset), content scripts load; the inline menu needs an account (`fm()` gates it). Missing desktop-app host answers as Chrome does ("host not found" on the port). |
| Vimium 2.4 | fails on `webNavigation.onHistoryStateUpdated`; Soprano Web's native layer replaces it |

- Extensions skip private (non-persistent) data stores unless
  `WKWebExtensionContext.hasAccessToPrivateData` is set.
- DNR limits: 100 static rulesets, 50 enabled, 30,000 dynamic + session rules; all of one
  extension's rules compile into one content rule list capped at 150,000
  (`WebExtensionConstants.h`, `ContentExtensionParser.cpp`). uBOL's default lists are about
  18,700 rules.
- Chrome Web Store packages are CRX3: a signed header before a ZIP. DuckDuckGo and Search
  verify the CRX3 signature before unpacking [DDG; SR]. Search fills missing `chrome.*`
  APIs (notifications, sessions, offscreen documents, userScripts…) with injected shims answered natively
  (`ExtensionShims.swift`) [SR].
- 1Password without its extension: Universal Autofill (⌘\) fills any app through
  Accessibility [OP-ua] (untested in Soprano Web); its macOS AutoFill provider has no public
  path into WKWebView web forms.

## Importing from Arc

Everything lives in `~/Library/Application Support/Arc/` and is readable without Full Disk
Access. The importer reads it in place, read-only; Chromium locks its SQLite files while Arc
runs, so open them with `immutable=1` (or read copies).

| Source | Format | Use |
|---|---|---|
| `StorableSidebar.json` | Swift `JSONEncoder`: dictionaries are alternating `[key, value, …]` arrays, enums `{"case": {"_0": payload}}`, dates in seconds since 2001 | Read only `sidebar.containers[1]` (`firebaseSyncState` and `sidebarSyncState` are sync copies). `spaces` (display order) → `containerIDs` pairs `pinned`/`unpinned`. `items` is a flat map of `{id, parentID, childrenIds (ordered), title, data}`; `data` is one of `itemContainer`, `list` (folder), `tab {savedURL, savedTitle, savedMuteStatus}`, `splitView`. `topAppsContainerIDs` maps a profile to its Favorites root. A Space's profile is `profile.custom._0.directoryBasename` (`Profile N`) or `profile.default`. Themes are extended-sRGB RGBA palettes. Title = `title ?? savedTitle ?? savedURL`. Drop ids missing from `items`. |
| `StorableArchiveItems.json` | same encoding | archived tabs: `archivedAt`, `reason` (`manual`/`auto`), `source` (space or `littleArc`), full tab record → history and Archive |
| `SidebarItemsFaviconCache/`, `ArchiveItemsFaviconCache/` | 16/32 px PNGs named `md5(<uppercase item UUID>)` | favicons without a database |
| `StorableLinkRouting.json` | rules `urlMatch contains <string>` → Space or most recent | Air Traffic Control rules |
| `User Data/<profile>/History` | Chromium SQLite: `urls`, `visits`; µs since 1601-01-01 | history per profile; skip `hidden` URLs and subframe transitions. Volumes reach 10⁵ visits per profile. |
| `User Data/<profile>/Favicons` | Chromium SQLite (`icon_mapping` → `favicons` → `favicon_bitmaps`) | fallback favicons |
| `User Data/<profile>/Secure Preferences` | `extensions.settings.<id>` | "you had these extensions" checklist |

Not importable: open tabs' current URLs (only in Chromium's `Sessions/` SNSS logs); cookies
and passwords (encrypted with the `<Browser> Safe Storage` Keychain key; take a user-exported
CSV instead, Chrome format `name,url,username,password,note`); Easels, Notes and Boosts
(stored in the Arc account) [A3]. Never import `StorableCommandBarAdditionalRanking.json`:
its keys are typed queries.

Other sources: Chrome `Bookmarks` (JSON tree, roots `bookmark_bar`/`other`/`synced`, nodes
`url`/`folder`) plus the same `History` schema; Safari's own files need Full Disk Access, so
read its File ▸ Export Browsing Data ZIP (`Bookmarks.html`, `History.json`, `Passwords.csv`)
instead.

## Prior art

| Project | License | Take |
|---|---|---|
| [driceroland/Search](https://github.com/driceroland/Search) @57912ad | MIT | Closest stack (SwiftPM, macOS 14, ad-hoc `build.sh`). Keychain passwords, import from Chromium browsers incl. Arc and Safari's export ZIP, tab sleep with `interactionState`, Chrome Web Store install on `WKWebExtension` with `chrome.*` shims, per-host zoom and permissions, crash recovery, a user-only Unix socket for automation. |
| [duckduckgo/apple-browsers](https://github.com/duckduckgo/apple-browsers) @0a38a23 (`macOS/DuckDuckGo/`, `SharedPackages/`) | Apache-2.0 | Most complete WebKit browser: multi-window, pinned tabs (shared or per window), tab suspension, Fire Button data clearing, permission center, favicons, history suggestions, crash-loop handling, `WKWebExtension` with CRX3 verification, download quarantine via `quarantinePropertiesKey`. Swift 5, ~30 WebKit SPIs; lift patterns, not packages. Its tracker list data (TDS) is CC BY-NC-SA 4.0. |
| [duckduckgo/autoconsent](https://github.com/duckduckgo/autoconsent) | MPL-2.0 | Cookie-banner automation built to embed in browsers. |
| Kagi Orion (closed) | — | Its own WebExtensions implementation (~70% API coverage) rather than `WKWebExtension`; release notes name a WebKit build per release, so it likely ships its own WebKit. Feature checklist: profiles, per-site settings, Arc import, tab suspension after 5 minutes in Low Power Mode [OR]. |

## Sources

- [A1] Arc Sunset: Key Dates and What to Expect — https://resources.arc.net/hc/en-us/articles/44412972248471-Arc-Sunset-Key-Dates-and-What-to-Expect
- [A2] Move from Arc to Dia — https://resources.arc.net/hc/en-us/articles/44413129117591-Move-from-Arc-to-Dia
- [A3] How Do I Export My Data from Arc? — https://resources.arc.net/hc/en-us/articles/25583851606039
- [A4] Arc for macOS 2024–2026 Release Notes — https://resources.arc.net/hc/en-us/articles/20498293324823
- [A5] Letter to Arc members 2025 — https://browsercompany.substack.com/p/letter-to-arc-members-2025
- [A6] Atlassian 8-K exhibit 99.1 — https://www.sec.gov/Archives/edgar/data/1650372/000165037225000040/ex991pressrelease.htm
- [A7] Command Bar actions — https://start.arc.net/command-bar-actions
- Help-center articles, read through 2024 Wayback snapshots: [H-fav] https://resources.arc.net/hc/en-us/articles/19230755904151 ·
  [H-pin] https://resources.arc.net/hc/en-us/articles/19231060187159 ·
  [H-fold] https://resources.arc.net/hc/en-us/articles/19228419623447 ·
  [H-space] https://resources.arc.net/hc/en-us/articles/19228064149143 ·
  [H-prof] https://resources.arc.net/hc/en-us/articles/19227964556183 ·
  [H-arch] https://resources.arc.net/hc/en-us/articles/19228855311127 ·
  [H-little] https://resources.arc.net/hc/en-us/articles/19235387524503 ·
  [H-peek] https://resources.arc.net/hc/en-us/articles/19335302900887 ·
  [H-split] https://resources.arc.net/hc/en-us/articles/19335393146775 ·
  [H-atc] https://resources.arc.net/hc/en-us/articles/22932014625431 ·
  [H-keys] https://resources.arc.net/hc/en-us/articles/20595231349911 ·
  [H-sync] https://resources.arc.net/hc/en-us/articles/22369796990487 ·
  [H-import] https://resources.arc.net/hc/en-us/articles/19335089616791
- [W-prof] Building Profiles with new WebKit API — https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/
- [AP-pk] Web browser public key credential entitlement — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential ; Passkey use in web browsers — https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers
- WKWebExtensionController — https://developer.apple.com/documentation/webkit/wkwebextensioncontroller
- [OP-add] 1Password: additional browsers — https://support.1password.com/additional-browsers/ ; [OP-ua] Universal Autofill — https://support.1password.com/mac-universal-autofill/
- [UB] uBlock Origin Lite Safari build — https://github.com/gorhill/uBlock/tree/master/platform/mv3/safari
- [DDG] duckduckgo/apple-browsers — https://github.com/duckduckgo/apple-browsers ; [SR] driceroland/Search — https://github.com/driceroland/Search
- [OR] Orion docs — https://help.kagi.com/orion/browser-extensions/macos-extensions.html ; https://help.kagi.com/orion/features/low-power-mode.html ; https://help.kagi.com/orion/getting-started/importing.html ; release notes https://orionbrowser.com/updates/orion-release-notes.html
- WebKit source — https://github.com/WebKit/WebKit (`Source/WebKit/UIProcess/API/Cocoa/*.h`, `Source/WebKit/Shared/Extensions/WebExtensionConstants.h`, `Source/WebCore/contentextensions/ContentExtensionParser.cpp`)
