import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windowManager: BrowserWindowManager?
    private var menuController: MainMenuController?
    private var automationController: BrowserAutomationController?
    private var pendingURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.installApplicationIcon()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsStore = BrowserSettingsStore()
        let themeManager = ThemeManager(
            themeId: settingsStore.settings.themeID,
            appearance: settingsStore.settings.appearance
        )
        themeManager.startDrivingApplicationAppearance()

        let support = BrowserFiles.supportDirectory()
        let manager = BrowserWindowManager(
            themeManager: themeManager,
            settingsStore: settingsStore,
            profiles: BrowserProfileStore(url: support.appendingPathComponent("profiles.json")),
            supportDirectory: support,
            bookmarks: BrowserBookmarkStore(url: support.appendingPathComponent("bookmarks.json")),
            downloads: BrowserDownloadStore(url: support.appendingPathComponent("downloads.json")),
            faviconStore: BrowserFaviconStore(),
            sessionStore: BrowserSessionStore(url: support.appendingPathComponent("session.json"))
        )
        windowManager = manager

        let menu = MainMenuController { [weak self] in self?.windowManager }
        menu.install()
        menuController = menu

        automationController = BrowserAutomationController { [weak self] in
            self?.windowManager
        }

        manager.restoreSession()
        NSApp.activate(ignoringOtherApps: true)
        if let controller = manager.activeController, controller.selectedTab?.isStartPage == true {
            controller.focusAddressBar()
        }

        if !pendingURLs.isEmpty {
            manager.open(pendingURLs)
            pendingURLs = []
        }
    }

    /// Links from other apps open in the most recently active normal window
    /// (never a private one), or a new window when none is open.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let windowManager else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        windowManager.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting keeps every window in the session (not on the
    /// recently-closed stack). Active downloads stop with resume data
    /// first, so they show as interrupted (and resumable) after relaunch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let windowManager else { return .terminateNow }
        windowManager.isTerminating = true
        windowManager.saveSessionNow()
        guard windowManager.downloadManager.hasActiveDownloads else { return .terminateNow }
        windowManager.downloadManager.interruptForQuit {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Clicking the Dock icon with no windows open opens a new window.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if let windowManager, windowManager.controllers.isEmpty {
            windowManager.newWindow()
        }
        return true
    }

    /// New Window, New Private Window and, with more than one profile,
    /// New Window With Profile ▸ <name>.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Window", action: #selector(newWindowFromDock), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        let privateItem = NSMenuItem(
            title: "New Private Window",
            action: #selector(newPrivateWindowFromDock),
            keyEquivalent: ""
        )
        privateItem.target = self
        menu.addItem(privateItem)
        if let profiles = windowManager?.profiles, profiles.hasSeveral {
            let submenu = NSMenu(title: MainMenuController.newWindowWithProfileTitle)
            for profile in profiles.profiles {
                let entry = NSMenuItem(title: profile.name, action: #selector(newProfileWindowFromDock(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = profile.id
                submenu.addItem(entry)
            }
            let parent = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
        return menu
    }

    @objc private func newWindowFromDock() {
        windowManager?.newWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func newPrivateWindowFromDock() {
        windowManager?.newPrivateWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func newProfileWindowFromDock(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        windowManager?.newWindow(profileID: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowManager?.saveSessionNow()
    }

    static func installApplicationIcon() {
        let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? AppResources.bundle.url(forResource: "AppIcon", withExtension: "icns")
        if let url, let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }
}
