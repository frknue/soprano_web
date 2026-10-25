import AppKit
import WebKit

/// Where the manager puts windows. The app uses the real screens; the
/// snapshot harness lays windows out on a virtual screen and shifts every
/// one by `offset`, so none ever reaches a display.
struct BrowserWindowPlacement {
    /// Visible frames windows are kept on (restore, cascade).
    var screens: @MainActor () -> [NSRect]
    /// A first window's frame.
    var defaultFrame: @MainActor () -> NSRect
    /// Added to every frame the manager gives a window and taken off again
    /// when it reads one back (session, `--print-windows`).
    var offset = NSPoint.zero

    var isOffscreen: Bool { offset != .zero }

    static var screen: BrowserWindowPlacement {
        BrowserWindowPlacement(
            screens: { NSScreen.screens.map(\.visibleFrame) },
            defaultFrame: {
                MainWindowSizing.initialFrame(
                    in: NSScreen.main?.visibleFrame ?? MainWindowSizing.fallbackVisibleFrame
                )
            }
        )
    }

    /// The harness: a 20,000 pt virtual screen, the first window at
    /// (100, 10,000) with `size`, everything moved 60,000 pt off the displays.
    static func offscreen(size: NSSize) -> BrowserWindowPlacement {
        let desk = NSRect(x: 0, y: 0, width: 20_000, height: 20_000)
        return BrowserWindowPlacement(
            screens: { [desk] },
            defaultFrame: { NSRect(x: 100, y: 10_000, width: size.width, height: size.height) },
            offset: NSPoint(x: -60_000, y: -60_000)
        )
    }
}

/// Owns every browser window and the app-wide pieces they share: the stores,
/// downloads, Settings, the recently-closed stack, Vimium's global marks,
/// notification clicks and the session file. `AppDelegate` (or the snapshot
/// harness) owns the one manager.
@MainActor
final class BrowserWindowManager {
    static let windowMinSize = NSSize(width: 760, height: 520)
    /// Stage 1's frame autosave name; a migrated window opens there.
    static let legacyFrameKey = "NSWindow Frame SopranoWebMainWindow"
    /// Session writes wait this long for more changes.
    static let sessionSaveDelay: TimeInterval = 0.5

    let themeManager: ThemeManager
    let settingsStore: BrowserSettingsStore
    let history: BrowserHistoryStore
    let bookmarks: BrowserBookmarkStore
    let downloads: BrowserDownloadStore
    let downloadManager: BrowserDownloadManager
    let sitePermissions: BrowserSitePermissionStore
    let faviconStore: BrowserFaviconStore
    let sessionStore: BrowserSessionStore
    let connectionSecurity = BrowserConnectionSecurity()
    /// False in the harness: it may restore a session file but never writes.
    let persistsSession: Bool
    let placement: BrowserWindowPlacement
    let defaults: UserDefaults
    /// Theme changes for every window (`ThemeManager` has one callback).
    let themeChanges = BrowserObservers<AppTheme>()

    /// Open windows in the order they opened; the CLI numbers them 1…n.
    private(set) var controllers: [BrowserWindowController] = []
    /// Window ids, most recently active last.
    private var activationOrder: [UUID] = []
    var recentlyClosed = BrowserRecentlyClosedStack()
    /// Vimium's uppercase marks, shared by every tab.
    var globalVimiumMarks: [String: VimiumMark] = [:]
    /// Set once quitting starts: windows stay in the session and stay off
    /// the recently-closed stack.
    var isTerminating = false

    private var settingsWindowController: SettingsWindowController?
    private var websitesSheet: BrowserWebsitesSheet?
    private var saveTimer: Timer?
    private var observations: [BrowserObservation] = []

