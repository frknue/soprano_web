import AppKit
import WebKit

@MainActor
final class BrowserWindowController: NSWindowController {
    let themeManager: ThemeManager
    let settingsStore: BrowserSettingsStore
    let history: BrowserHistoryStore
    let bookmarks: BrowserBookmarkStore
    let downloads: BrowserDownloadStore
    let sitePermissions: BrowserSitePermissionStore
    let sessionStore: BrowserSessionStore
    let persistsSession: Bool

    var tabs: [BrowserTab] = []
    var selectedIndex = 0
    var closedTabs: [BrowserTabState] = []
    var downloadsByRecord: [UUID: WKDownload] = [:]
    var progressTimer: Timer?
    var loadWaiters: [UUID: LoadWaiter] = [:]
    var recordsByDownload: [ObjectIdentifier: UUID] = [:]
    var destinationsByDownload: [ObjectIdentifier: URL] = [:]
    var isSidebarVisible = false
    var sidebarSection: BrowserSidebarSection = .history
    var findQuery = ""
    var staleStartTabs: Set<UUID> = []
    let connectionSecurity = BrowserConnectionSecurity()
    private var settingsWindowController: SettingsWindowController?

    private(set) var theme: AppTheme
    private var usesVerticalTabs: Bool
    private var isVerticalSidebarCollapsed: Bool
    private var lastSearchEngine: SearchEngine
    private let defaults: UserDefaults
    let verticalTabsView: BrowserVerticalTabsView
    let rootView = NSView()
    private let topBar = NSView()
    let toolbar: BrowserToolbarView
    let tabStrip: BrowserTabStripView
    let findBar: BrowserFindBar
    let sidebar: BrowserSidebarView
    let webArea = NSView()
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
    var globalVimiumMarks: [String: VimiumMark] = [:]

    var previousSelectedTabID: UUID?
    var lastFindQuery = ""
    var vimiumFindActive = false
    lazy var vimiumPromptPanel = VimiumPromptPanel(theme: theme)
    lazy var vimiumTextPanel = VimiumTextPanel(theme: theme)
    var vimiumToastView: NSView?
    var popupBlockedControl: ChromeButton?

    static let verticalSidebarCollapsedKey = "verticalSidebarCollapsed"

    struct LoadWaiter {
        let tabID: UUID
        let timer: Timer
        let completion: (Result<String, Error>) -> Void
    }

    init(
        themeManager: ThemeManager,
        settingsStore: BrowserSettingsStore,
        history: BrowserHistoryStore,
        bookmarks: BrowserBookmarkStore,
        downloads: BrowserDownloadStore,
        sitePermissions: BrowserSitePermissionStore,
        sessionStore: BrowserSessionStore = BrowserSessionStore(),
        persistsSession: Bool = true,
        frame: NSRect? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.themeManager = themeManager
        self.settingsStore = settingsStore
        self.history = history
        self.bookmarks = bookmarks
        self.downloads = downloads
        self.sitePermissions = sitePermissions
        self.sessionStore = sessionStore
        self.persistsSession = persistsSession
        self.theme = themeManager.currentTheme
        self.usesVerticalTabs = settingsStore.settings.usesVerticalTabs
        self.isVerticalSidebarCollapsed = defaults.bool(
            forKey: Self.verticalSidebarCollapsedKey
        )
        self.lastSearchEngine = settingsStore.settings.searchEngine
        self.defaults = defaults
        self.verticalTabsView = BrowserVerticalTabsView(theme: themeManager.currentTheme)
        self.toolbar = BrowserToolbarView(theme: theme)
        self.tabStrip = BrowserTabStripView(theme: theme)
        self.findBar = BrowserFindBar(theme: theme)
        self.sidebar = BrowserSidebarView(
            theme: theme,
            history: history,
            bookmarks: bookmarks,
            downloads: downloads
        )
        self.hairline = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        self.sidebarDivider = ChromeRuleView(axis: .vertical, color: theme.colors.borderSubtle)

        let initialFrame = frame ?? MainWindowSizing.initialFrame(
            in: NSScreen.main?.visibleFrame ?? MainWindowSizing.fallbackVisibleFrame
        )
        let window = BrowserWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        guard self.window != nil else {
            fatalError("BrowserWindowController requires a window")
        }
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 520)
        window.backgroundColor = theme.colors.bgBase
        if persistsSession {
            window.setFrameAutosaveName("SopranoWebMainWindow")
        }

        rootView.wantsLayer = true
        window.contentView = rootView
        buildLayout()
        wireCallbacks()
        applyTheme(theme)
        restoreOrCreateTab()
        applyTabsLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
        let vertical = usesVerticalTabs
        let collapsed = vertical && isVerticalSidebarCollapsed
        verticalTabsView.isHidden = !vertical || collapsed
        tabStrip.isHidden = vertical
        tabStripHeight.constant = vertical ? 0 : BrowserTabStripView.preferredHeight
        topBarHeight.constant = vertical
            ? BrowserToolbarView.preferredHeight
            : BrowserToolbarView.preferredHeight + BrowserTabStripView.preferredHeight

        topBarLeadingToRoot.isActive = !vertical || collapsed
        topBarLeadingToSidebar.isActive = vertical && !collapsed
        webLeadingToRoot.isActive = !vertical || collapsed
        webLeadingToSidebar.isActive = vertical && !collapsed
        // The traffic lights own the top-left corner; when the rail is hidden
        // they sit over a 76 pt strip and the toolbar starts after it.
        toolbarLeading.constant = collapsed ? 76 : 0

        toolbar.setVerticalTabsToggle(vertical && !collapsed)
        updateTabStrip()
        updateWindowMinSize()
        viewNeedsLayout()
    }

    func updateWindowMinSize() {
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

        toolbar.onSubmit = { [weak self] value in self?.navigateCurrent(to: value) }
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
        sidebar.onClear = { [weak self] section in self?.clear(section) }
        sidebar.onClose = { [weak self] in self?.hideSidebar() }

        history.onChange = { [weak self] in
            self?.sidebar.refresh()
            self?.markStartPagesStale()
        }
        bookmarks.onChange = { [weak self] in
            self?.sidebar.refresh()
            self?.markStartPagesStale()
            self?.updateChrome()
        }
        downloads.onChange = { [weak self] in self?.sidebar.refresh() }

        themeManager.onThemeChanged = { [weak self] theme in
            self?.applyTheme(theme)
        }
        settingsStore.onChange = { [weak self] settings in
            self?.applySettings(settings)
        }
    }

    func viewNeedsLayout() {
        rootView.needsLayout = true
        rootView.layoutSubtreeIfNeeded()
    }

    // MARK: - Settings and theme

    func revealWindowIfNeeded() {
        guard let window, !window.isVisible else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func showWindowAndEnsureTab() {
        if tabs.isEmpty {
            newTab(focusAddress: true)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
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
        if let settingsWindowController {
            settingsWindowController.showWindow(nil)
            settingsWindowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SettingsWindowController(
            settingsStore: settingsStore,
            themeManager: themeManager
        )
        settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func applySettings(_ settings: BrowserSettings) {
        let themeChanged = themeManager.themeId != settings.themeID
            || themeManager.appearance != settings.appearance
        if themeChanged {
            themeManager.update(themeId: settings.themeID, appearance: settings.appearance)
        }
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
        findBar.apply(theme: theme)
        sidebar.apply(theme: theme)
        for tab in tabs where tab.isStartPage {
            loadStartPage(tab)
        }
        updateChrome()
    }
}
