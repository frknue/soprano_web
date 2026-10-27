import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Clear Browsing Data

    /// The current Space's profile's store (a private window's own).
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

    /// Removes what `options` names from `options.range` up to now, for the
    /// current Space's profile. History clears the profile's list, its
    /// tabs on the closed-tab stack and (in a normal window) its Archive
    /// entries archived in the range; website data goes through the
    /// profile's `WKWebsiteDataStore`, whose removal finishes
    /// asynchronously.
    func clearBrowsingData(
        _ options: BrowserClearOptions,
        now: Date = Date(),
        completion: (@MainActor () -> Void)? = nil
    ) {
        let since = options.range.startDate(now: now)
        if options.history {
            dataContext.history.removeVisits(since: since, now: now)
            // A private window's Command Bar pages (memory only).
            dataContext.sessionVisits.removeVisits(since: since)
            // Closed tabs and windows carry their own back/forward lists.
            let profileID = self.profileID
            let spaceIDs = Set(spaces.spaces(ofProfile: profileID).map(\.id))
            manager.recentlyClosed.removeEntries(ofProfile: profileID, spaces: spaceIDs)
            closedTabs.removeAll()
            if !kind.isPrivate {
                // The idle clock may run ahead of `now` (the harness's).
                let end = max(now, manager.tabSleeper.now())
                manager.archive.removeEntries(ofProfile: profileID, archivedIn: min(since, end)...end)
            }
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
