# Status

Stage 3 is merged to `main` (#3, `2fdbdaa`, 2026-10-27), followed by #4 (`727eca4`: every
Space has its own profile, so its own cookies, History and Archive), and installed in
`/Applications/Soprano Web.app`. Its first launch migrates `bookmarks.json` into
`spaces.json` (kept as `bookmarks.json.migrated`) and the session to version 3.

Live check of #4 in the running dev app (2026-10-27; Work Space made through the New
Space path, then driven over the `browser` CLI against a local server): a cookie set in
Default is absent from Work's requests and `document.cookie` and the reverse, and each
Space's visits land only in its own `History.sqlite`.

## Goal

Stage 4 of `docs/ROADMAP.md`: Arc's extras (extensions with 1Password, Little Arc, Peek,
Split View, Site Control Center, Boosts, Capture, Mini Player, Reader and Translation,
GitHub live folder, AppleScript). Arc stops opening on 2026-12-22. The design contract,
with Furkan's decisions (macOS 26 floor; passwords through the 1Password extension), is
`docs/STAGE-4-PLAN.md`; phases P0–P12 run in its order on `feat/stage-4`. Stage 3's
contract is `docs/STAGE-3-PLAN.md`.

## Branches

| Branch | Base | State |
|---|---|---|
| `feat/stage-3` | `main` | Squash-merged as #3. 518 tests green in debug and release. |
| `feat/stage-4` | `main` | Stage 4 built (P0–P12), PR #5 open (not merged); 801 tests green in debug and release; the real EasyList's element hiding proven (`1f3cc7f`), compiled lists rebuilt at launch by converter version 2 (`9e162c7`). Open: 1Password sign-in and the by-hand checks below (Furkan), then a PR to `main`. |
| `feat/stage-3-search`, `feat/stage-3-import` | — | Merged into `feat/stage-3`; no further work there. |

## Done

