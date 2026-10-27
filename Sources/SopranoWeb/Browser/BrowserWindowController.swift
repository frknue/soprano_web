import AppKit
import WebKit

/// One browser window and its tabs. App-wide pieces (stores, downloads,
/// Settings, the recently-closed stack) live on `manager`; each tab's
/// profile data on its own `BrowserTab.dataContext`; the current Space's
/// on `dataContext`; this keeps per-window state only.
@MainActor
final class BrowserWindowController: NSWindowController {
    unowned let manager: BrowserWindowManager
    /// Stable for the window's life and across relaunches (session `id`).
    let id: UUID
    /// A page's `window.open` with a size: one tab, compact chrome (no tab
    /// list, read-only address), never saved in the session.
    let isPopup: Bool
    /// What the window-level chrome reads (sidebar History, address
    /// suggestions, Clear Browsing Data, the mark) and what new tabs use:
    /// the current Space's profile context. A private or pop-up window's
    /// is fixed, shared with every window a tab may move to; a private
    /// window's own context dies with the last window that uses it.
    private(set) var dataContext: BrowserDataContext
    /// The Space the window shows (`switchToSpace`); nil for private and
    /// pop-up windows, which have no Spaces.
    private(set) var currentSpaceID: UUID?

    /// Every live tab of the window, of every Space, in window order (what
    /// the session saves, sleep, content blocking and closing iterate).
    var tabs: [BrowserTab] = [] {
        didSet { refreshVisibleTabs() }
    }
    /// The current Space's tabs, in window order: what the tab strip and
    /// rail show and every index-based command counts (⌘1…⌘9, Vimium,
    /// the CLI's tab numbers). All tabs in a window without Spaces.
    private(set) var visibleTabs: [BrowserTab] = []
    /// Index of the selected tab in `visibleTabs`.
    var selectedIndex = 0
    /// Each Space's selected tab, kept while the window shows another
    /// Space.
    var spaceSelections: [UUID: UUID] = [:]
    var isSidebarVisible = false
    var sidebarSection: BrowserSidebarSection = .history
    var findQuery = ""
    var staleStartTabs: Set<UUID> = []
    /// A private window's closed tabs, in memory only (⇧⌘T in the window
    /// reopens them). Normal windows use the manager's stack.
    var closedTabs = BrowserRecentlyClosedStack()
    /// HTTP sign-in sheets waiting on this window.
    let credentialPrompts = BrowserCredentialPrompts()
    let permissionsState = BrowserPermissionsState()
    /// Store, theme and settings subscriptions; cancelled when the window
    /// closes.
    private var storeObservations: [BrowserObservation] = []
    /// The History, site decisions and favicons of every data context the
    /// window's tabs (and its current Space) use, by context id.
    private var contextObservations: [UUID: [BrowserObservation]] = [:]

    private(set) var theme: AppTheme
    private var usesVerticalTabs: Bool
    private var isVerticalSidebarCollapsed: Bool
    private var lastSearchEngine: BrowserSearchEngine
    let verticalTabsView: BrowserVerticalTabsView
    let rootView = NSView()
    private let topBar = NSView()
    let toolbar: BrowserToolbarView
    let tabStrip: BrowserTabStripView
    let findBar: BrowserFindBar
    let sidebar: BrowserSidebarView
    let webArea = NSView()
    let linkStatus = BrowserLinkStatusView()
    private let hairline: ChromeRuleView
    let sidebarDivider: ChromeRuleView
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var findBarHeightConstraint: NSLayoutConstraint!
    private(set) var webTrailingToRoot: NSLayoutConstraint!
    private(set) var webTrailingToSidebar: NSLayoutConstraint!
    private var topBarHeight: NSLayoutConstraint!
    private var tabStripHeight: NSLayoutConstraint!
    private var topBarLeadingToRoot: NSLayoutConstraint!
    private var topBarLeadingToSidebar: NSLayoutConstraint!
    private var toolbarLeading: NSLayoutConstraint!
    private var webLeadingToRoot: NSLayoutConstraint!
    private var webLeadingToSidebar: NSLayoutConstraint!

    lazy var palette = CommandPalettePanel(themeManager: themeManager)
    lazy var addressBar = BrowserAddressBarController(toolbar: toolbar, theme: theme)

