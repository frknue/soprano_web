import AppKit
import WebKit

/// The Site Control Center: the lock / site chip's popover for the page the
/// user looks at (`pageTab`: the Peek's, else the selected tab or focused
/// pane), reading and writing the tab's profile's site decisions (a
/// private window's overlay).
extension BrowserWindowController {
    /// The page the popover acts on.
    var siteControlTab: BrowserTab? { pageTab }

    /// The tab's page address: the loaded one, else the one it restores to.
    private func siteControlURL(of tab: BrowserTab) -> URL? {
        tab.webView.url ?? tab.state.url.flatMap(URL.init(string:))
    }

    /// The site key the popover reads and writes for `tab`: its page's,
    /// or a certificate interstitial's host (the page is `about:blank`).
    func siteControlHost(of tab: BrowserTab) -> String? {
        BrowserSitePermissionStore.siteKey(for: siteControlURL(of: tab))
            ?? tab.certificateInterstitial?.host.lowercased()
    }

    /// What the popover shows for `tab`; nil when its page has no site
    /// (the start page, `about:blank`, an extension page).
    func siteControlState(for tab: BrowserTab) -> BrowserSiteControlState? {
        let url = siteControlURL(of: tab)
        let interstitial = tab.certificateInterstitial
        guard let host = siteControlHost(of: tab) else { return nil }
        let context = tab.dataContext
        let isPrivate = context.kind.isPrivate
        let security = securityState(for: tab)
        let isWebPage = ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
        let blocksAds: Bool? = manager.contentBlocker.isEnabled && interstitial == nil && isWebPage
            ? context.sitePermissions.blocksContent(host: host)
            : nil
        let extensionRows = extensions.records
            .filter { $0.isEnabled && (!isPrivate || $0.allowsPrivate) }
            .map { record in
                BrowserSiteControlState.ExtensionAccess(
                    id: record.id,
                    name: record.name,
                    access: record.siteAccess,
                    allowedHere: BrowserSiteControlState.ExtensionAccess.isAllowed(
                        host: BrowserExtensions.siteHost(host),
                        access: record.siteAccess,
                        allowedSites: record.allowedSites
                    )
                )
            }
        return BrowserSiteControlState(
            tabID: tab.id,
            host: host,
            connectionTitle: security.title(host: interstitial?.host ?? url?.host ?? host),
            connectionDetail: interstitial?.problem.explanation(host: host) ?? security.detail,
            isSecure: security == .secure,
            hasCertificate: (interstitial?.trust ?? tab.webView.serverTrust) != nil,
            isPrivate: isPrivate,
            permissions: BrowserSiteControlState.permissions(
                host: host,
                store: context.sitePermissions,
                isPrivate: !context.kind.allowsWebNotifications
            ),
            zoomPercent: BrowserZoom.percent(tab.zoom),
            blocksAds: blocksAds,
            extensions: extensionRows,
            dataTarget: interstitial == nil ? BrowserSiteDataTarget(url: url) : nil,
            boost: interstitial == nil ? BrowserBoost.key(for: url).map { host in
                BrowserSiteControlState.BoostSummary(host: host, boost: manager.boosts.boost(host: host))
            } : nil
        )
    }

    // MARK: Popover

    /// The lock's click: opens the popover, or closes it when open (the
    /// click that just closed it by taking focus does nothing).
    func toggleSiteControl() {
        if siteControlPanel.isShown {
            siteControlPanel.close()
            return
        }
        if let resigned = siteControlPanel.lastResignedAt, Date().timeIntervalSince(resigned) < 0.3 {
            return
        }
        showSiteControl()
    }

    func showSiteControl() {
        guard let window, window.attachedSheet == nil,
              let tab = siteControlTab, let view = makeSiteControlView(for: tab)
        else {
            NSSound.beep()
            return
        }
        siteControlPanel.show(view, below: toolbar.securityAnchor, in: window)
    }

