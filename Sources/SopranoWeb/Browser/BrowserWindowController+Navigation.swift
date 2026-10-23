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
        tab.lifecycle.pendingRestore = nil
        tab.isStartPage = true
        tab.errorMessage = nil
        tab.failedURL = nil
        tab.pendingURL = BrowserStartPageSchemeHandler.url.absoluteString
        tab.isShowingErrorPage = false
        tab.suppressNextHistoryRecord = true
        tab.zoom = tab.zoom == 0 ? 1 : tab.zoom
        tab.webView.pageZoom = tab.zoom
        tab.webView.load(URLRequest(url: BrowserStartPageSchemeHandler.url))
    }

    func startPageHTML() -> String {
        BrowserStartPage.html(
            theme: theme,
            settings: settingsStore.settings,
            bookmarks: bookmarks.bookmarks,
            history: history.entries
        )
    }

    func markStartPagesStale() {
        for tab in tabs where tab.isStartPage {
            staleStartTabs.insert(tab.id)
        }
    }

    func updateChrome() {
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
        window?.title = tab.isStartPage ? "New Tab" : tab.displayTitle
        window?.representedURL = tab.isStartPage ? nil : url
        updatePopupBlockedControl()
    }
}

extension BrowserWindowController: WKNavigationDelegate {
    // MARK: - WebKit navigation

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.vimium?.pageDidStart()
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
        webView.pageZoom = tab.zoom
        linksDidCommit(tab)
        tab.isStartPage = webView.url?.scheme?.lowercased() == BrowserStartPageSchemeHandler.scheme
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
        tab.vimium?.pageDidFinish()
        resolveLoadWaiters(
            for: tab,
            result: .success(webView.url?.absoluteString ?? "")
        )
        if tab.suppressNextHistoryRecord {
            tab.suppressNextHistoryRecord = false
        } else if !tab.isStartPage,
                  let address = webView.url?.absoluteString,
                  ["http", "https", "file"].contains(webView.url?.scheme?.lowercased() ?? "")
        {
            history.record(url: address, title: tab.displayTitle)
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
        guard let tab = tab(for: webView), tab.id == selectedTab?.id else { return }
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
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }
}

extension BrowserWindowController {
    // MARK: - Load waiters

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
        let timer = Timer(
            timeInterval: timeout,
            target: self,
            selector: #selector(loadWaiterTimedOut(_:)),
            userInfo: id.uuidString,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        loadWaiters[id] = LoadWaiter(tabID: tab.id, timer: timer, completion: completion)
    }

    @objc private func loadWaiterTimedOut(_ timer: Timer) {
        guard let raw = timer.userInfo as? String,
              let id = UUID(uuidString: raw),
              let waiter = loadWaiters.removeValue(forKey: id)
        else { return }
        waiter.completion(.failure(
            BrowserAutomationError.unavailable("Timed out waiting for the page to load.")
        ))
    }

    func resolveLoadWaiters(for tab: BrowserTab, result: Result<String, Error>) {
        let ids = loadWaiters.compactMap { id, waiter in
            waiter.tabID == tab.id ? id : nil
        }
        for id in ids {
            guard let waiter = loadWaiters.removeValue(forKey: id) else { continue }
            waiter.timer.invalidate()
            waiter.completion(result)
        }
    }
}
