import Foundation

/// A per-site permission key as stored in `site-permissions.json`. Add new
/// permissions as static members.
struct SitePermission: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let camera = SitePermission(rawValue: "camera")
    static let microphone = SitePermission(rawValue: "microphone")
    static let notifications = SitePermission(rawValue: "notifications")
    static let popups = SitePermission(rawValue: "popups")

    /// Opening links with `scheme` (e.g. `zoommtg`) in another app.
    static func externalApp(scheme: String) -> SitePermission {
        SitePermission(rawValue: "externalApp:\(scheme.lowercased())")
    }
}

enum SitePermissionDecision: String, Codable, Sendable {
    case allow
    case deny
}

/// Remembered per-site decisions: `{ "version": 1, "sites": { host: {
/// permission: "allow" | "deny" } } }`. Keys and values this build does not
/// know are kept as they are, so an older build never drops a newer one's
/// decisions. A private window uses an overlay (`init(overlaying:)`): it
/// reads the saved decisions and keeps its own answers in memory.
@MainActor
final class BrowserSitePermissionStore {
    static let currentVersion = 1

    /// Host key → permission raw value → decision raw value. An overlay
    /// holds only its own answers.
    private(set) var sites: [String: [String: String]]
    /// Nil for an overlay: nothing is written.
    let url: URL?
    /// Notified after every change, and for an overlay also after the saved
    /// decisions underneath it changed.
    let changes = BrowserObservers<Void>()
    /// The saved decisions an overlay reads through to.
    private let base: BrowserSitePermissionStore?
    private var baseObservation: BrowserObservation?

    init(url: URL = BrowserFiles.supportDirectory().appendingPathComponent("site-permissions.json")) {
        self.url = url
        self.sites = JSONFile.read(File.self, at: url)?.sites ?? [:]
        self.base = nil
    }

    /// An in-memory layer over `base`: decisions read its own answers first,
    /// then `base`'s; `set` and `removeAll` change only the layer, which goes
    /// away with it.
    init(overlaying base: BrowserSitePermissionStore) {
        self.url = nil
        self.sites = [:]
        self.base = base
        baseObservation = base.changes.observe { [weak self] in self?.changes.notify() }
    }

    /// The key decisions are stored under: the lowercased host, or `"file"`
    /// for local files. Nil when the URL has no host.
    static func key(for url: URL?) -> String? {
        guard let url else { return nil }
        if url.isFileURL {
            return "file"
        }
        return normalized(url.host ?? "")
    }

    func decision(_ permission: SitePermission, host: String) -> SitePermissionDecision? {
        guard let key = Self.normalized(host) else { return nil }
        guard let raw = sites[key]?[permission.rawValue] else {
            return base?.decision(permission, host: key)
        }
        return SitePermissionDecision(rawValue: raw)
    }

    /// Records `decision` for the host; nil clears it.
    func set(_ permission: SitePermission, _ decision: SitePermissionDecision?, host: String) {
        guard let host = Self.normalized(host),
              sites[host]?[permission.rawValue] != decision?.rawValue
        else { return }
        sites[host, default: [:]][permission.rawValue] = decision?.rawValue
        if sites[host]?.isEmpty == true {
            sites[host] = nil
        }
        persist()
    }

    func removeAll(host: String) {
        guard let host = Self.normalized(host), sites[host] != nil else { return }
        sites[host] = nil
        persist()
    }

    func removeAll() {
        guard !sites.isEmpty else { return }
        sites.removeAll()
        persist()
    }

    private static func normalized(_ host: String) -> String? {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") {
            value.removeLast()
        }
        return value.isEmpty ? nil : value
    }

    private func persist() {
        if let url {
            try? JSONFile.write(File(version: Self.currentVersion, sites: sites), to: url)
        }
        changes.notify()
    }

    private struct File: Codable {
        var version: Int
        var sites: [String: [String: String]]

        init(version: Int, sites: [String: [String: String]]) {
            self.version = version
            self.sites = sites
        }

        /// A host or a decision that does not decode is skipped, not the file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            sites = [:]
            guard let hosts = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .sites) else { return }
            for host in hosts.allKeys {
                guard let permissions = try? hosts.nestedContainer(keyedBy: AnyKey.self, forKey: host) else {
                    continue
                }
                var decisions: [String: String] = [:]
                for permission in permissions.allKeys {
                    if let value = try? permissions.decode(String.self, forKey: permission) {
                        decisions[permission.stringValue] = value
                    }
                }
                if !decisions.isEmpty {
                    sites[host.stringValue] = decisions
                }
            }
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }
}