    /// The popover body for `tab`, wired to act on it; the harness puts it
    /// into the window offscreen instead of the panel.
    func makeSiteControlView(for tab: BrowserTab) -> BrowserSiteControlView? {
        guard let state = siteControlState(for: tab) else { return nil }
        let view = BrowserSiteControlView(theme: theme, state: state)
        view.onConnection = { [weak self, weak tab] in
            guard let self, let tab else { return }
            siteControlPanel.close()
            showConnectionDetails(for: tab)
        }
        view.onPermission = { [weak self, weak tab, weak view] permission, choice in
            guard let self, let tab else { return }
            setSitePermission(permission, choice, for: tab)
            refreshSiteControl(view, for: tab)
        }
        view.onZoom = { [weak self, weak tab, weak view] action in
            guard let self, let tab else { return }
            zoom(action, tab: tab)
            refreshSiteControl(view, for: tab)
        }
        view.onBlocksAds = { [weak self, weak tab, weak view] blocks in
            guard let self, let tab else { return }
            // Every window with tabs of the profile reloads its tabs of the
            // site.
            guard let host = siteControlHost(of: tab) else { return }
            tab.dataContext.sitePermissions.setBlocksContent(blocks, host: host)
            refreshSiteControl(view, for: tab)
        }
        view.onExtension = { [weak self, weak tab, weak view] id, action in
            guard let self, let tab else { return }
            guard let host = siteControlHost(of: tab) else { return }
            setExtensionAccess(id, action, host: host)
            refreshSiteControl(view, for: tab)
        }
        view.onBoost = { [weak self] in
            self?.showBoostEditor()
        }
        view.onClearData = { [weak self, weak tab] in
            guard let self, let tab else { return }
            siteControlPanel.close()
            confirmClearSiteData(for: tab)
        }
        return view
    }

    private func refreshSiteControl(_ view: BrowserSiteControlView?, for tab: BrowserTab) {
        guard let view, let state = siteControlState(for: tab) else { return }
        view.configure(state)
        if siteControlPanel.content === view {
            siteControlPanel.refit()
        }
    }

    // MARK: Actions

    /// Records `choice` for the tab's site in its profile (Ask forgets it;
    /// a private window's overlay then stops reading the saved one).
    func setSitePermission(_ permission: SitePermission, _ choice: BrowserSiteChoice, for tab: BrowserTab) {
        guard let host = siteControlHost(of: tab) else { return }
        let store = tab.dataContext.sitePermissions
        if let decision = choice.decision {
            store.set(permission, decision, host: host)
        } else {
            store.forget(permission, host: host)
        }
    }

    private func zoom(_ action: BrowserSiteControlView.ZoomAction, tab: BrowserTab) {
        switch action {
        case .zoomOut: zoomOut(tab)
        case .zoomIn: zoomIn(tab)
        case .reset: resetZoom(tab)
        }
    }

    private func setExtensionAccess(_ id: String, _ action: BrowserSiteControlView.ExtensionAction, host: String) {
        switch action {
        case let .access(access):
            try? extensions.setSiteAccess(id, access)
        case let .allowHere(true):
            try? extensions.setSite(id, host: host, allowed: true)
        case .allowHere(false):
            // The host and every parent site that covers it.
            let site = BrowserExtensions.siteHost(host)
            let covering = BrowserSiteControlState.ExtensionAccess.coveringSites(
                host: site,
                allowedSites: extensions.records.first { $0.id == id }?.allowedSites ?? []
            )
            for allowed in Set(covering + [site]) {
                try? extensions.setSite(id, host: allowed, allowed: false)
            }
        }
    }

    /// Keeps the open popover on the page the user looks at: closes it
    /// when that is another tab or has no site, else shows the tab's
    /// current state (a navigation, a CLI change).
    func updateSiteControlPanel() {
        guard siteControlPanel.isShown, let view = siteControlPanel.content else { return }
        guard let tab = pageTab, tab.id == view.state.tabID, let state = siteControlState(for: tab) else {
            siteControlPanel.close()
            return
        }
        if state != view.state {
            view.configure(state)
            siteControlPanel.refit()
        }
    }
}

