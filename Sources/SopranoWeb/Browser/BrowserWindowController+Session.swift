import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Session

    func saveSession() {
        guard persistsSession else { return }
        sessionStore.save(
            BrowserSession(
                tabs: tabs.map(\.state),
                selectedIndex: selectedIndex,
                savedAt: Date()
            )
        )
    }

    func restoreOrCreateTab() {
        let settings = settingsStore.settings
        if persistsSession,
           settings.restoreSession,
           let session = sessionStore.load(),
           !session.tabs.isEmpty
        {
            for state in session.tabs {
                addRestoredTab(state)
            }
            let index = min(max(0, session.selectedIndex), tabs.count - 1)
            selectTab(index: index, focus: false)
        } else {
            newTab(focusAddress: true)
        }
    }
}

extension BrowserWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        saveSession()
    }
}
