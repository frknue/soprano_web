import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windowManager: BrowserWindowManager?
    private var menuController: MainMenuController?
    private var automationController: BrowserAutomationController?
    private var pendingURLs: [URL] = []
    /// Settings ▸ Keyboard shortcuts ▸ "New Little Arc from any app".
    private let globalHotKey = BrowserGlobalHotKey()
    private var appliedGlobalHotKey: BrowserShortcut?
    private var settingsObservation: BrowserObservation?

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
        let profiles = BrowserProfileStore(url: support.appendingPathComponent("profiles.json"))
        let manager = BrowserWindowManager(
            themeManager: themeManager,
            settingsStore: settingsStore,
            profiles: profiles,
            supportDirectory: support,
            spaces: BrowserSpaceStore(
                url: support.appendingPathComponent("spaces.json"),
                profiles: profiles.profiles,
                bookmarksURL: support.appendingPathComponent("bookmarks.json")
            ),
            archive: BrowserArchiveStore(url: support.appendingPathComponent("archive.json")),
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

        manager.globalHotKey = globalHotKey
        applyGlobalHotKey(settingsStore.settings)
        settingsObservation = settingsStore.changes.observe { [weak self] settings in
            self?.applyGlobalHotKey(settings)
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

    /// Registers the global New Little Arc shortcut while the setting is on.
    /// A refused registration (another app holds it, no key types it) is
    /// retried with the next settings change; Settings shows it as
    /// unavailable (`BrowserGlobalHotKey.isRegistered`).
    private func applyGlobalHotKey(_ settings: BrowserSettings) {
        let wanted = settings.globalLittleArcEnabled ? BrowserShortcut(settings.globalLittleArcShortcut) : nil
        guard wanted != appliedGlobalHotKey || (wanted != nil && !globalHotKey.isRegistered) else { return }
        let registered = globalHotKey.register(wanted) { [weak self] in
            guard let manager = self?.windowManager else { return }
            NSApp.activate()
            manager.newLittleArc(commandBar: true)
        }
        appliedGlobalHotKey = registered ? wanted : nil
    }

    /// Links from other apps: a matching link rule's Space, else a Little
    /// Arc or the most recent window (Settings ▸ Links from other apps).
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

    /// New Window (in the active window's Space) and New Private Window.
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
