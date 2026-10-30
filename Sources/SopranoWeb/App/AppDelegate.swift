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

    /// The harness's window manager, for its Dock menu check.
    func adopt(_ manager: BrowserWindowManager) {
        windowManager = manager
    }

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
        BrowserScripting.manager = manager

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

    /// New Window (in the active window's Space), New Private Window, New
    /// Little Arc, then every Space (the one the most recent window with
    /// Spaces shows checked): choosing one shows it in that window. The Dock
    /// lists the open windows above these on its own.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [
            ("New Window", #selector(newWindowFromDock)),
            ("New Private Window", #selector(newPrivateWindowFromDock)),
            ("New Little Arc", #selector(newLittleArcFromDock)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        guard let manager = windowManager, !manager.spaces.spaces.isEmpty else { return menu }
        menu.addItem(.separator())
        let current = manager.mostRecentlyActive { $0.hasSpaces }?.currentSpaceID
        for space in manager.spaces.spaces {
            let item = NSMenuItem(
                title: BrowserSpacesMenu.menuTitle(BrowserSpacesMenu.spaceTitle(space)),
                action: #selector(spaceFromDock(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = space.id
            item.state = space.id == current ? .on : .off
            menu.addItem(item)
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

    @objc private func newLittleArcFromDock() {
        windowManager?.newLittleArc(commandBar: true)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A Space from the Dock menu: the most recent window with Spaces shows
    /// it (a new window on it when there is none) and comes forward.
    @objc private func spaceFromDock(_ sender: NSMenuItem) {
        guard let manager = windowManager, let id = sender.representedObject as? UUID else { return }
        if let controller = manager.mostRecentlyActive(where: { $0.hasSpaces }) {
            controller.switchToSpace(id)
            manager.present(controller)
        } else {
            manager.newWindow(spaceID: id)
        }
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
