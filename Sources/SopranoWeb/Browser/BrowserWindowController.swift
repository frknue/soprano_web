import AppKit
import WebKit

/// One browser window and its tabs. App-wide pieces (stores, downloads,
/// Settings, the recently-closed stack) live on `manager`; the window's data
/// store, site decisions, favicons and connection decisions on `dataContext`;
/// this keeps per-window state only.
@MainActor
final class BrowserWindowController: NSWindowController {
    unowned let manager: BrowserWindowManager
    /// Stable for the window's life and across relaunches (session `id`).
    let id: UUID
    /// A page's `window.open` with a size: one tab, compact chrome (no tab
    /// list, read-only address), never saved in the session.
    let isPopup: Bool
    /// What this window's tabs read and write; shared with every window a
    /// tab may move to. A private window's own context dies with the last
    /// window that uses it.
    let dataContext: BrowserDataContext

    var tabs: [BrowserTab] = []
    var selectedIndex = 0
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

    private(set) var theme: AppTheme
    private var usesVerticalTabs: Bool
    private var isVerticalSidebarCollapsed: Bool
    private var lastSearchEngine: SearchEngine
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
    var vimiumToastView: NSView?
    var popupBlockedControl: ChromeButton?

    static let verticalSidebarCollapsedKey = "verticalSidebarCollapsed"

    /// An empty window at `frame` (screen coordinates the window really
    /// uses) whose tabs use `dataContext`; the manager adds its tabs. Create
    /// windows through `BrowserWindowManager`.
    init(
        manager: BrowserWindowManager,
        id: UUID = UUID(),
        frame: NSRect,
        isPopup: Bool = false,
        dataContext: BrowserDataContext
    ) {
        self.manager = manager
        self.id = id
        self.isPopup = isPopup
        self.dataContext = dataContext
        let themeManager = manager.themeManager
        let settings = manager.settingsStore.settings
        let theme = Self.theme(for: dataContext.kind, appTheme: themeManager.currentTheme)
        self.theme = theme
        self.usesVerticalTabs = settings.usesVerticalTabs
        self.isVerticalSidebarCollapsed = manager.defaults.bool(
            forKey: Self.verticalSidebarCollapsedKey
        )
        self.lastSearchEngine = settings.searchEngine
        self.verticalTabsView = BrowserVerticalTabsView(theme: theme)
        self.toolbar = BrowserToolbarView(theme: theme)
        self.tabStrip = BrowserTabStripView(theme: theme)
        self.findBar = BrowserFindBar(theme: theme)
        self.sidebar = BrowserSidebarView(
            theme: theme,
            history: manager.history,
            bookmarks: manager.bookmarks,
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
        verticalTabsView.setPrivate(kind.isPrivate)
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
    var history: BrowserHistoryStore { manager.history }
    var bookmarks: BrowserBookmarkStore { manager.bookmarks }
    var downloads: BrowserDownloadStore { manager.downloads }
    private var defaults: UserDefaults { manager.defaults }

    // This window's data, owned by its data context.
    var kind: BrowserWindowKind { dataContext.kind }
    var sitePermissions: BrowserSitePermissionStore { dataContext.sitePermissions }
    var faviconStore: BrowserFaviconStore { dataContext.faviconStore }
    var connectionSecurity: BrowserConnectionSecurity { dataContext.connectionSecurity }

    /// This window as `BrowserTabMoveRule` sees it.
    var moveRuleWindow: BrowserTabMoveRule.Window {
        BrowserTabMoveRule.Window(id: id, context: dataContext.id, isPopup: isPopup)
    }

    /// A private window always uses Folio Ink; a normal window the app's
    /// theme.
    static func theme(for kind: BrowserWindowKind, appTheme: AppTheme) -> AppTheme {
        kind.isPrivate ? .folioInk : appTheme
    }

    var selectedTab: BrowserTab? {
        guard tabs.indices.contains(selectedIndex) else { return tabs.first }
        return tabs[selectedIndex]
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
        // A private window's mark sits in the rail header, or next to the
        // address field when there is no rail.
        toolbar.setPrivateMark(kind.isPrivate && !railShown)
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
        toolbar.onToggleVerticalSidebar = { [weak self] in self?.toggleVerticalSidebar() }

        toolbar.onSubmit = { [weak self] value in self?.submitAddress(value) }
        toolbar.onBookmark = { [weak self] in self?.toggleBookmark() }
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
        sidebar.onRemoveHistory = { [weak self] id in self?.history.remove(id: id) }
        sidebar.onRemoveBookmark = { [weak self] id in self?.bookmarks.remove(id: id) }
        sidebar.onRemoveDownload = { [weak self] id in self?.downloads.remove(id: id) }
        sidebar.onCancelDownload = { [weak self] id in self?.cancelDownload(id: id) }
        sidebar.onResumeDownload = { [weak self] id in self?.resumeDownload(id: id) }
        sidebar.onRetryDownload = { [weak self] id in self?.retryDownload(id: id) }
        sidebar.onClear = { [weak self] section in self?.clear(section) }
        sidebar.onClose = { [weak self] in self?.hideSidebar() }

        storeObservations = [
            history.changes.observe { [weak self] in
                self?.sidebar.refresh()
                self?.markStartPagesStale()
            },
            bookmarks.changes.observe { [weak self] in
                self?.sidebar.refresh()
                self?.markStartPagesStale()
                self?.updateChrome()
            },
            downloads.changes.observe { [weak self] in self?.sidebar.refresh() },
            faviconStore.changes.observe { [weak self] in
                guard let self, self.isSidebarVisible else { return }
                self.sidebar.refresh()
            },
            sitePermissions.changes.observe { [weak self] in self?.sitePermissionsChanged() },
            manager.themeChanges.observe { [weak self] theme in
                // A private window keeps Folio Ink.
                guard let self, !self.kind.isPrivate else { return }
                self.applyTheme(theme)
            },
            settingsStore.changes.observe { [weak self] settings in self?.applySettings(settings) },
        ]
        setUpPermissions()
    }

    /// Stops the store, theme and settings subscriptions (window closed).
    func cancelStoreObservations() {
        storeObservations.forEach { $0.cancel() }
        storeObservations.removeAll()
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

    func showSettings() {
        manager.showSettings()
    }

    private func applySettings(_ settings: BrowserSettings) {
        refreshPermissionStates()
        let searchChanged = lastSearchEngine != settings.searchEngine
        lastSearchEngine = settings.searchEngine
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
        for tab in tabs where tab.isStartPage {
            loadStartPage(tab)
        }
        updateChrome()
    }
}