    var previousSelectedTabID: UUID?
    var lastFindQuery = ""
    var vimiumFindActive = false
    lazy var vimiumPromptPanel = VimiumPromptPanel(theme: theme)
    lazy var vimiumTextPanel = VimiumTextPanel(theme: theme)
    /// ⌘D's popover and the rail's pin editor.
    lazy var bookmarkEditorPanel = BrowserPinEditorPanel()
    /// The open folder preview beside the rail, and its pending close.
    var folderPreview: BrowserPinFolderPreview?
    var folderPreviewHideTimer: Timer?
    /// The New Space / Edit Space sheet while it is open.
    var spaceSheet: BrowserSpaceSheet?
    var vimiumToastView: NSView?
    var popupBlockedControl: ChromeButton?
    /// The address field's zoom percentage (`updateZoomChip`).
    var zoomChip: ChromeButton?

    static let verticalSidebarCollapsedKey = "verticalSidebarCollapsed"

    /// An empty window at `frame` (screen coordinates the window really
    /// uses) showing Space `spaceID` (a normal window; `dataContext` is that
    /// Space's profile context) or, without one, a private or pop-up
    /// window of `dataContext`; the manager adds its tabs. Create windows
    /// through `BrowserWindowManager`.
    init(
        manager: BrowserWindowManager,
        id: UUID = UUID(),
        frame: NSRect,
        isPopup: Bool = false,
        dataContext: BrowserDataContext,
        spaceID: UUID?
    ) {
        self.manager = manager
        self.id = id
        self.isPopup = isPopup
        self.dataContext = dataContext
        self.currentSpaceID = isPopup || dataContext.kind.isPrivate ? nil : spaceID
        let themeManager = manager.themeManager
        let settings = manager.settingsStore.settings
        let theme = Self.theme(for: dataContext.kind, appTheme: themeManager.currentTheme)
        self.theme = theme
        self.usesVerticalTabs = settings.usesVerticalTabs
        self.isVerticalSidebarCollapsed = manager.defaults.bool(
            forKey: Self.verticalSidebarCollapsedKey
        )
        self.lastSearchEngine = settings.defaultSearchEngine
        self.verticalTabsView = BrowserVerticalTabsView(theme: theme)
        self.toolbar = BrowserToolbarView(theme: theme)
        self.tabStrip = BrowserTabStripView(theme: theme)
        self.findBar = BrowserFindBar(theme: theme)
        self.sidebar = BrowserSidebarView(
            theme: theme,
            history: dataContext.history,
            downloads: manager.downloads
        )
        self.hairline = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        self.sidebarDivider = ChromeRuleView(axis: .vertical, color: theme.colors.borderSubtle)
        let window = BrowserWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.allowsOffscreenFrame = manager.placement.isOffscreen
        super.init(window: window)

        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 520)
        window.backgroundColor = theme.colors.bgBase
        window.title = kind.windowTitle("New Tab")
        if kind.isPrivate {
            // Sheets, menus and the title bar follow Ink too, whatever the
            // app's appearance.
            window.appearance = theme.appearance.nsAppearance
        }
        window.setFrame(frame, display: false)

        rootView.wantsLayer = true
        window.contentView = rootView
        buildLayout()
        wireCallbacks()
        installTabChrome()
        installAddressBar()
        sidebar.privateDownloadContextID = dataContext.downloadContextID
        syncContextObservations()
        applyWindowMark()
        applyTheme(theme)
        applyTabsLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // App-wide stores, owned by the manager.
    var themeManager: ThemeManager { manager.themeManager }
    var settingsStore: BrowserSettingsStore { manager.settingsStore }
    var spaces: BrowserSpaceStore { manager.spaces }
    var downloads: BrowserDownloadStore { manager.downloads }
    private var defaults: UserDefaults { manager.defaults }

    // The current Space's data (a private or pop-up window's own), owned by
    // its data context. Per-tab work uses `BrowserTab.dataContext`.
    var kind: BrowserWindowKind { dataContext.kind }
    /// The current Space's profile (a private window's: the one it was
    /// opened over).
    var profileID: UUID { dataContext.profileID }

    /// Whether the window shows Spaces (a normal window that is not a
    /// pop-up).
    var hasSpaces: Bool { currentSpaceID != nil }

