import AppKit

// MARK: - Files

enum BrowserFiles {
    static var applicationName: String {
        Bundle.main.bundleIdentifier == "com.soprano.web.dev" ? "Soprano Web Dev" : "Soprano Web"
    }

    static var configName: String {
        Bundle.main.bundleIdentifier == "com.soprano.web.dev" ? "soprano-web-dev" : "soprano-web"
    }

    static func supportDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent(applicationName, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func configURL(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent(configName, isDirectory: true)
            .appendingPathComponent("settings.json")
    }
}

/// A small JSON file that survives a crash mid-write.
enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

/// The file shape of a list store: `{ "version": 1, "entries": [...] }`.
/// Reading also accepts the legacy bare array; an element that does not
/// decode is skipped instead of dropping the whole list.
struct JSONList<Element: Codable>: Codable {
    static var currentVersion: Int { 1 }

    var version: Int
    var entries: [Element]

    init(_ entries: [Element]) {
        self.version = Self.currentVersion
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            entries = try c.decodeIfPresent(LossyArray<Element>.self, forKey: .entries)?.elements ?? []
        } else {
            version = 1
            entries = try LossyArray<Element>(from: decoder).elements
        }
    }
}

/// Decodes a JSON array element by element and skips the ones that fail.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(Skipped.self)) == nil {
                // A failed decode does not advance the container; stop
                // rather than loop if even skipping fails.
                break
            }
        }
        self.elements = elements
    }

    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

// MARK: - Settings

enum AppearancePreference: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    var name: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

struct BrowserSettings: Codable, Equatable, Sendable {
    var version: Int = 1
    /// The default engine: a built-in's id or one of `customSearchEngines`'.
    var searchEngine: BrowserSearchEngineID = .duckDuckGo
    /// Settings ▸ Search engine ▸ Manage…, after the built-ins.
    var customSearchEngines: [BrowserSearchEngine] = []
    /// Keywords given to built-in engines, by id (`"google": "g"`); they
    /// have none by default.
    var searchEngineKeywords: [String: String] = [:]
    /// Empty means the built-in start page.
    var homepage: String = ""
    var themeID: String = "folio"
    var appearance: AppearancePreference = .system
    var restoreSession: Bool = true
    /// Nil means ~/Downloads.
    var downloadDirectory: String?
    /// Nil means the default (on). Stored as an optional so older settings
    /// files without the key keep their other values and start vertical.
    var verticalTabs: Bool? = true
    /// Ask the search engine for suggestions while typing in the address bar.
    var includeSearchSuggestions: Bool = true
    /// Settings ▸ Autoplay; applies to tabs opened afterwards.
    var autoplay: AutoplayPolicy = .stopMediaWithSound
    /// Settings ▸ "Allow websites to ask to send notifications". Off answers
    /// every request from a site without a remembered decision with "denied".
    var allowsNotificationRequests: Bool = true
    /// Show a save panel for every download instead of saving to
    /// `downloadDirectory`.
    var askDownloadLocation: Bool = false
    /// Settings ▸ "Remove history items".
    var historyRetention: BrowserHistoryRetention = .oneYear
    /// Settings ▸ "Put inactive tabs to sleep".
    var tabSleep: BrowserTabSleepAfter = .oneHour
    /// Settings ▸ "Default page zoom", one of `BrowserZoom.steps`; sites
    /// without a remembered zoom use it.
    var defaultZoom: Double = 1
    /// Settings ▸ "Block ads and trackers" (EasyList and EasyPrivacy).
    var blockAdsAndTrackers: Bool = true
    /// Settings ▸ Keyboard shortcuts: remapped shortcuts and their
    /// priority, by command id.
    var shortcuts = BrowserShortcutSettings()
    /// Settings ▸ Keyboard shortcuts ▸ "New Little Arc from any app": off
    /// by default; while on, `globalLittleArcShortcut` opens a Little Arc
    /// with the Command Bar whichever app is in front.
    var globalLittleArcEnabled: Bool = false
    /// That shortcut, as `"opt+cmd+n"`.
    var globalLittleArcShortcut: String = BrowserGlobalShortcut.fallback

    static let `default` = BrowserSettings()

    var usesVerticalTabs: Bool {
        verticalTabs ?? true
    }

    /// The shortcuts in effect (the registry's defaults, then `shortcuts`).
    var keymap: BrowserKeymap {
        get { BrowserKeymap(shortcuts) }
        set { shortcuts = newValue.settings }
    }

