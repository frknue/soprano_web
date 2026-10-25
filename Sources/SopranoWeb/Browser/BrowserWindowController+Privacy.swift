import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Clear Browsing Data

    /// The store every tab of this window uses.
    var websiteDataStore: WKWebsiteDataStore {
        (selectedTab ?? tabs.first)?.webView.configuration.websiteDataStore ?? .default()
    }

    func showClearBrowsingData() {
        revealWindowIfNeeded()
        guard let window, window.attachedSheet == nil else { return }
        BrowserClearBrowsingDataSheet.present(on: window, theme: theme) { [weak self] options in
            guard let options else { return }
            self?.clearBrowsingData(options)
        }
    }

    /// Removes what `options` names from `options.range` up to now. History
    /// clears the list and the closed-tab stack; website data goes through
    /// `WKWebsiteDataStore`, whose removal finishes asynchronously.
    func clearBrowsingData(
        _ options: BrowserClearOptions,
        now: Date = Date(),
        completion: (@MainActor () -> Void)? = nil
    ) {
        let since = options.range.startDate(now: now)
        if options.history {
            history.removeEntries(since: since)
            // Closed tabs and windows carry their own back/forward lists.
            manager.recentlyClosed.removeAll()
            saveSession()
        }
        if options.downloadList {
            downloads.removeFinished(startedSince: since)
        }
        let types = options.websiteDataTypes(available: WKWebsiteDataStore.allWebsiteDataTypes())
        guard !types.isEmpty else {
            completion?()
            return
        }
        websiteDataStore.removeData(ofTypes: types, modifiedSince: since) {
            completion?()
        }
    }
}
