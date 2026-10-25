import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Clear Browsing Data

    /// The store every tab of this window uses (its profile's, or a private
    /// window's own).
    var websiteDataStore: WKWebsiteDataStore {
        dataContext.websiteDataStore
    }

    /// The profile Clear Browsing Data names: nil while only one exists.
    var clearDataProfileName: String? {
        manager.profiles.hasSeveral ? manager.profile(of: self).name : nil
    }

    func showClearBrowsingData() {
        revealWindowIfNeeded()
        guard let window, window.attachedSheet == nil else { return }
        BrowserClearBrowsingDataSheet.present(on: window, theme: theme, profileName: clearDataProfileName) { [weak self] options in
            guard let options else { return }
            self?.clearBrowsingData(options)
        }
    }

    /// Removes what `options` names from `options.range` up to now, for this
    /// window's profile. History clears the profile's list and its entries
    /// on the closed-tab stack; website data goes through the window's
    /// `WKWebsiteDataStore`, whose removal finishes asynchronously.
    func clearBrowsingData(
        _ options: BrowserClearOptions,
        now: Date = Date(),
        completion: (@MainActor () -> Void)? = nil
    ) {
        let since = options.range.startDate(now: now)
        if options.history {
            history.removeVisits(since: since, now: now)
            // Closed tabs and windows carry their own back/forward lists.
            let profileID = self.profileID
            manager.recentlyClosed.removeAll { $0.profileID == profileID }
            closedTabs.removeAll()
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
