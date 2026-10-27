import AppKit

/// Where a link opens, from the click that activated it.
enum BrowserLinkDisposition: Equatable, Sendable {
    case currentTab
    case backgroundTab
    case foregroundTab
    /// A Peek over the page (`BrowserWindowController.openPeek`).
    case peek
    /// A new pane of the page's split (`BrowserWindowController
    /// .openLinkPane`).
    case splitPane

    /// `WKNavigationAction.buttonNumber` is a bitmask (left 1, right 2,
    /// middle 4). ⌘-click and middle-click open a background tab; adding ⇧
    /// brings it to the front. ⇧ alone opens a Peek, ⌥ alone a split pane.
    /// Every other click stays in the tab. WebKit doesn't treat ⌥-click
    /// as a download (`shouldPerformDownload` is only the `download`
    /// attribute), so it reaches the link handling.
    static func disposition(
        modifierFlags: NSEvent.ModifierFlags,
        buttonNumber: Int
    ) -> BrowserLinkDisposition {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isMiddle = buttonNumber & 4 != 0
        guard flags.contains(.command) || isMiddle else {
            if flags.contains(.shift) { return .peek }
            return flags.contains(.option) ? .splitPane : .currentTab
        }
        return flags.contains(.shift) ? .foregroundTab : .backgroundTab
    }

    /// A link activated in a tab of `origin` showing `pageURL`: the click's
    /// own disposition, and a plain click from a pinned or favorite tab to
    /// another site (`BrowserPeekRule.isOtherSite`) that would load in the
    /// main frame opens a Peek too. Only web links (http, https) open a
    /// Peek or a split pane; ⇧ or ⌥ on anything else stays in the tab.
    static func disposition(
        modifierFlags: NSEvent.ModifierFlags,
        buttonNumber: Int,
        origin: BrowserTabOrigin,
        pageURL: URL?,
        linkURL: URL?,
        targetsMainFrame: Bool
    ) -> BrowserLinkDisposition {
        let base = disposition(modifierFlags: modifierFlags, buttonNumber: buttonNumber)
        let isWeb = ["http", "https"].contains(linkURL?.scheme?.lowercased() ?? "")
        switch base {
        case .peek, .splitPane:
            return isWeb ? base : .currentTab
        case .currentTab:
            guard isWeb, targetsMainFrame, origin != .today,
                  BrowserPeekRule.isOtherSite(from: pageURL, to: linkURL)
            else { return .currentTab }
            return .peek
        case .backgroundTab, .foregroundTab:
            return base
        }
    }

    /// A `window.open` or a link's new window that is not a link click
    /// (scripted): ⌘ or middle still open a background tab and ⇧⌘ a
    /// foreground one; ⇧ or ⌥ held by chance change nothing (no Peek or
    /// split pane, so a sized pop-up stays a pop-up).
    static func scriptedDisposition(
        modifierFlags: NSEvent.ModifierFlags,
        buttonNumber: Int
    ) -> BrowserLinkDisposition {
        switch disposition(modifierFlags: modifierFlags, buttonNumber: buttonNumber) {
        case .peek, .splitPane, .currentTab: .currentTab
        case let other: other
        }
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

/// Peek's "other site": a host comparison, no public-suffix list. Hosts
/// are lowercased with a trailing dot and a leading `www.` dropped; two
/// are the same site when equal or when one is a subdomain of the other
/// (`docs.example.com` and `example.com`). Ports never matter; an IP
/// address is the same site only as itself.
enum BrowserPeekRule {
    /// Whether a link from `pageURL` to `linkURL` leaves the site. A page
    /// without a host (a file, `about:blank`) leaves it for any web host;
    /// a link without a host never does.
    static func isOtherSite(from pageURL: URL?, to linkURL: URL?) -> Bool {
        guard let link = siteHost(linkURL?.host) else { return false }
        guard let page = siteHost(pageURL?.host) else { return true }
        return !isSameSite(page, link)
    }

    /// `a` and `b` as `siteHost` gives them.
    static func isSameSite(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard !isIPAddress(a), !isIPAddress(b) else { return false }
        return a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }

    /// The host the comparison uses; nil for none.
    static func siteHost(_ host: String?) -> String? {
        guard var host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return nil }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        if host.hasPrefix("www."), host.count > 4 {
            host.removeFirst(4)
        }
        return host.isEmpty ? nil : host
    }

    /// IPv6 (has a colon) or a dotted IPv4 address.
    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count == 4 && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
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
