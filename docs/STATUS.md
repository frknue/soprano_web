# Status

Stage 3 is merged to `main` (#3, `2fdbdaa`, 2026-10-27) and installed in
`/Applications/Soprano Web.app`. Its first launch migrates `bookmarks.json` into
`spaces.json` (kept as `bookmarks.json.migrated`) and the session to version 3.

## Goal

Stage 3 of `docs/ROADMAP.md`: Arc's organization model (Spaces, pinned tabs, Favorites,
folders, Today and Archive, Command Bar, shortcuts, custom search engines) and import from
Arc, Chrome and Safari. Arc stops opening on 2026-12-22. The design contract, including
Furkan's final decisions (pinned tabs replace bookmarks; a Space's color is a mark only),
is `docs/STAGE-3-PLAN.md`.

## Branches

| Branch | Base | State |
|---|---|---|
| `feat/stage-3` | `main` | Squash-merged as #3. 518 tests green in debug and release. |
| `feat/stage-3-search`, `feat/stage-3-import` | — | Merged into `feat/stage-3`; no further work there. |

## Done

| Phase | Commits | What |
|---|---|---|
| P1 | `24c13c0` | Spaces model and store, bookmarks → per-Space pins, `bookmarks.json` migration |
| P2 | `c886ddf`, `98d8d7a` | A window shows one Space; per-tab data context; session v3 |
| P3 | `2f601a1`, `628c07c` | Rail (Space header, Favorites, pinned outline, Today, switcher), live pinned/favorite tabs, New/Edit Space sheet |
| P4 | `d0efbed` | Archive (`archive.json`), auto-archive per profile, ⌘W / ⇧⌘K, sidebar Archive |
| P5 | `07d25b7` (merged `898682e`) | Custom search engines and keywords |
| P6 | `20a5acc` | Command registry, Settings ▸ Keyboard shortcuts with priorities, Command Bar ⌘T/⌘L, ⌃Tab, ⌥⌘↑/↓, ⇧⌘C, ⌥⇧⌘C, ⇧⌘D |
| P7 | `3829a74` (merged `93e6817`), `3131716` | Import from Arc/Chrome/Safari/bookmarks HTML, Export Pinned Tabs, links-from-other-apps rules |
| Reviews | `deb24e5`, `89ba36b`, `3f777ae` | P4/P6 and P7 review fixes; ⇧⌘K on 21 tabs 1.9 s → 0.3 s |

Real Arc folder on this Mac (read-only harness import into a temporary support folder):
4 Spaces, 161 pins in 48 folders, 13 favorites, 147 archived tabs, 1 link rule, 46,873
visits (History older than the retention setting, one year by default, is left out); a
second import creates nothing.

## Next — start here

1. GUI check by Furkan (agents may not launch the app): Site wins / Press twice with
   real key presses, ⌃Tab release, shifted-punctuation remaps in the menu bar, a real
   drag in the rail outline, the Command Bar's rounded corners in Folio Ink.
2. Stage 4 (`docs/ROADMAP.md` §4).

Known, not stage 3: resuming or retrying a download uses the current Space's web view,
not the profile it came from (download records carry no profile). A History row keeps
the host as its title when the page sets its title after the load finished. Each tab
change rebuilds every rail row (~40 ms with 20+ tabs); batch closes do it once.

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
