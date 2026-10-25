import AppKit

extension BrowserWindowController {
    // MARK: - Tab context menu

    /// Reload, Duplicate, Mute, Copy Link, Move Tab to New Window, the close
    /// actions and Reopen Closed Tab for one tab. `closeAfterTitle` names
    /// the run after it: "Close Tabs Below" in the rail, "… to the Right"
    /// in the strip.
    func tabContextMenu(for id: UUID, closeAfterTitle: String) -> NSMenu? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs[index]
        let menu = NSMenu(title: "Tab")
        menu.autoenablesItems = false

        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.isEnabled = enabled
            menu.addItem(item)
        }

        let hasPage = !tab.isStartPage && tab.item.url != nil
        add("Reload", #selector(reloadTabFromMenu(_:)))
        add("Duplicate", #selector(duplicateTabFromMenu(_:)), enabled: tab.isStartPage || tab.webView.url != nil)
        add(tab.isMuted ? "Unmute Tab" : "Mute Tab", #selector(toggleMuteFromMenu(_:)))
        add("Copy Link", #selector(copyTabLinkFromMenu(_:)), enabled: hasPage)
        menu.addItem(.separator())
        add("Move Tab to New Window", #selector(moveTabToNewWindowFromMenu(_:)))
        menu.addItem(.separator())
        add("Close Tab", #selector(closeTabFromMenu(_:)))
        add("Close Other Tabs", #selector(closeOtherTabsFromMenu(_:)), enabled: tabs.count > 1)
        add(closeAfterTitle, #selector(closeTabsAfterFromMenu(_:)), enabled: index < tabs.count - 1)
        menu.addItem(.separator())
        add("Reopen Closed Tab", #selector(reopenClosedTabFromMenu(_:)), enabled: !manager.recentlyClosed.isEmpty)
        return menu
    }

    func toggleMute(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        toggleMute(tab)
    }

    /// Closes every tab but `id` and selects it.
    func closeOtherTabs(keeping id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        closeTabs(tabs.filter { $0.id != id }.map(\.id), thenSelect: id)
    }

    /// Closes every tab after `id` (below it in the rail, right of it in
    /// the strip). The selection stays, or moves to `id` when it was closed.
    func closeTabs(after id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[(index + 1)...].map(\.id)
        guard !closing.isEmpty else { return }
        let selected = selectedTab.map(\.id).flatMap { closing.contains($0) ? nil : $0 } ?? id
        closeTabs(closing, thenSelect: selected)
    }

    private func closeTabs(_ ids: [UUID], thenSelect selection: UUID) {
        selectTab(id: selection, focus: false)
        for closing in ids.reversed() {
            closeTab(id: closing)
        }
        selectTab(id: selection, focus: true)
    }

    private func menuTab(_ sender: NSMenuItem) -> BrowserTab? {
        guard let id = sender.representedObject as? UUID else { return nil }
        return tabs.first { $0.id == id }
    }

    @objc func reloadTabFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        reload(tab)
    }

    @objc func duplicateTabFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        duplicateTab(id: tab.id)
    }

    @objc func toggleMuteFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        toggleMute(tab)
    }

    @objc func copyTabLinkFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender), let url = tab.item.url?.absoluteString else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }

    @objc func closeTabFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        closeTab(id: tab.id)
    }

    @objc func closeOtherTabsFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        closeOtherTabs(keeping: tab.id)
    }

    @objc func closeTabsAfterFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        closeTabs(after: tab.id)
    }

    @objc func reopenClosedTabFromMenu(_ sender: NSMenuItem) {
        reopenClosedTab()
    }
}