    /// The Space whose pins the window's pin surfaces (⌘D, the sidebar's
    /// outline, the Spaces menu, Vimium `b`, address suggestions) read and
    /// write: the current Space; a private or pop-up window's profile's
    /// first Space.
    var pinSpaceID: UUID? {
        currentSpaceID ?? spaces.firstSpace(ofProfile: profileID)?.id
    }

    /// The pin Space's pinned tree; empty without one.
    var currentPinTree: BrowserPinTree {
        pinSpaceID.map(spaces.pinTree(inSpace:)) ?? BrowserPinTree()
    }

    /// This window as `BrowserTabMoveRule` sees it.
    var moveRuleWindow: BrowserTabMoveRule.Window {
        BrowserTabMoveRule.Window(id: id, context: dataContext.id, isPopup: isPopup, hasSpaces: hasSpaces)
    }

    /// A private window always uses Folio Ink; a normal window the app's
    /// theme.
    static func theme(for kind: BrowserWindowKind, appTheme: AppTheme) -> AppTheme {
        kind.isPrivate ? .folioInk : appTheme
    }

    var selectedTab: BrowserTab? {
        guard visibleTabs.indices.contains(selectedIndex) else { return visibleTabs.first }
        return visibleTabs[selectedIndex]
    }

    /// Recomputes `visibleTabs` (the current Space's tabs: favorite tabs,
    /// then pinned tabs, then Today tabs; `BrowserPinLinks.order`) and keeps
    /// `selectedIndex` on the same tab. Runs when `tabs` changes, and when a
    /// tab's link, its Space or the pins and favorites change.
    func refreshVisibleTabs() {
        let selectedID = visibleTabs.indices.contains(selectedIndex) ? visibleTabs[selectedIndex].id : nil
        let spaceTabs = tabs.filter { $0.spaceID == currentSpaceID }
        if let spaceID = currentSpaceID, spaceTabs.contains(where: { $0.origin != .today }) {
            let byID = Dictionary(spaceTabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            visibleTabs = BrowserPinLinks.order(
                spaceTabs.map { (id: $0.id, origin: $0.origin) },
                favorites: spaces.favorites(ofProfile: profileID).map(\.id),
                pins: spaces.pins(inSpace: spaceID).map(\.id)
            ).compactMap { byID[$0] }
        } else {
            visibleTabs = spaceTabs
        }
        if let selectedID, let index = visibleTabs.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        }
    }

    /// Makes `space` the current Space: the window's data context becomes
    /// its profile's, the visible tabs its tabs, and the window-level
    /// chrome (sidebar History, mark) follows. The caller selects a tab.
    func setCurrentSpace(_ space: BrowserSpace) {
        guard hasSpaces else { return }
        let context = manager.context(for: space.profileID)
        let contextChanged = context !== dataContext
        currentSpaceID = space.id
        dataContext = context
        refreshVisibleTabs()
        selectedIndex = 0
        syncContextObservations()
        if contextChanged {
            sidebar.history = context.history
            addressBar.close()
        }
        applyWindowMark()
    }

