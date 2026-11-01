import AppKit
import WebKit

/// Settings as a page in a tab, like Chrome's chrome://settings:
/// `soprano-web://settings`, served by the `soprano-web` scheme handler.
/// A sidebar of sections, a search box that filters the rows, and cards of
/// rows with switches, menus and buttons in Folio colors. The page posts
/// `{type: "settings", action, …}` on the `sopranoWeb` channel
/// (`Message`); the app accepts them only from the main frame of this
/// page (`acceptsMessage`), applies them (`apply`, which checks every key
/// and value) and answers with the whole state
/// (`window.__sopranoSettings.apply(state)`). The managers (search
/// engines, shortcuts, websites, website data, links from other apps,
/// extensions, Clear Browsing Data, Import) stay native sheets on the
/// page's window (`Sheet`).
enum BrowserSettingsWebPage {
    static let host = "settings"
    static let url = URL(string: "\(BrowserStartPageSchemeHandler.scheme)://\(host)")!
    static let messageType = "settings"

    static func isSettings(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == BrowserStartPageSchemeHandler.scheme && url?.host?.lowercased() == host
    }

    /// Only the settings page's own main frame may change settings: never
    /// a frame inside it, never another page.
    static func acceptsMessage(frameURL: URL?, isMainFrame: Bool) -> Bool {
        isMainFrame && isSettings(frameURL)
    }

    // MARK: Messages

    /// A native sheet the page opens on its window.
    enum Sheet: String, CaseIterable, Sendable {
        case searchEngines, shortcuts, websites, websiteData, linkRouting, extensions, clearData, importData
    }

    enum Message: Equatable {
        /// The page loaded or came back on screen: send the state.
        case ready
        case set(key: String, value: SettingValue)
        case open(Sheet)
        case updateLists
        case makeDefault
        case chooseDownloads
        case recordShortcut
        case allowTranslation(String)
        case revealSettingsFile

        init?(_ body: [String: Any]) {
            switch body["action"] as? String {
            case "ready":
                self = .ready
            case "set":
                guard let key = body["key"] as? String, let value = SettingValue(body["value"]) else { return nil }
                self = .set(key: key, value: value)
            case "open":
                guard let sheet = (body["sheet"] as? String).flatMap(Sheet.init(rawValue:)) else { return nil }
                self = .open(sheet)
            case "updateLists":
                self = .updateLists
            case "makeDefault":
                self = .makeDefault
            case "chooseDownloads":
                self = .chooseDownloads
            case "recordShortcut":
                self = .recordShortcut
            case "allowTranslation":
                guard let code = body["code"] as? String else { return nil }
                self = .allowTranslation(code)
            case "revealSettingsFile":
                self = .revealSettingsFile
            default:
                return nil
            }
        }
    }

    /// A value a control posts: a switch's or a menu's/field's text.
    enum SettingValue: Equatable {
        case bool(Bool)
        case text(String)

        init?(_ value: Any?) {
            // NSNumber bridges booleans and numbers alike; only a real
            // boolean is a switch's value.
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if let text = value as? String {
                self = .text(text)
            } else {
                return nil
            }
        }
    }

    /// The longest homepage the field accepts.
    static let homepageLimit = 2048

