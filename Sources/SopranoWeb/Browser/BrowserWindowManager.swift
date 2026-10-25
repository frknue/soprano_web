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
/// profiles, downloads, Settings, the recently-closed stack, Vimium's global
/// marks, notification clicks and the session file. The normal windows of
/// one profile share its `BrowserDataContext` (`context(for:)`); each
/// private window gets its own. `AppDelegate` (or the snapshot harness) owns
/// the one manager.
@MainActor
final class BrowserWindowManager {
    static let windowMinSize = NSSize(width: 760, height: 520)
    /// Stage 1's frame autosave name; a migrated window opens there.
    static let legacyFrameKey = "NSWindow Frame SopranoWebMainWindow"
    /// Session writes wait this long for more changes.
    static let sessionSaveDelay: TimeInterval = 0.5
    /// History's retention pass and frecency refresh repeat this often.
    static let historyMaintenanceInterval: TimeInterval = 86_400

    let themeManager: ThemeManager
    let settingsStore: BrowserSettingsStore
    let profiles: BrowserProfileStore
    /// The support folder: the Default profile's files, and `Profiles/<id>/`
    /// for the others.
    let supportDirectory: URL
    /// Every Space with its pins, and every profile's favorites.
    let spaces: BrowserSpaceStore
    let downloads: BrowserDownloadStore
    let downloadManager: BrowserDownloadManager
    let faviconStore: BrowserFaviconStore
    let sessionStore: BrowserSessionStore
    /// The Default profile's data: `WKWebsiteDataStore.default()`,
    /// `History.sqlite` and `site-permissions.json` in the support folder.
    let defaultContext: BrowserDataContext
    /// False in the harness: it may restore a session file but never writes.
    let persistsSession: Bool
    let placement: BrowserWindowPlacement
    let defaults: UserDefaults
    /// Expanded pin folders and ⌘D's last folder per Space, for every window.
    let pinUIState: BrowserPinUIState
    /// Theme changes for every window (`ThemeManager` has one callback).
    let themeChanges = BrowserObservers<AppTheme>()
    /// Puts idle tabs to sleep (Settings ▸ "Put inactive tabs to sleep",
    /// memory pressure).
    let tabSleeper = BrowserTabSleeper()
    /// Settings ▸ "Block ads and trackers": the compiled EasyList and
    /// EasyPrivacy lists every tab gets, in `<support>/ContentBlocking/`.
    let contentBlocker: BrowserContentBlocker

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
    /// The normal context of every profile but Default, made on first use.
    var profileContexts: [UUID: BrowserDataContext] = [:]
    /// Every profile's History, opened on first use (a window, the daily
    /// retention pass).
    var historyStores: [UUID: BrowserHistoryStore] = [:]
    /// Settings sheets: Websites, Website Data and Profiles.
    var websitesSheet: BrowserWebsitesSheet?
    var websiteDataSheet: BrowserWebsiteDataSheet?
    var profilesSheet: BrowserProfilesSheet?

    private var settingsWindowController: SettingsWindowController?
    private var saveTimer: Timer?
    private var observations: [BrowserObservation] = []
    private var historyMaintenanceTimer: Timer?
    private var appliedHistoryRetention: BrowserHistoryRetention?

