# Changelog

All notable changes to Soprano Web are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The version in a released heading matches `CFBundleShortVersionString` in
`Support/Info.plist`, the single source of truth for the version shown in the
app.

## [Unreleased]

### Added
- A native Vimium keyboard layer for pages: counts, scrolling, link hints
  (open, new tab, copy, queue), find, omnibar, bookmarks, tab search, history,
  tab manipulation, marks, visual mode, zoom, mute, source view and a full
  `?` help sheet. Text inputs enter insert mode automatically.
- An Arc-style vertical tab rail on the left, with a `+` header button. `⌘S`
  collapses or expands the rail; Settings switches between the rail and
  horizontal tabs.
- Soprano Web 0.1: a native WebKit browser in Folio chrome with tabs, an address
  bar with search fallback, back/forward/reload, zoom, find in page and session
  restore.
- History, bookmarks and downloads in a right sidebar, with search and context
  menus; downloads use `WKDownload`, show live progress, use unique filenames and
  reveal in Finder.
- A local start page showing bookmarks and recent pages, and a themed error page
  with the failed address and a reload hint. The start page has a real URL, so
  back/forward returns to it instead of `about:blank`.
- `browser` CLI automation: `goto`, `wait-for-load`, `snapshot` with `@e1` refs,
  click/fill/press, `get`/`is`, `eval`, `screenshot`, tab listing/selection/close
  and `--tab`.
- Settings for search engine, homepage, theme, appearance, session restore and
  download folder, stored in `~/.config/soprano-web/settings.json`.
- Offscreen `snapshot` harness for the chrome, sidebar, find bar and settings
  window.

### Changed
- Closing the last tab now closes the window, like Safari and Chrome. The app
  keeps running in the Dock; reopening it creates a fresh start tab.

### Fixed
- `⌘L` (File → Open Location…) now focuses and selects the address bar; the
  shortcut was listed in Keyboard Shortcuts but never bound.
