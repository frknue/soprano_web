import AppKit
import WebKit

extension BrowserSitePermissionStore {
    /// Whether the content blocker runs on `host`'s pages: on unless the
    /// connection popover's "Block ads on this site" switch turned it off.
    func blocksContent(host: String) -> Bool {
        decision(.contentBlocking, host: host) != .deny
    }

    func setBlocksContent(_ blocks: Bool, host: String) {
        if blocks {
            forget(.contentBlocking, host: host)
        } else {
            set(.contentBlocking, .deny, host: host)
        }
    }
}

/// Which tabs get the content blocker's lists.
///
/// A site switched off loses the lists in every tab whose top-level page is
/// on that host, instead of getting a compiled exceptions list
/// (`ignore-previous-rules` with `if-top-url`). An exception only reaches
/// rules of its own list, so it would have to be appended to every EasyList
/// and EasyPrivacy list and each of them recompiled (seconds of CPU per
/// list) on every switch; taking the lists off the tab is immediate and
/// exact: WebKit applies a tab's lists to every load of its page, so the
/// page's third-party requests and its subframes (whatever their own host)
/// load unblocked, and a subframe of that host inside another site's page
/// stays blocked, as with uBlock Origin's per-site switch.
enum BrowserContentBlockingPolicy {
    /// Whether a tab whose top-level page is `pageURL` gets the lists. A
    /// page without a site (the start page, `about:blank`, a new web view)
    /// follows the setting.
    @MainActor
    static func blocks(pageURL: URL?, isEnabled: Bool, sitePermissions: BrowserSitePermissionStore) -> Bool {
        guard isEnabled else { return false }
        guard let host = BrowserSitePermissionStore.siteKey(for: pageURL) else { return true }
        return sitePermissions.blocksContent(host: host)
    }
}

extension BrowserWindowController {
    /// Whether a page at `url` of data context `context` gets the lists.
    func blocksContent(onPage url: URL?, in context: BrowserDataContext) -> Bool {
        BrowserContentBlockingPolicy.blocks(
            pageURL: url,
            isEnabled: manager.contentBlocker.isEnabled,
            sitePermissions: context.sitePermissions
        )
    }

    /// Attaches the blocker's current lists to `webView` (of data context
    /// `context`: its tab's) for a top-level page at `pageURL`, or takes
    /// them off. Runs before a main-frame navigation is allowed, so the new
    /// page's loads follow it. Returns whether anything changed.
    @discardableResult
    func applyContentBlocking(to webView: BrowserWebView, pageURL: URL?, in context: BrowserDataContext) -> Bool {
        let lists = blocksContent(onPage: pageURL, in: context) ? manager.contentBlocker.activeLists : []
        let identifiers = lists.compactMap { $0.identifier }
        guard webView.contentRuleListIDs != identifiers else { return false }
        let contentController = webView.configuration.userContentController
        contentController.removeAllContentRuleLists()
        for list in lists {
            contentController.add(list)
        }
        webView.contentRuleListIDs = identifiers
        return true
    }

    /// `applyContentBlocking` for the tab's own web view and context.
    @discardableResult
    func applyContentBlocking(to tab: BrowserTab, pageURL: URL?) -> Bool {
        applyContentBlocking(to: tab.webView, pageURL: pageURL, in: tab.dataContext)
    }

    /// Every tab follows the setting, new lists and the site switches.
    /// `reloadingChanged` reloads the loaded pages whose blocking turned on
    /// or off (the site switch), so the page loads again with or without
    /// it; otherwise only new loads follow.
    func applyContentBlockingToTabs(reloadingChanged: Bool) {
        for tab in tabsWithPeek {
            let webView = tab.webView
            let wasBlocking = !webView.contentRuleListIDs.isEmpty
            guard applyContentBlocking(to: tab, pageURL: webView.url),
                  reloadingChanged,
                  wasBlocking != !webView.contentRuleListIDs.isEmpty,
                  webView.url != nil, !tab.isStartPage, !tab.isRestorePending
            else { continue }
            webView.reload()
        }
    }

    /// The connection popover's "Block ads on this site" switch for the
    /// tab's page; nil when blocking is off or the page has no web site.
    func siteBlockingAccessory(for tab: BrowserTab) -> BrowserSiteBlockingAccessory? {
        let url = tab.webView.url
        guard manager.contentBlocker.isEnabled,
              tab.certificateInterstitial == nil,
              ["http", "https"].contains(url?.scheme?.lowercased() ?? ""),
              let host = BrowserSitePermissionStore.siteKey(for: url)
        else { return nil }
        let sitePermissions = tab.dataContext.sitePermissions
        return BrowserSiteBlockingAccessory(
            host: host,
            isOn: sitePermissions.blocksContent(host: host),
            theme: theme
        ) { blocks in
            // Every window with tabs of the profile reloads its tabs of the
            // site.
            sitePermissions.setBlocksContent(blocks, host: host)
        }
    }
}

/// The switch under the connection details: "Block ads on this site".
@MainActor
final class BrowserSiteBlockingAccessory: NSView {
    let host: String
    let toggle: ChromeSwitch
    private let label = NSTextField(labelWithString: "Block ads on this site")
    private let onChange: (Bool) -> Void

    init(host: String, isOn: Bool, theme: AppTheme, onChange: @escaping (Bool) -> Void) {
        self.host = host
        self.toggle = ChromeSwitch(isOn: isOn, theme: theme)
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        toggle.target = self
        toggle.action = #selector(toggled)
        label.font = ChromeFont.label
        label.textColor = theme.colors.textPrimary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggle)
        addSubview(label)
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: Chrome.switchSize.width),
            toggle.heightAnchor.constraint(equalToConstant: Chrome.switchSize.height),
            label.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func toggled() {
        onChange(toggle.isOn)
    }
}