    /// Every engine and the default (an unknown default reads as DuckDuckGo).
    var searchEngines: BrowserSearchEngines {
        get {
            BrowserSearchEngines(
                custom: customSearchEngines,
                builtInKeywords: searchEngineKeywords,
                defaultID: searchEngine
            )
        }
        set {
            customSearchEngines = newValue.custom
            searchEngineKeywords = newValue.builtInKeywords
            searchEngine = newValue.defaultID
        }
    }

    var defaultSearchEngine: BrowserSearchEngine {
        searchEngines.defaultEngine
    }

    var downloadDirectoryURL: URL {
        if let downloadDirectory, !downloadDirectory.isEmpty {
            return URL(fileURLWithPath: downloadDirectory, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
}

extension BrowserSettings {
    /// Decodes key by key: a missing key, a wrong type or an unknown enum
    /// value falls back to that key's default and keeps the others. A new
    /// setting adds one line here.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? version
        // Engines before the default, so it can name a custom one; a bad
        // entry, a repeated id or keyword is dropped, an unknown default is
        // DuckDuckGo.
        let engines = BrowserSearchEngines(
            custom: (try? c.decodeIfPresent(LossyArray<BrowserSearchEngine>.self, forKey: .customSearchEngines))?
                .elements ?? [],
            builtInKeywords: (try? c.decodeIfPresent(BrowserSearchKeywordMap.self, forKey: .searchEngineKeywords))?
                .keywords ?? [:],
            defaultID: (try? c.decodeIfPresent(BrowserSearchEngineID.self, forKey: .searchEngine)) ?? searchEngine
        )
        customSearchEngines = engines.custom
        searchEngineKeywords = engines.builtInKeywords
        searchEngine = engines.defaultID
        homepage = (try? c.decodeIfPresent(String.self, forKey: .homepage)) ?? homepage
        themeID = (try? c.decodeIfPresent(String.self, forKey: .themeID)) ?? themeID
        appearance = (try? c.decodeIfPresent(AppearancePreference.self, forKey: .appearance)) ?? appearance
        restoreSession = (try? c.decodeIfPresent(Bool.self, forKey: .restoreSession)) ?? restoreSession
        downloadDirectory = (try? c.decodeIfPresent(String.self, forKey: .downloadDirectory)) ?? downloadDirectory
        // Missing stays nil, which `usesVerticalTabs` reads as on.
        verticalTabs = try? c.decodeIfPresent(Bool.self, forKey: .verticalTabs)
        includeSearchSuggestions = (try? c.decodeIfPresent(Bool.self, forKey: .includeSearchSuggestions)) ?? includeSearchSuggestions
        autoplay = (try? c.decodeIfPresent(AutoplayPolicy.self, forKey: .autoplay)) ?? autoplay
        allowsNotificationRequests = (try? c.decodeIfPresent(Bool.self, forKey: .allowsNotificationRequests))
            ?? allowsNotificationRequests
        askDownloadLocation = (try? c.decodeIfPresent(Bool.self, forKey: .askDownloadLocation)) ?? askDownloadLocation
        historyRetention = (try? c.decodeIfPresent(BrowserHistoryRetention.self, forKey: .historyRetention))
            ?? historyRetention
        tabSleep = (try? c.decodeIfPresent(BrowserTabSleepAfter.self, forKey: .tabSleep)) ?? tabSleep
        defaultZoom = ((try? c.decodeIfPresent(Double.self, forKey: .defaultZoom)) ?? nil)
            .flatMap(BrowserZoom.validated)
            .map(BrowserZoom.nearestStep) ?? defaultZoom
        blockAdsAndTrackers = (try? c.decodeIfPresent(Bool.self, forKey: .blockAdsAndTrackers)) ?? blockAdsAndTrackers
        shortcuts = (try? c.decodeIfPresent(BrowserShortcutSettings.self, forKey: .shortcuts)) ?? shortcuts
        globalLittleArcEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .globalLittleArcEnabled))
            ?? globalLittleArcEnabled
        // A chord the system, text editing or another command uses never
        // becomes a global hotkey (a hand-edited file included): a taken
        // chord falls back to the default, and when that one is taken too
        // the hotkey stays off rather than steal a command's chord.
        let keymap = self.keymap
        let stored = (try? c.decodeIfPresent(String.self, forKey: .globalLittleArcShortcut)).flatMap { BrowserShortcut($0) }
        let fallback = BrowserShortcut(BrowserGlobalShortcut.fallback)
        if let stored, BrowserGlobalShortcut.isAcceptable(stored, keymap: keymap) {
            globalLittleArcShortcut = stored.storageText
        } else if let fallback, BrowserGlobalShortcut.isAcceptable(fallback, keymap: keymap) {
            globalLittleArcShortcut = fallback.storageText
        } else {
            globalLittleArcEnabled = false
        }
    }
}

