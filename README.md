<div align="center">

<img src="app-icon.png" alt="" width="112">

# Soprano Web

**A native WebKit browser for macOS, in the Soprano family.**

Tabs, history, bookmarks, downloads and find, in Folio chrome — plus a CLI that
lets an agent navigate, inspect and click a page from any shell.

<img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white">
<img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
<img alt="AppKit, programmatic" src="https://img.shields.io/badge/AppKit-programmatic-2b6cb0">
<img alt="WebKit" src="https://img.shields.io/badge/engine-WebKit-2f5f8a">
<img alt="MIT" src="https://img.shields.io/badge/license-MIT-b8bb26">

</div>

Soprano Web is the browser member of the family. It runs the system WebKit
engine (`WKWebView`), not an embedded Chromium, so the app has no engine binary,
no helper processes to sign, and no browser update treadmill of its own: engine
fixes arrive with macOS.

## Install

Build from a checkout:

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

swift build
swift test
./scripts/install.sh        # release build → /Applications/Soprano Web.app
```

`./scripts/install.sh` never restarts a running instance; the update applies on
the next launch. `./scripts/dev.sh --build-only` packages an isolated
`.build/debug/Soprano Web Dev.app` (`com.soprano.web.dev`) without launching it.
`./scripts/dev.sh` launches that dev build.

macOS 14 Sonoma or newer. The app is ad-hoc/local signed like the rest of the
family, not notarized.

## The first five minutes

1. Press `⌘L`, type an address or a search, press Return. Tabs live in the
   Arc-style vertical rail on the left by default; `⌘S` collapses or expands it.
   **Settings → Vertical tabs** switches between the vertical rail and the
   horizontal-tab layout.
2. `⌘T` opens the start page; the `+` beside the tabs does the same. `⌘W` closes
   a tab; closing the last one closes the window, and the app stays in the Dock.
   Click it to reopen with a fresh start tab. `⇧⌘T` brings the last closed tab
   back.
3. `⌘D` bookmarks the page. `⌘Y`, `⌥⌘B` and `⌥⌘L` open History, Bookmarks and
   Downloads in the right sidebar.
4. `⌘F` finds in the page; `Return` / `⇧Return` move between matches.
5. `⌘,` opens Settings: search engine, homepage, theme, appearance, session
   restore and download folder.

The start page shows bookmarks and recent pages. `⌘=` / `⌘-` / `⌘0` zoom the
page. `⇧⌘B` toggles the sidebar.

## Vimium keys

Soprano Web has a native Vimium layer on every page. Focus a page and press `?`
for the full key sheet; text fields switch to insert mode automatically, and
`Esc` returns to normal mode.

- `j` / `k` / `h` / `l`, `d` / `u`, `gg` / `G` scroll; counts work (`5j`).
- `f` / `F` show link hints; `yf` copies a link; `⌥F` queues links in new tabs.
- `o` / `O` open the omnibar, `b` / `B` search bookmarks, `T` searches tabs.
- `/` finds, `n` / `N` step matches, `*` / `#` find selected text.
- `H` / `L` history, `J` / `K` tabs, `g0` / `g$` first/last, `x` / `X` close/reopen.
- `yy` copies the URL, `p` / `P` open the clipboard, `m` / `` ` `` handle marks.
- `v` / `V` enter visual mode; `y` yanks.
- `gs` shows the DOM source; `?` opens the complete key list.

`gf` / `gF` (frames), `W` (new window), and `⌥P` (pin) are marked unavailable
in the help sheet; the rest of Vimium's default map is implemented.

## Shortcuts

| Shortcut | Action |
|---|---|
| `⌘L` | Focus the address bar |
| `⌘T` / `⌘W` / `⇧⌘T` | New / close / reopen tab |
| `⌃Tab` / `⌃⇧Tab` | Next / previous tab |
| `⌘1`…`⌘9` | Select tab 1–9 |
| `⌘[` / `⌘]` | Back / forward |
| `⌘R` / `⌘.` | Reload / stop |
| `⌘F`, `⌘G`, `⇧⌘G` | Find, next match, previous match |
| `⌘D` | Bookmark this page |
| `⌘Y` / `⌥⌘B` / `⌥⌘L` | History / bookmarks / downloads |
| `⇧⌘B` | Toggle the right sidebar |
| `⌘S` | Toggle the vertical tab sidebar |
| `⌘P` | Command palette |
| `⌘,` | Settings |
| `⌘+` / `⌘-` / `⌘0` | Zoom in / out / reset |

## Agent automation

The app binary is the CLI. Start the app first, then call its binary from any
shell:

```bash
APP="/Applications/Soprano Web.app/Contents/MacOS/SopranoWeb"

"$APP" browser goto https://example.com
"$APP" browser wait-for-load
"$APP" browser snapshot                 # accessible outline with @e1 refs
"$APP" browser click @e1
"$APP" browser fill '#search' soprano
"$APP" browser get text 'h1'
"$APP" browser screenshot /tmp/page.png
"$APP" browser tabs                     # 1-based tab list
"$APP" browser --tab 2 url
"$APP" browser vimium "gg"              # drive the normal-mode key layer
```

`goto` accepts an address or a search query. It returns when navigation starts;
call `browser wait-for-load` before `snapshot`, `title` or `get` when the page
must be loaded. `--tab n` targets a tab by its 1-based number; otherwise the
selected tab is used. `snapshot` assigns ephemeral refs (`@e1`, `@e2`, …) to
interactive elements for the next commands. `eval`, `press`,
`check`/`uncheck`, `scroll-into-view`, `is` and `dblclick` round out the surface;
`"$APP" browser --help` lists it all.

Requests are routed to the running app through a request-scoped distributed
notification. There is no CDP endpoint and no Chrome extension support; this is
the family automation model, matching Soprano's browser pane.

## Files

- Settings: `~/.config/soprano-web/settings.json` (written on first change).
- Session, history, bookmarks, downloads:
  `~/Library/Application Support/Soprano Web/`.
- Downloads default to `~/Downloads`; Settings can choose another folder.

The Dev build (`com.soprano.web.dev`) uses `Soprano Web Dev` and
`~/.config/soprano-web-dev/` instead, so testing never touches release data.

The `Settings ▸ Downloads` row shows the resolved path. History and bookmarks are
local JSON; nothing leaves the machine.

## Scope

Soprano Web 0.1 is a single-window browser. Deliberately not built yet: private
windows, named profiles, Chrome/Safari extension installation, a password
manager, tab groups/sync, favicons, printing and PDF export. The engine decision
is WebKit; see `AGENTS.md` for why and what would have to change before adding a
second engine.

## Architecture

- `Sources/SopranoWeb/Browser/` — tabs, `WKWebView` delegates, navigation,
  history/bookmarks/downloads, sidebar, start page, automation, snapshot harness.
- `Sources/SopranoWeb/App/` — app delegate, menu, settings window.
- `Sources/SopranoWeb/Vendored/` — Folio chrome copied from Soprano. Never edit
  these here; run `scripts/sync-soprano-chrome.sh` after changing Soprano.
- `scripts/` — package, sign, install, icon and chrome-sync scripts.

`swift test` covers address resolution, stores, settings, session round-trip,
start-page escaping and every WebKit delegate selector (a nearly matching Swift
signature is accepted by the compiler but never called by WebKit, so the
selectors are checked directly).

The window is fully programmatic AppKit, like the rest of the family: no
storyboards, no xibs, no SwiftUI, no Electron.

## License

MIT. See `LICENSE`.
