import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Navigation

    /// The address bar's load: in the selected tab, which the Peek over it
    /// leaves.
    func navigateCurrent(to input: String) {
        closePeek(focusPage: false)
        guard let tab = selectedTab else { return }
        navigate(tab, to: input)
        window?.makeFirstResponder(tab.webView)
    }

    func navigate(_ tab: BrowserTab, to input: String) {
        guard let url = BrowserAddressResolver.resolve(
            input,
            searchEngines: settingsStore.settings.searchEngines
        ) else {
            NSSound.beep()
            return
        }
        navigate(tab, to: url)
    }

    func navigate(_ tab: BrowserTab, to url: URL) {
        if tab.isAsleep {
            // Wake with the history first; the new page goes after it.
            loadRestoredTabIfNeeded(tab)
        }
        if BrowserAddressResolver.isStartPage(url) {
            loadStartPage(tab)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "file", "about", "blob", "data", BrowserExtensions.scheme].contains(scheme) else {
            NSWorkspace.shared.open(url)
            return
        }
        tab.lifecycle.pendingRestore = nil
        if let context = extensionContext(for: url), kind.isPrivate, !context.hasAccessToPrivateData {
            // Not allowed in private windows: its pages don't open here.
            NSSound.beep()
            return
        }
        if !webViewFits(tab, url: url) {
            // An extension page needs its extension's web view; a web page
            // leaving one needs the tab's own again.
            replaceWebView(of: tab, for: url)
        }
        if reloadCrashedEntry(tab, at: url) { return }
        tab.isStartPage = false
        tab.errorMessage = nil
        tab.failedURL = nil
        tab.pendingURL = url.absoluteString
        tab.isShowingErrorPage = false
        if url.isFileURL {
            tab.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            tab.webView.load(URLRequest(url: url))
        }
    }

    func goBack() {
        guard let tab = pageTab else { return }
        goBack(tab)
    }

    func goBack(_ tab: BrowserTab) {
        guard tab.webView.canGoBack else { return }
        tab.pendingURL = tab.webView.backForwardList.backItem?.url.absoluteString
        tab.webView.goBack()
    }

    func goForward() {
        guard let tab = pageTab else { return }
        goForward(tab)
    }

    func goForward(_ tab: BrowserTab) {
        guard tab.webView.canGoForward else { return }
        tab.pendingURL = tab.webView.backForwardList.forwardItem?.url.absoluteString
        tab.webView.goForward()
    }

    func reloadOrStop() {
        guard let tab = pageTab else { return }
        if tab.webView.isLoading {
            tab.webView.stopLoading()
        } else if let failed = tab.failedURL, let url = URL(string: failed) {
            navigate(tab, to: url)
        } else if tab.isStartPage {
            loadStartPage(tab)
        } else {
            tab.pendingURL = tab.webView.url?.absoluteString
            tab.webView.reload()
        }
    }

    func reload() {
        guard let tab = pageTab else { return }
        reload(tab)
    }

    func reload(_ tab: BrowserTab) {
        if let failed = tab.failedURL, let url = URL(string: failed) {
            navigate(tab, to: url)
        } else if tab.isStartPage {
            loadStartPage(tab)
        } else {
            tab.pendingURL = tab.webView.url?.absoluteString
            tab.webView.reload()
        }
    }

    /// Every "focus the address" path (new tab, new window, launch, the
    /// CLI): the toolbar's field, or with the toolbar hidden (⇧⌘D) the
    /// Command Bar on the selected tab's address.
    func focusAddressBar() {
        if isToolbarHidden, !role.isCompact {
            showCommandBar(.editCurrent, toggles: false)
            return
        }
        toolbar.focusAddress(selectAll: true)
    }

    func focusPage() {
        guard let tab = pageTab else { return }
        window?.makeFirstResponder(tab.webView)
    }

    func goHome() {
        let homepage = settingsStore.settings.homepage
        navigateCurrent(to: homepage.isEmpty ? "" : homepage)
    }

    func loadStartPage(_ tab: BrowserTab) {
        if tab.isAsleep {
            // A sleeping start page comes back with its history.
            loadRestoredTabIfNeeded(tab)
            if tab.isStartPage { return }
        }
        tab.lifecycle.pendingRestore = nil
        tab.isStartPage = true
        tab.errorMessage = nil
        tab.failedURL = nil
        tab.pendingURL = BrowserStartPageSchemeHandler.url.absoluteString
        tab.isShowingErrorPage = false
        tab.zoom = settingsStore.settings.defaultZoom
        tab.webView.pageZoom = tab.zoom
        tab.webView.load(URLRequest(url: BrowserStartPageSchemeHandler.url))
    }

    /// A URL change without a page load (`history.pushState`, a hash route)
    /// becomes a visit in the tab's profile's History once it has stayed
    /// for a second; see `BrowserSameDocumentVisits`.
    func sameDocumentURLChanged(_ tab: BrowserTab) {
        tab.sameDocumentTimer?.invalidate()
        tab.sameDocumentTimer = nil
        guard tab.dataContext.kind.recordsHistory, !tab.isStartPage,
              tab.sameDocumentVisits.urlChanged(
                  to: tab.webView.url?.absoluteString,
                  isLoading: tab.webView.isLoading,
                  now: Date()
              )
        else { return }
        tab.sameDocumentTimer = Timer.scheduledTimer(
            withTimeInterval: BrowserSameDocumentVisits.debounce,
            repeats: false
        ) { [weak self, weak tab] _ in
            MainActor.assumeIsolated {
                guard let self, let tab, self.tabsWithPeek.contains(where: { $0 === tab }) else { return }
                tab.sameDocumentTimer = nil
                guard tab.dataContext.kind.recordsHistory,
                      let url = tab.sameDocumentVisits.takeDueVisit(
                          currentURL: tab.webView.url?.absoluteString,
                          isLoading: tab.webView.isLoading,
                          now: Date()
                      )
                else { return }
                tab.dataContext.history.record(url: url, title: tab.displayTitle, kind: .sameDocument)
            }
        }
    }

    /// The page set its title (`document.title`) after its load finished,
    /// when its visit was already recorded under the old one: that row
    /// takes the new title in the tab's own History. A private window's
    /// Command Bar pages take it in memory; nothing is written.
    func lateTitleChanged(_ tab: BrowserTab, title: String) {
        guard let url = tab.webView.url?.absoluteString else { return }
        guard tab.dataContext.kind.recordsHistory else {
            tab.dataContext.sessionVisits.updateTitle(url: url, title: title)
            return
        }
        // During a load the visit isn't recorded yet (it takes the title
        // then); error pages (`errorMessage` lasts until the next
        // navigation, unlike `isShowingErrorPage`) and the start page are
        // never rows.
        guard !tab.webView.isLoading, !tab.isStartPage, tab.errorMessage == nil,
              tab.certificateInterstitial == nil
        else { return }
        tab.dataContext.history.updateTitle(url: url, title: title)
    }

    func markStartPagesStale() {
        for tab in tabs where tab.isStartPage {
            staleStartTabs.insert(tab.id)
        }
    }

    func updateChrome() {
        updateCaptureIndicator()
        updateSiteControlPanel()
        guard let tab = selectedTab else { return }
        updateTabChrome(for: tab)
        let url = tab.webView.url
        let shownURL = tab.failedURL ?? url?.absoluteString ?? ""
        toolbar.setAddress(tab.isStartPage ? "" : shownURL, security: securityState(for: tab))
        toolbar.setProgress(tab.webView.estimatedProgress, isLoading: tab.webView.isLoading)
        let isPinned = pinSpaceID.map { spaces.isPinned(shownURL, inSpace: $0) } ?? false
        toolbar.setBookmarked(!tab.isStartPage && isPinned)
        toolbar.setBookmarkEnabled(!tab.isStartPage && !shownURL.isEmpty)
        toolbar.setSidebarToggle(isSidebarVisible)
        toolbar.setDownloadsToggle(isSidebarVisible && sidebarSection == .downloads)
        window?.title = kind.windowTitle(tab.isStartPage ? "New Tab" : tab.displayTitle)
        window?.representedURL = tab.isStartPage ? nil : url
        updatePopupBlockedControl()
        updateZoomChip()
    }
}

