import Foundation

/// What "Clear site data" removes for a page's host: WebKit's website data
/// records whose domain is the host's registrable domain (WebKit keys a
/// record by it, so the data of every subdomain goes with it; it keeps no
/// finer grain), minus their cookies, plus the cookies set for exactly
/// that host. An IP address or a single-label host (`localhost`) is its
/// own record and matches only itself.
struct BrowserSiteDataTarget: Equatable, Sendable {
    /// Lowercased, without a trailing dot.
    let host: String

    init?(host: String) {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        while value.hasSuffix(".") {
            value.removeLast()
        }
        guard !value.isEmpty else { return nil }
        self.host = value
    }

    /// The target of a web page's address; nil for a page without an
    /// http(s) host (the start page, files, extension pages).
    init?(url: URL?) {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host else {
            return nil
        }
        self.init(host: host)
    }

    /// An IPv4 or IPv6 address: no registrable domain above it.
    var isAddress: Bool {
        if host.contains(":") {
            return true
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCIIDigit) && (Int(part) ?? 256) <= 255
        }
    }

    /// Whether a data record named `displayName` (its domain) holds the
    /// host's data: the host itself, or a domain the host is under.
    func matchesRecord(_ displayName: String) -> Bool {
        guard let record = BrowserSiteDataTarget(host: displayName)?.host else { return false }
        if record == host {
            return true
        }
        guard !isAddress, record.contains(".") || record == "localhost" else { return false }
        return host.hasSuffix("." + record)
    }

    /// Whether a cookie of `domain` (`example.com` host-only, or
    /// `.example.com` for its subdomains too) was set for exactly this
    /// host.
    func matchesCookie(domain: String) -> Bool {
        var value = domain
        if value.hasPrefix(".") {
            value.removeFirst()
        }
        return BrowserSiteDataTarget(host: value)?.host == host
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// A site permission's value in the Site Control Center: nothing stored
/// (WebKit asks, or the default applies), allowed or blocked.
enum BrowserSiteChoice: String, CaseIterable, Sendable {
    case ask
    case allow
    case deny

    init(_ decision: SitePermissionDecision?) {
        switch decision {
        case .allow: self = .allow
        case .deny: self = .deny
        case nil: self = .ask
        }
    }

    var decision: SitePermissionDecision? {
        switch self {
        case .ask: nil
        case .allow: .allow
        case .deny: .deny
        }
    }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .allow: "Allow"
        case .deny: "Block"
        }
    }
}

/// What the Site Control Center shows for one tab's page.
struct BrowserSiteControlState: Equatable {
    struct Permission: Equatable {
        let permission: SitePermission
        let label: String
        let choice: BrowserSiteChoice
        /// False for notifications in a private window (always blocked).
        let isEnabled: Bool
    }

    struct ExtensionAccess: Equatable {
        let id: String
        let name: String
        let access: BrowserExtensionRecord.SiteAccess
        /// Whether the extension may run on this host now.
        let allowedHere: Bool

        var summary: String {
            switch access {
            case .allSites: "On all sites"
            case .specificSites: allowedHere ? "On this site" : "Not on this site"
            case .onClick: "When you click"
            }
        }

        /// "On specific sites" covers a host and its subdomains.
        static func isAllowed(
            host: String,
            access: BrowserExtensionRecord.SiteAccess,
            allowedSites: [String]
        ) -> Bool {
            switch access {
            case .allSites: return true
            case .onClick: return false
            case .specificSites:
                let host = host.lowercased()
                return allowedSites.contains { site in
                    let site = site.lowercased()
                    return host == site || host.hasSuffix("." + site)
                }
            }
        }
    }

    /// The tab the popover acts on (the Peek's, or the focused pane's).
    let tabID: UUID
    /// The site key permissions are stored under (`BrowserSitePermissionStore.siteKey`).
    let host: String
    let connectionTitle: String
    let connectionDetail: String
    let isSecure: Bool
    let hasCertificate: Bool
    let isPrivate: Bool
    let permissions: [Permission]
    let zoomPercent: String
    /// Nil hides "Block ads on this site" (blocking off, not a web page).
    let blocksAds: Bool?
    let extensions: [ExtensionAccess]
    /// Nil hides "Clear site data" (not an http(s) page).
    let dataTarget: BrowserSiteDataTarget?

    static let permissionRows: [(SitePermission, String)] = [
        (.camera, "Camera"),
        (.microphone, "Microphone"),
        (.notifications, "Notifications"),
        (.popups, "Pop-ups"),
    ]

    /// The permission rows of `host` in `store` (the tab profile's, or a
    /// private window's overlay).
    @MainActor
    static func permissions(
        host: String,
        store: BrowserSitePermissionStore,
        isPrivate: Bool
    ) -> [Permission] {
        permissionRows.map { permission, label in
            let blocked = isPrivate && permission == .notifications
            return Permission(
                permission: permission,
                label: label,
                choice: blocked ? .deny : BrowserSiteChoice(store.decision(permission, host: host)),
                isEnabled: !blocked
            )
        }
    }

    /// The lines `browser site info` and the harness print.
    var lines: [String] {
        var lines = [
            "site: \(host)\(isPrivate ? " (private)" : "")",
            "connection: \(connectionTitle)\(hasCertificate ? " (certificate)" : "")",
        ]
        lines += permissions.map { "permission: \($0.permission.rawValue) \($0.choice.rawValue)\($0.isEnabled ? "" : " (fixed)")" }
        lines.append("zoom: \(zoomPercent)")
        lines.append("block-ads: \(blocksAds.map { $0 ? "on" : "off" } ?? "n/a")")
        lines += extensions.map { "extension: \($0.name) | \($0.summary)" }
        lines.append("clear-data: \(dataTarget?.host ?? "n/a")")
        return lines
    }
}
