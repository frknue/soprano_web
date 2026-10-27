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
| `feat/stage-4` | `main` | In progress: P0, P1 and P2 done (575 tests green in debug and release); 1Password sign-in (Furkan) and P3 next. |
| `feat/stage-3-search`, `feat/stage-3-import` | — | Merged into `feat/stage-3`; no further work there. |

## Done

| Phase | Commits | What |
|---|---|---|
| Stage 4 P0 | `c1e00aa`, `36ba6c3`, `a16a68f` | macOS 26 floor (tools 6.2, `LSMinimumSystemVersion` 26.0); downloads resume and retry in the profile they started in; a title set after the load renames its History row |
| Stage 4 P1 | `e57986c` and the commits after it | Web extensions on `WKWebExtension`: one app-wide controller, Chrome Web Store install with full CRX3 check, unpacked folders, daily updates, tab/window adapters, toolbar buttons and popups, permission sheets, site access, private access, commands, Settings ▸ Extensions, `browser extension` CLI |
| Stage 4 P2 | the `feat: 1Password` commit after `afbd375` | 1Password 8.12.42.36 runs on native stand-ins (`BrowserExtensionShims`, data-driven by manifest): notifications → Notification Center, `webNavigation.onCreatedNavigationTarget` from the opener, empty `storage.managed`, Chrome user agent, port-less `permissions` origins, `.wasm` MIME, `clients.matchAll`, native WebSocket; missing native hosts answer "host not found"; `browser extension action` |
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
3. Stage 4 P3 (Little Arc) of `docs/STAGE-4-PLAN.md`.

Known, not planned: each tab change rebuilds every rail row (~40 ms with 20+ tabs); batch
closes do it once.

Not built from ROADMAP §3: Arc's `Arc Data Export.md` lossy fallback (the real files
read fine), Arc's `defaultDestination` link rule (Little Arc is §4).

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
