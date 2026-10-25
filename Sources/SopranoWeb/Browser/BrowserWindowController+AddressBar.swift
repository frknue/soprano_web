import AppKit

extension BrowserWindowController {
    // MARK: - Address bar suggestions

    /// Hangs the dropdown under the address field, above the page and the
    /// sidebars, and routes the field's typing and keys through it.
    func installAddressBar() {
        let dropdown = addressBar.dropdown
        rootView.addSubview(dropdown)
        let anchor = toolbar.addressAnchorView
        NSLayoutConstraint.activate([
            dropdown.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: 6),
            dropdown.leadingAnchor.constraint(equalTo: anchor.leadingAnchor),
            dropdown.trailingAnchor.constraint(equalTo: anchor.trailingAnchor),
        ])

        addressBar.makeInput = { [weak self] query in
            self?.addressSuggestionInput(for: query) ?? AddressSuggestionInput(query: query)
        }
        addressBar.includesSearchSuggestions = { [weak self] in
            self?.settingsStore.settings.includeSearchSuggestions ?? false
        }
        addressBar.onOpen = { [weak self] row, newTab in
            self?.openAddressSuggestion(row, newTab: newTab)
        }
        addressBar.onFocusPage = { [weak self] in self?.focusPage() }
        toolbar.onAddressTextChange = { [weak self] text in self?.addressBar.textDidChange(text) }
        toolbar.onAddressCommand = { [weak self] selector in
            self?.addressBar.handle(selector) ?? false
        }
        toolbar.onAddressFocusChange = { [weak self] focused in
            if !focused { self?.addressBar.close() }
        }
    }

    func addressSuggestionInput(for query: String) -> AddressSuggestionInput {
        let selectedID = selectedTab?.id
        let openTabs = tabs.compactMap { tab -> AddressSuggestionTab? in
            guard tab.id != selectedID, let url = tab.item.url?.absoluteString else { return nil }
            return AddressSuggestionTab(id: tab.id, title: tab.displayTitle, url: url)
        }
        return AddressSuggestionInput(
            query: query,
            kind: kind,
            history: history.entries,
            bookmarks: bookmarks.bookmarks,
            tabs: openTabs,
            searchEngine: settingsStore.settings.searchEngine
        )
    }

    /// The field's own Return (empty field): a typed navigation.
    func submitAddress(_ value: String) {
        selectedTab?.typedNavigationPending = true
        navigateCurrent(to: value)
    }

    func openAddressSuggestion(_ row: AddressSuggestion, newTab: Bool) {
        switch row.target {
        case .tab(let id):
            selectTab(id: id, focus: true)
        case .url(let address):
            openAddress(address, typed: true, newTab: newTab)
        case .search(let query):
            guard let url = settingsStore.settings.searchEngine.searchURL(for: query) else { return }
            openAddress(url.absoluteString, typed: false, newTab: newTab)
        }
    }

    private func openAddress(_ address: String, typed: Bool, newTab: Bool) {
        if newTab {
            let tab = self.newTab(url: address)
            if typed { tab.typedNavigationPending = true }
            return
        }
        guard let tab = selectedTab, let url = URL(string: address) else { return }
        if typed { tab.typedNavigationPending = true }
        navigate(tab, to: url)
        window?.makeFirstResponder(tab.webView)
    }
}