| Phase | Commits | What |
|---|---|---|
| Stage 4 P0 | `c1e00aa`, `36ba6c3`, `a16a68f` | macOS 26 floor (tools 6.2, `LSMinimumSystemVersion` 26.0); downloads resume and retry in the profile they started in; a title set after the load renames its History row |
| Stage 4 P1 | `e57986c` and the commits after it | Web extensions on `WKWebExtension`: one app-wide controller, Chrome Web Store install with full CRX3 check, unpacked folders, daily updates, tab/window adapters, toolbar buttons and popups, permission sheets, site access, private access, commands, Settings ▸ Extensions, `browser extension` CLI |
| Stage 4 P2 | `372331f` | 1Password 8.12.42.36 runs on native stand-ins (`BrowserExtensionShims`, data-driven by manifest): notifications → Notification Center, `webNavigation.onCreatedNavigationTarget` from the opener, empty `storage.managed`, Chrome user agent, port-less `permissions` origins, `.wasm` MIME, `clients.matchAll`, native WebSocket; missing native hosts answer "host not found"; `browser extension action` |
| Stage 4 review fixes | `6e165fe` | P1/P2 security and P0 reviews: web pages can't open extension pages app-side; one load gate for extensions (no `file:`, other apps ask); install shows permissions, updates grant nothing new; folder id takeover refused; in-process ZIP extraction (no `ditto`); native-host allowlists; worker WebSocket policy (`connect-src`, local hosts need host access, caps); attributed, capped notifications; deleted-Space downloads never resume in Default and stop on delete |
| Stage 4 P3 | see `git log` | Little Arc (window role normal/popup/little; links from other apps → rule, else Little Arc or most recent window; Arc `defaultDestination` import; ⌥⌘N + Carbon global shortcut; ⌘O and "Open in"; 6 h idle close into the Archive; session v4; CLI `little`, `windows` kind column) and review fixes P2-1, P2-2, P3-1, P3-2, P3-3 with tests (ditto/zip ZIP fixtures) |
| Stage 4 P4 | see `git log` | Peek (pinned/favorite links to other sites by host rule, ⇧-click; overlay panel with its own web view in the opener's data context, routed through `tab(for:)`; Open as Tab ⌘O keeps history; Esc/⌘W/backdrop close; one per window; CLI `peek`, harness `--peek*`, `shift-`/`opt-` clicks) and P3 review fixes P2-A–D, P3-E–H with tests. Harness check: a pinned `127.0.0.1` page's plain click on a `localhost` link opened a Peek (History in Default), a link inside it navigated (back list `b.html`), ⌘O made tab 2 of 2 and `browser back` returned to `b.html`; same-site and Today plain clicks stayed in the tab; a private window's Peek recorded nothing |
| Stage 4 P5 | see `git log` | Split View (`BrowserSplit`: 2–4 panes of one Space, dividers with saved ratios, one rail row with every pane's favicon and one strip item; ⌃⇧= with the Command Bar, ⌃⇧-, ⌃⇧1…4, ⌥-click (WebKit never flags it a download; it reaches `handleLinkNavigation`), drop on a pane edge, "Open in Split View"; the focused pane is the selected tab; visible panes exempt from sleep/archive; session v5; Arc Today split views import; Peek covers the whole split; CLI `split`, `tabs` pane marks; harness `--split*`, `--print-splits`) and P4 review fixes P2-1–P2-4, P3-5–P3-8 with tests. Harness: 2-pane rail and 4-pane strip captures, `--click-page opt-` opened example.com as pane 2 |
| Stage 4 P6 | see `git log` | Site Control Center (`BrowserSiteControl*`: the lock's Folio popover for `pageTab` — Peek or focused pane — in its profile's site store, a private window's overlay: connection row → details sheet, camera/microphone/notifications/pop-ups Ask/Allow/Block, zoom, "Block ads on this site", extensions' site access, "Clear site data" = the domain's WebKit records minus cookies + the host's own cookies, then reload; no per-site autoplay; CLI `site info|clear|permission`; harness `--site-control`, `--security-info`/`--site-blocking` through it) and P5 review fixes P1-1, P2-1–P2-3, P3-1, P3-2 with tests, plus an Arc Today split import test. Harness: popover captured on example.com; `--split-drop`, `--split-command add/1/close`, `--split-separate`, ⌥-click on a `target=_blank` link and a pinned+Today split all behaved. Dev app: cookies on `127.0.0.1:8766` and `localhost:8766`, `browser site clear` on localhost; the server then saw no Cookie from localhost and `site=127_0_0_1` from 127.0.0.1 |
| Stage 4 P7 | see `git log` | Boosts (`BrowserBoost*`: per host plus its `www.` form — other subdomains separate, Arc's rule — app-wide `boosts.json` with tolerant decoding and `.corrupt`; CSS `<style>` at document start and JS in the `SopranoWebBoost` world, which has no `sopranoWeb` handler; every script checks `location.hostname`; swapped with the state scripts in `refreshStateScripts` for every tab incl. private, Peek, panes, Little Arc; CSS/zaps live, JS from the next load; editor sheet from the Site Control Center's Boost row and `/boost`; Zap mode in the isolated world posts the element path, `BrowserZapSelector` builds the selector; CLI `boost list|show|css|js|zap|enable|disable|remove`, `-` read from the CLI's stdin) and P6 review fixes P2-1, P3-1–P3-3 with tests. Harness: page with a CSS+JS+zap Boost, editor sheet and the popover's Boost row captured. Dev app: `echo 'body{background:red}' \| browser boost css 127.0.0.1 -` → `rgb(255, 0, 0)`, a JS Boost set the title after reload, localhost unaffected, `boost disable` removed the CSS live. |
| Stage 4 P8 | see `git log` | Capture (`BrowserCapture*`: ⇧⌘2 = `capture`, remappable, File ▸ Capture…, `/capture`; an overlay pinned to `pageTab`'s web view — Peek or focused pane — drag an area (`takeSnapshot` rect in view points, rendered at the backing scale), click for the visible page, Full Page (`createPDF` with the rect set to the document in CSS px × `pageZoom`, rasterized off the main actor, capped at 16,384 px: lower scale first, then cut); Esc cancels; another tab, pane, Space or Peek closes it; pasteboard PNG + unique `Soprano Capture <date> at <time>.png` in the download folder + thumbnail toast that reveals in Finder; private windows too; CLI `screenshot [--full] [--] <path>` with real option parsing; harness `--capture-area/-visible/-full/-drag/-overlay`) and P7 review fixes: Boost CSS as an adopted constructed sheet (a strict CSP `style-src` blocked the `<style>`; it also cascades after the page's sheets now, P2-2), host guard declares nothing (P2-1), editor Save is ⌘↩ (P2-3), Zap session ends on commit/page change and records only its host (P3-1), Zap listens on `window` and swallows pointer/dblclick/auxclick/contextmenu (P3-2), `CSS.escape` rules and custom-element tags (P3-3), one `insertRule` per zap (P3-4), editor keeps unsaved zaps (P3-5), the popover's Boost row follows the store (P3-6), CLI hosts ASCII/punycode (P3-7), CLI input over 16 MB refused by name (P3-8); each with a test. Harness: 1440×900 at 2×, area 300×200 → 600×400 PNG, long page (5,040 CSS px) full → 2880×10080, at 125% and scrolled to 1,500 → 2880×12600 from Block 1, a 30,120 px page → 1440×16384 cut, overlay with selection and toast captured; CSP page (`style-src 'self'` header) gets the Boost background. Dev app: `browser screenshot --full /tmp/x.png` on the long page scrolled to 2,000 → 2260×10080 from Block 1; `--wide` refused. |
| Stage 4 P9 | see `git log` | Mini Player and media controls (`BrowserMedia*`, `BrowserMiniPlayer*`, `+Media`: isolated-world `mediaInfo` reports per frame incl. Media Session metadata/artwork/state; leaving a tab with a playing visible main-frame video moves its web view into a floating non-activating panel (fill CSS, Back to Tab, Close pauses, frame remembered except private); selection/Space switch/sleep/archive leave it alone; rail bottom and toolbar controls; Settings switch; CLI `media`; harness `--media-seed`, `--mini-player`, `--print-media`) and P8 review fixes P2-1 (viewport width, pixel-area budget), P3-1–P3-5 with tests. Harness: panel and rail/toolbar controls captured, `callActionHandler('nexttrack')` reached the page. Dev app check not run (budget) |
| Stage 4 P10 | `2ee48c5` | Reader and Translate (`BrowserReader*`, `BrowserTranslation*`, `+Reader`, `+Translate`: vendored Readability.js 0.6.0 with `LICENSE`/`NOTICE` in the resource bundle, `package-app.sh` refuses a bundle without them; isolated-world `pageInfo` per main-frame commit; Reader swaps in a Folio `<html class="soprano-reader">` and puts the page's own root, sheets and scroll back without reload; ⇧⌘R and the Reader chip; Translate via `TranslationSession(installedSource:target:)` with offers outside `Locale.preferredLanguages`, Show Original, Never Offer, Settings ▸ "Never offer to translate", private windows in memory, a missing language pair asks to open System Settings; CLI `reader`, `translate`; harness `--reader`, `--translate`) and P9 review fixes with tests: hidden toolbar chip takes no width, the Mini Player returns its tab on a WebContent crash, artwork capped and a failed address fetched once, the Capture overlay keeps its own button's focus, a failed capture save leaves no temporary file, a tab never on screen stays out of the Mini Player, a Peek from the Mini Player's page opens a tab. 778 tests green in debug and release. Dev app (2026-10-30): `browser reader on` on en.wikipedia.org/wiki/WebKit showed `soprano-reader` with 38 paragraphs, `off` put the page back with `history.length` still 1; on de.wikipedia.org the language read `de` (no offer: German is a preferred language) and `translate to en` answered that German → English isn't downloaded on this Mac. Not checked: a translation itself (needs a downloaded pair) |
| Stage 4 P11 | see `git log` | GitHub pull requests as live folders (`BrowserLiveFolders.swift`, `+LiveFolders`, `BrowserLiveFolderCommands`: a `BrowserPinFolder` with `source` — a repository's open PRs via `gh pr list` or a `gh search prs` query — saved as a plain folder plus `source`; PRs fetched through `gh` (found in the Homebrew/user tool folders, 30 s limit) every 5 minutes, when a folder opens or its preview shows (unless < 30 s old), kept in memory and shown before the folder's children with derived ids; a failure keeps what was shown and the tooltip says why; rows open a Today tab (the one on it if any); nothing moves into a live folder; New / Edit Live Folder… in the rail menu via the pin editor; Spaces menu and start page show them; CLI `live-folders`, `live-folder add|refresh`; harness `--live-folder`, `--live-fetch`, `--live-refresh`, `--live-open`, `--live-folder-editor`, `--print-live-folders`). 792 tests green in debug and release. Harness: fixture from `gh pr list -R Valkental/shop-theme` → 4 rows under the expanded folder, `--live-open` opened PR 82 as a Today tab, `--live-fetch signed-out` → "!" and the `gh auth login` tooltip, the Edit Live Folder editor captured. Dev app (launched with `open`, launchd's PATH): `live-folder add Valkental/shop-theme` → 4 PRs in 0.6 s, `review-requested:@me is:open` → 2 PRs across repos, a missing repo → `gh`'s GraphQL error, and (after putting `gh`'s options before the `--` a negated word needs) `author:@me is:open -label:bug` → 19 PRs; `spaces.json` held the three sources and no PR address (the test folders were removed afterwards). Not built: Arc's other sources (RSS, issues) |
| Stage 4 P12 | see `git log` | AppleScript and Dock menu (`Support/SopranoWeb.sdef`, `App/BrowserScripting.swift`: windows — the CLI's, most recently active first, private never — with name, index, kind, current space, active tab; their current Space's tabs with name, settable URL, loading, index, selected; Spaces; `new window [URL] [in space]`, `new tab [URL] [in window]`, `select` tab/space, `close` tab (archives)/window, `reload`, `execute javascript [in tab]` — the CLI's `eval` JSON, only with Settings ▸ "Allow JavaScript from Apple Events", off by default, -1743 otherwise; `Info.plist` `NSAppleScriptEnabled`/`OSAScriptingDefinition`, `package-app.sh` copies and requires the sdef; Dock menu adds New Little Arc and the Spaces; Settings rows scroll now — Links from other apps and Extensions were under the footer before). 799 tests green in debug and release. Harness from the dev app's binary (in-process `NSAppleScript`, no Automation prompt): window/tab/space reads, `new tab URL "https://example.com" in w`, `set URL of t1 to "example.org"` → `https://example.org/`, `select t1`, `close t2`, `select space "Work"` → current space Work, `new window … in space "Default"` became window 1, `close w2`, a closed tab → -1728, `execute javascript` with the setting off → -1743; Dock menu printed with Work checked. Not checked: `execute javascript` answering through Apple events from another process: `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded: false)` for `com.soprano.web.dev` answered -1744 (user consent required), so sending would show the Automation prompt |
| P1 | `24c13c0` | Spaces model and store, bookmarks → per-Space pins, `bookmarks.json` migration |
| P2 | `c886ddf`, `98d8d7a` | A window shows one Space; per-tab data context; session v3 |
| P3 | `2f601a1`, `628c07c` | Rail (Space header, Favorites, pinned outline, Today, switcher), live pinned/favorite tabs, New/Edit Space sheet |
| P4 | `d0efbed` | Archive (`archive.json`), auto-archive per profile, ⌘W / ⇧⌘K, sidebar Archive |
| P5 | `07d25b7` (merged `898682e`) | Custom search engines and keywords |
| P6 | `20a5acc` | Command registry, Settings ▸ Keyboard shortcuts with priorities, Command Bar ⌘T/⌘L, ⌃Tab, ⌥⌘↑/↓, ⇧⌘C, ⌥⇧⌘C, ⇧⌘D |
| P7 | `3829a74` (merged `93e6817`), `3131716` | Import from Arc/Chrome/Safari/bookmarks HTML, Export Pinned Tabs, links-from-other-apps rules |
| Reviews | `deb24e5`, `89ba36b`, `3f777ae` | P4/P6 and P7 review fixes; ⇧⌘K on 21 tabs 1.9 s → 0.3 s |

P0 live check in the dev app (2026-10-27, `browser goto` to a local page that sets
`document.title` 1 s after `load`): its `History.sqlite` row read `127.0.0.1` right after
the load and `Late Title Smoke` 3 s later, one visit.

P1 live check in the dev app (2026-10-27, built-in blocker off, local page loading
`pagead2.googlesyndication.com/pagead/js/adsbygoogle.js` and jQuery from
`code.jquery.com`): without extensions both load; `browser extension install` of uBlock
Origin Lite from its store link (2026.1026.1812, verified and unpacked in ~1 s); 4 s
later the ad still loaded (WebKit was still compiling its rulesets), 25 s later the ad
script is blocked and jQuery loads, also on reload of an older tab. Wappalyzer 6.12.8
installs with no errors and badges pages. A local test extension saw `onInstalled`,
`tabs.onCreated`, `onActivated`, `onUpdated` (loading, complete), content-script
messaging, its context-menu item and its popup.

Real Arc folder on this Mac (read-only harness import into a temporary support folder):
4 Spaces, 161 pins in 48 folders, 13 favorites, 147 archived tabs, 1 link rule, 46,873
visits (History older than the retention setting, one year by default, is left out); a
second import creates nothing.

P2 live check in the dev app (2026-10-27, 1Password `aeblfdkhhhdcdjpifhhbdiojplfjncoa`
from its store link, 8.12.42.36). Each stand-in and the error that demanded it:
1. none → `TypeError: undefined is not an object (evaluating
   'chrome.notifications.onClicked')`, background failed → `notifications` (and, from
   the code, `webNavigation.onCreatedNavigationTarget`, `storage.managed`, Chrome user
   agent ≥ 149).
2. → `Invalid call to runtime.connectNative(). No native messaging host
   com.1password.1password(7)` (its desktop app) → an unknown host now opens and closes
   the port with "Specified native messaging host not found.", as in Chrome.
3. → `WASM is not initialized` at launch: its core is called before its WebAssembly is
   ready; WebKit serves `.wasm` as `application/octet-stream`, so streaming compile failed
   and fell back (69 ms fetch → 169 ms ready vs. the call at 95 ms) → `wasm` stand-in;
   three launches since without errors (the race is 1Password's own and could return on
   a slow launch).
4. On a local form (`http://127.0.0.1:8766/login.html`) → `permissions.contains(): …
   'http://127.0.0.1:8766/*' is not a valid pattern` → `permissions` (ports dropped).
5. Known from Search, confirmed here: a worker's `new WebSocket` never returns (probe
   extension's badge stopped before it; with the stand-in it reached a local server and
   got "pong") → `webSocket`; `clients.matchAll()` listed no page (probe popup now lists
   itself, visible) → `clients`. `onCreatedNavigationTarget` fired for a `target=_blank`
   link with source and new tab ids.
Now `browser extension errors` says "No errors." for 1Password, uBlock Origin Lite and
Wappalyzer (both shimmed too). Its toolbar button has no popup until an account exists
(1Password sets it to "" and opens its welcome page instead, as in Chrome): Welcome →
Continue → "Add account" (Create / Sign in) → Sign in opens
`https://my.1password.com/signin?auth-only=1`. Its content scripts load (a dynamic
`import()` of an extension file from a content script works); the in-page menu needs an
account: the frame configuration sets `inlineDisabled` when `fm()` (any account in its
database) is false. A failed first background start left WebKit failing with "Importing
a module script failed" after the package changed, until remove + install.

Review-fix checks (2026-10-27). Harness, local fixture extension with `<all_urls>` and
`file:///*` host permissions and content scripts, before (`d0fc673`) → after (`6e165fe`):
a page doing `location = "chrome-extension://<id>/secret.html"` opened the extension page →
stays on the page; `tabs.update(…, { url: "file:///etc/hosts" })` loaded it → refused;
granted patterns `<all_urls>`, `file:///*` → `<all_urls>`. Its content script ran on
`http:` pages and on no `file:` page even with `file:///*` granted, and WebKit reports a
`file:` URL's permission as unknown under `<all_urls>` or `file:///*`
(`MatchPattern("<all_urls>").matches(file:)` is false): `<all_urls>` doesn't cover
`file:` on macOS 26, so no "Allow access to file URLs" switch. Dev app after the fix: uBlock
Origin Lite, Wappalyzer and 1Password "No errors.", uBOL blocks
`pagead2.googlesyndication.com` (jQuery loads), its popup opens, 1Password's button opens
its welcome page, no update additions pending; only 1Password keeps `webSocket`.

## Next — start here

1. **1Password sign-in (Furkan).** In the dev app or, after `./scripts/install.sh`, in
   Soprano Web: Settings ▸ Extensions, paste
   `https://chromewebstore.google.com/detail/aeblfdkhhhdcdjpifhhbdiojplfjncoa` and
   install (or `browser extension install aeblfdkhhhdcdjpifhhbdiojplfjncoa`). A
   "Welcome to 1Password!" tab opens (else click the 1Password toolbar button): Continue
   → Sign in → on my.1password.com enter email, Secret Key and password (or "Use QR
   Code" with the phone app) and finish 2FA. Verify: the toolbar icon turns unlocked;
   its button now opens a popup with your vault (not "connecting"); on a sign-in page
   the 1Password icon/menu appears in the username field and fills; ⇧⌘L locks and the
   popup asks for the password; `browser extension errors aeblfdkhhhdcdjpifhhbdiojplfjncoa`
   says "No errors." (a frozen popup or extension after sign-in points at the notifier
   WebSocket; report what `errors` prints). The desktop app can't connect (ad-hoc
   signature); unlock with the account password.
2. GUI check. Agents may launch the dev app (`open -g -n ".build/debug/Soprano Web
   Dev.app"`; its own support folder and WebKit container) and drive it over the
   `browser` CLI. What needs a person's hands: Site wins / Press twice with real key
   presses, ⌃Tab release, shifted-punctuation remaps in the menu bar, a real drag in the
   rail outline, the Command Bar's rounded corners in Folio Ink, Delete Space from the
   switcher's menu (the CLI has no Space create/delete).
3. By hand (Furkan): AppleScript's `execute javascript` from Script Editor or Terminal against the dev app (macOS asks once to let it control "Soprano Web Dev"): turn on Settings ▸ "Allow JavaScript from Apple Events", then `osascript -e 'tell application "Soprano Web Dev" to execute javascript "document.title"'` answers the front tab's title as JSON (`"…"`), and with the setting off it fails with -1743; the Dock menu's New Little Arc and a Space. A live folder from the rail's menu (New Live Folder…, a click on a PR, Refresh, Edit Live Folder…); Translate with a downloaded language pair (System Settings ▸ General ▸ Language & Region ▸ Translation Languages); ⇧⌘2 with a real pointer (drag an area, click for the visible page, Full Page, Esc) and a click on the toast revealing the file in Finder; Zap mode with a real pointer (hover outline, click hides, Esc ends) and typing in the Boost editor (↩ newline, ⌘↩ saves); a real tab drag onto a pane edge and a real divider drag (P5), and the lock's popover menus (Ask/Allow/Block, extension access) with real clicks; the Mini Player with a real video in the dev app (P9).
4. Merge PR #5 (https://github.com/frknue/soprano_web/pull/5) into `main` on Furkan's go.

Known, not planned: each tab change rebuilds every rail row (~40 ms with 20+ tabs); batch
closes do it once.

Not built from ROADMAP §3: Arc's `Arc Data Export.md` lossy fallback (the real files
read fine). Arc's `defaultDestination` imports since stage 4 P3.

## Open questions

- Search: Should custom engines get live suggestions? The start page's search box shows only for
  https engines with `%s` as a whole query value.
- Import: the meaning of Arc's link-routing `matches` (mapped to "equals") and how a rule
  names a specific Space are unconfirmed; the real file only holds `contains` rules.
- Resolved: Safari's history export records one visit per page at its last visit time
  (not N visits). P7 import pipeline, sheet and bookmarks HTML export are built on
  `feat/stage-3`; imports leave out History older than Settings ▸ Remove history items.

## Links

- Plan: `docs/STAGE-3-PLAN.md` · Roadmap: `docs/ROADMAP.md` §3 · Evidence:
  `docs/ARC-PARITY.md`
