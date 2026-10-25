import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Navigation

    func navigateCurrent(to input: String) {
        guard let tab = selectedTab else { return }
        navigate(tab, to: input)
        window?.makeFirstResponder(tab.webView)
    }

    func navigate(_ tab: BrowserTab, to input: String) {
        guard let url = BrowserAddressResolver.resolve(
            input,
            searchEngine: settingsStore.settings.searchEngine
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
        guard ["http", "https", "file", "about", "blob", "data"].contains(scheme) else {
            NSWorkspace.shared.open(url)
            return
        }
        tab.lifecycle.pendingRestore = nil
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
        guard let tab = selectedTab else { return }
        goBack(tab)
    }

    func goBack(_ tab: BrowserTab) {
        guard tab.webView.canGoBack else { return }
        tab.pendingURL = tab.webView.backForwardList.backItem?.url.absoluteString
        tab.webView.goBack()
    }

    func goForward() {
        guard let tab = selectedTab else { return }
        goForward(tab)
    }

    func goForward(_ tab: BrowserTab) {
        guard tab.webView.canGoForward else { return }
        tab.pendingURL = tab.webView.backForwardList.forwardItem?.url.absoluteString
        tab.webView.goForward()
    }

    func reloadOrStop() {
        guard let tab = selectedTab else { return }
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
        guard let tab = selectedTab else { return }
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

    func focusAddressBar() {
        toolbar.focusAddress(selectAll: true)
    }

    func focusPage() {
        guard let tab = selectedTab else { return }
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
    /// becomes a visit once it has stayed for a second; see
    /// `BrowserSameDocumentVisits`.
    func sameDocumentURLChanged(_ tab: BrowserTab) {
        tab.sameDocumentTimer?.invalidate()
        tab.sameDocumentTimer = nil
        guard kind.recordsHistory, !tab.isStartPage,
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
                guard let self, let tab, self.tabs.contains(where: { $0 === tab }) else { return }
                tab.sameDocumentTimer = nil
                guard self.kind.recordsHistory,
                      let url = tab.sameDocumentVisits.takeDueVisit(
                          currentURL: tab.webView.url?.absoluteString,
                          isLoading: tab.webView.isLoading,
                          now: Date()
                      )
                else { return }
                self.history.record(url: url, title: tab.displayTitle, kind: .sameDocument)
            }
        }
    }

    func markStartPagesStale() {
        for tab in tabs where tab.isStartPage {
            staleStartTabs.insert(tab.id)
        }
    }

    func updateChrome() {
        updateCaptureIndicator()
        guard let tab = selectedTab else { return }
        updateTabChrome(for: tab)
        let url = tab.webView.url
        let shownURL = tab.failedURL ?? url?.absoluteString ?? ""
        toolbar.setAddress(tab.isStartPage ? "" : shownURL, security: securityState(for: tab))
        toolbar.setProgress(tab.webView.estimatedProgress, isLoading: tab.webView.isLoading)
        toolbar.setBookmarked(!tab.isStartPage && bookmarks.isBookmarked(shownURL))
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
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        clearCrashState(tab)
        // The committed page's site decides (a redirect can change it).
        applyContentBlocking(to: tab.webView, pageURL: webView.url)
        // A new document: its site's zoom, no unsaved input or capture yet.
        tab.zoom = siteZoom(for: webView.url)
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
        } else if kind.recordsHistory,
                  !tab.isStartPage,
                  let address = webView.url?.absoluteString,
                  ["http", "https", "file"].contains(webView.url?.scheme?.lowercased() ?? "")
        {
            history.record(url: address, title: tab.displayTitle, kind: visitKind)
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
        applyContentBlocking(to: tab.webView, pageURL: webView.url)
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
            ?? nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
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
        updateChrome()
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
        if handleLinkNavigation(navigationAction, in: webView) {
            decisionHandler(.cancel)
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
            applyContentBlocking(to: tab.webView, pageURL: url)
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
