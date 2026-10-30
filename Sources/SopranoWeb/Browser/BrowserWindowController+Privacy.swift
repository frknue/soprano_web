import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Clear Browsing Data

    /// The current Space's store (a private window's own).
    var websiteDataStore: WKWebsiteDataStore {
        dataContext.websiteDataStore
    }

    /// The Space Clear Browsing Data names (a private window's: the one it
    /// was opened over): nil while only one exists.
    var clearDataSpaceName: String? {
        spaces.spaces.count > 1 ? manager.space(of: self)?.displayName : nil
    }

    func showClearBrowsingData() {
        revealWindowIfNeeded()
        guard let window, window.attachedSheet == nil else { return }
        BrowserClearBrowsingDataSheet.present(on: window, theme: theme, spaceName: clearDataSpaceName) { [weak self] options in
            guard let options else { return }
            self?.clearBrowsingData(options)
        }
    }

    /// Removes what `options` names from `options.range` up to now, for the
    /// current Space. History clears the Space's list, its tabs on the
    /// closed-tab stack and (in a normal window) its Archive entries
    /// archived in the range; website data goes through the Space's
    /// `WKWebsiteDataStore`, whose removal finishes asynchronously.
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
            let spaceIDs = Set(spaces.space(ofProfile: profileID).map { [$0.id] } ?? [])
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
        // WebKit calls back on the main thread.
        websiteDataStore.removeData(ofTypes: types, modifiedSince: since) {
            MainActor.assumeIsolated { completion?() }
        }
    }
}
