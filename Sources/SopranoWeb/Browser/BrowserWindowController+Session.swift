import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Session

    var currentSession: BrowserSession {
        BrowserSession(
            tabs: tabs.map(\.state),
            selectedIndex: selectedIndex,
            savedAt: Date(),
            closedTabs: closedTabs.entries
        )
    }

    func saveSession() {
        guard persistsSession else { return }
        sessionStore.save(currentSession)
    }

    /// Restores the saved tabs (when the setting is on) and the closed-tab
    /// stack. Only the selected tab loads; the others load on first
    /// selection. `persistsSession` gates writes only, so the snapshot
    /// harness can restore a session file it was handed.
    func restoreOrCreateTab() {
        let session = sessionStore.load()
        closedTabs = BrowserClosedTabStack(session?.closedTabs ?? [])
        if settingsStore.settings.restoreSession,
           let session,
           !session.tabs.isEmpty
        {
            for state in session.tabs {
                addRestoredTab(state)
            }
            let index = min(max(0, session.selectedIndex), tabs.count - 1)
            selectTab(index: index, focus: false)
        } else {
            newTab(focusAddress: true)
        }
    }

    /// Runs when a tab becomes the selected one: a restored tab loads, a
    /// background tab whose page crashed reloads.
    func prepareSelectedTab(_ tab: BrowserTab) {
        loadRestoredTabIfNeeded(tab)
        if tab.lifecycle.reloadsWhenSelected {
            tab.lifecycle.reloadsWhenSelected = false
            reloadAfterCrash(tab)
        }
    }

    /// Loads a restored tab that has not loaded yet, back/forward list
    /// included, without selecting it. No-op for a loaded tab.
    func loadRestoredTabIfNeeded(_ tab: BrowserTab) {
        guard let state = tab.lifecycle.pendingRestore else { return }
        tab.lifecycle.pendingRestore = nil
        tab.suppressNextHistoryRecord = true
        tab.zoom = state.zoom
        if let data = state.interactionState {
            // Restoring the archived list also navigates to its current item.
            tab.webView.interactionState = data
            if let current = tab.webView.backForwardList.currentItem?.url,
               Self.restoredItem(current, matches: state.url)
            {
                tab.isStartPage = BrowserAddressResolver.isStartPage(current)
                tab.pendingURL = current.absoluteString
                return
            }
        }
        if let value = state.url,
           let url = URL(string: value),
           ["http", "https", "file", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "")
        {
            navigate(tab, to: url)
        } else {
            loadStartPage(tab)
        }
    }

    /// The archived list's current item is the saved page. It is not after
    /// an error page (saved under the failed address) or a list that did
    /// not decode; the tab then loads the saved address.
    private static func restoredItem(_ url: URL, matches saved: String?) -> Bool {
        guard let saved else { return BrowserAddressResolver.isStartPage(url) }
        return url.absoluteString == saved
    }

    /// Releases a tab that is leaving the window. The caller removes it from
    /// `tabs`.
    func discardTab(_ tab: BrowserTab) {
        resolveLoadWaiters(
            for: tab,
            result: .failure(BrowserAutomationError.unavailable("The tab was closed."))
        )
        tab.vimium?.shutdown()
        tab.invalidateObservations()
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
    }

    /// Closing the window (⇧⌘W or the close button) closes its tabs onto
    /// the closed-tab stack, the selected one last so ⇧⌘T brings it back
    /// first.
    func closeAllTabs() {
        guard !tabs.isEmpty else { return }
        let selectedID = selectedTab?.id
        let ordered = tabs.filter { $0.id != selectedID } + tabs.filter { $0.id == selectedID }
        for tab in ordered {
            closedTabs.push(tab.state)
            discardTab(tab)
        }
        tabs.removeAll()
        selectedIndex = 0
        tabStrip.clear()
        verticalTabsView.clear()
        saveSession()
    }

    // MARK: - Crash recovery

    func handleWebContentCrash(_ tab: BrowserTab) {
        let now = Date()
        let action = BrowserCrashPolicy.action(
            isSelected: tab.id == selectedTab?.id,
            previousCrash: tab.lifecycle.lastCrashAt,
            now: now
        )
        tab.lifecycle.lastCrashAt = now
        // WebKit clears `url` once this callback returns; keep the address
        // for the address bar, the session and the reload.
        if !tab.isStartPage {
            tab.failedURL = tab.failedURL ?? tab.webView.url?.absoluteString ?? tab.pendingURL
            tab.lifecycle.crashedURL = tab.failedURL
        }
        switch action {
        case .reload:
            reloadAfterCrash(tab)
            showVimiumToast("The page crashed and was reloaded.")
        case .showCrashPage:
            showCrashPage(tab)
            resolveLoadWaiters(
                for: tab,
                result: .failure(BrowserAutomationError.unavailable("The page crashed."))
            )
        case .reloadWhenSelected:
            tab.lifecycle.reloadsWhenSelected = true
            resolveLoadWaiters(
                for: tab,
                result: .failure(BrowserAutomationError.unavailable("The page crashed."))
            )
        }
        metadataChanged(tab)
    }

    /// Reloads a crashed tab. ⌘R on the crash page and the Reload button take
    /// the same path: `navigate` to the crashed address, which reloads the
    /// entry in place (`reloadCrashedEntry`).
    func reloadAfterCrash(_ tab: BrowserTab) {
        removeCrashPage(tab)
        tab.suppressNextHistoryRecord = true
        if !tab.isStartPage, let address = tab.failedURL, let url = URL(string: address) {
            navigate(tab, to: url)
        } else {
            loadStartPage(tab)
        }
    }

    /// Navigating to the address that crashed reloads that back/forward
    /// entry instead of pushing a copy of it. False when `url` is not the
    /// crashed entry (an error page's failed address, another page).
    func reloadCrashedEntry(_ tab: BrowserTab, at url: URL) -> Bool {
        guard let crashed = tab.lifecycle.crashedURL,
              crashed == url.absoluteString,
              tab.webView.backForwardList.currentItem?.url.absoluteString == crashed
        else { return false }
        removeCrashPage(tab)
        tab.isStartPage = false
        tab.errorMessage = nil
        tab.failedURL = nil
        tab.isShowingErrorPage = false
        tab.pendingURL = crashed
        tab.webView.reload()
        return true
    }

    func showCrashPage(_ tab: BrowserTab) {
        removeCrashPage(tab)
        let address = tab.failedURL ?? tab.webView.url?.absoluteString ?? tab.pendingURL ?? ""
        let view = BrowserCrashView(url: address, theme: theme)
        view.onReload = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.reloadAfterCrash(tab)
        }
        tab.webView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: tab.webView.topAnchor),
            view.leadingAnchor.constraint(equalTo: tab.webView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: tab.webView.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: tab.webView.bottomAnchor),
        ])
        tab.lifecycle.crashView = view
    }

    func removeCrashPage(_ tab: BrowserTab) {
        tab.lifecycle.crashView?.removeFromSuperview()
        tab.lifecycle.crashView = nil
    }

    /// A page committed: the tab is no longer crashed.
    func clearCrashState(_ tab: BrowserTab) {
        removeCrashPage(tab)
        tab.lifecycle.crashedURL = nil
    }
}

extension BrowserWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeAllTabs()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        saveSession()
    }
}