    init(
        themeManager: ThemeManager,
        settingsStore: BrowserSettingsStore,
        profiles: BrowserProfileStore,
        supportDirectory: URL,
        spaces: BrowserSpaceStore,
        downloads: BrowserDownloadStore,
        faviconStore: BrowserFaviconStore,
        sessionStore: BrowserSessionStore,
        persistsSession: Bool = true,
        placement: BrowserWindowPlacement = .screen,
        defaults: UserDefaults = .standard,
        filterLists: [BrowserFilterListSource] = BrowserFilterListSource.defaults
    ) {
        self.themeManager = themeManager
        self.settingsStore = settingsStore
        self.profiles = profiles
        self.supportDirectory = supportDirectory
        self.spaces = spaces
        self.downloads = downloads
        self.downloadManager = BrowserDownloadManager(store: downloads, settingsStore: settingsStore)
        self.faviconStore = faviconStore
        self.sessionStore = sessionStore
        self.persistsSession = persistsSession
        self.placement = placement
        self.defaults = defaults
        self.pinUIState = BrowserPinUIState(defaults: defaults)
        let defaultHistory = BrowserHistoryStore(directory: supportDirectory)
        self.defaultContext = BrowserDataContext(
            kind: .normal,
            profileID: BrowserProfile.defaultID,
            websiteDataStore: .default(),
            history: defaultHistory,
            sitePermissions: BrowserSitePermissionStore(
                url: supportDirectory.appendingPathComponent("site-permissions.json")
            ),
            faviconStore: faviconStore,
            connectionSecurity: BrowserConnectionSecurity()
        )
        self.contentBlocker = BrowserContentBlocker(
            directory: supportDirectory.appendingPathComponent("ContentBlocking", isDirectory: true),
            sources: filterLists,
            isEnabled: settingsStore.settings.blockAdsAndTrackers
        )
        historyStores[BrowserProfile.defaultID] = defaultHistory
        themeManager.onThemeChanged = { [weak self] theme in
            self?.websitesSheet?.apply(theme: theme)
            self?.websiteDataSheet?.apply(theme: theme)
            self?.profilesSheet?.apply(theme: theme)
            self?.themeChanges.notify(theme)
        }
        // Every profile keeps a Space: a new profile gets one, a deleted
        // profile's go (`deleteProfile` also removes them first).
        spaces.reconcile(with: profiles.profiles)
        observations = [
            settingsStore.changes.observe { [weak self] settings in
                self?.applyTheme(of: settings)
                self?.applyHistoryRetention(settings.historyRetention)
                self?.contentBlocker.setEnabled(settings.blockAdsAndTrackers)
            },
            profiles.changes.observe { [weak self] in
                guard let self else { return }
                self.spaces.reconcile(with: self.profiles.profiles)
            },
        ]
        downloadManager.fallbackWindow = { [weak self] in self?.activeController?.window }
        BrowserNotificationCenter.shared.onClick = { [weak self] click in self?.openNotification(click) }
        startHistoryMaintenance()
        tabSleeper.start(manager: self)
        contentBlocker.start()
    }

    // MARK: - History retention

