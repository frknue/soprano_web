# Status

Resumed 2026-10-27. Nothing of stage 3 is on `main`; `main` @c1154c4 is stage 2 and must
stay untouched until stage 3 is finished and Furkan asks for the merge. Never run
`scripts/install.sh` from a stage 3 branch: launching it converts the real
`bookmarks.json` into `spaces.json`.

## Goal

Stage 3 of `docs/ROADMAP.md`: Arc's organization model (Spaces, pinned tabs, Favorites,
folders, Today and Archive, Command Bar, shortcuts, custom search engines) and import from
Arc, Chrome and Safari. Arc stops opening on 2026-12-22. The design contract, including
Furkan's final decisions (pinned tabs replace bookmarks; a Space's color is a mark only),
is `docs/STAGE-3-PLAN.md`.

## Branches

| Branch | Base | State |
|---|---|---|
| `feat/stage-3` | `main` | P1, P2, P5 (search engines) and the import readers, merged, built and green (432 tests). This file lives here. |
| `feat/stage-3-search`, `feat/stage-3-import` | — | Merged into `feat/stage-3`; no further work there. |

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

P2 is finished (`98d8d7a`): the review found and fixed sign-in answers crossing profiles
and ⌘W reopening a Space's lone start tab. Harness proof: tabs of Default and Work Spaces
in one window load from a local server; the Default tab that finished while its Space
was hidden recorded its visit and cookie only in Default.

1. P3 rail UI and live pinned/favorite tabs (plan "Rail" and the pinned-tab bullets of
   "Windows and tabs"). Merge All Windows must turn a pin-linked tab into a Today tab when
   the target already has a live tab for that pin.
2. P4 Archive, P6 Command Bar and shortcut registry, P7 import pipeline and UI.
3. Last: CHANGELOG `[Unreleased]`, ROADMAP §3, `swift test -c release`, and the merge to
   `main` only when Furkan asks.

Known, not stage 3: resuming or retrying a download uses the current Space's web view,
not the profile it came from (download records carry no profile).

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