    init(
        themeManager: ThemeManager,
        settingsStore: BrowserSettingsStore,
        history: BrowserHistoryStore,
        bookmarks: BrowserBookmarkStore,
        downloads: BrowserDownloadStore,
        sitePermissions: BrowserSitePermissionStore,
        faviconStore: BrowserFaviconStore,
        sessionStore: BrowserSessionStore,
        persistsSession: Bool = true,
        placement: BrowserWindowPlacement = .screen,
        defaults: UserDefaults = .standard
    ) {
        self.themeManager = themeManager
        self.settingsStore = settingsStore
        self.history = history
        self.bookmarks = bookmarks
        self.downloads = downloads
        self.downloadManager = BrowserDownloadManager(store: downloads, settingsStore: settingsStore)
        self.sitePermissions = sitePermissions
        self.faviconStore = faviconStore
        self.sessionStore = sessionStore
        self.persistsSession = persistsSession
        self.placement = placement
        self.defaults = defaults

        themeManager.onThemeChanged = { [weak self] theme in
            self?.websitesSheet?.apply(theme: theme)
            self?.themeChanges.notify(theme)
        }
        observations = [
            settingsStore.changes.observe { [weak self] settings in self?.applyTheme(of: settings) },
            sitePermissions.changes.observe { [weak self] in self?.websitesSheet?.reload() },
        ]
        downloadManager.fallbackWindow = { [weak self] in self?.activeController?.window }
        BrowserNotificationCenter.shared.onClick = { [weak self] click in self?.openNotification(click) }
    }

    // MARK: - Windows

    /// The browser window that has keyboard focus.
    var keyController: BrowserWindowController? {
        controllers.first { $0.window?.isKeyWindow == true }
    }

    /// The key browser window, else the most recently active one: where
    /// menu commands, links from other apps and the CLI go by default.
    var activeController: BrowserWindowController? {
        if let keyController { return keyController }
        for id in activationOrder.reversed() {
            if let controller = controllers.first(where: { $0.id == id }) {
                return controller
            }
        }
        return controllers.last
    }

    /// The window new tabs and links from other apps go to: the active
    /// window unless it is a pop-up, else the most recently active window
    /// with tabs.
    var tabbedController: BrowserWindowController? {
        if let active = activeController, !active.isPopup { return active }
        for id in activationOrder.reversed() {
            if let controller = controllers.first(where: { $0.id == id }), !controller.isPopup {
                return controller
            }
        }
        return nil
    }

    /// Where a pop-up window's new tabs and links go: `tabbedController`,
    /// else a new empty window (the caller adds the tab and presents it).
    func windowForNewTabs() -> BrowserWindowController {
        tabbedController ?? makeWindow(frame: frameForNewWindow())
    }

    /// 1-based, as `browser windows` lists them.
    func number(of controller: BrowserWindowController) -> Int? {
        controllers.firstIndex { $0 === controller }.map { $0 + 1 }
    }

    /// A tab in any window.
    func tab(id: UUID) -> (window: BrowserWindowController, tab: BrowserTab)? {
        for controller in controllers {
            if let tab = controller.tabs.first(where: { $0.id == id }) {
                return (controller, tab)
            }
        }
        return nil
    }

    func windowBecameActive(_ controller: BrowserWindowController) {
        activationOrder.removeAll { $0 == controller.id }
        activationOrder.append(controller.id)
    }

