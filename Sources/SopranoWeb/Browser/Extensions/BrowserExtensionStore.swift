import Foundation

/// One installed extension as `extensions.json` keeps it: where it came
/// from, the user's choices (enabled, private windows, site access) and
/// what WebKit granted or denied it, restored before every load.
struct BrowserExtensionRecord: Codable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// Installed from the Chrome Web Store; updated daily.
        case webStore
        /// Copied from an unpacked folder (its path at install time).
        case folder(String)

        var title: String {
            switch self {
            case .webStore: "Chrome Web Store"
            case let .folder(path): "Unpacked (\(path))"
            }
        }
    }

    /// Settings ▸ Extensions ▸ Site access, as Chrome names it.
    enum SiteAccess: String, Codable, CaseIterable, Sendable {
        /// Every site the extension asked for at install.
        case allSites = "all"
        /// Only `allowedSites`.
        case specificSites = "specific"
        /// None until the toolbar button is clicked on a page (activeTab).
        case onClick = "click"

        var title: String {
            switch self {
            case .allSites: "On all sites"
            case .specificSites: "On specific sites"
            case .onClick: "When you click the extension"
            }
        }
    }

    var id: String
    var source: Source
    var name: String
    var version: String
    var isEnabled = true
    /// "Allow in private windows" (`hasAccessToPrivateData`).
    var allowsPrivate = false
    var siteAccess: SiteAccess = .allSites
    /// Hosts of `specificSites` (`example.com` also covers its subdomains).
    var allowedSites: [String] = []
    /// WebKit's granted and denied permissions and match patterns with
    /// their expiration (`distantFuture`: none).
    var grantedPermissions: [String: Date] = [:]
    var deniedPermissions: [String: Date] = [:]
    var grantedMatchPatterns: [String: Date] = [:]
    var deniedMatchPatterns: [String: Date] = [:]
    var requestedOptionalAccessToAllHosts = false
    var installedAt: Date
    var lastUpdateCheck: Date?

    init(id: String, source: Source, name: String, version: String, installedAt: Date = Date()) {
        self.id = id
        self.source = source
        self.name = name
        self.version = version
        self.installedAt = installedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, folder, name, version, enabled, privateAccess, siteAccess, allowedSites
        case grantedPermissions, deniedPermissions, grantedMatchPatterns, deniedMatchPatterns
        case optionalAllHosts, installedAt, lastUpdateCheck
    }

    /// A record needs a valid id and a known source; everything else falls
    /// back to its default when missing or unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        guard BrowserExtensionID.isValid(id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "not an extension id")
        }
        switch try c.decode(String.self, forKey: .source) {
        case "webStore":
            source = .webStore
        case "folder":
            guard let path = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? nil, !path.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .folder, in: c, debugDescription: "no folder")
            }
            source = .folder(path)
        default:
            throw DecodingError.dataCorruptedError(forKey: .source, in: c, debugDescription: "unknown source")
        }
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? id
        version = ((try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil) ?? ""
        isEnabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? true
        allowsPrivate = ((try? c.decodeIfPresent(Bool.self, forKey: .privateAccess)) ?? nil) ?? false
        siteAccess = ((try? c.decodeIfPresent(String.self, forKey: .siteAccess)) ?? nil)
            .flatMap(SiteAccess.init(rawValue:)) ?? .allSites
        allowedSites = ((try? c.decodeIfPresent([String].self, forKey: .allowedSites)) ?? nil) ?? []
        grantedPermissions = Self.dates(c, .grantedPermissions)
        deniedPermissions = Self.dates(c, .deniedPermissions)
        grantedMatchPatterns = Self.dates(c, .grantedMatchPatterns)
        deniedMatchPatterns = Self.dates(c, .deniedMatchPatterns)
        requestedOptionalAccessToAllHosts = ((try? c.decodeIfPresent(Bool.self, forKey: .optionalAllHosts)) ?? nil) ?? false
        installedAt = ((try? c.decodeIfPresent(Date.self, forKey: .installedAt)) ?? nil) ?? Date(timeIntervalSince1970: 0)
        lastUpdateCheck = (try? c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        switch source {
        case .webStore:
            try c.encode("webStore", forKey: .source)
        case let .folder(path):
            try c.encode("folder", forKey: .source)
            try c.encode(path, forKey: .folder)
        }
        try c.encode(name, forKey: .name)
        try c.encode(version, forKey: .version)
        try c.encode(isEnabled, forKey: .enabled)
        try c.encode(allowsPrivate, forKey: .privateAccess)
        try c.encode(siteAccess.rawValue, forKey: .siteAccess)
        try c.encode(allowedSites, forKey: .allowedSites)
        try c.encode(grantedPermissions, forKey: .grantedPermissions)
        try c.encode(deniedPermissions, forKey: .deniedPermissions)
        try c.encode(grantedMatchPatterns, forKey: .grantedMatchPatterns)
        try c.encode(deniedMatchPatterns, forKey: .deniedMatchPatterns)
        try c.encode(requestedOptionalAccessToAllHosts, forKey: .optionalAllHosts)
        try c.encode(installedAt, forKey: .installedAt)
        try c.encodeIfPresent(lastUpdateCheck, forKey: .lastUpdateCheck)
    }

    /// A `{ name: date }` map; entries that don't read are dropped.
    private static func dates(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String: Date] {
        guard let raw = (try? c.decodeIfPresent([String: LossyDate].self, forKey: key)) ?? nil else { return [:] }
        return raw.compactMapValues(\.date)
    }

    private struct LossyDate: Decodable {
        var date: Date?

        init(from decoder: Decoder) throws {
            date = try? decoder.singleValueContainer().decode(Date.self)
        }
    }
}