// MARK: - Clear site data

/// What `clearSiteData` removed.
struct BrowserSiteDataRemoval: Equatable {
    /// The data records' names (domains).
    var records: [String]
    var cookies: Int

    var summary: String {
        let names = records.isEmpty ? "no website data" : "website data of \(records.joined(separator: ", "))"
        return "\(names), \(cookies) cookie\(cookies == 1 ? "" : "s")"
    }
}

extension BrowserWindowController {
    /// "Clear site data…": asks, then clears and reloads the page.
    func confirmClearSiteData(for tab: BrowserTab) {
        guard let window, window.attachedSheet == nil,
              let target = BrowserSiteDataTarget(url: tab.webView.url)
        else { return }
        let alert = NSAlert()
        alert.messageText = "Clear data for \(target.host)?"
        alert.informativeText = """
        Removes the site's cookies, storage and caches in this profile (WebKit \
        stores them per domain, so the domain's other subdomains lose theirs \
        too; cookies only \(target.host)'s), then reloads the page. You may be \
        signed out.
        """
        alert.addButton(withTitle: "Clear Site Data")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak tab] response in
            guard response == .alertFirstButtonReturn, let self, let tab else { return }
            Task { @MainActor in
                _ = await self.clearSiteData(of: tab)
            }
        }
    }

    /// Removes `tab`'s site data in its profile (`BrowserSiteDataTarget`)
    /// and reloads it. Nil when the page has no http(s) host.
    func clearSiteData(of tab: BrowserTab) async -> BrowserSiteDataRemoval? {
        guard let target = BrowserSiteDataTarget(url: siteControlURL(of: tab)) else { return nil }
        let removal = await Self.clearSiteData(target, in: tab.dataContext.websiteDataStore)
        if !tab.isStartPage, tab.webView.url != nil {
            reload(tab)
        }
        return removal
    }

    /// The records of the target's domain (cookies aside), then the
    /// cookies set for exactly its host.
    static func clearSiteData(_ target: BrowserSiteDataTarget, in store: WKWebsiteDataStore) async -> BrowserSiteDataRemoval {
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            .filter { target.matchesRecord($0.displayName) }
        let types = records.reduce(into: Set<String>()) { $0.formUnion($1.dataTypes) }
            .subtracting([WKWebsiteDataTypeCookies])
        if !types.isEmpty {
            await store.removeData(ofTypes: types, for: records)
        }
        let cookieStore = store.httpCookieStore
        let cookies = await cookieStore.allCookies().filter { target.matchesCookie(domain: $0.domain) }
        for cookie in cookies {
            await cookieStore.deleteCookie(cookie)
        }
        return BrowserSiteDataRemoval(records: records.map(\.displayName).sorted(), cookies: cookies.count)
    }

    // MARK: - CLI

    /// `browser site [info|clear|permission <name> allow|deny|ask]` on `tab`.
    func performSiteCommand(
        _ arguments: [String],
        tab: BrowserTab,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let noSite = BrowserAutomationError.unavailable("The page has no site.")
        switch arguments.first {
        case "clear":
            Task { @MainActor in
                guard let removal = await clearSiteData(of: tab) else {
                    completion(.failure(noSite))
                    return
                }
                completion(.success("cleared \(removal.summary)"))
            }
        case "permission":
            guard arguments.count == 3, let choice = BrowserSiteChoice(rawValue: arguments[2]) else {
                completion(.failure(BrowserAutomationError.invalidArguments(BrowserCommandRequest.siteUsage)))
                return
            }
            guard siteControlState(for: tab) != nil else {
                completion(.failure(noSite))
                return
            }
            setSitePermission(SitePermission(rawValue: arguments[1]), choice, for: tab)
            fallthrough
        default:
            guard let state = siteControlState(for: tab) else {
                completion(.failure(noSite))
                return
            }
            completion(.success(state.lines.joined(separator: "\n")))
        }
    }
}