@MainActor
final class BrowserSettingsStore {
    private(set) var settings: BrowserSettings
    let url: URL
    let changes = BrowserObservers<BrowserSettings>()
    /// Set when `settings.json` exists but cannot be read; the first write
    /// moves it to `unreadableURL` instead of overwriting it.
    private var preservesUnreadableFile = false

    init(
        url: URL = BrowserFiles.configURL(),
        settings: BrowserSettings? = nil
    ) {
        self.url = url
        if let settings {
            self.settings = settings
        } else if let saved = JSONFile.read(BrowserSettings.self, at: url) {
            self.settings = saved
        } else {
            self.settings = .default
            preservesUnreadableFile = FileManager.default.fileExists(atPath: url.path)
        }
    }

    var unreadableURL: URL {
        url.appendingPathExtension("unreadable")
    }

    var displayPath: String {
        url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    func update(_ change: (inout BrowserSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        write(next)
        changes.notify(next)
    }

    func save() {
        write(settings)
    }

    private func write(_ settings: BrowserSettings) {
        if preservesUnreadableFile {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: unreadableURL)
            guard (try? fileManager.moveItem(at: url, to: unreadableURL)) != nil
                || !fileManager.fileExists(atPath: url.path)
            else { return }
            preservesUnreadableFile = false
        }
        try? JSONFile.write(settings, to: url)
    }
}

// MARK: - Addresses

enum BrowserAddressResolver {
    /// Resolves what the address bar or a command-line argument means:
    /// "keyword query" searches that engine, an address opens, anything
    /// else searches the default engine. `about:start` and empty input
    /// both mean the start page.
    static func resolve(
        _ input: String,
        searchEngines: BrowserSearchEngines = .default
    ) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let search = searchEngines.resolve(trimmed) {
            return search.url
        }
        if let url = address(for: trimmed) {
            return url
        }
        return searchEngines.defaultEngine.searchURL(for: trimmed)
    }

    /// The URL `input` names when it reads as an address (the start page
    /// for empty input), or nil when it reads as a search.
    static func address(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return URL(string: "about:start") }

        let lowercased = trimmed.lowercased()
        if lowercased == "about:start" || lowercased == "start" {
            return URL(string: "about:start")
        }
        if lowercased == "about:blank" {
            return URL(string: "about:blank")
        }

        let isLocal = lowercased == "localhost"
            || lowercased.hasPrefix("localhost:")
            || lowercased == "127.0.0.1"
            || lowercased.hasPrefix("127.0.0.1:")
            || lowercased == "0.0.0.0"
            || lowercased.hasPrefix("0.0.0.0:")
            || lowercased == "[::1]"
            || lowercased.hasPrefix("[::1]:")
        if isLocal {
            return URL(string: "http://\(trimmed)")
        }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
            if ["http", "https", "file", "about"].contains(scheme) {
                return url
            }
            // mailto:, tel: and app schemes are handed to the system by the
            // navigation delegate; they still need to reach it as a URL.
            if url.scheme != nil {
                return url
            }
        }

        if !trimmed.contains(where: \.isWhitespace),
           trimmed.contains(".") || trimmed.contains(":")
        {
            return URL(string: "https://\(trimmed)")
        }

        return nil
    }

    static func isStartPage(_ url: URL?) -> Bool {
        if url?.scheme?.lowercased() == "soprano-web" {
            return true
        }
        return url?.scheme == "about" && url?.path == "start"
    }

    static func isLocal(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

// MARK: - Session

/// One saved tab. Files before the sleep slice also hold a per-tab `zoom`;
/// it is ignored, since a page takes its site's zoom when it loads.
/// Version 3 adds the tab's Space and its pin or favorite link (`pinID`,
/// `favoriteID`); without them a tab is a Today tab of its window's
/// profile's first Space.
struct BrowserTabState: Codable, Equatable, Sendable {
    /// Nil is the start page.
    var url: String?
    var title: String = ""
    /// WebKit's archived back/forward list (`WKWebView.interactionState`).
    /// Nil in files written before it was saved; the tab then restores its
    /// URL only.
    var interactionState: Data?
    /// The tab's Space; nil in a private window and in version 2 files.
    var spaceID: UUID?
    var origin: BrowserTabOrigin = .today
    /// Where the last load of a linked tab's pin landed (its redirect
    /// target), so a restored tab there shows no "/".
    var linkLanding: String?
    /// When the tab was last selected or used, so idle time (the Archive's
    /// `archiveAfter`, tab sleep) carries over a relaunch. Nil in older
    /// files: the tab counts from the restore.
    var lastActiveAt: Date?

    private enum CodingKeys: String, CodingKey {
        case url, title, interactionState, spaceID, pinID, favoriteID, linkLanding, lastActiveAt
    }
}

extension BrowserTabState {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? title
        interactionState = try? c.decodeIfPresent(Data.self, forKey: .interactionState)
        spaceID = (try? c.decodeIfPresent(UUID.self, forKey: .spaceID)) ?? nil
        if let pin = (try? c.decodeIfPresent(UUID.self, forKey: .pinID)) ?? nil {
            origin = .pinned(pin)
        } else if let favorite = (try? c.decodeIfPresent(UUID.self, forKey: .favoriteID)) ?? nil {
            origin = .favorite(favorite)
        }
        if origin != .today {
            linkLanding = (try? c.decodeIfPresent(String.self, forKey: .linkLanding)) ?? nil
        }
        lastActiveAt = (try? c.decodeIfPresent(Date.self, forKey: .lastActiveAt)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(interactionState, forKey: .interactionState)
        try c.encodeIfPresent(spaceID, forKey: .spaceID)
        try c.encodeIfPresent(origin.pinID, forKey: .pinID)
        try c.encodeIfPresent(origin.favoriteID, forKey: .favoriteID)
        try c.encodeIfPresent(origin == .today ? nil : linkLanding, forKey: .linkLanding)
        try c.encodeIfPresent(lastActiveAt, forKey: .lastActiveAt)
    }
}

/// A window frame in screen coordinates (bottom-left origin).
struct BrowserWindowFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: NSRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var rect: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }
}

