import AppKit

extension BrowserWindowManager {
    // MARK: - Archive

    /// The idle pass's archive half (`BrowserTabSleeper.idlePass`): every
    /// Today tab of every normal window idle at least its profile's
    /// `archiveAfter` (`BrowserArchivePolicy`), measured from
    /// `lifecycle.lastActiveAt` on the sleeper's clock, goes into the
    /// Archive (reason auto), every window's in one Archive write. A
    /// window's selected tab is in use, so its idle time starts over first.
    /// Returns the new entries.
    @discardableResult
    func archiveIdleTabs(now: Date) -> [BrowserArchiveEntry] {
        var due: [(controller: BrowserWindowController, tab: BrowserTab, entry: BrowserArchiveEntry)] = []
        for controller in controllers where controller.hasSpaces {
            controller.selectedTab?.lifecycle.lastActiveAt = now
            for tab in controller.tabs {
                guard let profile = profiles.profile(id: tab.dataContext.profileID),
                      BrowserArchivePolicy.shouldArchive(
                          controller.archiveCandidate(tab),
                          now: now,
                          archiveAfter: profile.archiveAfter
                      ),
                      let entry = controller.archiveEntry(for: tab, reason: .auto, at: now)
                else { continue }
                due.append((controller, tab, entry))
            }
        }
        guard !due.isEmpty else { return [] }
        let archived = archive.archive(due.map(\.entry))
        for controller in controllers {
            let tabs = due.filter { $0.controller === controller }.map(\.tab)
            guard !tabs.isEmpty else { continue }
            controller.removeArchivedTabs(tabs)
        }
        return archived
    }

    /// Restores archived entry `id` as a Today tab of its Space (the
    /// profile's first Space when it is gone or now another profile's),
    /// selected, and takes it out of the Archive. It opens in `controller`
    /// when that window has Spaces (switching it to the Space), else in
    /// the most recently active normal window, else in a new one. Nil, and
    /// nothing changes, when the entry or its profile is gone.
    @discardableResult
    func restoreArchived(_ id: UUID, preferring controller: BrowserWindowController?) -> BrowserTab? {
        guard let entry = archive.entry(id: id),
              profiles.profile(id: entry.profileID) != nil,
              let space = entry.spaceID.flatMap(spaces.space(id:)).flatMap({ $0.profileID == entry.profileID ? $0 : nil })
                ?? spaces.firstSpace(ofProfile: entry.profileID)
        else { return nil }
        let tab: BrowserTab?
        let target: BrowserWindowController
        if let existing = controller.flatMap({ $0.hasSpaces ? $0 : nil }) ?? mostRecentlyActive(where: \.hasSpaces) {
            target = existing
            let state = BrowserTabState(url: entry.url, title: entry.title, spaceID: space.id, origin: .today)
            let restored = target.addRestoredTab(state)
            target.selectTab(id: restored.id, focus: true)
            tab = restored
        } else {
            target = newWindow(url: entry.url, spaceID: space.id)
            tab = target.selectedTab
        }
        archive.remove(id: id)
        if target !== controller {
            present(target)
        }
        target.updateTabStrip()
        target.saveSession()
        return tab
    }
}