    /// Prunes every profile's History to Settings ▸ "Remove history items"
    /// and refreshes frecency now (off the main thread) and once a day.
    private func startHistoryMaintenance() {
        appliedHistoryRetention = settingsStore.settings.historyRetention
        runHistoryMaintenance(retention: settingsStore.settings.historyRetention)
        historyMaintenanceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.historyMaintenanceInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.runHistoryMaintenance(retention: self.settingsStore.settings.historyRetention)
            }
        }
    }

    private func applyHistoryRetention(_ retention: BrowserHistoryRetention) {
        guard retention != appliedHistoryRetention else { return }
        appliedHistoryRetention = retention
        runHistoryMaintenance(retention: retention)
    }

    private func runHistoryMaintenance(retention: BrowserHistoryRetention) {
        for profile in profiles.profiles {
            history(for: profile).runMaintenance(retention: retention)
        }
    }

    // MARK: - Windows

    /// The browser window that has keyboard focus.
    var keyController: BrowserWindowController? {
        controllers.first { $0.window?.isKeyWindow == true }
    }

    /// The key browser window, else the most recently active one: where
    /// menu commands go by default.
    var activeController: BrowserWindowController? {
        mostRecentlyActive { _ in true }
    }

    /// The window new tabs from menu commands go to: the active window
    /// unless it is a pop-up, else the most recently active window with
    /// tabs.
    var tabbedController: BrowserWindowController? {
        mostRecentlyActive { !$0.isPopup }
    }

    /// Where links from other apps and the CLI's new tabs go: the most
    /// recently active normal window with tabs (never a private window).
    var outsideTabbedController: BrowserWindowController? {
        mostRecentlyActive { !$0.isPopup && $0.kind.acceptsOutsideRequests }
    }

    /// The key window, else the most recently active one, that `matches`.
    func mostRecentlyActive(where matches: (BrowserWindowController) -> Bool) -> BrowserWindowController? {
        if let keyController, matches(keyController) { return keyController }
        for id in activationOrder.reversed() {
            if let controller = controllers.first(where: { $0.id == id }), matches(controller) {
                return controller
            }
        }
        return controllers.last(where: matches)
    }

    /// Where a pop-up window's new tabs and links go: the most recently
    /// active window with tabs whose current Space uses the pop-up's data
    /// context, else a new empty window of that context (on its profile's
    /// first Space; `isNew`: the caller adds the tab and presents it).
    func windowForNewTabs(from popup: BrowserWindowController) -> (window: BrowserWindowController, isNew: Bool) {
        let context = popup.dataContext
        if let window = mostRecentlyActive(where: { !$0.isPopup && $0.dataContext === context }) {
            return (window, false)
        }
        return (makeWindow(frame: frameForNewWindow(), context: context), true)
    }

    /// The windows the `browser` CLI sees, numbered 1…n in this order.
    var automationControllers: [BrowserWindowController] {
        controllers.filter { $0.kind.acceptsOutsideRequests }
    }

    /// The window the CLI acts on without `--window`.
    var automationActiveController: BrowserWindowController? {
        mostRecentlyActive { $0.kind.acceptsOutsideRequests }
    }

    /// 1-based, as `browser windows` lists them; nil for a private window.
    func number(of controller: BrowserWindowController) -> Int? {
        automationControllers.firstIndex { $0 === controller }.map { $0 + 1 }
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

    /// The profile new windows open in: the key (else most recently active)
    /// window's current Space's, Default when none is open.
    var activeProfileID: UUID {
        activeController?.profileID ?? BrowserProfile.defaultID
    }

    /// File ▸ New Window (⌘N): a start tab (or `url`), one step down and
    /// right of the key window. It shows `spaceID`, else the first Space of
    /// `profileID` (File ▸ New Window With Profile, `new-window
    /// --profile`), else the key window's current Space (a private or
    /// pop-up key window: its profile's first Space).
    @discardableResult
    func newWindow(url: String? = nil, profileID: UUID? = nil, spaceID: UUID? = nil) -> BrowserWindowController {
        let space = spaceID.flatMap(spaces.space(id:))
            ?? profileID.flatMap { spaces.firstSpace(ofProfile: profiles.resolvedID($0)) }
            ?? activeController?.currentSpaceID.flatMap(spaces.space(id:))
            ?? spaces.firstSpace(ofProfile: activeProfileID)
        let controller = makeWindow(
            frame: frameForNewWindow(),
            context: context(for: space?.profileID ?? profileID ?? activeProfileID),
            spaceID: space?.id
        )
        controller.newTab(url: url, focusAddress: url == nil)
        present(controller)
        scheduleSessionSave()
        return controller
    }

    /// File ▸ New Private Window (⇧⌘N): a window with its own
    /// non-persistent data store and a start tab (or `url`), over the
    /// profile of the window it was opened from (its current Space's;
    /// Default when none).
    @discardableResult
    func newPrivateWindow(url: String? = nil) -> BrowserWindowController {
        let base = context(for: activeProfileID)
        let controller = makeWindow(frame: frameForNewWindow(), context: .makePrivate(over: base))
        controller.newTab(url: url, focusAddress: url == nil)
        present(controller)
        return controller
    }

    /// Closes a window the way its close button does: its tabs go onto the
    /// recently-closed stack as one entry (an emptied window, a pop-up
    /// window and a private window go nowhere; `remember: false`, a deleted
    /// profile's window, neither).
    func closeWindow(_ controller: BrowserWindowController, remember: Bool = true) {
        windowClosing(controller, remember: remember)
        controller.window?.close()
    }

    /// The window is closing (close button, ⇧⌘W, its last tab,
    /// `close-window`, its tabs moved away, its profile deleted). Runs once
    /// per window; quitting keeps it in the session instead. The last window
    /// of a private data context takes the context's download rows with it.
    func windowClosing(_ controller: BrowserWindowController, remember: Bool = true) {
        guard !isTerminating, let index = controllers.firstIndex(where: { $0 === controller }) else { return }
        if remember, !controller.isPopup, controller.kind.usesAppRecentlyClosed, !controller.tabs.isEmpty {
            recentlyClosed.push(BrowserClosedEntry(.window(controller.windowState)))
        }
        controllers.remove(at: index)
        activationOrder.removeAll { $0 == controller.id }
        controller.tearDown()
        let context = controller.dataContext
        if let id = context.downloadContextID, !controllers.contains(where: { $0.dataContext === context }) {
            downloads.forgetPrivateContext(id)
        }
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

    /// A new, empty window at `frame` (session coordinates). A private
    /// `context` or a pop-up gets a window of that context without Spaces;
    /// otherwise the window shows Space `spaceID` (when it exists), else
    /// the first Space of `context`'s profile (nil: Default), and uses that
    /// Space's profile context. `activate` makes it the window commands go
    /// to by default.
    func makeWindow(
        id: UUID = UUID(),
        frame: NSRect,
        isPopup: Bool = false,
        context: BrowserDataContext? = nil,
        spaceID: UUID? = nil,
        activate: Bool = true
    ) -> BrowserWindowController {
        var windowContext = context ?? defaultContext
        var space: BrowserSpace?
        if !isPopup, !windowContext.kind.isPrivate {
            space = spaceID.flatMap(spaces.space(id:))
                ?? spaces.firstSpace(ofProfile: windowContext.profileID)
                ?? spaces.ensureSpace(forProfile: profiles.profile(id: windowContext.profileID) ?? .defaultProfile)
            if let space {
                windowContext = self.context(for: space.profileID)
            }
        }
        let controller = BrowserWindowController(
            manager: self,
            id: id,
            frame: frame.offsetBy(dx: placement.offset.x, dy: placement.offset.y),
            isPopup: isPopup,
            dataContext: windowContext,
            spaceID: space?.id
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

    /// Opens a saved window (restore or reopen) with its tabs, lazily, on
    /// its Space with each tab in its own (`placedInSpaces`; a version 2
    /// window's tabs join its profile's first Space, a profile that is gone
    /// counts as Default).
    @discardableResult
    private func openWindow(_ state: BrowserWindowState, fallbackFrame: NSRect? = nil) -> BrowserWindowController {
        var state = state
        state.profileID = profiles.resolvedID(state.profileID)
        state = state.placedInSpaces(spaces.list)
        let frame = state.frame?.rect ?? fallbackFrame ?? frameForNewWindow()
        let controller = makeWindow(
            id: state.id,
            frame: BrowserWindowFrames.clamped(frame, to: placement.screens(), minSize: Self.windowMinSize),
            context: context(for: state.profileID),
            spaceID: state.currentSpaceID
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

    /// Every normal window with tabs (pop-up and private windows are never
    /// saved) and the recently-closed stack.
    var currentSession: BrowserSession {
        let open = controllers.filter { !$0.tabs.isEmpty && !$0.isPopup && $0.kind.savesSession }
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

    /// Entries only ever go back into normal windows (every one holds every
    /// Space): a tab into its Space (the first Space of its profile when
    /// that one is gone; Default's when the profile is gone too), switching
    /// the window to it.
    private func reopen(_ entry: BrowserClosedEntry) {
        var entry = entry
        entry.profileID = profiles.resolvedID(entry.profileID)
        let candidates = mostRecentlyActiveFirst { !$0.isPopup && $0.kind.usesAppRecentlyClosed }
        let target = entry.reopenTarget(openWindows: candidates.map(\.id))
        switch (target, entry.content) {
        case let (.window(id, index), .tab(state, _, _)):
            guard let controller = controllers.first(where: { $0.id == id }) else { return }
            controller.reopenTab(placedInSpace(state, profileID: entry.profileID), at: index)
            present(controller)
        case let (.newWindow, .window(state)):
            let controller = openWindow(state)
            present(controller)
        case let (.newWindow, .tab(state, _, _)):
            let state = placedInSpace(state, profileID: entry.profileID)
            let controller = openWindow(BrowserWindowState(
                tabs: [state],
                profileID: entry.profileID,
                currentSpaceID: state.spaceID
            ))
            present(controller)
        case (.window, .window):
            return
        }
        scheduleSessionSave()
    }

    /// A closed tab's state with the Space it reopens in: its own while it
    /// exists, else the first Space of `profileID`.
    private func placedInSpace(_ state: BrowserTabState, profileID: UUID) -> BrowserTabState {
        var state = state
        state.spaceID = state.spaceID.flatMap(spaces.space(id:))?.id
            ?? spaces.firstSpace(ofProfile: profileID)?.id
        return state
    }

    /// The windows that `match`: the key one first, then by most recent
    /// activation.
    func mostRecentlyActiveFirst(where matches: (BrowserWindowController) -> Bool) -> [BrowserWindowController] {
        var ordered: [BrowserWindowController] = []
        if let keyController, matches(keyController) {
            ordered.append(keyController)
        }
        for id in activationOrder.reversed() {
            if let controller = controllers.first(where: { $0.id == id }), matches(controller),
               !ordered.contains(where: { $0 === controller })
            {
                ordered.append(controller)
            }
        }
        for controller in controllers.reversed() where matches(controller) && !ordered.contains(where: { $0 === controller }) {
            ordered.append(controller)
        }
        return ordered
    }

    // MARK: - App-wide pieces

    /// A tab's web view configuration for `context`: its data store,
    /// autoplay and the start page. Nothing in it refers to a window, so
    /// the tab can move into any window whose current Space uses `context`.
    func makeTabConfiguration(for context: BrowserDataContext) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = context.websiteDataStore
        configuration.mediaTypesRequiringUserActionForPlayback = settingsStore.settings.autoplay.mediaTypesRequiringUserAction
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences = BrowserWindowController.makePreferences()
        configuration.applicationNameForUserAgent = BrowserUserAgent.applicationName
        configuration.setURLSchemeHandler(
            makeStartPageSchemeHandler(),
            forURLScheme: BrowserStartPageSchemeHandler.scheme
        )
        return configuration
    }

    /// Serves each web view the start page of the tab it belongs to.
    func makeStartPageSchemeHandler() -> BrowserStartPageSchemeHandler {
        BrowserStartPageSchemeHandler { [weak self] webView in
            guard let self else { return "" }
            return self.startPageHTML(for: self.tab(forWebView: webView))
        }
    }

    /// The tab whose page `webView` is, in any window.
    func tab(forWebView webView: WKWebView) -> BrowserTab? {
        for controller in controllers {
            if let tab = controller.tab(for: webView) {
                return tab
            }
        }
        return nil
    }

    /// `tab`'s start page: the app theme, the pins of its Space (a private
    /// or pop-up tab's: its profile's first Space) and its profile's
    /// recent pages; a private tab's in Folio Ink without recent pages.
    func startPageHTML(for tab: BrowserTab?) -> String {
        let context = tab?.dataContext ?? defaultContext
        let kind = context.kind
        let space = tab?.spaceID.flatMap(spaces.space(id:)) ?? spaces.firstSpace(ofProfile: context.profileID)
        return BrowserStartPage.html(
            theme: kind.isPrivate ? .folioInk : themeManager.currentTheme,
            settings: settingsStore.settings,
            pins: space?.pinned ?? BrowserPinTree(),
            history: kind.suggestsHistory ? context.history.recentPages(limit: BrowserStartPage.recentLimit) : [],
            kind: kind
        )
    }

    func showSettings() {
        let controller = settingsWindowController ?? {
            let controller = SettingsWindowController(
                settingsStore: settingsStore,
                themeManager: themeManager,
                contentBlocker: contentBlocker
            )
            controller.onShowWebsites = { [weak self] parent in self?.showWebsites(on: parent) }
            controller.onShowWebsiteData = { [weak self] parent in self?.showWebsiteData(on: parent) }
            controller.onShowProfiles = { [weak self] parent in self?.showProfiles(on: parent) }
            settingsWindowController = controller
            return controller
        }()
        guard !placement.isOffscreen else { return }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Settings ▸ Websites, as a sheet on Settings, showing the active
    /// window's profile (a picker switches when there are several).
    func showWebsites(on parent: NSWindow) {
        let sheet = websitesSheet ?? makeWebsitesSheet()
        websitesSheet = sheet
        sheet.apply(theme: themeManager.currentTheme)
        sheet.reload()
        guard let window = sheet.window, window.sheetParent == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.websitesSheet = nil
        }
    }

    func makeWebsitesSheet(selected: UUID? = nil) -> BrowserWebsitesSheet {
        BrowserWebsitesSheet(
            picker: BrowserProfilePicker(
                profiles: profiles,
                selected: selected ?? activeProfileID,
                theme: themeManager.currentTheme
            ),
            theme: themeManager.currentTheme
        ) { [weak self] id in
            self?.context(for: id).sitePermissions
        }
    }

    /// Settings ▸ Website Data, as a sheet on Settings, showing the active
    /// window's profile (a picker switches when there are several).
    func showWebsiteData(on parent: NSWindow) {
        guard websiteDataSheet == nil else { return }
        let sheet = makeWebsiteDataSheet()
        websiteDataSheet = sheet
        sheet.present(on: parent) { [weak self] in
            self?.websiteDataSheet = nil
        }
    }

    func makeWebsiteDataSheet(selected: UUID? = nil) -> BrowserWebsiteDataSheet {
        BrowserWebsiteDataSheet(
            theme: themeManager.currentTheme,
            picker: BrowserProfilePicker(
                profiles: profiles,
                selected: selected ?? activeProfileID,
                theme: themeManager.currentTheme
            )
        ) { [weak self] id in
            self?.context(for: id).websiteDataStore
        }
    }

    /// Settings ▸ Profiles, as a sheet on Settings.
    func showProfiles(on parent: NSWindow) {
        let sheet = profilesSheet ?? makeProfilesSheet()
        profilesSheet = sheet
        guard let window = sheet.window, window.sheetParent == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.profilesSheet = nil
        }
    }

    func makeProfilesSheet() -> BrowserProfilesSheet {
        let sheet = BrowserProfilesSheet(profiles: profiles, theme: themeManager.currentTheme)
        sheet.windowCount = { [weak self] id in
            self?.windowsClosing(onDeleteOf: id).count ?? 0
        }
        sheet.onDelete = { [weak self] id in self?.deleteProfile(id) }
        return sheet
    }

    /// Links from other apps: the most recently active normal window, in
    /// its current Space, or a new one when none is open. A lone start tab
    /// takes the first link.
    func open(_ urls: [URL]) {
        let files = urls.filter { url in
            guard url.isFileURL else { return true }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        guard !files.isEmpty else { return }
        let controller = outsideTabbedController ?? newWindow()
        for (index, url) in files.enumerated() {
            if index == 0, controller.visibleTabs.count == 1, let tab = controller.selectedTab, tab.isStartPage {
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
