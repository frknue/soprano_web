import Foundation

/// One site's Boost: the user's own CSS, JavaScript and hidden elements
/// for a host. Boosts are app-wide (every Space and private windows run
/// them) and keyed by `BrowserBoost.key(_:)`: the host with a leading
/// `www.` dropped, so `www.example.com` and `example.com` share one Boost
/// while other subdomains have their own (Arc's rule).
struct BrowserBoost: Codable, Equatable, Sendable {
    var host: String
    var name: String
    var isEnabled: Bool
    var css: String
    var js: String
    /// CSS selectors of zapped (hidden) elements.
    var zaps: [String]

    init(host: String, name: String? = nil, isEnabled: Bool = true, css: String = "", js: String = "", zaps: [String] = []) {
        self.host = host
        self.name = name ?? host
        self.isEnabled = isEnabled
        self.css = css
        self.js = js
        self.zaps = zaps
    }

    private enum CodingKeys: String, CodingKey {
        case host, name, isEnabled = "enabled", css, js, zaps
    }

    /// Missing or mistyped fields take their defaults; only a Boost without
    /// a usable host fails (and the list skips it).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw = try? c.decode(String.self, forKey: .host), let host = Self.key(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .host, in: c, debugDescription: "Boost without a host")
        }
        self.host = host
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? host
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        css = (try? c.decodeIfPresent(String.self, forKey: .css)) ?? ""
        js = (try? c.decodeIfPresent(String.self, forKey: .js)) ?? ""
        zaps = ((try? c.decodeIfPresent([String].self, forKey: .zaps)) ?? []).filter { !$0.isEmpty }
    }

    /// The page gets a Boost sheet: CSS, or zapped selectors (one hiding
    /// rule each, `BrowserBoostScripts.styleSource`).
    var hasStyle: Bool { !css.isEmpty || !zaps.isEmpty }

    var isEmpty: Bool { css.isEmpty && js.isEmpty && zaps.isEmpty }

    /// The Boost key of a host: lowercased, trailing dots and one leading
    /// `www.` dropped. Nil for an empty host.
    static func key(_ host: String) -> String? {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") {
            value.removeLast()
        }
        if value.hasPrefix("www."), value.count > 4 {
            value.removeFirst(4)
        }
        return value.isEmpty ? nil : value
    }

    /// The Boost key of an http(s) page; nil for any other page.
    static func key(for url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return key(url.host ?? "")
    }
}

/// Every Boost, saved to `<support>/boosts.json` (`{"version": 1,
/// "entries": [...]}`) after each change and announced on `changes`. A
/// Boost that does not decode is skipped; an unreadable file is kept as
/// `boosts.json.corrupt` and the list starts empty.
@MainActor
final class BrowserBoostStore {
    let url: URL
    let changes = BrowserObservers<Void>()
    /// Sorted by host.
    private(set) var boosts: [BrowserBoost]

    var corruptURL: URL { url.appendingPathExtension("corrupt") }

    init(url: URL = BrowserFiles.supportDirectory().appendingPathComponent("boosts.json")) {
        self.url = url
        if let file = JSONFile.read(JSONList<BrowserBoost>.self, at: url) {
            var byHost: [String: BrowserBoost] = [:]
            for boost in file.entries where byHost[boost.host] == nil {
                byHost[boost.host] = boost
            }
            boosts = byHost.values.sorted { $0.host < $1.host }
        } else {
            boosts = []
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: corruptURL)
                try? fileManager.copyItem(at: url, to: corruptURL)
                try? JSONFile.write(JSONList<BrowserBoost>([]), to: url)
            }
        }
    }

    func boost(host: String) -> BrowserBoost? {
        guard let key = BrowserBoost.key(host) else { return nil }
        return boosts.first { $0.host == key }
    }

    /// The enabled Boost of an http(s) page, if any.
    func activeBoost(for url: URL?) -> BrowserBoost? {
        guard let key = BrowserBoost.key(for: url), let boost = boost(host: key), boost.isEnabled else { return nil }
        return boost
    }

    /// Changes the host's Boost, making it first when there is none.
    /// Returns the result; nil for an empty host.
    @discardableResult
    func update(host: String, _ change: (inout BrowserBoost) -> Void) -> BrowserBoost? {
        guard let key = BrowserBoost.key(host) else { return nil }
        let index = boosts.firstIndex { $0.host == key }
        var boost = index.map { boosts[$0] } ?? BrowserBoost(host: key)
        change(&boost)
        boost.host = key
        if boost.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            boost.name = key
        }
        boost.zaps = boost.zaps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let index {
            guard boosts[index] != boost else { return boost }
            boosts[index] = boost
        } else {
            boosts.append(boost)
            boosts.sort { $0.host < $1.host }
        }
        persist()
        return boost
    }

    /// Adds `selector` to the host's zapped elements (once).
    @discardableResult
    func zap(_ selector: String, host: String) -> BrowserBoost? {
        update(host: host) { boost in
            if !boost.zaps.contains(selector) {
                boost.zaps.append(selector)
            }
        }
    }

    @discardableResult
    func remove(host: String) -> Bool {
        guard let key = BrowserBoost.key(host), let index = boosts.firstIndex(where: { $0.host == key }) else {
            return false
        }
        boosts.remove(at: index)
        persist()
        return true
    }

    private func persist() {
        try? JSONFile.write(JSONList(boosts), to: url)
        changes.notify()
    }
}
