import AppKit

/// Today tabs go into the Archive (`BrowserArchiveStore`): ⌘W on one (it
/// also goes onto Recently Closed), ⇧⌘K for every Today tab of the
/// current Space, and the idle pass (`BrowserWindowManager.archiveIdleTabs`).
/// Pinned and favorite tabs, start pages and private or pop-up windows'
/// tabs never do. The sidebar's Archive section restores them.
extension BrowserWindowController {
    // MARK: - Archiving

    /// What `BrowserArchivePolicy` reads from `tab` in this window.
    func archiveCandidate(_ tab: BrowserTab) -> BrowserArchiveCandidate {
        BrowserArchiveCandidate(
            inSpace: hasSpaces && !kind.isPrivate && tab.spaceID != nil,
            isToday: tab.origin == .today,
            isStartPage: tab.isStartPage || !BrowserArchiveEntry.isArchivable(tab.item.url),
            activity: sleepCandidate(tab)
        )
    }

    /// Why `tab` never archives on its own now; nil when idle time decides.
    func archiveExemption(_ tab: BrowserTab) -> BrowserArchiveExemption? {
        BrowserArchivePolicy.exemption(for: archiveCandidate(tab))
    }

    /// The Archive entry `tab` would become; nil for a tab that never
    /// archives: pinned or favorite, a start page, a private or pop-up
    /// window's.
    func archiveEntry(for tab: BrowserTab, reason: BrowserArchiveReason, at date: Date? = nil) -> BrowserArchiveEntry? {
        let candidate = archiveCandidate(tab)
        guard candidate.inSpace, candidate.isToday, !candidate.isStartPage, let url = tab.item.url else { return nil }
        return BrowserArchiveEntry(
            url: url.absoluteString,
            title: tab.title.trimmingCharacters(in: .whitespacesAndNewlines),
            spaceID: tab.spaceID,
            profileID: tab.dataContext.profileID,
            archivedAt: date ?? manager.tabSleeper.now(),
            reason: reason,
            faviconKey: BrowserFaviconSelection.key(for: url)
        )
    }

    /// Writes `tab` into the Archive without touching the window; nil (and
    /// nothing written) for a tab that never archives.
    @discardableResult
    func recordArchive(_ tab: BrowserTab, reason: BrowserArchiveReason, at date: Date? = nil) -> BrowserArchiveEntry? {
        guard let entry = archiveEntry(for: tab, reason: reason, at: date) else { return nil }
        return manager.archive.archive([entry]).first
    }

    /// Archives `tab` and takes it out of the window (`archiveTabs`).
    @discardableResult
    func archiveTab(_ tab: BrowserTab, reason: BrowserArchiveReason, at date: Date? = nil) -> BrowserArchiveEntry? {
        archiveTabs([tab], reason: reason, at: date).first
    }

    /// Archives `tabs` with one Archive write and takes them out of the
    /// window, without Recently Closed. A Space left without tabs gets a
    /// start tab (`detachTab`); the window's last tab first gets a start
    /// tab beside it, so archiving never closes a window.
    @discardableResult
    func archiveTabs(_ tabs: [BrowserTab], reason: BrowserArchiveReason, at date: Date? = nil) -> [BrowserArchiveEntry] {
        let pairs = tabs.compactMap { tab in archiveEntry(for: tab, reason: reason, at: date).map { (tab, $0) } }
        guard !pairs.isEmpty else { return [] }
        let stored = manager.archive.archive(pairs.map(\.1))
        removeArchivedTabs(pairs.map(\.0))
        return stored
    }

    /// Takes tabs already written to the Archive out of the window.
    func removeArchivedTabs(_ archived: [BrowserTab]) {
        for tab in archived where self.tabs.contains(where: { $0 === tab }) {
            if self.tabs.count == 1 {
                newTab(select: true)
            }
            detachTab(tab)
            discardTab(tab)
        }
    }

    /// ⇧⌘K (Spaces ▸ Archive Today Tabs): archives every Today tab of the
    /// current Space with one Archive write; start pages stay. The
    /// selected tab goes last, so the selection moves once, to what is
    /// left.
    @discardableResult
    func archiveTodayTabs() -> [BrowserArchiveEntry] {
        guard hasSpaces, !kind.isPrivate else { return [] }
        let selectedID = selectedTab?.id
        let today = visibleTabs.filter { tab in
            let candidate = archiveCandidate(tab)
            return candidate.isToday && !candidate.isStartPage
        }
        let ordered = today.filter { $0.id != selectedID } + today.filter { $0.id == selectedID }
        let archived = archiveTabs(ordered, reason: .manual)
        updateTabStrip()
        saveSession()
        return archived
    }

    /// Whether ⇧⌘K has anything to archive in this window.
    var canArchiveTodayTabs: Bool {
        hasSpaces && !kind.isPrivate && visibleTabs.contains { tab in
            let candidate = archiveCandidate(tab)
            return candidate.isToday && !candidate.isStartPage
        }
    }

    // MARK: - Sidebar

    /// The sidebar's Archive rows' restore: `BrowserWindowManager.restoreArchived`.
    func restoreArchived(id: UUID) {
        manager.restoreArchived(id, preferring: self)
    }

    /// The Space mark an Archive row shows: the Space's icon, name and
    /// color; nil when the Space is gone.
    func archiveSpaceMark(_ spaceID: UUID?) -> BrowserSidebarSpaceMark? {
        guard let space = spaceID.flatMap(spaces.space(id:)) else { return nil }
        return BrowserSidebarSpaceMark(
            text: BrowserSpacesMenu.spaceTitle(space),
            color: space.color.color(in: theme.colors)
        )
    }
}