    /// Brings a window forward. In the harness it is only ordered in,
    /// behind everything and off every display; it never becomes key.
    func present(_ controller: BrowserWindowController) {
        guard let window = controller.window else { return }
        windowBecameActive(controller)
        if placement.isOffscreen {
            window.orderBack(nil)
            window.displayIfNeeded()
        } else {
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// File ▸ New Window (⌘N): a start tab (or `url`), one step down and
    /// right of the key window.
    @discardableResult
    func newWindow(url: String? = nil) -> BrowserWindowController {
        let controller = makeWindow(frame: frameForNewWindow())
        controller.newTab(url: url, focusAddress: url == nil)
        present(controller)
        scheduleSessionSave()
        return controller
    }

    /// Closes a window the way its close button does: its tabs go onto the
    /// recently-closed stack as one entry (an emptied window and a pop-up
    /// window go nowhere).
    func closeWindow(_ controller: BrowserWindowController) {
        windowClosing(controller)
        controller.window?.close()
    }

    /// The window is closing (close button, ⇧⌘W, its last tab,
    /// `close-window`, its tabs moved away). Runs once per window; quitting
    /// keeps it in the session instead.
    func windowClosing(_ controller: BrowserWindowController) {
        guard !isTerminating, let index = controllers.firstIndex(where: { $0 === controller }) else { return }
        let state = controller.windowState
        if !state.tabs.isEmpty, !controller.isPopup {
            recentlyClosed.push(BrowserClosedEntry(.window(state)))
        }
        controllers.remove(at: index)
        activationOrder.removeAll { $0 == controller.id }
        controller.tearDown()
        scheduleSessionSave()
        // AppKit finishes closing the window after this returns; the
        // controller owns the window, so it stays alive until then.
        DispatchQueue.main.async {
            withExtendedLifetime(controller) {}
        }
    }

    /// The frame the session stores: the window's frame without the
    /// harness offset.
    func sessionFrame(of controller: BrowserWindowController) -> NSRect? {
        controller.window.map { $0.frame.offsetBy(dx: -placement.offset.x, dy: -placement.offset.y) }
    }

    /// A new, empty window at `frame` (session coordinates). `activate`
    /// makes it the window commands go to by default.
    func makeWindow(
        id: UUID = UUID(),
        frame: NSRect,
        isPopup: Bool = false,
        activate: Bool = true
    ) -> BrowserWindowController {
        let controller = BrowserWindowController(
            manager: self,
            id: id,
            frame: frame.offsetBy(dx: placement.offset.x, dy: placement.offset.y),
            isPopup: isPopup
        )
        controllers.append(controller)
        if activate {
            windowBecameActive(controller)
        }
        return controller
    }

    /// A new window's frame: one step down and right of `source` (else the
    /// key or most recently active window with tabs), or the default frame.
    func frameForNewWindow(cascadingFrom source: BrowserWindowController? = nil) -> NSRect {
        let screens = placement.screens()
        let base = source.flatMap { $0.isPopup ? nil : $0 } ?? tabbedController
        if let base, let frame = sessionFrame(of: base) {
            return BrowserWindowFrames.cascaded(from: frame, screens: screens)
        }
        return BrowserWindowFrames.clamped(placement.defaultFrame(), to: screens, minSize: Self.windowMinSize)
    }

    /// Opens a saved window (restore or reopen) with its tabs, lazily.
    @discardableResult
    private func openWindow(_ state: BrowserWindowState, fallbackFrame: NSRect? = nil) -> BrowserWindowController {
        let frame = state.frame?.rect ?? fallbackFrame ?? frameForNewWindow()
        let controller = makeWindow(
            id: state.id,
            frame: BrowserWindowFrames.clamped(frame, to: placement.screens(), minSize: Self.windowMinSize)
        )
        controller.restoreTabs(state)
        if controller.tabs.isEmpty {
            controller.newTab(focusAddress: true)
        }
        return controller
    }

    // MARK: - Session

    /// Launch: every saved window (when Settings ▸ restore is on) with its
    /// frame on today's screens, or one new window; the recently-closed
    /// stack either way. Only each window's selected tab loads.
    func restoreSession() {
        let session = sessionStore.load()
        recentlyClosed = BrowserRecentlyClosedStack(session?.recentlyClosed ?? [])
        var restored: [Int: BrowserWindowController] = [:]
        if settingsStore.settings.restoreSession, let session {
            let legacyFrame = BrowserWindowFrames.autosavedFrame(defaults.string(forKey: Self.legacyFrameKey))
            for (index, state) in session.windows.enumerated() where !state.tabs.isEmpty {
                restored[index] = openWindow(state, fallbackFrame: legacyFrame ?? placement.defaultFrame())
            }
        }
        guard !restored.isEmpty else {
            newWindow()
            return
        }
        // The window that was in front ends up in front.
        let front = session?.activeWindowIndex.flatMap { restored[$0] }
        for controller in controllers where controller !== front {
            present(controller)
        }
        if let front {
            present(front)
        }
    }

    var currentSession: BrowserSession {
        let open = controllers.filter { !$0.tabs.isEmpty && !$0.isPopup }
        let active = activeController
        return BrowserSession(
            windows: open.map(\.windowState),
            activeWindowIndex: open.firstIndex { $0 === active },
            recentlyClosed: recentlyClosed.entries,
            savedAt: Date()
        )
    }

    /// Writes the session shortly, once for a burst of changes.
    func scheduleSessionSave() {
        guard persistsSession, saveTimer == nil else { return }
        let timer = Timer(timeInterval: Self.sessionSaveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSessionNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    /// Writes every window and the recently-closed stack now (quit).
    func saveSessionNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard persistsSession else { return }
        sessionStore.save(currentSession)
    }

    // MARK: - Recently closed

    /// ⇧⌘T: the most recently closed tab or window.
    func reopenMostRecent() {
        guard let entry = recentlyClosed.pop() else { return }
        reopen(entry)
    }

    /// History ▸ Recently Closed: one entry, wherever it is in the stack.
    func reopen(entryID: UUID) {
        guard let entry = recentlyClosed.remove(id: entryID) else { return }
        reopen(entry)
    }

    private func reopen(_ entry: BrowserClosedEntry) {
        let target = entry.reopenTarget(
            openWindowIDs: controllers.map(\.id),
            keyWindowID: activeController?.id
        )
        switch (target, entry.content) {
        case let (.window(id, index), .tab(state, _, _)):
            guard let controller = controllers.first(where: { $0.id == id }) else { return }
            controller.reopenTab(state, at: index)
            present(controller)
        case let (.newWindow, .window(state)):
            let controller = openWindow(state)
            present(controller)
        case let (.newWindow, .tab(state, _, _)):
            let controller = openWindow(BrowserWindowState(tabs: [state]))
            present(controller)
        case (.window, .window):
            return
        }
        scheduleSessionSave()
    }

    // MARK: - App-wide pieces

    /// Every tab's web view configuration: the default data store, autoplay
    /// and the start page. Nothing in it refers to a window.
    func makeTabConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = settingsStore.settings.autoplay.mediaTypesRequiringUserAction
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences = BrowserWindowController.makePreferences()
        configuration.applicationNameForUserAgent = BrowserUserAgent.applicationName
        configuration.setURLSchemeHandler(makeStartPageSchemeHandler(), forURLScheme: BrowserStartPageSchemeHandler.scheme)
        return configuration
    }

    func makeStartPageSchemeHandler() -> BrowserStartPageSchemeHandler {
        BrowserStartPageSchemeHandler { [weak self] in self?.startPageHTML() ?? "" }
    }

    func startPageHTML() -> String {
        BrowserStartPage.html(
            theme: themeManager.currentTheme,
            settings: settingsStore.settings,
            bookmarks: bookmarks.bookmarks,
            history: history.entries
        )
    }

    func showSettings() {
        let controller = settingsWindowController ?? {
            let controller = SettingsWindowController(settingsStore: settingsStore, themeManager: themeManager)
            controller.onShowWebsites = { [weak self] parent in self?.showWebsites(on: parent) }
            settingsWindowController = controller
            return controller
        }()
        guard !placement.isOffscreen else { return }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Settings ▸ Websites, as a sheet on Settings.
    func showWebsites(on parent: NSWindow) {
        let sheet = websitesSheet ?? BrowserWebsitesSheet(store: sitePermissions, theme: themeManager.currentTheme)
        websitesSheet = sheet
        sheet.apply(theme: themeManager.currentTheme)
        sheet.reload()
        guard let window = sheet.window, window.sheetParent == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.websitesSheet = nil
        }
    }

    /// Links from other apps: the most recently active window, or a new one
    /// when none is open. A lone start tab takes the first link.
    func open(_ urls: [URL]) {
        let files = urls.filter { url in
            guard url.isFileURL else { return true }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        guard !files.isEmpty else { return }
        let controller = tabbedController ?? newWindow()
        for (index, url) in files.enumerated() {
            if index == 0, controller.tabs.count == 1, let tab = controller.selectedTab, tab.isStartPage {
                controller.navigate(tab, to: url)
            } else {
                controller.newTab(url: url.absoluteString)
            }
        }
        present(controller)
        controller.focusPage()
    }

    /// A notification click: find the tab in any window, bring that window
    /// forward and let the page handle the click.
    private func openNotification(_ click: BrowserNotificationCenter.Click) {
        guard let (controller, tab) = tab(id: click.tabID) else { return }
        if !placement.isOffscreen {
            NSApp.activate()
        }
        present(controller)
        controller.openNotification(click, tab: tab)
    }

    private func applyTheme(of settings: BrowserSettings) {
        guard themeManager.themeId != settings.themeID || themeManager.appearance != settings.appearance else {
            return
        }
        themeManager.update(themeId: settings.themeID, appearance: settings.appearance)
    }
}