    /// Applies one control's value to `settings`; false (nothing changed)
    /// for an unknown key, a value of the wrong kind or one the setting
    /// doesn't offer.
    @discardableResult
    static func apply(key: String, value: SettingValue, to settings: inout BrowserSettings) -> Bool {
        switch (key, value) {
        case let ("includeSearchSuggestions", .bool(on)): settings.includeSearchSuggestions = on
        case let ("restoreSession", .bool(on)): settings.restoreSession = on
        case let ("verticalTabs", .bool(on)): settings.verticalTabs = on
        case let ("askDownloadLocation", .bool(on)): settings.askDownloadLocation = on
        case let ("miniPlayer", .bool(on)): settings.miniPlayer = on
        case let ("allowsNotificationRequests", .bool(on)): settings.allowsNotificationRequests = on
        case let ("blockAdsAndTrackers", .bool(on)): settings.blockAdsAndTrackers = on
        case let ("allowsJavaScriptFromAppleEvents", .bool(on)): settings.allowsJavaScriptFromAppleEvents = on
        case let ("globalLittleArcEnabled", .bool(on)): settings.globalLittleArcEnabled = on
        case let ("searchEngine", .text(id)):
            guard settings.searchEngines.all.contains(where: { $0.id.rawValue == id }) else { return false }
            settings.searchEngines.setDefault(BrowserSearchEngineID(rawValue: id))
        case let ("themeID", .text(id)):
            guard AppTheme.isKnownId(id) else { return false }
            settings.themeID = id
        case let ("appearance", .text(raw)):
            guard let appearance = AppearancePreference(rawValue: raw) else { return false }
            settings.appearance = appearance
        case let ("defaultZoom", .text(raw)):
            guard let zoom = Double(raw), let step = BrowserZoom.steps.first(where: { BrowserZoom.isSame($0, zoom) }) else {
                return false
            }
            settings.defaultZoom = step
        case let ("historyRetention", .text(raw)):
            guard let retention = BrowserHistoryRetention(rawValue: raw) else { return false }
            settings.historyRetention = retention
        case let ("tabSleep", .text(raw)):
            guard let sleep = BrowserTabSleepAfter(rawValue: raw) else { return false }
            settings.tabSleep = sleep
        case let ("autoplay", .text(raw)):
            guard let autoplay = AutoplayPolicy(rawValue: raw) else { return false }
            settings.autoplay = autoplay
        case let ("homepage", .text(text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= homepageLimit else { return false }
            settings.homepage = trimmed
        default:
            return false
        }
        return true
    }

    // MARK: State

    /// What the page shows besides `settings.json`: facts the app reads
    /// elsewhere.
    struct Environment {
        var theme: AppTheme
        var blockerStatus: String
        var canUpdateLists: Bool
        var defaultBrowser: String
        var isDefaultBrowser: Bool
        var canBecomeDefault: Bool
        /// The New Little Arc shortcut as shown ("⌥⌘N"), "Type a
        /// shortcut…" while recording.
        var globalShortcut: String
        var isRecordingShortcut: Bool
        /// The switch is on but macOS refused the shortcut.
        var shortcutUnavailable: Bool
        var settingsFile: String
        var version: String
    }

    /// The state `window.__sopranoSettings.apply` renders: `values` by
    /// control key, each menu's `options`, `text` facts and the `theme`'s
    /// colors as CSS variables.
    static func state(settings: BrowserSettings, environment: Environment) -> [String: Any] {
        func options<T>(_ items: [T], value: (T) -> String, label: (T) -> String) -> [[String: String]] {
            items.map { ["value": value($0), "label": label($0)] }
        }
        let zoom = BrowserZoom.steps.first { BrowserZoom.isSame($0, settings.defaultZoom) } ?? 1
        let values: [String: Any] = [
            "searchEngine": settings.searchEngines.defaultID.rawValue,
            "includeSearchSuggestions": settings.includeSearchSuggestions,
            "homepage": settings.homepage,
            "themeID": settings.themeID,
            "appearance": settings.appearance.rawValue,
            "defaultZoom": zoomValue(zoom),
            "restoreSession": settings.restoreSession,
            "verticalTabs": settings.usesVerticalTabs,
            "tabSleep": settings.tabSleep.rawValue,
            "historyRetention": settings.historyRetention.rawValue,
            "askDownloadLocation": settings.askDownloadLocation,
            "autoplay": settings.autoplay.rawValue,
            "miniPlayer": settings.miniPlayer,
            "allowsNotificationRequests": settings.allowsNotificationRequests,
            "blockAdsAndTrackers": settings.blockAdsAndTrackers,
            "allowsJavaScriptFromAppleEvents": settings.allowsJavaScriptFromAppleEvents,
            "globalLittleArcEnabled": settings.globalLittleArcEnabled,
        ]
        let menus: [String: Any] = [
            "searchEngine": options(settings.searchEngines.all, value: \.id.rawValue, label: \.name),
            "themeID": options(AppTheme.options, value: \.id, label: \.name),
            "appearance": options(AppearancePreference.allCases, value: \.rawValue, label: \.name),
            "defaultZoom": options(BrowserZoom.steps, value: zoomValue, label: BrowserZoom.percent),
            "tabSleep": options(BrowserTabSleepAfter.allCases, value: \.rawValue, label: \.name),
            "historyRetention": options(BrowserHistoryRetention.allCases, value: \.rawValue, label: \.name),
            "autoplay": options(AutoplayPolicy.allCases, value: \.rawValue, label: \.name),
        ]
        let text: [String: Any] = [
            "downloadDirectory": settings.downloadDirectoryURL.path,
            "blockerStatus": environment.blockerStatus,
            "canUpdateLists": environment.canUpdateLists,
            "defaultBrowser": environment.isDefaultBrowser
                ? "Soprano Web is your default browser"
                : "Your default browser is \(environment.defaultBrowser)",
            "isDefaultBrowser": environment.isDefaultBrowser,
            "canBecomeDefault": environment.canBecomeDefault,
            "globalShortcut": environment.globalShortcut,
            "isRecordingShortcut": environment.isRecordingShortcut,
            "shortcutStatus": environment.isRecordingShortcut
                ? "Type the new shortcut; Esc cancels"
                : environment.shortcutUnavailable
                ? "Another app holds this shortcut; choose another"
                : "Opens a Little Arc with the Command Bar from any app",
            "neverTranslate": settings.neverTranslateLanguages.map {
                ["code": $0, "name": BrowserTranslationOffer.displayName($0)]
            },
            "settingsFile": environment.settingsFile,
            "version": environment.version,
        ]
        return ["values": values, "options": menus, "text": text, "theme": themeState(environment.theme)]
    }

    /// "1", "1.25": a zoom step as the menu's value.
    static func zoomValue(_ zoom: Double) -> String {
        zoom == zoom.rounded() ? String(Int(zoom)) : String(zoom)
    }

    static func themeState(_ theme: AppTheme) -> [String: Any] {
        let colors = theme.colors
        let hex = BrowserStartPage.hex
        return [
            "scheme": colors.appearance == .light ? "light" : "dark",
            "colors": [
                "bg": hex(colors.bgBase),
                "panel": hex(colors.bgPanel),
                "raised": hex(colors.bgRaised),
                "overlay": hex(colors.bgOverlay),
                "text": hex(colors.textPrimary),
                "muted": hex(colors.textMuted),
                "border": hex(colors.borderSubtle),
                "border-strong": hex(colors.borderStrong),
                "accent": hex(colors.accent),
                "ink": hex(colors.inkButtonFill),
                "ink-label": hex(colors.inkButtonLabel),
            ],
        ]
    }

    /// `state` as a JavaScript literal: JSON, with `<` escaped so the text
    /// can sit inside a `<script>` element whatever the values hold.
    static func literal(_ state: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json.replacingOccurrences(of: "<", with: "\\u003c")
    }

    /// The script that hands the page a new state.
    static func applyScript(_ state: [String: Any]) -> String {
        "window.__sopranoSettings && window.__sopranoSettings.apply(\(literal(state)));"
    }

    // MARK: Page

    /// The sidebar's sections, in page order.
    static let sections: [(id: String, title: String, icon: String)] = [
        ("search", "Search engine", "M11 11l4 4M7 12.5a5.5 5.5 0 1 1 0-11 5.5 5.5 0 0 1 0 11z"),
        ("appearance", "Appearance", "M8 1.5a6.5 6.5 0 1 0 0 13zM8 1.5a6.5 6.5 0 0 1 0 13"),
        ("startup", "On startup", "M8 1.5v6M4.2 3.8a6 6 0 1 0 7.6 0"),
        ("tabs", "Tabs", "M1.5 4.5h13v9h-13zM1.5 4.5V2.5h5v2"),
        ("privacy", "Privacy and security", "M8 1.5l5.5 2v4.2c0 3.2-2.3 5.6-5.5 6.8-3.2-1.2-5.5-3.6-5.5-6.8V3.5z"),
        ("downloads", "Downloads", "M8 1.5v9M4.5 7l3.5 3.5L11.5 7M2.5 13.5h11"),
        ("media", "Media", "M2.5 3h11v10h-11zM6.5 6v4l3.5-2z"),
        ("languages", "Languages", "M2 3.5h7M5.5 2v1.5M3.5 3.5c.5 2.5 2.5 4.5 5 5.5M7.5 3.5c-.5 2.5-2.5 4.5-5 5.5M8 14l3-7 3 7M9 11.5h4"),
        ("shortcuts", "Keyboard shortcuts", "M1.5 4h13v8h-13zM4 6.5h1M7.5 6.5h1M11 6.5h1M5 9.5h6"),
        ("browser", "Default browser", "M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM1.5 8h13M8 1.5c-2 2-2 11 0 13M8 1.5c2 2 2 11 0 13"),
        ("extensions", "Extensions", "M3 5.5h3v-1a1.5 1.5 0 1 1 3 0v1h3v3h-1a1.5 1.5 0 1 0 0 3h1v3H3v-3h1a1.5 1.5 0 1 0 0-3H3z"),
        ("system", "System", "M8 5.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5zM8 1v2M8 13v2M1 8h2M13 8h2M3 3l1.5 1.5M11.5 11.5L13 13M3 13l1.5-1.5M11.5 4.5L13 3"),
    ]

    static func html(state: [String: Any]) -> String {
        let nav = sections.map { section in
            """
            <a href="#\(section.id)" data-nav="\(section.id)"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="\(section.icon)"/></svg><span>\(section.title)</span></a>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en" translate="no">
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none';">
        <title>Settings</title>
        <style>\(css)</style>
        </head>
        <body>
        <aside>
          <h1>Settings</h1>
          <nav>
        \(nav)
          </nav>
          <p class="about">Soprano Web <span data-text="version"></span></p>
        </aside>
        <main>
          <div class="searchbar">
            <label class="search">
              <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M11 11l4 4M7 12.5a5.5 5.5 0 1 1 0-11 5.5 5.5 0 0 1 0 11z"/></svg>
              <input id="search" type="search" placeholder="Search settings" autocomplete="off" spellcheck="false">
            </label>
          </div>
          <div class="content">
        \(sectionsHTML)
            <p class="noresults" hidden>No settings match “<span id="query"></span>”.</p>
          </div>
        </main>
        <script id="state" type="application/json">\(literal(state))</script>
        <script>\(script)</script>
        </body>
        </html>
        """
    }

    // Rows: `data-switch` (a switch for that key), `select[data-key]`
    // (a menu), `data-open` (a native sheet), `data-command` (an action),
    // `data-text` (a fact from `text`). `data-keywords` adds search words.
    private static let sectionsHTML = """
        <section id="search">
          <h2>Search engine</h2>
          <div class="card">
            <div class="row"><div class="text"><div class="label">Search engine used in the address bar</div><div class="desc">Type a keyword first to search another engine</div></div><select data-key="searchEngine" aria-label="Search engine"></select></div>
            <div class="row"><div class="text"><div class="label">Show search suggestions</div><div class="desc">Ask the search engine for suggestions while you type in the address bar</div></div><button class="switch" data-switch="includeSearchSuggestions" role="switch" aria-label="Show search suggestions"></button></div>
            <button class="row link" data-open="searchEngines" data-keywords="keyword site search custom engine"><div class="text"><div class="label">Manage search engines and site search</div><div class="desc">Add engines and keywords, such as “w cats”</div></div><span class="chevron">›</span></button>
          </div>
        </section>
        <section id="appearance">
          <h2>Appearance</h2>
          <div class="card">
            <div class="row" data-keywords="color palette dark light"><div class="text"><div class="label">Theme</div></div><select data-key="themeID" aria-label="Theme"></select></div>
            <div class="row" data-keywords="dark light mode"><div class="text"><div class="label">Mode</div><div class="desc">Folio follows it; the other themes keep their own colors</div></div><select data-key="appearance" aria-label="Mode"></select></div>
            <div class="row" data-keywords="default page zoom size text"><div class="text"><div class="label">Page zoom</div><div class="desc">Sites you zoomed keep their own zoom</div></div><select data-key="defaultZoom" aria-label="Page zoom"></select></div>
          </div>
        </section>
        <section id="startup">
          <h2>On startup</h2>
          <div class="card">
            <div class="row" data-keywords="restore session reopen windows"><div class="text"><div class="label">Continue where you left off</div><div class="desc">Reopen your windows and tabs when Soprano Web starts</div></div><button class="switch" data-switch="restoreSession" role="switch" aria-label="Continue where you left off"></button></div>
            <div class="row" data-keywords="home start page"><div class="text"><div class="label">Homepage</div><div class="desc">Empty uses the start page</div></div><input id="homepage" class="field" type="text" placeholder="Start page" spellcheck="false" autocomplete="off" aria-label="Homepage"></div>
          </div>
        </section>
        <section id="tabs">
          <h2>Tabs</h2>
          <div class="card">
            <div class="row" data-keywords="sidebar rail"><div class="text"><div class="label">Vertical tabs</div><div class="desc">Tabs in a sidebar instead of across the top</div></div><button class="switch" data-switch="verticalTabs" role="switch" aria-label="Vertical tabs"></button></div>
            <div class="row" data-keywords="memory performance sleep"><div class="text"><div class="label">Put inactive tabs to sleep</div><div class="desc">Frees memory; a sleeping tab loads again when you return to it</div></div><select data-key="tabSleep" aria-label="Put inactive tabs to sleep"></select></div>
          </div>
        </section>
        <section id="privacy">
          <h2>Privacy and security</h2>
          <div class="card">
            <div class="row" data-keywords="adblock content blocker easylist easyprivacy"><div class="text"><div class="label">Block ads and trackers</div><div class="desc" data-text="blockerStatus"></div></div><div class="controls"><button class="btn" data-command="updateLists">Update now</button><button class="switch" data-switch="blockAdsAndTrackers" role="switch" aria-label="Block ads and trackers"></button></div></div>
            <button class="row link" data-open="clearData" data-keywords="cookies cache history delete"><div class="text"><div class="label">Clear browsing data</div><div class="desc">History, cookies, cache and more</div></div><span class="chevron">›</span></button>
            <div class="row" data-keywords="history delete keep"><div class="text"><div class="label">Remove history items</div><div class="desc">Older pages leave History on their own</div></div><select data-key="historyRetention" aria-label="Remove history items"></select></div>
            <button class="row link" data-open="websites" data-keywords="websites keep awake zoom permissions camera microphone location pop-ups popups notifications site settings"><div class="text"><div class="label">Site settings</div><div class="desc">Camera, microphone, notifications and pop-ups for each site</div></div><span class="chevron">›</span></button>
            <button class="row link" data-open="websiteData" data-keywords="cookies storage data"><div class="text"><div class="label">Website data</div><div class="desc">Cookies and storage sites keep on this Mac</div></div><span class="chevron">›</span></button>
            <div class="row" data-keywords="notifications permission"><div class="text"><div class="label">Sites can ask to send notifications</div><div class="desc">Off answers every new request with “Don’t Allow”</div></div><button class="switch" data-switch="allowsNotificationRequests" role="switch" aria-label="Sites can ask to send notifications"></button></div>
          </div>
        </section>
        <section id="downloads">
          <h2>Downloads</h2>
          <div class="card">
            <div class="row" data-keywords="folder location save"><div class="text"><div class="label">Location</div><div class="desc path" data-text="downloadDirectory"></div></div><button class="btn" data-command="chooseDownloads">Change</button></div>
            <div class="row" data-keywords="save panel ask"><div class="text"><div class="label">Ask where to save each file</div></div><button class="switch" data-switch="askDownloadLocation" role="switch" aria-label="Ask where to save each file"></button></div>
          </div>
        </section>
        <section id="media">
          <h2>Media</h2>
          <div class="card">
            <div class="row" data-keywords="video audio sound autoplay"><div class="text"><div class="label">Autoplay</div><div class="desc">Applies to tabs opened afterwards</div></div><select data-key="autoplay" aria-label="Autoplay"></select></div>
            <div class="row" data-keywords="picture in picture video floating"><div class="text"><div class="label">Mini Player for videos</div><div class="desc">A playing video follows you into a floating window when you leave its tab</div></div><button class="switch" data-switch="miniPlayer" role="switch" aria-label="Mini Player for videos"></button></div>
          </div>
        </section>
        <section id="languages">
          <h2>Languages</h2>
          <div class="card">
            <div class="row" data-keywords="translate translation"><div class="text"><div class="label">Never offer to translate</div><div class="desc">Add a language with the Translate button’s “Never Offer”; remove it here to be offered again</div><div class="chips" id="neverTranslate"></div></div></div>
          </div>
        </section>
        <section id="shortcuts">
          <h2>Keyboard shortcuts</h2>
          <div class="card">
            <button class="row link" data-open="shortcuts" data-keywords="keys hotkeys remap"><div class="text"><div class="label">Customize keyboard shortcuts</div><div class="desc">Change any command’s shortcut and whether sites can use it</div></div><span class="chevron">›</span></button>
            <div class="row" data-keywords="little arc global hotkey"><div class="text"><div class="label">New Little Arc from any app</div><div class="desc" data-text="shortcutStatus"></div></div><div class="controls"><button class="btn mono" data-command="recordShortcut" data-text="globalShortcut"></button><button class="switch" data-switch="globalLittleArcEnabled" role="switch" aria-label="New Little Arc from any app"></button></div></div>
          </div>
        </section>
        <section id="browser">
          <h2>Default browser</h2>
          <div class="card">
            <div class="row" data-keywords="default handler"><div class="text"><div class="label">Default browser</div><div class="desc" data-text="defaultBrowser"></div></div><button class="btn primary" data-command="makeDefault">Make default</button></div>
            <button class="row link" data-open="linkRouting" data-keywords="links other apps rules routing little arc"><div class="text"><div class="label">Links from other apps</div><div class="desc">Rules that pick the Space a link from another app opens in</div></div><span class="chevron">›</span></button>
            <button class="row link" data-open="importData" data-keywords="import arc chrome safari brave edge bookmarks history"><div class="text"><div class="label">Import browser data</div><div class="desc">Spaces, pinned tabs and History from Arc, Chrome, Safari and others</div></div><span class="chevron">›</span></button>
          </div>
        </section>
        <section id="extensions">
          <h2>Extensions</h2>
          <div class="card">
            <button class="row link" data-open="extensions" data-keywords="add-ons chrome web store ublock 1password"><div class="text"><div class="label">Manage extensions</div><div class="desc">Install from the Chrome Web Store, site access, private windows</div></div><span class="chevron">›</span></button>
          </div>
        </section>
        <section id="system">
          <h2>System</h2>
          <div class="card">
            <div class="row" data-keywords="applescript automation script"><div class="text"><div class="label">Allow JavaScript from Apple Events</div><div class="desc">Lets AppleScript run scripts in your pages</div></div><button class="switch" data-switch="allowsJavaScriptFromAppleEvents" role="switch" aria-label="Allow JavaScript from Apple Events"></button></div>
            <div class="row" data-keywords="settings json file config"><div class="text"><div class="label">Settings file</div><div class="desc path" data-text="settingsFile"></div></div><button class="btn" data-command="revealSettingsFile">Show in Finder</button></div>
          </div>
        </section>
    """

    private static let css = """
    :root {
      --bg: #1c1b19; --panel: #232220; --raised: #2a2926; --overlay: #33312d; --text: #ece7dd;
      --muted: #a29d93; --border: #3a3834; --border-strong: #4a4742; --accent: #d9a35b;
      --ink: #ece7dd; --ink-label: #2a2926;
    }
    * { box-sizing: border-box; }
    html { scroll-padding-top: 76px; }
    body {
      margin: 0; display: flex; min-height: 100vh;
      background: var(--bg); color: var(--text);
      font: 13px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    aside {
      position: sticky; top: 0; align-self: flex-start; height: 100vh;
      width: 248px; flex: none; padding: 26px 12px 18px; display: flex; flex-direction: column;
    }
    h1 { font: 400 26px/1.1 ui-serif, "New York", Georgia, serif; letter-spacing: -0.01em; margin: 4px 12px 22px; }
    nav { display: flex; flex-direction: column; gap: 1px; overflow: auto; }
    nav a {
      display: flex; align-items: center; gap: 12px; height: 32px; padding: 0 12px;
      border-radius: 6px; color: var(--text); text-decoration: none; font-weight: 450;
    }
    nav a:hover { background: var(--overlay); }
    nav a.current { background: var(--raised); box-shadow: inset 0 0 0 1px var(--border); }
    nav a.dim { opacity: 0.4; }
    svg { width: 16px; height: 16px; flex: none; fill: none; stroke: currentColor; stroke-width: 1.3; stroke-linecap: round; stroke-linejoin: round; }
    nav svg { color: var(--muted); }
    nav a.current svg { color: var(--text); }
    .about { margin: auto 12px 0; padding-top: 16px; color: var(--muted); font-size: 11px; }
    main { flex: 1; min-width: 0; padding: 0 40px 64px; }
    .searchbar { position: sticky; top: 0; z-index: 1; padding: 22px 0 14px; background: var(--bg); }
    .searchbar::after {
      content: ""; position: absolute; left: 0; right: 0; bottom: -14px; height: 14px; pointer-events: none;
      background: linear-gradient(var(--bg), transparent);
    }
    .search {
      display: flex; align-items: center; gap: 8px; max-width: 680px; height: 36px; padding: 0 12px; margin: 0 auto;
      background: var(--panel); border: 1px solid var(--border); border-radius: 8px; color: var(--muted);
    }
    .search:focus-within { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }
    .search input { flex: 1; border: 0; outline: 0; background: transparent; color: var(--text); font: inherit; font-size: 13px; }
    .search input::placeholder { color: var(--muted); }
    .content { max-width: 680px; margin: 0 auto; }
    section { margin-top: 18px; }
    section[hidden] { display: none; }
    h2 { font: 600 15px/1.2 -apple-system, BlinkMacSystemFont, sans-serif; margin: 0 0 10px 2px; }
    .card { background: var(--raised); border: 1px solid var(--border); border-radius: 12px; overflow: hidden; }
    .row {
      display: flex; align-items: center; gap: 16px; width: 100%; min-height: 56px; padding: 10px 16px;
      border: 0; border-top: 1px solid var(--border); background: none; color: inherit; font: inherit; text-align: left;
    }
    .row:first-child { border-top: 0; }
    .row[hidden] { display: none; }
    .row.first { border-top: 0; }
    .link { cursor: default; }
    .link:hover { background: var(--overlay); }
    .text { flex: 1; min-width: 0; }
    .label { font-weight: 500; }
    .desc { color: var(--muted); font-size: 12px; margin-top: 2px; }
    .desc:empty { display: none; }
    .path { font: 11.5px ui-monospace, "SF Mono", Menlo, monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .chevron { color: var(--muted); font-size: 20px; line-height: 1; }
    .controls { display: flex; align-items: center; gap: 12px; flex: none; }
    select, .field, .btn {
      height: 28px; border: 1px solid var(--border-strong); border-radius: 6px;
      background: var(--panel); color: var(--text); font: inherit; font-size: 12.5px;
    }
    select { min-width: 190px; padding: 0 8px; flex: none; }
    .field { width: 260px; padding: 0 10px; flex: none; outline: 0; }
    .field::placeholder { color: var(--muted); }
    .btn { padding: 0 12px; flex: none; white-space: nowrap; }
    .btn:hover:not(:disabled) { background: var(--overlay); }
    .btn:disabled { opacity: 0.45; }
    .btn.primary { background: var(--ink); color: var(--ink-label); border-color: var(--ink); }
    .btn.mono { font: 12px ui-monospace, "SF Mono", Menlo, monospace; min-width: 70px; }
    .btn.recording { border-color: var(--ink); box-shadow: inset 0 0 0 1px var(--ink); }
    select:focus-visible, .field:focus, .btn:focus-visible, .switch:focus-visible, .link:focus-visible {
      outline: 0; box-shadow: 0 0 0 2px var(--accent);
    }
    .switch {
      position: relative; flex: none; width: 32px; height: 18px; padding: 0; border-radius: 9px;
      border: 1px solid var(--border-strong); background: var(--panel);
    }
    .switch::after {
      content: ""; position: absolute; top: 2px; left: 2px; width: 12px; height: 12px; border-radius: 50%;
      background: var(--muted); transition: transform 120ms ease, background 120ms ease;
    }
    .switch[aria-checked="true"] { background: var(--ink); border-color: var(--ink); }
    .switch[aria-checked="true"]::after { transform: translateX(14px); background: var(--ink-label); }
    .chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
    .chips:empty { display: none; }
    .chip {
      display: inline-flex; align-items: center; gap: 6px; height: 24px; padding: 0 4px 0 10px;
      border: 1px solid var(--border-strong); border-radius: 12px; background: var(--panel); color: var(--text); font: inherit; font-size: 12px;
    }
    .chip span { color: var(--muted); font-size: 14px; width: 16px; text-align: center; }
    .chip:hover span { color: var(--text); }
    .noresults { color: var(--muted); margin: 28px 2px; }
    @media (max-width: 760px) {
      aside { display: none; }
      main { padding: 0 20px 48px; }
    }
    """

    private static let script = """
    (() => {
      "use strict";
      const post = (message) => {
        const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sopranoWeb;
        if (handler) handler.postMessage(Object.assign({ type: "settings" }, message));
      };
      const all = (selector, root = document) => Array.from(root.querySelectorAll(selector));
      let state = JSON.parse(document.getElementById("state").textContent);

      const fill = (select, options, value) => {
        const signature = JSON.stringify(options);
        if (select.dataset.options !== signature) {
          select.replaceChildren(...options.map((option) => {
            const element = document.createElement("option");
            element.value = option.value;
            element.textContent = option.label;
            return element;
          }));
          select.dataset.options = signature;
        }
        select.value = value;
      };

      const apply = (next) => {
        state = next;
        const root = document.documentElement;
        for (const [name, value] of Object.entries(next.theme.colors)) root.style.setProperty("--" + name, value);
        root.style.colorScheme = next.theme.scheme;
        for (const element of all("[data-switch]")) {
          element.setAttribute("aria-checked", String(Boolean(next.values[element.dataset.switch])));
        }
        for (const select of all("select[data-key]")) {
          fill(select, next.options[select.dataset.key] || [], String(next.values[select.dataset.key]));
        }
        const home = document.getElementById("homepage");
        if (document.activeElement !== home) home.value = next.values.homepage;
        for (const element of all("[data-text]")) element.textContent = next.text[element.dataset.text] ?? "";
        for (const element of all(".path")) element.title = element.textContent;
        const makeDefault = document.querySelector('[data-command="makeDefault"]');
        makeDefault.hidden = next.text.isDefaultBrowser;
        makeDefault.disabled = !next.text.canBecomeDefault;
        document.querySelector('[data-command="updateLists"]').disabled = !next.text.canUpdateLists;
        document.querySelector('[data-command="recordShortcut"]').classList.toggle("recording", next.text.isRecordingShortcut);
        const chips = document.getElementById("neverTranslate");
        chips.replaceChildren(...next.text.neverTranslate.map((language) => {
          const chip = document.createElement("button");
          chip.className = "chip";
          chip.title = "Offer to translate " + language.name + " again";
          chip.dataset.code = language.code;
          chip.append(language.name);
          const remove = document.createElement("span");
          remove.textContent = "×";
          chip.append(remove);
          return chip;
        }));
        chips.closest(".row").querySelector(".desc").textContent = next.text.neverTranslate.length
          ? "Remove a language to be offered translations for it again"
          : "None. Add a language with the Translate button’s “Never Offer”.";
        filter();
      };
      window.__sopranoSettings = { apply };

      document.addEventListener("click", (event) => {
        const target = event.target.closest("button, a");
        if (!target) return;
        if (target.dataset.switch) {
          const on = target.getAttribute("aria-checked") !== "true";
          target.setAttribute("aria-checked", String(on));
          post({ action: "set", key: target.dataset.switch, value: on });
        } else if (target.dataset.open) {
          post({ action: "open", sheet: target.dataset.open });
        } else if (target.dataset.command) {
          post({ action: target.dataset.command });
        } else if (target.dataset.code) {
          post({ action: "allowTranslation", code: target.dataset.code });
        } else if (target.dataset.nav) {
          event.preventDefault();
          const search = document.getElementById("search");
          if (search.value) { search.value = ""; filter(); }
          chosen = target.dataset.nav;
          document.getElementById(chosen).scrollIntoView({ behavior: "smooth" });
        }
      });
      for (const select of all("select[data-key]")) {
        select.addEventListener("change", () => post({ action: "set", key: select.dataset.key, value: select.value }));
      }
      const home = document.getElementById("homepage");
      const saveHome = () => post({ action: "set", key: "homepage", value: home.value });
      home.addEventListener("change", saveHome);
      home.addEventListener("keydown", (event) => { if (event.key === "Enter") home.blur(); });

      // Search: rows whose words contain every word typed; sections without
      // one hide, and so do their sidebar entries.
      const search = document.getElementById("search");
      const words = (text) => text.toLocaleLowerCase().split(/\\s+/).filter(Boolean);
      function filter() {
        const query = words(search.value);
        let shown = 0;
        for (const section of all("section")) {
          let visible = 0;
          for (const row of all(".row", section)) {
            const haystack = (row.textContent + " " + (row.dataset.keywords || "") + " " + section.querySelector("h2").textContent).toLocaleLowerCase();
            const match = query.every((word) => haystack.includes(word));
            row.hidden = !match;
            row.classList.toggle("first", false);
            if (match && visible === 0) row.classList.add("first");
            if (match) visible += 1;
          }
          section.hidden = visible === 0;
          document.querySelector('[data-nav="' + section.id + '"]').classList.toggle("dim", visible === 0);
          shown += visible;
        }
        const none = document.querySelector(".noresults");
        none.hidden = shown > 0;
        document.getElementById("query").textContent = search.value;
        spy();
      }
      search.addEventListener("input", filter);
      search.addEventListener("keydown", (event) => {
        if (event.key === "Escape" && search.value) { search.value = ""; filter(); }
      });

      // The sidebar marks the section at the top of the page, or the one
      // just chosen (a link, the address's #section) until the user
      // scrolls: the last sections can't reach the top.
      let chosen = null;
      function spy() {
        const sections = all("section").filter((section) => !section.hidden);
        let current = sections.find((section) => section.id === chosen);
        if (!current) {
          current = sections[0];
          for (const section of sections) {
            if (section.getBoundingClientRect().top <= 90) current = section;
          }
          if (window.innerHeight + window.scrollY >= document.body.scrollHeight - 2 && sections.length) {
            current = sections[sections.length - 1];
          }
        }
        for (const link of all("nav a")) link.classList.toggle("current", Boolean(current) && link.dataset.nav === current.id);
      }
      const release = () => { if (chosen) { chosen = null; spy(); } };
      for (const type of ["wheel", "touchmove", "keydown"]) window.addEventListener(type, release, { passive: true });
      window.addEventListener("scroll", spy, { passive: true });

      apply(state);
      if (location.hash.length > 1) {
        const section = document.getElementById(location.hash.slice(1));
        if (section) { chosen = section.id; section.scrollIntoView(); spy(); }
      }
      post({ action: "ready" });
      document.addEventListener("visibilitychange", () => { if (!document.hidden) post({ action: "ready" }); });
    })();
    """
}
