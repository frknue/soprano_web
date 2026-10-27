import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Session

    /// What the session saves for this window: every tab of every Space,
    /// the current Space and each Space's selection.
    var windowState: BrowserWindowState {
        let ids = tabs.map(\.id)
        return BrowserWindowState(
            id: id,
            frame: manager.sessionFrame(of: self).map(BrowserWindowFrame.init),
            tabs: tabs.map(\.state),
            selectedIndex: selectedTab.flatMap { selected in ids.firstIndex(of: selected.id) } ?? 0,
            profileID: profileID,
            currentSpaceID: currentSpaceID,
            spaceSelections: spaceSelections.compactMap { spaceID, tabID in
                ids.firstIndex(of: tabID).map { BrowserSpaceSelection(spaceID: spaceID, index: $0) }
            }.sorted { $0.index < $1.index }
        )
    }

    /// Something the session holds changed; the manager writes every window
    /// shortly after (debounced).
    func saveSession() {
        manager.scheduleSessionSave()
    }

    /// Adds a saved window's tabs (placed in today's Spaces,
    /// `BrowserWindowState.placedInSpaces`), each in its Space with its
    /// profile's context, and each Space's selection. Only the current
    /// Space's selected tab loads; the others load on first selection. A
    /// current Space without tabs gets a start tab.
    func restoreTabs(_ state: BrowserWindowState) {
        var restored: [BrowserTab] = []
        for tab in state.tabs {
            restored.append(addRestoredTab(tab))
        }
        for selection in state.spaceSelections where restored.indices.contains(selection.index) {
            spaceSelections[selection.spaceID] = restored[selection.index].id
        }
        guard !tabs.isEmpty else { return }
        let selected = restored.indices.contains(state.selectedIndex) ? restored[state.selectedIndex] : nil
        if let selected, selected.spaceID == currentSpaceID {
            selectTab(id: selected.id, focus: false)
        } else if let current = currentSpaceID {
            switchToSpace(current, focus: false)
        } else {
            selectTab(index: 0, focus: false)
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

    /// Loads a tab that is not loaded (restored, or asleep), back/forward
    /// list included, without selecting it. A sleeping tab that is selected
    /// shows its snapshot until the page is back. No-op for a loaded tab.
    func loadRestoredTabIfNeeded(_ tab: BrowserTab) {
        guard let state = tab.lifecycle.pendingRestore else { return }
        tab.lifecycle.pendingRestore = nil
        if let sleep = tab.lifecycle.sleep {
            tab.lifecycle.sleep = nil
            if tab.id == selectedTab?.id {
                showWakeSnapshot(sleep.snapshot, for: tab)
            }
            metadataChanged(tab)
        }
        tab.suppressNextHistoryRecord = true
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

    /// Releases a tab that left the window for good (closed). The caller
    /// detaches it first.
    func discardTab(_ tab: BrowserTab) {
        resolveLoadWaiters(
            for: tab,
            result: .failure(BrowserAutomationError.unavailable("The tab was closed."))
        )
        tab.vimium?.shutdown()
        tab.invalidateObservations()
        tab.webView.stopLoading()
        removeWakeSnapshot(tab)
        tab.webView.removeFromSuperview()
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
    /// The close button and ⇧⌘W: the whole window goes onto the
    /// recently-closed stack.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        manager.windowClosing(self)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        cancelRecentTabs()
        manager.windowClosing(self)
    }

    /// ⌃Tab's switcher closes with the window's key status (another window,
    /// another app): a ⌃ released elsewhere must not pick a tab later.
    func windowDidResignKey(_ notification: Notification) {
        cancelRecentTabs()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        manager.windowBecameActive(self)
    }

    func windowDidMove(_ notification: Notification) {
        saveSession()
    }

    func windowDidResize(_ notification: Notification) {
        saveSession()
    }
}