extension BrowserWindowController: WKNavigationDelegate {
    // MARK: - WebKit navigation

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.vimium?.pageDidStart()
        tab.sameDocumentVisits.navigationStarted()
        tab.sameDocumentTimer?.invalidate()
        tab.sameDocumentTimer = nil
        if tab.isShowingErrorPage {
            tab.isShowingErrorPage = false
        } else {
            tab.errorMessage = nil
            tab.failedURL = nil
            tab.certificateInterstitial = nil
        }
        if webView.url?.scheme?.lowercased() == BrowserStartPageSchemeHandler.scheme {
            tab.isStartPage = true
        }
        if tab.id == selectedTab?.id {
            updateChrome()
        } else if tab === peek?.tab {
            // A Peek's navigation: the open Site Control Center follows it.
            updateSiteControlPanel()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        clearCrashState(tab)
        if tab.awaitsLinkLanding {
            // Where the pin's load landed, redirects followed: not "away".
            tab.awaitsLinkLanding = false
            tab.linkLanding = webView.url?.absoluteString
        }
        // The committed page's site decides (a redirect can change it).
        applyContentBlocking(to: tab, pageURL: webView.url)
        // A new document: its site's zoom, no unsaved input or capture yet.
        tab.zoom = siteZoom(for: webView.url, in: tab)
        webView.pageZoom = tab.zoom
        tab.lifecycle.unsavedFrames.removeAll()
        tab.lifecycle.capturingFrames.removeAll()
        wakeSnapshotPageCommitted(tab)
        linksDidCommit(tab)
        tab.isStartPage = webView.url?.scheme?.lowercased() == BrowserStartPageSchemeHandler.scheme
        if !tab.isStartPage, tab.errorMessage == nil, tab.certificateInterstitial == nil {
            // A committed page doesn't inherit the previous title ("New Tab"
            // after the start page); the title observer fills in its own.
            tab.title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if tab.id == selectedTab?.id {
            updateChrome()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.isStartPage = webView.url?.scheme?.lowercased() == BrowserStartPageSchemeHandler.scheme
        if let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty
        {
            tab.title = title
        }
        tab.pendingURL = nil
        removeWakeSnapshot(tab)
        tab.vimium?.pageDidFinish()
        resolveLoadWaiters(
            for: tab,
            result: .success(webView.url?.absoluteString ?? "")
        )
        let visitKind: BrowserVisitKind = tab.typedNavigationPending ? .typed : tab.pendingVisitKind ?? .link
        tab.typedNavigationPending = false
        tab.pendingVisitKind = nil
        tab.sameDocumentVisits.pageLoaded(webView.url?.absoluteString)
        tab.sameDocumentTimer?.invalidate()
        tab.sameDocumentTimer = nil
        if tab.suppressNextHistoryRecord {
            tab.suppressNextHistoryRecord = false
        } else if !tab.isStartPage,
                  let address = webView.url?.absoluteString,
                  ["http", "https", "file"].contains(webView.url?.scheme?.lowercased() ?? "")
        {
            if tab.dataContext.kind.recordsHistory {
                // The tab's own profile, even while its Space is hidden.
                tab.dataContext.history.record(url: address, title: tab.displayTitle, kind: visitKind)
            } else {
                // A private window's Command Bar remembers its pages in
                // memory only.
                tab.dataContext.sessionVisits.record(url: address, title: tab.displayTitle, kind: visitKind)
            }
        }
        if tab.id == selectedTab?.id {
            updateChrome()
        }
        updateTabStrip()
        saveSession()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleFailure(webView, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleFailure(webView, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
    ) {
        guard let tab = tab(for: webView) else { return }
        // The page's site may have changed; its subresources load next.
        applyContentBlocking(to: tab, pageURL: webView.url)
        guard tab.id == selectedTab?.id else { return }
        updateChrome()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        handleWebContentCrash(tab)
    }

    private func handleFailure(_ webView: WKWebView, error: Error) {
        let nsError = error as NSError
        // A navigation that becomes a download ends with "Frame load
        // interrupted" by policy; it is not a page failure.
        if nsError.code == NSURLErrorCancelled
            || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
        {
            return
        }
        guard let tab = tab(for: webView) else { return }
        removeWakeSnapshot(tab)
        let failedURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
            ?? tab.pendingURL
            ?? tab.failedURL
            ?? ""
        if showCertificateInterstitial(tab, error: nsError, failedURL: failedURL) {
            return
        }
        tab.errorMessage = nsError.localizedDescription
        tab.failedURL = failedURL.isEmpty ? nil : failedURL
        tab.isShowingErrorPage = true
        tab.title = "Can’t Open Page"
        tab.suppressNextHistoryRecord = true
        webView.loadHTMLString(
            BrowserErrorPage.html(
                theme: theme,
                url: failedURL,
                message: nsError.localizedDescription
            ),
            baseURL: nil
        )
        updateTabStrip()
        if tab === peek?.tab {
            updatePeekChrome()
        } else {
            updateChrome()
        }
        resolveLoadWaiters(
            for: tab,
            result: .failure(BrowserAutomationError.unavailable(nsError.localizedDescription))
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if !BrowserWebSchemes.isWeb(url) {
            openExternalLink(url, from: webView)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if let tab = tab(for: webView), !allowsExtensionNavigation(navigationAction, to: url, in: tab) {
            // A page asking for an extension's page, or an extension page
            // for a local file (`allowsExtensionNavigation`).
            decisionHandler(.cancel)
            return
        }
        if handleLinkNavigation(navigationAction, in: webView) {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true, let tab = tab(for: webView), !webViewFits(tab, url: url) {
            // Into or out of an extension page: the tab's web view is
            // swapped for one that can show it.
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let self, let tab, self.tabsWithPeek.contains(where: { $0 === tab }) else { return }
                self.navigate(tab, to: url)
            }
            return
        }
        if navigationAction.targetFrame?.isMainFrame != false,
           let tab = tab(for: webView),
           ["http", "https", "file"].contains(scheme)
        {
            tab.pendingURL = url.absoluteString
            tab.pendingVisitKind = BrowserVisitKind(navigationAction.navigationType)
        }
        if navigationAction.targetFrame?.isMainFrame == true, let tab = tab(for: webView) {
            // The new page's lists are in place before it starts loading.
            applyContentBlocking(to: tab, pageURL: url)
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
        if BrowserContentDisposition.isAttachment(disposition) {
            decisionHandler(.download)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        adoptDownload(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        adoptDownload(download)
    }
}

extension BrowserWindowController {
    // MARK: - Load waiters

    /// Answers once the tab's navigation finishes (or fails, or `timeout`
    /// passes). The waiter lives on the tab, so it survives a move to
    /// another window.
    func waitForLoad(
        _ tab: BrowserTab,
        timeout: TimeInterval = BrowserCommandRequest.defaultWaitTimeout,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        if !tab.webView.isLoading, tab.pendingURL == nil {
            completion(.success(tab.webView.url?.absoluteString ?? ""))
            return
        }
        let id = UUID()
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak tab] _ in
            MainActor.assumeIsolated {
                guard let waiter = tab?.loadWaiters.removeValue(forKey: id) else { return }
                waiter.completion(.failure(
                    BrowserAutomationError.unavailable("Timed out waiting for the page to load.")
                ))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tab.loadWaiters[id] = BrowserLoadWaiter(timer: timer, completion: completion)
    }

    func resolveLoadWaiters(for tab: BrowserTab, result: Result<String, Error>) {
        let waiters = tab.loadWaiters.values
        tab.loadWaiters.removeAll()
        for waiter in waiters {
            waiter.timer.invalidate()
            waiter.completion(result)
        }
    }
}
