import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windowController: BrowserWindowController?
    private var menuController: MainMenuController?
    private var automationController: BrowserAutomationController?
    private var pendingURLs: [URL] = []
    private var didFinishLaunching = false

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
        let history = BrowserHistoryStore(url: support.appendingPathComponent("history.json"))
        let bookmarks = BrowserBookmarkStore(url: support.appendingPathComponent("bookmarks.json"))
        let downloads = BrowserDownloadStore(url: support.appendingPathComponent("downloads.json"))
        let sessionStore = BrowserSessionStore(url: support.appendingPathComponent("session.json"))

        let controller = BrowserWindowController(
            themeManager: themeManager,
            settingsStore: settingsStore,
            history: history,
            bookmarks: bookmarks,
            downloads: downloads,
            sessionStore: sessionStore
        )
        windowController = controller

        let menu = MainMenuController { [weak self] in self?.windowController }
        menu.install()
        menuController = menu

        automationController = BrowserAutomationController { [weak self] in
            self?.windowController
        }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if controller.selectedTab?.isStartPage == true {
            controller.focusAddressBar()
        }

        didFinishLaunching = true
        openPendingURLs()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        if didFinishLaunching {
            openPendingURLs()
        }
    }

    private func openPendingURLs() {
        guard let controller = windowController, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        if urls.isEmpty { return }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        for (index, url) in urls.enumerated() {
            if url.isFileURL {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue
                else { continue }
            }
            if index == 0,
               controller.tabs.count == 1,
               let tab = controller.selectedTab,
               tab.isStartPage
            {
                controller.navigate(tab, to: url)
            } else {
                controller.newTab(url: url.absoluteString)
            }
        }
        controller.focusPage()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            windowController?.showWindowAndEnsureTab()
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.saveSession()
    }

    static func installApplicationIcon() {
        let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? AppResources.bundle.url(forResource: "AppIcon", withExtension: "icns")
        if let url, let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }
}
