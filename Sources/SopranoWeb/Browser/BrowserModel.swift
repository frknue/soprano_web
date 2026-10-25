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

enum SearchEngine: String, Codable, CaseIterable, Sendable {
    case duckDuckGo
    case google
    case bing

    var name: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        }
    }

    var searchFormURL: String {
        switch self {
        case .duckDuckGo: "https://duckduckgo.com/"
        case .google: "https://www.google.com/search"
        case .bing: "https://www.bing.com/search"
        }
    }

    func searchURL(for query: String) -> URL? {
        var components = URLComponents()
        switch self {
        case .duckDuckGo:
            components.host = "duckduckgo.com"
            components.path = "/"
        case .google:
            components.host = "www.google.com"
            components.path = "/search"
        case .bing:
            components.host = "www.bing.com"
            components.path = "/search"
        }
        components.scheme = "https"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }
}

struct BrowserSettings: Codable, Equatable, Sendable {
    var version: Int = 1
    var searchEngine: SearchEngine = .duckDuckGo
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

    static let `default` = BrowserSettings()

    var usesVerticalTabs: Bool {
        verticalTabs ?? true
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
        searchEngine = (try? c.decodeIfPresent(SearchEngine.self, forKey: .searchEngine)) ?? searchEngine
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
    /// Resolves what the address bar or a command-line argument means.
    /// `about:start` and empty input both mean the start page.
    static func resolve(
        _ input: String,
        searchEngine: SearchEngine = .duckDuckGo
    ) -> URL? {
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

        return searchEngine.searchURL(for: trimmed)
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

struct BrowserTabState: Codable, Equatable, Sendable {
    /// Nil is the start page.
    var url: String?
    var title: String = ""
    var zoom: Double = 1
    /// WebKit's archived back/forward list (`WKWebView.interactionState`).
    /// Nil in files written before it was saved; the tab then restores its
    /// URL only.
    var interactionState: Data?
}

extension BrowserTabState {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? title
        zoom = (try? c.decodeIfPresent(Double.self, forKey: .zoom)) ?? zoom
        interactionState = try? c.decodeIfPresent(Data.self, forKey: .interactionState)
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

/// One saved window: its tabs, the selected one, where it was and its
/// profile.
struct BrowserWindowState: Codable, Equatable, Sendable {
    /// Stable across relaunches, so a closed tab finds its window again.
    var id = UUID()
    /// Nil for the window a version 1 session migrates to.
    var frame: BrowserWindowFrame?
    var tabs: [BrowserTabState]
    var selectedIndex = 0
    /// Missing in files written before profiles: Default. A profile that no
    /// longer exists opens in Default too.
    var profileID = BrowserProfile.defaultID
}

extension BrowserWindowState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        frame = try? c.decodeIfPresent(BrowserWindowFrame.self, forKey: .frame)
        tabs = (try? c.decodeIfPresent(LossyArray<BrowserTabState>.self, forKey: .tabs))?.elements ?? []
        selectedIndex = (try? c.decodeIfPresent(Int.self, forKey: .selectedIndex)) ?? 0
        profileID = ((try? c.decodeIfPresent(UUID.self, forKey: .profileID)) ?? nil) ?? BrowserProfile.defaultID
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
struct BrowserSession: Codable, Equatable, Sendable {
    static let currentVersion = 2

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

    /// Where a version 1 file is kept after it migrates.
    var migratedURL: URL {
        url.appendingPathExtension("migrated")
    }

    /// Reads the session. A version 1 file is copied to `migratedURL` once;
    /// the next save replaces it with version 2.
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