/// One saved window: its tabs, the selected one, where it was, the Space it
/// shows and each Space's selection.
struct BrowserWindowState: Codable, Equatable, Sendable {
    /// Stable across relaunches, so a closed tab finds its window again.
    var id = UUID()
    /// Nil for the window a version 1 session migrates to.
    var frame: BrowserWindowFrame?
    /// Every tab of every Space, in window order.
    var tabs: [BrowserTabState]
    /// Index in `tabs` of the selected tab (of the current Space).
    var selectedIndex = 0
    /// The current Space's profile (version 2: the window's profile).
    /// Missing in files written before profiles: Default. A profile that no
    /// longer exists opens in Default too.
    var profileID = BrowserProfile.defaultID
    /// The Space the window shows (a Little Arc's: its Space); nil in a
    /// private window and in version 2 files (`placedInSpaces` picks the
    /// profile's first Space).
    var currentSpaceID: UUID?
    /// The tab each Space selects when the window switches to it.
    var spaceSelections: [BrowserSpaceSelection] = []
    /// Normal or Little Arc (pop-ups are never saved); missing before
    /// version 4: normal.
    var role: BrowserWindowRole = .normal
    /// The window's split views (version 5); none before.
    var splits: [BrowserSplitState] = []
}

/// A Space's remembered tab in a saved window: its index in the window's
/// `tabs`.
struct BrowserSpaceSelection: Codable, Equatable, Sendable {
    var spaceID: UUID
    var index: Int
}

extension BrowserWindowState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        frame = try? c.decodeIfPresent(BrowserWindowFrame.self, forKey: .frame)
        tabs = (try? c.decodeIfPresent(LossyArray<BrowserTabState>.self, forKey: .tabs))?.elements ?? []
        selectedIndex = (try? c.decodeIfPresent(Int.self, forKey: .selectedIndex)) ?? 0
        profileID = ((try? c.decodeIfPresent(UUID.self, forKey: .profileID)) ?? nil) ?? BrowserProfile.defaultID
        currentSpaceID = (try? c.decodeIfPresent(UUID.self, forKey: .currentSpaceID)) ?? nil
        spaceSelections = (try? c.decodeIfPresent(LossyArray<BrowserSpaceSelection>.self, forKey: .spaceSelections))?
            .elements ?? []
        role = (try? c.decodeIfPresent(BrowserWindowRole.self, forKey: .role)) ?? .normal
        splits = (try? c.decodeIfPresent(LossyArray<BrowserSplitState>.self, forKey: .splits))?.elements ?? []
    }

    /// The selected tab's title, as the Window menu showed it.
    var title: String {
        let tab = tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : tabs.first
        return tab?.displayTitle ?? "New Window"
    }
}