/// `extensions.json`: `{ "version": 1, "extensions": [record…] }`. A
/// record that doesn't decode is skipped and a repeated id keeps its first
/// record.
struct BrowserExtensionsFile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var extensions: [BrowserExtensionRecord]

    init(extensions: [BrowserExtensionRecord]) {
        self.extensions = extensions
    }

    private enum CodingKeys: String, CodingKey {
        case version, extensions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = (try? c.decodeIfPresent(LossyArray<BrowserExtensionRecord>.self, forKey: .extensions))?.elements ?? []
        var seen: Set<String> = []
        extensions = decoded.filter { seen.insert($0.id).inserted }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(extensions, forKey: .extensions)
    }
}

/// The only way in or out of the installed extensions: `extensions.json`
/// in the support folder (synchronous, atomic, `changes` after each
/// write; an unreadable file is kept as `.corrupt`) and each package in
/// `<support>/Extensions/<id>/`.
@MainActor
final class BrowserExtensionStore {
    let url: URL
    /// `<support>/Extensions/`.
    let directory: URL
    let changes = BrowserObservers<Void>()
    private(set) var records: [BrowserExtensionRecord]

    init(supportDirectory: URL) {
        url = supportDirectory.appendingPathComponent("extensions.json")
        directory = supportDirectory.appendingPathComponent("Extensions", isDirectory: true)
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let file = try? decoder.decode(BrowserExtensionsFile.self, from: data) {
                records = file.extensions
            } else {
                // Kept for a look; the next write starts a fresh file.
                let corrupt = url.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: corrupt)
                try? FileManager.default.moveItem(at: url, to: corrupt)
                records = []
            }
        } else {
            records = []
        }
        // Leftovers of an install a quit interrupted.
        cleanStaging()
    }

    func record(id: String) -> BrowserExtensionRecord? {
        records.first { $0.id == id }
    }

    /// The installed package of `id`.
    func folder(for id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    /// A fresh place for a package being unpacked, on the same volume as
    /// the packages (it moves in with `installPackage`).
    func stagingFolder() -> URL {
        directory.appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Puts an unpacked package in place of `id`'s (an update replaces the
    /// old one whole).
    func installPackage(_ staged: URL, id: String) throws {
        let fileManager = FileManager.default
        let target = folder(for: id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) {
            let old = directory.appendingPathComponent(".staging", isDirectory: true)
                .appendingPathComponent("old-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: target, to: old)
            do {
                try fileManager.moveItem(at: staged, to: target)
            } catch {
                try? fileManager.moveItem(at: old, to: target)
                throw error
            }
            try? fileManager.removeItem(at: old)
        } else {
            try fileManager.moveItem(at: staged, to: target)
        }
    }

    /// Adds `record`, or replaces the one with its id.
    func save(_ record: BrowserExtensionRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            guard records[index] != record else { return }
            records[index] = record
        } else {
            records.append(record)
        }
        commit()
    }

    func update(id: String, _ change: (inout BrowserExtensionRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var record = records[index]
        change(&record)
        guard record != records[index] else { return }
        records[index] = record
        commit()
    }

    /// Forgets `id` and deletes its package.
    func remove(id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
        guard records.contains(where: { $0.id == id }) else { return }
        records.removeAll { $0.id == id }
        commit()
    }

    private func cleanStaging() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(".staging", isDirectory: true))
    }

    private func commit() {
        try? JSONFile.write(BrowserExtensionsFile(extensions: records), to: url)
        changes.notify()
    }
}
