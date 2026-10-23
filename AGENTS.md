# Soprano Web

A native WebKit browser for macOS in the Soprano family: Swift 6 + programmatic
AppKit (no storyboards/xibs/SwiftUI), SPM, macOS 14+, `WKWebView`, shipped as a
hand-packaged `.app` via `scripts/package-app.sh`. Folio chrome is vendored from
Soprano.

## Commands

Homebrew Swift with the Command Line Tools SDK. Xcode's newer SDK breaks
Homebrew Swift, so pin `DEVELOPER_DIR` and `SDKROOT` on every Swift command:

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

swift build
swift test
swift test --filter BrowserDelegateSelectorTests
./scripts/dev.sh --build-only        # packages .build/debug/Soprano Web Dev.app
./scripts/dev.sh                     # builds, packages and launches (user-driven only)
./scripts/install.sh                 # release build → /Applications/Soprano Web.app
```

The `ld: warning: building for macOS-14.0 …` link warnings are expected. There is
no linter or formatter; match surrounding style.

## Verification

- Verify source changes with `swift build` and `swift test`. Run
  `swift test -c release` before installing; a delegate signature can compile in
  debug and fail in release. `scripts/install.sh` and `scripts/dev.sh` build
  through `scripts/build-with-guard.sh`, which refuses to package a build that
  printed "nearly matches optional requirement".
- Verify UI with the offscreen snapshot command and read the PNG:

  ```bash
  .build/debug/SopranoWeb snapshot --out /tmp/sw.png --size 1440x900 \
      --theme folio-paper [--url <url>] [--sidebar history|bookmarks|downloads] \
      [--find] [--settings] [--vertical-tabs] [--collapsed]
      [--hints] [--help] [--prompt]
  ```

  It builds the real window with volatile stores, captures the chrome with
  AppKit and the page with WebKit, and writes a PNG. Layer backgrounds on views
  unhidden after first display may not appear in the cached AppKit pass; that is
  a harness limitation, not the app.
- Verify real navigation and the agent surface against a running dev app:

  ```bash
  open -n ".build/debug/Soprano Web Dev.app"
  APP=".build/debug/Soprano Web Dev.app/Contents/MacOS/SopranoWeb"
  "$APP" browser goto https://example.com
  "$APP" browser wait-for-load
  "$APP" browser snapshot
  "$APP" browser vimium "gg"       # drive normal-mode keys without the keyboard
  ```

- Do not launch the GUI or run `./scripts/dev.sh` without `--build-only` unless
  the user asks. After a verified change to the app or packaging, run
  `./scripts/install.sh` as the last step: it replaces
  `/Applications/Soprano Web.app` without restarting a running instance, and the
  update lands on next launch. Report the result.
- WebKit delegate conformance is runtime-checked in
  `BrowserDelegateSelectorTests`. Keep that test green: a delegate method with a
  nearly matching Swift signature compiles but WebKit never calls it. Confirmed
  with `class_getInstanceMethod`; do not "fix" it by silencing the warning.

## Architecture

- `Browser/BrowserWindowController.swift` — the window, tab ownership, WebKit
  delegates, navigation policy, downloads, find, sidebar and session saves.
- `Browser/BrowserTab.swift`, `BrowserModel.swift` — tab state, settings,
  address resolution, session format.
- `Browser/BrowserDataStores.swift` — history, bookmarks and downloads JSON.
- `Browser/BrowserToolbarView.swift`, `BrowserTabStripView.swift`,
  `BrowserVerticalTabsView.swift`, `BrowserTabButton.swift`,
  `BrowserSidebarView.swift`, `BrowserFindBar.swift`,
  `BrowserStartPage.swift`, `BrowserErrorPage.swift` — chrome and local pages.
- `Browser/BrowserAutomationCommand.swift` + `BrowserAutomation.swift` — CLI
  routing and the `@e1` snapshot/action scripts. `browser vimium <keys>` feeds
  the selected tab's Vimium controller for verification.
- `Browser/VimiumController.swift`, `VimiumKeyMap.swift`, `VimiumPageScripts.swift`,
  `VimiumPanels.swift`, `BrowserWebView.swift` — the native Vimium mode layer.
- `Browser/SnapshotCommand.swift` — offscreen UI harness.
- `App/` — app delegate, menu, settings window, resources.
- `Vendored/` — Folio design system from Soprano. Never edit these files here.

`SOPRANO_COMMIT` records the Soprano commit the vendored files came from. Refresh
them with `scripts/sync-soprano-chrome.sh [checkout] [ref]`; it stages every file
before replacing anything, so a missing source leaves the repo untouched.
`scripts/render-app-icon.swift` is local here until the `web` glyph moves into
Soprano's design source; do not sync that file blindly.

## Engine decision

WebKit, not Chromium or Gecko:

- Gecko has no supported embeddable macOS view (GeckoView is Android-only), so
  "Firefox-based" means forking Firefox, not a family app.
- Chromium/CEF is viable but makes the app a C++/Swift hybrid with nested
  framework and helper bundles, hundreds of MB, and responsibility for shipping
  every Chromium security update. It buys CDP and Chrome extension/site parity.
- WebKit is an OS framework, matches Soprano's existing browser pane and
  automation surface, signs like the rest of the family, and inherits engine
  security fixes from macOS. The cost is no CDP, and Chrome extensions only
  through `WKWebExtension` (macOS 15.4), which lacks some `chrome.*` APIs.

Do not add a second engine without a concrete product requirement (a Chrome-only
site or a CDP flow that cannot use the CLI).

## Conventions

- Swift 6, macOS 14+, programmatic AppKit, Folio tokens and components only.
  Fonts by role through `ChromeFont`, radii from `Chrome.Radius`, accent only for
  keyboard focus, one hairline between regions.
- Tests use swift-testing (`import Testing`, `@Test`, `#expect`), one
  `struct …Tests` per file. Never `import Foundation` next to `import Testing` in
  a test file; import `AppKit` instead and get Foundation types through it.
