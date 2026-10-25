# Status

Paused 2026-10-25 by Furkan, mid stage 3. Nothing of stage 3 is on `main`; `main` @c1154c4
is stage 2 and must stay untouched until stage 3 is finished and Furkan asks for the
merge. Never run `scripts/install.sh` from a stage 3 branch: launching it converts the
real `bookmarks.json` into `spaces.json`.

## Goal

Stage 3 of `docs/ROADMAP.md`: Arc's organization model (Spaces, pinned tabs, Favorites,
folders, Today and Archive, Command Bar, shortcuts, custom search engines) and import from
Arc, Chrome and Safari. Arc stops opening on 2026-12-22. The design contract, including
Furkan's final decisions (pinned tabs replace bookmarks; a Space's color is a mark only),
is `docs/STAGE-3-PLAN.md`.

## Branches (all pushed to origin)

| Branch | Base | State |
|---|---|---|
| `feat/stage-3` | `main` | P1 committed and green (`24c13c0`). P2 committed as WIP on top: the app builds, the test target does not compile, nothing verified. This file lives here. |
| `feat/stage-3-search` | `24c13c0` | P5 custom search engines, complete but never built or tested. |
| `feat/stage-3-import` | `c1154c4` | Import readers (pure, no UI), complete but never built or tested. |

## Done

- **P1** Spaces model and store (`BrowserSpaces.swift`, `BrowserSpaceStore.swift`,
  `spaces.json`), bookmarks renamed to pins (`BrowserPins.swift`, `BrowserPinEditor.swift`),
  migration from `bookmarks.json`, `archiveAfter` per profile, harness flags `--pins-tree`,
  `--pin-*`, `--print-pins`. 378 tests passed at `24c13c0`.
- **Import readers** (`feat/stage-3-import`, `Sources/SopranoWeb/Browser/Import/`):
  `BrowserArcImportReader`, `BrowserChromiumHistoryReader`, `BrowserChromeBookmarksReader`,
  `BrowserSafariExportReader`, `BrowserNetscapeBookmarks` (parse and write) and a neutral
  model in `BrowserImportModel.swift`, with one test file each.
- **P5** search engines (`feat/stage-3-search`): `BrowserSearchEngines.swift`,
  Settings ▸ Search engine ▸ Manage… (`App/BrowserSearchEnginesSheet.swift`), keywords
  (`w cats`), settings `customSearchEngines` and `searchEngineKeywords`, harness flags
  `--search-engine`, `--search-engine-keyword`, `--default-search-engine`,
  `--search-engines-sheet`. The old `SearchEngine` enum is gone.

## Next — start here

1. **Finish P2 on `feat/stage-3`** (windows show one Space at a time; plan section
   "Windows and tabs"). Already written: `BrowserTab.dataContext`/`spaceID`/origin, window
   `currentSpaceID` with selection remembered per Space, `visibleTabs`, per-tab contexts
   in the Navigation, Links, Permissions, SignIn, Sleep, Zoom, ContentBlocking, Downloads
   and TabActions extensions, `BrowserWindowController+Spaces.swift`
   (`switchToSpace`), `BrowserSpaceSwitching.swift` (index and wrap math),
   `BrowserSpacesMenu.swift` (replaces the deleted `BrowserBookmarksMenu.swift`), session
   version 3 with v2 migration, the tab move rule against the target's current Space,
   CLI `browser spaces` / `browser space`, harness `--space`, `--create-space`,
   `--print-spaces` and a rail swipe.
   Left to do:
   - The test target doesn't compile: `#require` on a mutating member at
     `Tests/SopranoWebTests/BrowserSessionRestoreTests.swift:120` and
     `BrowserSitePermissionOverlayTests.swift:59`. Fix them, then run `swift test`.
   - Review the diff against the plan (it was written in one pass, never run).
   - Harness proof the plan asks for: tabs in two Spaces of different profiles loading
     from a local test server; `--print-windows` must show each tab's visits and cookies
     in its own profile, including a tab that finished loading while its Space was hidden.
     Capture a PNG after switching and look at it.
   - Note the shortcut decisions (⌃1…⌃9, ⌥⌘←/→) in AGENTS.md and update its Architecture
     section for the new files.
2. Merge `feat/stage-3-search` into `feat/stage-3` (expect conflicts in
   `BrowserModel.swift`, `BrowserWindowController.swift`, `+AddressBar`, `+Navigation`,
   `SnapshotCommand.swift` and `AGENTS.md`), then build and test.
3. Merge `feat/stage-3-import` (new files only), then build and run the reader tests.
4. Then P3 rail UI, P4 Archive, P6 Command Bar and shortcut registry, P7 import pipeline
   and UI, as in the plan. Last: CHANGELOG `[Unreleased]`, ROADMAP §3, `swift test -c
   release`, and the merge to `main` only when Furkan asks.

## Open questions

- Search: Should custom engines get live suggestions? The start page's search box shows only for
  https engines with `%s` as a whole query value.
- Import: the meaning of Arc's link-routing `matches` (mapped to "equals") and how a rule
  names a specific Space are unconfirmed; the real file only holds `contains` rules.
- Safari history export gives one visit per URL plus a count: record N visits or one
  weighted visit.

## Links

- Plan: `docs/STAGE-3-PLAN.md` · Roadmap: `docs/ROADMAP.md` §3 · Evidence:
  `docs/ARC-PARITY.md`
