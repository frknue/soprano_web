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

@MainActor
final class BrowserSettingsStore {
    private(set) var settings: BrowserSettings
    let url: URL
    var onChange: ((BrowserSettings) -> Void)?

    init(
        url: URL = BrowserFiles.configURL(),
        settings: BrowserSettings? = nil
    ) {
        self.url = url
        self.settings = settings ?? JSONFile.read(BrowserSettings.self, at: url) ?? .default
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
        try? JSONFile.write(next, to: url)
        onChange?(next)
    }

    func save() {
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
}

struct BrowserSession: Codable, Equatable, Sendable {
    var tabs: [BrowserTabState]
    var selectedIndex: Int
    var savedAt: Date
}

@MainActor
final class BrowserSessionStore {
    let url: URL

    init(url: URL = BrowserFiles.supportDirectory().appendingPathComponent("session.json")) {
        self.url = url
    }

    func load() -> BrowserSession? {
        JSONFile.read(BrowserSession.self, at: url)
    }

    func save(_ session: BrowserSession) {
        try? JSONFile.write(session, to: url)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
