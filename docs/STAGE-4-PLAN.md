# Stage 4 — Arc extras (design contract)

The design every stage 4 phase builds against. Status, branches and the next step are in
`docs/STATUS.md`. Read the repo `AGENTS.md` first (build env, `taskpolicy -b`, `-j 2`,
swift-testing rules, harness, dev app, CHANGELOG, conventions), then `docs/ROADMAP.md` §4
and `docs/ARC-PARITY.md` (feature matrix, "What WebKit keeps private", "Extensions under
WKWebExtension", prior art). Branch: `feat/stage-4`, one or more commits per phase.

## User decisions (final, do not re-ask)
- **macOS 26 is the floor** (2026-10-27). No `#available` checks for macOS ≤ 26 anywhere;
  remove the ones that exist. Symbols only in the macOS 27 SDK stay out (toolchain).
- **Passwords: the 1Password extension** on `WKWebExtension`, with native stand-ins for
  the Chrome APIs WebKit lacks; the user signs in to 1Password inside the extension.
  Universal Autofill (⌘\) is the fallback until it runs. No own vault.
- From stage 3, still binding: do it the Arc way unless WebKit or signing forbids it;
  every Space is isolated (its own profile: cookies, website data, History, site
  decisions, Archive, Favorites); Folio tokens only, accent for keyboard focus only.

## Decided here (Arc behavior, adapted)
- **Extensions are app-wide**: one `WKWebExtensionController` serves every Space, so an
  extension (and 1Password's sign-in) is installed and signed in once. Its tabs and
  windows are the real ones across Spaces; each tab keeps its own data store. Private
  windows see an extension only when "Allow in private windows" is on
  (`hasAccessToPrivateData`). Deviates from Arc (per Profile) because Spaces never share
  a profile here.
- **Little Arc** belongs to one Space: the Space of the most recently active normal
  window when it opens (its mark shows which). ⌘O moves its tab into that Space (a
  window showing it, else the most recent normal window switched to it); its "Open in"
  menu moves it to another Space (the page reloads there: other profile). Links from
  other apps: a matching link rule wins; otherwise Settings ▸ Links from other apps ▸
  "Open links from other apps in" (Little Arc, default, or the most recent window).
  Arc's imported `defaultDestination` sets that choice.
- **Boosts are per host, app-wide** (`<support>/boosts.json`): they are the user's own
  code, not site data, so every Space runs them.
- **Peek's "other site"** is a host comparison: hosts with a leading `www.` dropped are
  the same site when equal or when one is a subdomain of the other. No public-suffix
  list.

## Phases (build order: daily impact before Arc stops on 2026-12-22)

Each phase ends with: `swift build` + `swift test` green (debug; release before install),
harness flags documented in `AGENTS.md` for every new surface, the dev app exercised over
the `browser` CLI where the CLI reaches, `CHANGELOG.md` `[Unreleased]` lines, the
roadmap item moved or deleted, `docs/STATUS.md` updated, committed on `feat/stage-4`.

### P0 — Platform and known bugs
- Floor to macOS 26: `Package.swift` (`swift-tools-version` that knows `.v26`,
  `platforms: [.macOS(.v26)]`), `Support/Info.plist` `LSMinimumSystemVersion`, the
  `AGENTS.md` link-warning note, removed availability checks, ROADMAP "Needs a decision"
  (floor and 1Password resolved).
- Downloads remember their profile (`profileID` in the download record, tolerant
  decoding); resume and retry use that profile's data context, never the current Space's.
- A History row takes the page's title when the page sets it after the load finished
  (`title` KVO → update the newest visit of that URL within the merge window).

### P1 — Web extensions runtime
- `BrowserExtensions` (manager-owned): one `WKWebExtensionController` (persistent
  configuration), set on every normal web view's configuration; private web views only for
  extensions with private access. Installed extensions in `<support>/Extensions/<id>/`
  plus `extensions.json` (id, source, version, enabled, private access, granted
  permissions and match patterns; tolerant decoding).
- Install: Chrome Web Store URL or id → CRX3 download, verification as Chrome does it for
  store installs: every proof verifies over `"CRX3 SignedData\0"` + 4-byte little-endian
  length + the signed header data (protobuf field 10000) + the ZIP; a developer proof's
  key hash gives the extension id; the Web Store publisher's ECDSA proof is required.
  Unzip with symlink and path-escape checks; also an unpacked folder. Update check daily.
  Research with exact SDK signatures, anchors and prior art (Search's lessons on
  user agent, stable `uniqueIdentifier`/`baseURL`, own popover):
  `docs/research/p1-extensions.md` (line anchors as of P0; re-check before editing).
- Tabs and windows protocols (`WKWebExtensionTab`, `WKWebExtensionWindow`) over the real
  controllers and tabs; toolbar action buttons with badge and popover popups; permission
  prompts as Folio sheets (remember the answer); per-site access; extension context-menu
  items in the web-view menu; extension commands as dynamic rows next to the fixed
  `BrowserCommandID` registry (menu, Command Bar, key routing).
- Settings ▸ Extensions (list, enable, private access, site access, remove) and the
  Command Bar's extension rows.
- Proof: uBlock Origin Lite installs from the store and blocks on a test page; Wappalyzer
  loads (ARC-PARITY load test).

### P2 — 1Password
- Native stand-ins for what 1Password 8.12 calls: `chrome.notifications` (→
  `UNUserNotificationCenter`), `webNavigation.onCreatedNavigationTarget`,
  `storage.managed` (empty), and whatever the next failure names — found by loading it
  and reading the background errors, one at a time. Route: the installed copy's
  background gets a prepended shim script that answers through native messaging
  (`webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:replyHandler:)`);
  the original package's
  signature is checked before the copy is patched.
- Proof: background starts without errors, the toolbar popup opens, the in-page fill menu
  appears on a sign-in form. Signing in to 1Password is the user's step: stop there and
  hand over with exact instructions.

### P3 — Little Arc
- A window role (normal, pop-up, little) replaces `isPopup`; `BrowserWindowKind` stays
  the data kind (normal or private), so a Little Arc window uses its Space's own context
  and tabs move to and from it under `BrowserTabMoveRule`. One tab, compact toolbar with
  an editable address (Space mark, address, "Open in" menu, ⌘O button), cascaded from
  the screen's top right, no rail or tab strip; it never shows other Spaces.
- ⌥⌘N opens one with the Command Bar; Settings ▸ Keyboard shortcuts offers a global
  shortcut (Carbon `RegisterEventHotKey`, off by default).
- Links it opens in new tabs (target=_blank, ⌘-click) go to its Space's window.
- Archived after 6 h idle (the tab into the Archive, the window closes): the idle pass
  must age a Little Arc's lone selected tab and close the window instead of adding a start
  tab. Saved and restored in the session (version 4 with the role; older versions
  migrate). Code map for P3–P5: `docs/research/p3-p5.md` (line anchors as of P0;
  re-check before editing).
- CLI: `browser windows` lists it with kind `little`; harness `--open-link` shows the routing.

### P4 — Peek
- A Peek is an overlay over the page: rounded Folio panel with its own web view in the tab's
  data context, a dimmed backdrop, title bar with back/forward, "Open as Tab" (⌘O: the web
  view becomes a Today tab after the opener, history kept) and close (Esc, click on the
  backdrop, ⌘W).
- Opens for: a link click from a pinned or favorite tab to another site (see above), and
  ⇧-click on any link. One Peek per window; a second replaces it.
- Harness flags and `--print-peek`.

### P5 — Split View
- A split is 2–4 tabs of one Space shown side by side in one window, one rail row (their
  favicons) and one strip item; saved in the session. ⌃⇧= adds a pane (new tab, Command
  Bar), ⌃⇧- closes the focused pane, ⌃⇧1…4 focus a pane, ⌥-click on a link opens it in a
  new pane, drag a tab onto a page edge adds it. Dividers resize (ratios saved).
- The focused pane is the "selected tab" for every command, Vimium and the CLI. Each pane
  keeps its origin (pinned, favorite, Today); archiving archives its Today tabs.

### P6 — Site Control Center
Code map and API facts for P6–P12: `docs/research/p6-p12.md`.
- The lock / site chip opens a popover for the selected tab's site in its Space:
  connection (today's sheet behind a row), permissions (camera, microphone,
  notifications, pop-ups) with per-site values, zoom −/+/reset, "Block ads on this site",
  Boosts (P7) and extensions' site access (P1), "Clear site data" (the site's
  registrable domain's website data — WebKit keys records by domain — plus that host's
  cookies, in the tab's profile, then reload). Replaces the lock's sheet; the harness's
  `--security-info` / `--site-blocking` move to the popover.
- No per-site autoplay: WebKit fixes autoplay per web view at creation, so a per-site
  value would mean rebuilding the web view (losing back/forward). Settings ▸ Autoplay
  stays global.

### P7 — Boosts
- Per-host Boost: name, enabled, CSS (a `<style>` added at document start), JavaScript
  (its own `WKContentWorld` with no `sopranoWeb` handler — user code never posts as ours;
  every script checks `location.hostname` itself, user scripts can't be host-scoped),
  Zap list (selectors hidden). Editor sheet with monospace text views; Zap mode: hover
  outlines elements, click hides, Esc ends.
- CLI: `browser boost list|show <host>|css <host> <file|->|js <host> <file|->|zap <host>
  <selector>|enable|disable|remove <host>` so an agent can write one (the client reads
  the file or stdin).

### P8 — Capture
- ⇧⌘2: drag an area on the page, or click for the visible page; a menu offers full page
  (`createPDF` with the rect set to the document size, rendered to an image with the
  height capped). Result: pasteboard plus a PNG in `~/Downloads`, with a toast showing it.
  CLI `screenshot [--full] <path>`.

### P9 — Mini Player and media controls
- A page script reports Media Session metadata and playback state per tab. Leaving a tab
  with a playing, visible video moves its web view into a floating non-activating panel
  (video fills it by injected CSS; returning to the tab or the panel's button moves it
  back; close pauses). Rail bottom: the playing tab's title, artwork, play/pause, next,
  mute; click selects the tab. Selection changes, Space switches and tab sleep leave the
  panel's web view alone.

### P10 — Reader and Translation
- Reader (⇧⌘R): vendored Readability.js 0.6.0 (Apache-2.0; `LICENSE` and `NOTICE` next
  to it, shipped as resources) in an isolated world; the article shows in a Folio reader
  page in the tab; toggles back.
- Translate page: `NLLanguageRecognizer` detects the language;
  `TranslationSession(installedSource:target:)` translates text nodes in batches from an
  isolated-world script; "Show original" restores. Offered in the address field when the
  page's language isn't the user's. A pair not installed on the Mac opens System Settings'
  Translation Languages (downloading in-app needs SwiftUI's `.translationTask`; AppKit
  only).

### P11 — GitHub pull requests as a live folder
- A pinned folder with a `source` key (GitHub pull requests: a repo through `gh pr list`,
  or a query through `gh search prs`), so older builds still read it as a folder; the
  fetched PRs live in a runtime cache, never in `children`. Refreshed every 5 minutes and
  on open; rows open the PR; read-only. Process running and `gh` path resolution after
  Soprano Git's `GitProcess.swift` / `GitRunner.swift` (it has no `gh` code itself).

### P12 — AppleScript and Dock menu
- `.sdef`: application → windows → tabs, spaces; properties URL, title, loading; commands
  make new tab/window, close, reload, select, `execute javascript` (only with Settings ▸
  "Allow JavaScript from Apple Events"; `@objc` scripting classes, the sdef copied into
  `Contents/Resources` by `scripts/package-app.sh`). Dock menu: New Window, New Private
  Window, New Little Arc, the Spaces (the Dock already lists open windows).
