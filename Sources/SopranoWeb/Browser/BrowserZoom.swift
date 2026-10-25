import Foundation

/// Page zoom levels: Safari's steps from 50% to 300%. ⌘+ and ⌘- move one
/// step; Settings ▸ Default page zoom picks one of them.
enum BrowserZoom {
    static let steps: [Double] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]
    static let range = 0.5...3.0

    /// Two levels closer than this are the same level.
    private static let tolerance = 0.001

    /// The next step above `zoom`, or the largest.
    static func zoomedIn(from zoom: Double) -> Double {
        steps.first { $0 > zoom + tolerance } ?? steps[steps.count - 1]
    }

    /// The next step below `zoom`, or the smallest.
    static func zoomedOut(from zoom: Double) -> Double {
        steps.last { $0 < zoom - tolerance } ?? steps[0]
    }

    /// `value` when it is a usable level (finite, 50–300%); nil otherwise.
    static func validated(_ value: Double) -> Double? {
        value.isFinite && range.contains(value) ? value : nil
    }

    /// The step closest to `value` (Settings ▸ Default page zoom).
    static func nearestStep(_ value: Double) -> Double {
        steps.min { abs($0 - value) < abs($1 - value) } ?? 1
    }

    static func isSame(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < tolerance
    }

    /// "125%".
    static func percent(_ zoom: Double) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }
}

extension BrowserSitePermissionStore {
    /// The key per-site values (zoom, Keep This Site Awake) are stored
    /// under: the host of an http(s) page, `"file"` for local files. Nil
    /// for the start page, `about:`, `data:` and other pages without a
    /// site.
    static func siteKey(for url: URL?) -> String? {
        guard let url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return key(for: url)
    }

    /// The zoom remembered for `host`; nil uses the default page zoom.
    func zoom(host: String) -> Double? {
        value(.zoom, host: host).flatMap(Double.init).flatMap(BrowserZoom.validated)
    }

    /// Remembers `zoom` for `host`; nil forgets it, so the site follows the
    /// default page zoom again.
    func setZoom(_ zoom: Double?, host: String) {
        guard let zoom, let valid = BrowserZoom.validated(zoom) else {
            forget(.zoom, host: host)
            return
        }
        setValue(String(valid), for: .zoom, host: host)
    }

    /// Whether the user keeps `host`'s tabs awake (tab menu ▸ Keep This
    /// Site Awake).
    func keepsAwake(host: String) -> Bool {
        decision(.keepAwake, host: host) == .allow
    }

    func setKeepsAwake(_ keepsAwake: Bool, host: String) {
        if keepsAwake {
            set(.keepAwake, .allow, host: host)
        } else {
            forget(.keepAwake, host: host)
        }
    }
}
