import AppKit

/// Where a link opens, from the click that activated it.
enum BrowserLinkDisposition: Equatable, Sendable {
    case currentTab
    case backgroundTab
    case foregroundTab

    /// `WKNavigationAction.buttonNumber` is a bitmask (left 1, right 2,
    /// middle 4). ⌘-click and middle-click open a background tab; adding ⇧
    /// brings it to the front. Every other click stays in the tab.
    static func disposition(
        modifierFlags: NSEvent.ModifierFlags,
        buttonNumber: Int
    ) -> BrowserLinkDisposition {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isMiddle = buttonNumber & 4 != 0
        guard flags.contains(.command) || isMiddle else { return .currentTab }
        return flags.contains(.shift) ? .foregroundTab : .backgroundTab
    }

    /// The index a link-opened tab is inserted at: after its opener and after
    /// the tabs that opener already opened next to it, so several links open
    /// in click order. `openerIDs[i]` is the opener of `tabs[i]`.
    static func insertionIndex(openerIndex: Int, openerID: UUID, openerIDs: [UUID?]) -> Int {
        var index = openerIndex + 1
        while index < openerIDs.count, openerIDs[index] == openerID {
            index += 1
        }
        return min(index, openerIDs.count)
    }
}

/// Schemes that load inside a tab. Anything else is handed to another app.
@MainActor
enum BrowserWebSchemes {
    static let all: Set<String> = [
        "http", "https", "file", "about", "blob", "data", BrowserStartPageSchemeHandler.scheme,
        BrowserExtensions.scheme,
    ]

    static func isWeb(_ url: URL) -> Bool {
        all.contains(url.scheme?.lowercased() ?? "")
    }
}

/// Pop-up blocking: WebKit opens only user-initiated windows unless the
/// page's host is allowed; a page-world wrapper reports `window.open` calls
/// that returned null.
@MainActor
enum BrowserPopupPolicy {
    /// The most blocked pop-ups remembered per page.
    static let maxBlocked = 10

    /// Whether pages on `pageURL`'s host may open windows without a click.
    static func opensWithoutGesture(pageURL: URL?, permissions: BrowserSitePermissionStore) -> Bool {
        guard let host = BrowserSitePermissionStore.key(for: pageURL) else { return false }
        return permissions.decision(.popups, host: host) == .allow
    }

    /// The URL to offer for a `popupBlocked` report, or nil to ignore it.
    /// `window.open(…, "noopener")` returns null even when the window
    /// opened, so a noopener report for a URL that just opened is dropped.
    static func blockedURL(_ raw: String?, noopener: Bool, recentlyOpened: [URL]) -> URL? {
        guard let raw, !raw.isEmpty, raw.count <= 8192,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "about", "file", "blob"].contains(scheme)
        else { return nil }
        if noopener, recentlyOpened.contains(url) {
            return nil
        }
        return url
    }

    /// Adds `url` as the newest blocked pop-up, dropping an earlier copy and
    /// the oldest beyond `maxBlocked`.
    static func appending(_ url: URL, to blocked: [URL]) -> [URL] {
        var list = blocked.filter { $0 != url }
        list.append(url)
        if list.count > maxBlocked {
            list.removeFirst(list.count - maxBlocked)
        }
        return list
    }
}

/// What to do with a page's link to another app (`mailto:`, `zoommtg:`, …).
enum BrowserExternalAppDecision: Equatable {
    /// The site is allowed to open this scheme.
    case open
    /// Ask first; `host` is the site key to remember an "always allow" under.
    case prompt(host: String?)
    /// The site is denied this scheme.
    case block
}

@MainActor
enum BrowserExternalAppPolicy {
    static func decision(
        for url: URL,
        pageURL: URL?,
        permissions: BrowserSitePermissionStore
    ) -> BrowserExternalAppDecision {
        let host = BrowserSitePermissionStore.key(for: pageURL)
        guard let host, let scheme = url.scheme, !scheme.isEmpty else {
            return .prompt(host: host)
        }
        switch permissions.decision(.externalApp(scheme: scheme), host: host) {
        case .allow: return .open
        case .deny: return .block
        case nil: return .prompt(host: host)
        }
    }
}

/// The `Version/… Safari/605.1.15` token appended to WebKit's user agent;
/// sites that sniff for Safari reject the bare WKWebView agent.
enum BrowserUserAgent {
    static let fallbackVersion = "26.0"
    static let safariBuild = "605.1.15"

    /// `applicationNameForUserAgent` for a Safari `CFBundleShortVersionString`
    /// ("26.0.1" → "Version/26.0 Safari/605.1.15"); the fallback version
    /// when it is missing or not numeric.
    static func applicationName(safariVersion: String?) -> String {
        "Version/\(majorMinor(safariVersion) ?? fallbackVersion) Safari/\(safariBuild)"
    }

    static func majorMinor(_ version: String?) -> String? {
        guard let version else { return nil }
        let parts = version.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard let major = parts.first, isNumber(major) else { return nil }
        let minor = parts.count > 1 && isNumber(parts[1]) ? parts[1] : "0"
        return "\(major).\(minor)"
    }

    private static func isNumber(_ part: Substring) -> Bool {
        !part.isEmpty && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber)
    }

    /// The installed Safari's version, read once.
    static let installedSafariVersion: String? = {
        let candidates = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
            URL(fileURLWithPath: "/Applications/Safari.app"),
        ]
        for case let url? in candidates {
            let plist = url.appendingPathComponent("Contents/Info.plist")
            if let info = NSDictionary(contentsOf: plist),
               let version = info["CFBundleShortVersionString"] as? String
            {
                return version
            }
        }
        return nil
    }()

    static var applicationName: String {
        applicationName(safariVersion: installedSafariVersion)
    }
}