extension BrowserTabState {
    /// The title a closed tab shows in History ▸ Recently Closed.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = url.flatMap(URL.init(string:))?.host, !host.isEmpty { return host }
        return url == nil ? "New Tab" : "Untitled"
    }
}

/// `session.json`: every open window and the recently-closed stack.
///
/// Version 1 (stage 1) held one window's `tabs`, `selectedIndex` and
/// `closedTabs`; it decodes as one window whose closed tabs return to it.
/// Version 2 windows have no Spaces; their tabs open in the first Space of
/// the window's profile (`BrowserWindowState.placedInSpaces`). Version 3
/// adds each window's `currentSpaceID` and `spaceSelections` and each
/// tab's `spaceID` and pin or favorite link. Version 4 adds each window's
/// `role` (`normal` or `little`); older windows are normal. Version 5 adds
/// each window's `splits` (`BrowserSplitState`); older windows have none.
struct BrowserSession: Codable, Equatable, Sendable {
    static let currentVersion = 5

    /// The version of the file this was read from; new sessions are current.
    var version = Self.currentVersion
    var windows: [BrowserWindowState]
    /// Index in `windows` of the window that was in front.
    var activeWindowIndex: Int?
    /// Most recently closed last; see `BrowserRecentlyClosedStack`.
    var recentlyClosed: [BrowserClosedEntry] = []
    var savedAt: Date

    enum CodingKeys: String, CodingKey {
        case version, windows, activeWindowIndex, recentlyClosed, savedAt
    }

    private enum Version1Keys: String, CodingKey {
        case tabs, selectedIndex, closedTabs
    }
}

extension BrowserSession {
    /// Files written before `version` existed are version 1. A window, tab or
    /// closed entry that does not decode is skipped instead of dropping the
    /// session.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let savedAt = (try? c.decodeIfPresent(Date.self, forKey: .savedAt)) ?? .distantPast
        guard c.contains(.windows) else {
            self = try Self.version1(from: decoder, savedAt: savedAt)
            return
        }
        self.init(
            version: (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion,
            windows: (try? c.decodeIfPresent(LossyArray<BrowserWindowState>.self, forKey: .windows))?.elements ?? [],
            activeWindowIndex: try? c.decodeIfPresent(Int.self, forKey: .activeWindowIndex),
            recentlyClosed: (try? c.decodeIfPresent(LossyArray<BrowserClosedEntry>.self, forKey: .recentlyClosed))?
                .elements ?? [],
            savedAt: savedAt
        )
    }

    /// One window with the saved tabs; the closed tabs go back to it.
    private static func version1(from decoder: Decoder, savedAt: Date) throws -> BrowserSession {
        let c = try decoder.container(keyedBy: Version1Keys.self)
        let tabs = (try? c.decodeIfPresent(LossyArray<BrowserTabState>.self, forKey: .tabs))?.elements ?? []
        let closed = (try? c.decodeIfPresent(LossyArray<BrowserTabState>.self, forKey: .closedTabs))?.elements ?? []
        let window = BrowserWindowState(
            tabs: tabs,
            selectedIndex: (try? c.decodeIfPresent(Int.self, forKey: .selectedIndex)) ?? 0
        )
        let windowID = tabs.isEmpty ? nil : window.id
        return BrowserSession(
            version: 1,
            windows: tabs.isEmpty ? [] : [window],
            activeWindowIndex: tabs.isEmpty ? nil : 0,
            recentlyClosed: closed.map { BrowserClosedEntry(.tab($0, windowID: windowID, index: nil)) },
            savedAt: savedAt
        )
    }
}

@MainActor
final class BrowserSessionStore {
    let url: URL

    init(url: URL = BrowserFiles.supportDirectory().appendingPathComponent("session.json")) {
        self.url = url
    }

    /// Where an older file (version 1 or 2) is kept after it migrates.
    var migratedURL: URL {
        url.appendingPathExtension("migrated")
    }

    /// Reads the session. An older file is copied to `migratedURL` once (a
    /// copy already there stays); the next save replaces it with the
    /// current version.
    func load() -> BrowserSession? {
        guard let session = JSONFile.read(BrowserSession.self, at: url) else { return nil }
        if session.version < BrowserSession.currentVersion,
           !FileManager.default.fileExists(atPath: migratedURL.path)
        {
            try? FileManager.default.copyItem(at: url, to: migratedURL)
        }
        return session
    }

    func save(_ session: BrowserSession) {
        try? JSONFile.write(session, to: url)
    }
}
