import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Bookmarks, find, sidebar

    func toggleBookmark() {
        guard let tab = selectedTab,
              !tab.isStartPage,
              let address = tab.webView.url?.absoluteString
        else {
            NSSound.beep()
            return
        }
        bookmarks.toggle(url: address, title: tab.displayTitle)
        updateChrome()
    }

    func showFindBar() {
        findBar.isHidden = false
        webArea.addSubview(findBar, positioned: .above, relativeTo: nil)
        findBar.needsDisplay = true
        findBar.displayIfNeeded()
        findBar.focus()
    }

    func hideFindBar() {
        vimiumFindActive = false
        findBar.isHidden = true
        findQuery = ""
        findBar.setResult(found: false, hasQuery: false)
        if let tab = selectedTab {
            tab.webView.find("", configuration: WKFindConfiguration()) { _ in }
            window?.makeFirstResponder(tab.webView)
        }
        viewNeedsLayout()
    }

    func findNext() {
        if findBar.isHidden {
            showFindBar()
            return
        }
        performFind(backwards: false, updateResult: true)
        if vimiumFindActive {
            vimiumFindActive = false
            focusPage()
        }
    }

    func findPrevious() {
        if findBar.isHidden {
            showFindBar()
            return
        }
        performFind(backwards: true, updateResult: true)
        if vimiumFindActive {
            vimiumFindActive = false
            focusPage()
        }
    }

    func beginVimiumFind() {
        vimiumFindActive = true
        showFindBar()
    }

    func repeatVimiumFind(backwards: Bool) {
        guard let tab = selectedTab else { return }
        guard !lastFindQuery.isEmpty else {
            showVimiumToast("No find query.")
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        tab.webView.find(lastFindQuery, configuration: configuration) { [weak self] result in
            self?.findBar.setResult(found: result.matchFound, hasQuery: true)
        }
    }

    func setVimiumFindQuery(_ query: String, backwards: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastFindQuery = trimmed
        repeatVimiumFind(backwards: backwards)
    }

    func endVimiumFind() {
        vimiumFindActive = false
        if !findBar.isHidden {
            hideFindBar()
        } else {
            selectedTab?.webView.find("", configuration: WKFindConfiguration()) { _ in }
            focusPage()
        }
    }

    func performFind(backwards: Bool, updateResult: Bool) {
        guard let tab = selectedTab else { return }
        guard !findQuery.isEmpty else {
            tab.webView.find("", configuration: WKFindConfiguration()) { _ in }
            findBar.setResult(found: false, hasQuery: false)
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        tab.webView.find(findQuery, configuration: configuration) { [weak self] result in
            guard updateResult else { return }
            self?.findBar.setResult(found: result.matchFound, hasQuery: true)
        }
    }

    func toggleSidebar(section: BrowserSidebarSection? = nil) {
        if isSidebarVisible, section == nil || section == sidebarSection {
            hideSidebar()
            return
        }
        showSidebar(section: section ?? sidebarSection)
    }

    func showSidebar(section: BrowserSidebarSection) {
        sidebarSection = section
        sidebar.select(section)
        isSidebarVisible = true
        sidebar.isHidden = false
        sidebarDivider.isHidden = false
        webTrailingToRoot.isActive = false
        webTrailingToSidebar.isActive = true
        updateChrome()
        updateWindowMinSize()
        viewNeedsLayout()
    }

    func hideSidebar() {
        isSidebarVisible = false
        sidebar.isHidden = true
        sidebarDivider.isHidden = true
        webTrailingToSidebar.isActive = false
        webTrailingToRoot.isActive = true
        updateChrome()
        updateWindowMinSize()
        viewNeedsLayout()
    }

    func clear(_ section: BrowserSidebarSection) {
        switch section {
        case .history:
            guard !history.entries.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "Clear History?"
            alert.informativeText = "This removes every page from the history list. It cannot be undone."
            alert.addButton(withTitle: "Clear")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if let window {
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn {
                        self?.history.clear()
                    }
                }
            }
        case .downloads:
            downloads.clearFinished()
        case .bookmarks:
            break
        }
    }

    func openFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func revealFile(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