    /// Observes the History, site decisions and favicons of every data
    /// context the tabs and the current Space use, and stops observing the
    /// ones no longer used. Runs when tabs come and go and on a Space
    /// switch.
    func syncContextObservations() {
        var used: [UUID: BrowserDataContext] = [dataContext.id: dataContext]
        for tab in tabs {
            used[tab.dataContext.id] = tab.dataContext
        }
        for id in contextObservations.keys where used[id] == nil {
            contextObservations.removeValue(forKey: id)?.forEach { $0.cancel() }
        }
        for (id, context) in used where contextObservations[id] == nil {
            contextObservations[id] = [
                context.history.changes.observe { [weak self, weak context] in
                    guard let self, let context else { return }
                    // The list queries the database; a hidden one reloads
                    // when shown.
                    if context === self.dataContext, self.isSidebarVisible, self.sidebar.section == .history {
                        self.sidebar.refresh()
                    }
                    self.markStartPagesStale()
                },
                context.faviconStore.changes.observe { [weak self, weak context] in
                    guard let self, let context, context === self.dataContext else { return }
                    // Pins and favorites without a live tab show the
                    // cached favicon.
                    self.updateRail()
                    if self.isSidebarVisible {
                        self.sidebar.redisplayRows()
                    }
                },
                // Each tab reads its own context's decisions, so every tab
                // re-reads; only tabs whose state changed reload.
                context.sitePermissions.changes.observe { [weak self] in self?.sitePermissionsChanged() },
            ]
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        verticalTabsView.isHidden = true
        rootView.addSubview(verticalTabsView)

        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.wantsLayer = true
        rootView.addSubview(topBar)

        webArea.translatesAutoresizingMaskIntoConstraints = false
        webArea.wantsLayer = true
        rootView.addSubview(webArea)

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.isHidden = true
        rootView.addSubview(sidebar)

        sidebarDivider.isHidden = true
        rootView.addSubview(sidebarDivider)

        topBar.addSubview(tabStrip)
        topBar.addSubview(toolbar)
        topBar.addSubview(hairline)

        findBar.isHidden = true
        webArea.addSubview(findBar)

        NSLayoutConstraint.activate([
            verticalTabsView.topAnchor.constraint(equalTo: rootView.topAnchor),
            verticalTabsView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            verticalTabsView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            verticalTabsView.widthAnchor.constraint(equalToConstant: BrowserVerticalTabsView.preferredWidth),

            topBar.topAnchor.constraint(equalTo: rootView.topAnchor),
            topBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),

            tabStrip.topAnchor.constraint(equalTo: topBar.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),

            toolbar.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            toolbar.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: BrowserToolbarView.preferredHeight),

            hairline.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: Chrome.hairline),

            webArea.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            webArea.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            sidebar.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            sidebar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            sidebarDivider.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            sidebarDivider.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarDivider.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            sidebarDivider.widthAnchor.constraint(equalToConstant: Chrome.hairline),

            findBar.topAnchor.constraint(equalTo: webArea.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: webArea.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: webArea.trailingAnchor),
        ])

        sidebarWidthConstraint = sidebar.widthAnchor.constraint(equalToConstant: 300)
        sidebarWidthConstraint.isActive = true
        findBarHeightConstraint = findBar.heightAnchor.constraint(equalToConstant: BrowserFindBar.preferredHeight)
        findBarHeightConstraint.isActive = true

        webTrailingToRoot = webArea.trailingAnchor.constraint(equalTo: rootView.trailingAnchor)
        webTrailingToSidebar = webArea.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor)
        webTrailingToRoot.isActive = true

        topBarHeight = topBar.heightAnchor.constraint(equalToConstant: 86)
        topBarHeight.isActive = true
        tabStripHeight = tabStrip.heightAnchor.constraint(equalToConstant: BrowserTabStripView.preferredHeight)
        tabStripHeight.isActive = true

        topBarLeadingToRoot = topBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor)
        topBarLeadingToSidebar = topBar.leadingAnchor.constraint(equalTo: verticalTabsView.trailingAnchor)
        topBarLeadingToRoot.isActive = true

        toolbarLeading = toolbar.leadingAnchor.constraint(equalTo: topBar.leadingAnchor)
        toolbarLeading.isActive = true

        webLeadingToRoot = webArea.leadingAnchor.constraint(equalTo: rootView.leadingAnchor)
        webLeadingToSidebar = webArea.leadingAnchor.constraint(equalTo: verticalTabsView.trailingAnchor)
        webLeadingToRoot.isActive = true
    }

    private func applyTabsLayout() {
        let compact = isPopup
        let vertical = usesVerticalTabs && !compact
        let collapsed = vertical && isVerticalSidebarCollapsed
        let railShown = vertical && !collapsed
        let stripShown = !vertical && !compact
        verticalTabsView.isHidden = !railShown
        tabStrip.isHidden = !stripShown
        tabStripHeight.constant = stripShown ? BrowserTabStripView.preferredHeight : 0
        topBarHeight.constant = stripShown
            ? BrowserToolbarView.preferredHeight + BrowserTabStripView.preferredHeight
            : BrowserToolbarView.preferredHeight

        topBarLeadingToRoot.isActive = !railShown
        topBarLeadingToSidebar.isActive = railShown
        webLeadingToRoot.isActive = !railShown
        webLeadingToSidebar.isActive = railShown
        // The traffic lights own the top-left corner; without a rail or a
        // strip above it they sit over a 76 pt strip and the toolbar starts
        // after it.
        toolbarLeading.constant = collapsed || compact ? 76 : 0

        toolbar.setVerticalTabsToggle(railShown)
        toolbar.setCompact(compact)
        // The window's mark ("Private", its profile, or both) sits in the
        // rail header, or next to the address field when there is no rail.
        toolbar.setWindowMarkShown(!railShown)
        updateTabStrip()
        updateWindowMinSize()
        viewNeedsLayout()
    }

    func updateWindowMinSize() {
        if isPopup {
            window?.minSize = BrowserPopupWindowFrame.minimumWindowSize(chromeHeight: BrowserToolbarView.preferredHeight)
            return
        }
        let rail = usesVerticalTabs && !isVerticalSidebarCollapsed
            ? BrowserVerticalTabsView.preferredWidth
            : 0
        let rightSidebar: CGFloat = isSidebarVisible ? 300 : 0
        let width = max(760, 400 + rail + rightSidebar)
        window?.minSize = NSSize(width: width, height: 520)
        if let window, window.frame.width < width {
            var frame = window.frame
            frame.size.width = width
            window.setFrame(frame, display: true)
        }
    }

    private func wireCallbacks() {
        tabStrip.onSelect = { [weak self] id in self?.selectTab(id: id, focus: true) }
        tabStrip.onClose = { [weak self] id in self?.closeTab(id: id) }
        tabStrip.onNewTab = { [weak self] in self?.newTab(focusAddress: true) }
        verticalTabsView.onSelect = { [weak self] id in self?.selectTab(id: id, focus: true) }
        verticalTabsView.onClose = { [weak self] id in self?.closeTab(id: id) }
        verticalTabsView.onNewTab = { [weak self] in self?.newTab(focusAddress: true) }
        verticalTabsView.onSwipeSpace = { [weak self] step in self?.switchToNeighborSpace(step: step) }
        toolbar.onToggleVerticalSidebar = { [weak self] in self?.toggleVerticalSidebar() }

        toolbar.onSubmit = { [weak self] value in self?.submitAddress(value) }
        toolbar.onBookmark = { [weak self] in self?.starPressed() }
        toolbar.onDownloads = { [weak self] in self?.toggleSidebar(section: .downloads) }
        toolbar.onSecurityInfo = { [weak self] in self?.showConnectionInfo() }
        toolbar.onSidebar = { [weak self] in
            guard let self else { return }
            self.toggleSidebar(section: self.sidebarSection)
        }

        findBar.onQueryChanged = { [weak self] query in
            self?.findQuery = query
            self?.lastFindQuery = query
            self?.performFind(backwards: false, updateResult: true)
        }
        findBar.onNext = { [weak self] in self?.findNext() }
        findBar.onPrevious = { [weak self] in self?.findPrevious() }
        findBar.onClose = { [weak self] in self?.hideFindBar() }

        sidebar.onOpenURL = { [weak self] url in self?.navigateCurrent(to: url) }
        sidebar.onOpenFile = { [weak self] path in self?.openFile(path) }
        sidebar.onRevealFile = { [weak self] path in self?.revealFile(path) }
        sidebar.onRemoveHistory = { [weak self] url in self?.dataContext.history.removePage(url: url) }
        wireRail()
        sidebar.onRemoveDownload = { [weak self] id in self?.downloads.remove(id: id) }
        sidebar.onCancelDownload = { [weak self] id in self?.cancelDownload(id: id) }
        sidebar.onResumeDownload = { [weak self] id in self?.resumeDownload(id: id) }
        sidebar.onRetryDownload = { [weak self] id in self?.retryDownload(id: id) }
        sidebar.onClear = { [weak self] section in self?.clear(section) }
        sidebar.onClose = { [weak self] in self?.hideSidebar() }

        storeObservations = [
            spaces.changes.observe { [weak self] in
                // A deleted Space's tabs close, a window on it moves on;
                // a deleted pin's live tab becomes a Today tab.
                self?.spacesChanged()
                self?.refreshVisibleTabs()
                self?.markStartPagesStale()
                self?.applyWindowMark()
                self?.updateTabStrip()
                self?.updateChrome()
            },
            downloads.changes.observe { [weak self] in self?.sidebar.refresh() },
            manager.profiles.changes.observe { [weak self] in self?.applyWindowMark() },
            manager.themeChanges.observe { [weak self] theme in
                // A private window keeps Folio Ink.
                guard let self, !self.kind.isPrivate else { return }
                self.applyTheme(theme)
            },
            settingsStore.changes.observe { [weak self] settings in self?.applySettings(settings) },
            // Settings ▸ Block ads and trackers, or new lists: new loads
            // follow; nothing reloads.
            manager.contentBlocker.changes.observe { [weak self] in
                self?.applyContentBlockingToTabs(reloadingChanged: false)
            },
        ]
        setUpPermissions()
    }

    /// Stops the store, theme and settings subscriptions (window closed).
    func cancelStoreObservations() {
        storeObservations.forEach { $0.cancel() }
        storeObservations.removeAll()
        contextObservations.values.forEach { $0.forEach { $0.cancel() } }
        contextObservations.removeAll()
    }

    /// Shows "Private", the current Space (when there are several), its
    /// profile, or both next to the address field; the rail header always
    /// shows the current Space (`railMark`).
    func applyWindowMark() {
        let mark = manager.windowMark(for: self)
        verticalTabsView.setMark(railMark)
        toolbar.setWindowMark(mark)
        viewNeedsLayout()
    }

    func viewNeedsLayout() {
        rootView.needsLayout = true
        rootView.layoutSubtreeIfNeeded()
    }

    // MARK: - Settings and theme

    /// Shows the window when it is minimized or hidden; never in the harness.
    func revealWindowIfNeeded() {
        guard let window, !window.isVisible else { return }
        manager.present(self)
    }

    func toggleVerticalSidebar() {
        if !usesVerticalTabs {
            settingsStore.update { $0.verticalTabs = true }
            usesVerticalTabs = settingsStore.settings.usesVerticalTabs
            isVerticalSidebarCollapsed = false
        } else {
            isVerticalSidebarCollapsed.toggle()
        }
        defaults.set(isVerticalSidebarCollapsed, forKey: Self.verticalSidebarCollapsedKey)
        applyTabsLayout()
    }

    /// ⌥⌘B Show Pinned Tabs: the rail (vertical tabs on, not collapsed).
    func showRail() {
        guard usesVerticalTabs, !isVerticalSidebarCollapsed else {
            toggleVerticalSidebar()
            return
        }
    }

    func showSettings() {
        manager.showSettings()
    }

    private func applySettings(_ settings: BrowserSettings) {
        refreshPermissionStates()
        // Settings ▸ Default page zoom: sites without their own zoom follow.
        applySiteZooms()
        let searchChanged = lastSearchEngine != settings.defaultSearchEngine
        lastSearchEngine = settings.defaultSearchEngine
        if searchChanged {
            for tab in tabs where tab.isStartPage {
                staleStartTabs.insert(tab.id)
            }
            if let tab = selectedTab, tab.isStartPage, staleStartTabs.remove(tab.id) != nil {
                loadStartPage(tab)
            }
        }

        let wantsVertical = settings.usesVerticalTabs
        if usesVerticalTabs != wantsVertical {
            usesVerticalTabs = wantsVertical
            if !wantsVertical, isVerticalSidebarCollapsed {
                isVerticalSidebarCollapsed = false
                defaults.set(false, forKey: Self.verticalSidebarCollapsedKey)
            }
            applyTabsLayout()
        }
        updateChrome()
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        rootView.layer?.backgroundColor = theme.colors.bgBase.cgColor
        topBar.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        webArea.layer?.backgroundColor = theme.colors.bgBase.cgColor
        hairline.color = theme.colors.borderSubtle
        sidebarDivider.color = theme.colors.borderSubtle
        window?.backgroundColor = theme.colors.bgBase
        tabStrip.apply(theme: theme)
        verticalTabsView.apply(theme: theme)
        toolbar.apply(theme: theme)
        addressBar.apply(theme: theme)
        findBar.apply(theme: theme)
        sidebar.apply(theme: theme)
        linkStatus.apply(theme: theme)
        // A sleeping start page builds with the new theme when it wakes.
        for tab in tabs where tab.isStartPage && !tab.isRestorePending {
            loadStartPage(tab)
        }
        updateChrome()
    }
}