- Settings are plain JSON at `~/.config/soprano-web/settings.json`; session and
  list data live in `~/Library/Application Support/Soprano Web/`. The
  vertical-vs-horizontal choice is configuration (`verticalTabs`); whether the
  rail is collapsed is UI state in `UserDefaults`. Tests always inject temporary
  URLs/defaults and never touch the real files.
- Every WebKit action that changes the page runs on the main actor; JSON stores
  are synchronous and atomic.
- Commit only paths changed in the session. Short imperative subjects,
  `feat:` / `fix:` / `docs:` / `test:` / `chore:` prefixes.
- After a user-visible change, add a line under `## [Unreleased]` in
  `CHANGELOG.md` in the matching Keep a Changelog group, written for the user and
  naming the shortcut or setting.
- Releases: rename `[Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, add a fresh
  `[Unreleased]`, set `CFBundleShortVersionString` and `CFBundleVersion` in
  `Support/Info.plist` (the only version source), `swift test`, install, commit
  `release: vX.Y.Z`.
- Push, open PRs, tags and merges only when the user asks for that action.

## Known gaps

`docs/ROADMAP.md` lists what is not built yet, in build order, and
`docs/ARC-PARITY.md` the evidence behind each item: Arc's behavior, file:line,
the WebKit API with its macOS version, and prior art. Read both before adding a
browser feature; move or delete the roadmap item when it ships.

`BrowserAutomationScripts.swift` is a copy of the JavaScript in Soprano's browser
pane. Extract the scripts into a Foundation-only file in Soprano and add that
file to `scripts/sync-soprano-chrome.sh`; until then the two copies can drift.

Vimium's `gf`/`gF` frame commands, `W` new-window, and `⌥P` pin are deliberately
unavailable (single-window app, pins not modeled); the help sheet says so.
