import AppKit
import WebKit

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate,
    WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate
{
    let themeManager: ThemeManager
    let settingsStore: BrowserSettingsStore
    let history: BrowserHistoryStore
    let bookmarks: BrowserBookmarkStore
    let downloads: BrowserDownloadStore
    let sessionStore: BrowserSessionStore
    let persistsSession: Bool

    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedIndex = 0
    private(set) var closedTabs: [BrowserTabState] = []
    private var downloadsByRecord: [UUID: WKDownload] = [:]
    private var progressTimer: Timer?
    private var loadWaiters: [UUID: LoadWaiter] = [:]
    private var recordsByDownload: [ObjectIdentifier: UUID] = [:]
    private var destinationsByDownload: [ObjectIdentifier: URL] = [:]
    private var isSidebarVisible = false
    private var sidebarSection: BrowserSidebarSection = .history
    private var findQuery = ""
    private var staleStartTabs: Set<UUID> = []
    private var settingsWindowController: SettingsWindowController?

    private var theme: AppTheme
    private var usesVerticalTabs: Bool
    private var isVerticalSidebarCollapsed: Bool
    private var lastSearchEngine: SearchEngine
    private let defaults: UserDefaults
    private let verticalTabsView: BrowserVerticalTabsView
    private let rootView = NSView()
    private let topBar = NSView()
    private let toolbar: BrowserToolbarView
    private let tabStrip: BrowserTabStripView
    private let findBar: BrowserFindBar
    private let sidebar: BrowserSidebarView
    private let webArea = NSView()
    private let hairline: ChromeRuleView
    private let sidebarDivider: ChromeRuleView
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var findBarHeightConstraint: NSLayoutConstraint!
    private var webTrailingToRoot: NSLayoutConstraint!
    private var webTrailingToSidebar: NSLayoutConstraint!
    private var topBarHeight: NSLayoutConstraint!
    private var tabStripHeight: NSLayoutConstraint!
    private var topBarLeadingToRoot: NSLayoutConstraint!
    private var topBarLeadingToSidebar: NSLayoutConstraint!
    private var toolbarLeading: NSLayoutConstraint!
    private var webLeadingToRoot: NSLayoutConstraint!
    private var webLeadingToSidebar: NSLayoutConstraint!

    lazy var palette = CommandPalettePanel(themeManager: themeManager)
    var globalVimiumMarks: [String: VimiumMark] = [:]

    private var previousSelectedTabID: UUID?
    private var lastFindQuery = ""
    private var vimiumFindActive = false
    private lazy var vimiumPromptPanel = VimiumPromptPanel(theme: theme)
    private lazy var vimiumTextPanel = VimiumTextPanel(theme: theme)
    private var vimiumToastView: NSView?

    static let verticalSidebarCollapsedKey = "verticalSidebarCollapsed"

    private struct LoadWaiter {
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

    private func updateWindowMinSize() {
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

    private func restoreOrCreateTab() {
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

    // MARK: - Tabs

    @discardableResult
    func newTab(
        url: String? = nil,
        focusAddress: Bool = false,
        select: Bool = true
    ) -> BrowserTab {
        let tab = makeTab()
        tabs.append(tab)
        if let url, !url.isEmpty {
            navigate(tab, to: url)
        } else {
            loadStartPage(tab)
        }
        if select {
            selectTab(index: tabs.count - 1, focus: !focusAddress)
            if focusAddress {
                toolbar.focusAddress(selectAll: true)
            }
        }
        updateTabStrip()
        saveSession()
        return tab
    }

    private func makeTab(configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let configuration = configuration ?? makeConfiguration()
        if configuration.urlSchemeHandler(forURLScheme: BrowserStartPageSchemeHandler.scheme) == nil {
            configuration.setURLSchemeHandler(
                BrowserStartPageSchemeHandler { [weak self] in self?.startPageHTML() ?? "" },
                forURLScheme: BrowserStartPageSchemeHandler.scheme
            )
        }
        let tabID = UUID()
        let contentController = WKUserContentController()
        contentController.addUserScript(WKUserScript(
            source: VimiumPageScripts.focusObserver,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        contentController.add(
            VimiumFocusHandler(controller: self, tabID: tabID),
            name: VimiumPageScripts.focusMessageName
        )
        configuration.userContentController = contentController

        let webView = BrowserWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true
        webArea.addSubview(webView)
        webArea.addSubview(findBar, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webArea.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webArea.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webArea.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webArea.bottomAnchor),
        ])

        let tab = BrowserTab(id: tabID, webView: webView)
        let vimium = VimiumController(windowController: self, tab: tab)
        tab.vimium = vimium
        webView.keyHandler = { [weak vimium] event in
            vimium?.handle(event) ?? false
        }
        observe(tab)
        return tab
    }

    private func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.setURLSchemeHandler(
            BrowserStartPageSchemeHandler { [weak self] in self?.startPageHTML() ?? "" },
            forURLScheme: BrowserStartPageSchemeHandler.scheme
        )
        return configuration
    }

    private func addRestoredTab(_ state: BrowserTabState) {
        let tab = makeTab()
        tab.title = state.title
        tab.zoom = state.zoom
        tab.suppressNextHistoryRecord = true
        tabs.append(tab)
        if let value = state.url,
           let url = URL(string: value)
        {
            tab.isStartPage = false
            tab.webView.load(URLRequest(url: url))
        } else {
            loadStartPage(tab)
        }
    }

    private func observe(_ tab: BrowserTab) {
        let webView = tab.webView
        tab.observations = [
            webView.observe(\.title, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab else { return }
                    if let title = tab.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !title.isEmpty
                    {
                        tab.title = title
                    }
                    self.metadataChanged(tab)
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab else { return }
                    self.metadataChanged(tab)
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab, tab.id == self.selectedTab?.id else { return }
                    self.updateChrome()
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab, tab.id == self.selectedTab?.id else { return }
                    self.updateChrome()
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab, tab.id == self.selectedTab?.id else { return }
                    self.updateChrome()
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab, tab.id == self.selectedTab?.id else { return }
                    self.updateChrome()
                }
            },
        ]
    }

    private func metadataChanged(_ tab: BrowserTab) {
        if tab.id == selectedTab?.id {
            updateChrome()
        }
        updateTabStrip()
        saveSession()
    }

    func selectTab(id: UUID, focus: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        selectTab(index: index, focus: focus)
    }

    func selectTab(index: Int, focus: Bool) {
        guard tabs.indices.contains(index) else { return }
        let previous = selectedTab
        selectedIndex = index
        for tab in tabs {
            tab.webView.isHidden = tab.id != tabs[index].id
        }
        let tab = tabs[index]
        if let previous, previous.id != tab.id {
            previousSelectedTabID = previous.id
        }
        if tab.isStartPage, staleStartTabs.remove(tab.id) != nil {
            loadStartPage(tab)
        }
        tabStrip.update(
            tabs: tabs.map { ($0.id, $0.displayTitle) },
            selectedID: tab.id
        )
        verticalTabsView.update(
            tabs: tabs.map { ($0.id, $0.displayTitle) },
            selectedID: tab.id
        )
        updateChrome()
        if focus {
            window?.makeFirstResponder(tab.webView)
        }
        saveSession()
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        selectTab(index: (selectedIndex + 1) % tabs.count, focus: true)
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        selectTab(index: (selectedIndex - 1 + tabs.count) % tabs.count, focus: true)
    }

    func selectTab(number: Int) {
        guard number >= 1, tabs.indices.contains(number - 1) else { return }
        selectTab(index: number - 1, focus: true)
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        closedTabs.append(tab.state)
        if closedTabs.count > 20 {
            closedTabs.removeFirst(closedTabs.count - 20)
        }
        resolveLoadWaiters(
            for: tab,
            result: .failure(BrowserAutomationError.unavailable("The tab was closed."))
        )
        tab.vimium?.shutdown()
        tab.invalidateObservations()
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        tabs.remove(at: index)

        if tabs.isEmpty {
            tabStrip.clear()
            verticalTabsView.clear()
            saveSession()
            window?.performClose(nil)
            return
        }

        let next = min(index, tabs.count - 1)
        selectTab(index: next, focus: true)
        updateTabStrip()
        saveSession()
    }

    func closeSelectedTab() {
        guard let tab = selectedTab else { return }
        closeTab(id: tab.id)
    }

    func reopenClosedTab() {
        guard let state = closedTabs.popLast() else { return }
        addRestoredTab(state)
        selectTab(index: tabs.count - 1, focus: true)
        updateTabStrip()
        saveSession()
    }

    private func updateTabStrip() {
        guard let selectedTab else { return }
        let list = tabs.map { ($0.id, $0.displayTitle) }
        tabStrip.update(tabs: list, selectedID: selectedTab.id)
        verticalTabsView.update(tabs: list, selectedID: selectedTab.id)
    }

    // MARK: - Navigation

    func navigateCurrent(to input: String) {
        guard let tab = selectedTab else { return }
        navigate(tab, to: input)
        window?.makeFirstResponder(tab.webView)
    }

    private func navigate(_ tab: BrowserTab, to input: String) {
        guard let url = BrowserAddressResolver.resolve(
            input,
            searchEngine: settingsStore.settings.searchEngine
        ) else {
            NSSound.beep()
            return
        }
        navigate(tab, to: url)
    }

    func navigate(_ tab: BrowserTab, to url: URL) {
        if BrowserAddressResolver.isStartPage(url) {
            loadStartPage(tab)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "file", "about", "blob", "data"].contains(scheme) else {
            NSWorkspace.shared.open(url)
            return
        }
        tab.isStartPage = false
        tab.errorMessage = nil
        tab.failedURL = nil
        tab.pendingURL = url.absoluteString
        tab.isShowingErrorPage = false
        if url.isFileURL {
            tab.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            tab.webView.load(URLRequest(url: url))
        }
    }

    func goBack() {
        guard let tab = selectedTab, tab.webView.canGoBack else { return }
        tab.pendingURL = tab.webView.backForwardList.backItem?.url.absoluteString
        tab.webView.goBack()
    }

    func goForward() {
        guard let tab = selectedTab, tab.webView.canGoForward else { return }
        tab.pendingURL = tab.webView.backForwardList.forwardItem?.url.absoluteString
        tab.webView.goForward()
    }

    func reloadOrStop() {
        guard let tab = selectedTab else { return }
        if tab.webView.isLoading {
            tab.webView.stopLoading()
        } else if let failed = tab.failedURL, let url = URL(string: failed) {
            navigate(tab, to: url)
        } else if tab.isStartPage {
            loadStartPage(tab)
        } else {
            tab.pendingURL = tab.webView.url?.absoluteString
            tab.webView.reload()
        }
    }

    func reload() {
        guard let tab = selectedTab else { return }
        if let failed = tab.failedURL, let url = URL(string: failed) {
            navigate(tab, to: url)
        } else if tab.isStartPage {
            loadStartPage(tab)
        } else {
            tab.pendingURL = tab.webView.url?.absoluteString
            tab.webView.reload()
        }
    }

    func focusAddressBar() {
        toolbar.focusAddress(selectAll: true)
    }

    func focusPage() {
        guard let tab = selectedTab else { return }
        window?.makeFirstResponder(tab.webView)
    }

    func goHome() {
        let homepage = settingsStore.settings.homepage
        navigateCurrent(to: homepage.isEmpty ? "" : homepage)
    }

    private func loadStartPage(_ tab: BrowserTab) {
        tab.isStartPage = true
        tab.errorMessage = nil
        tab.failedURL = nil
        tab.pendingURL = BrowserStartPageSchemeHandler.url.absoluteString
        tab.isShowingErrorPage = false
        tab.suppressNextHistoryRecord = true
        tab.zoom = tab.zoom == 0 ? 1 : tab.zoom
        tab.webView.pageZoom = tab.zoom
        tab.webView.load(URLRequest(url: BrowserStartPageSchemeHandler.url))
    }

    private func startPageHTML() -> String {
        BrowserStartPage.html(
            theme: theme,
            settings: settingsStore.settings,
            bookmarks: bookmarks.bookmarks,
            history: history.entries
        )
    }

    private func markStartPagesStale() {
        for tab in tabs where tab.isStartPage {
            staleStartTabs.insert(tab.id)
        }
    }

    private func updateChrome() {
        guard let tab = selectedTab else { return }
        let url = tab.webView.url
        let shownURL = tab.failedURL ?? url?.absoluteString ?? ""
        toolbar.setAddress(
            tab.isStartPage ? "" : shownURL,
            secure: url?.scheme?.lowercased() == "https",
            local: tab.isStartPage || BrowserAddressResolver.isLocal(url)
        )
        toolbar.setProgress(tab.webView.estimatedProgress, isLoading: tab.webView.isLoading)
        toolbar.setBookmarked(!tab.isStartPage && bookmarks.isBookmarked(shownURL))
        toolbar.setBookmarkEnabled(!tab.isStartPage && !shownURL.isEmpty)
        toolbar.setSidebarToggle(isSidebarVisible)
        toolbar.setDownloadsToggle(isSidebarVisible && sidebarSection == .downloads)
        window?.title = tab.isStartPage ? "New Tab" : tab.displayTitle
        window?.representedURL = tab.isStartPage ? nil : url
    }

    // MARK: - Bookmarks, find, sidebar

    func toggleBookmark() {
        guard let tab = selectedTab,
              !tab.isStartPage,
              let address = tab.webView.url?.absoluteString
        else {
            NSSound.beep()
            return
        }
        bookmarks.toggle(url: address, title: tab.displayTitle)
        updateChrome()
    }

    func showFindBar() {
        findBar.isHidden = false
        webArea.addSubview(findBar, positioned: .above, relativeTo: nil)
        findBar.needsDisplay = true
        findBar.displayIfNeeded()
        findBar.focus()
    }

    func hideFindBar() {
        vimiumFindActive = false
        findBar.isHidden = true
        findQuery = ""
        findBar.setResult(found: false, hasQuery: false)
        if let tab = selectedTab {
            tab.webView.find("", configuration: WKFindConfiguration()) { _ in }
            window?.makeFirstResponder(tab.webView)
        }
        viewNeedsLayout()
    }

    func findNext() {
        if findBar.isHidden {
            showFindBar()
            return
        }
        performFind(backwards: false, updateResult: true)
        if vimiumFindActive {
            vimiumFindActive = false
            focusPage()
        }
    }

    func findPrevious() {
        if findBar.isHidden {
            showFindBar()
            return
        }
        performFind(backwards: true, updateResult: true)
        if vimiumFindActive {
            vimiumFindActive = false
            focusPage()
        }
    }

    func beginVimiumFind() {
        vimiumFindActive = true
        showFindBar()
    }

    func repeatVimiumFind(backwards: Bool) {
        guard let tab = selectedTab else { return }
        guard !lastFindQuery.isEmpty else {
            showVimiumToast("No find query.")
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        tab.webView.find(lastFindQuery, configuration: configuration) { [weak self] result in
            self?.findBar.setResult(found: result.matchFound, hasQuery: true)
        }
    }

    func setVimiumFindQuery(_ query: String, backwards: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastFindQuery = trimmed
        repeatVimiumFind(backwards: backwards)
    }

    func endVimiumFind() {
        vimiumFindActive = false
        if !findBar.isHidden {
            hideFindBar()
        } else {
            selectedTab?.webView.find("", configuration: WKFindConfiguration()) { _ in }
            focusPage()
        }
    }

    private func performFind(backwards: Bool, updateResult: Bool) {
        guard let tab = selectedTab else { return }
        guard !findQuery.isEmpty else {
            tab.webView.find("", configuration: WKFindConfiguration()) { _ in }
            findBar.setResult(found: false, hasQuery: false)
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        tab.webView.find(findQuery, configuration: configuration) { [weak self] result in
            guard updateResult else { return }
            self?.findBar.setResult(found: result.matchFound, hasQuery: true)
        }
    }

    func toggleSidebar(section: BrowserSidebarSection? = nil) {
        if isSidebarVisible, section == nil || section == sidebarSection {
            hideSidebar()
            return
        }
        showSidebar(section: section ?? sidebarSection)
    }

    func showSidebar(section: BrowserSidebarSection) {
        sidebarSection = section
        sidebar.select(section)
        isSidebarVisible = true
        sidebar.isHidden = false
        sidebarDivider.isHidden = false
        webTrailingToRoot.isActive = false
        webTrailingToSidebar.isActive = true
        updateChrome()
        updateWindowMinSize()
        viewNeedsLayout()
    }

    func hideSidebar() {
        isSidebarVisible = false
        sidebar.isHidden = true
        sidebarDivider.isHidden = true
        webTrailingToSidebar.isActive = false
        webTrailingToRoot.isActive = true
        updateChrome()
        updateWindowMinSize()
        viewNeedsLayout()
    }

    private func viewNeedsLayout() {
        rootView.needsLayout = true
        rootView.layoutSubtreeIfNeeded()
    }

    private func clear(_ section: BrowserSidebarSection) {
        switch section {
        case .history:
            guard !history.entries.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "Clear History?"
            alert.informativeText = "This removes every page from the history list. It cannot be undone."
            alert.addButton(withTitle: "Clear")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if let window {
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn {
                        self?.history.clear()
                    }
                }
            }
        case .downloads:
            downloads.clearFinished()
        case .bookmarks:
            break
        }
    }

    private func openFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealFile(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func cancelDownload(id: UUID) {
        downloadsByRecord[id]?.cancel { _ in }
        downloadsByRecord.removeValue(forKey: id)
        downloads.cancel(id: id)
        stopProgressTimerIfIdle()
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

    func selectLastTab() {
        guard !tabs.isEmpty else { return }
        selectTab(index: tabs.count - 1, focus: true)
    }

    func selectPreviousVisitedTab() {
        guard let id = previousSelectedTabID,
              let index = tabs.firstIndex(where: { $0.id == id })
        else {
            showVimiumToast("No previous tab.")
            return
        }
        selectTab(index: index, focus: true)
    }

    func moveSelectedTab(by offset: Int) {
        guard tabs.count > 1 else {
            showVimiumToast("Only one tab is open.")
            return
        }
        let target = selectedIndex + offset
        guard tabs.indices.contains(target) else {
            showVimiumToast(offset < 0 ? "Already the first tab." : "Already the last tab.")
            return
        }
        tabs.swapAt(selectedIndex, target)
        selectedIndex = target
        updateTabStrip()
        saveSession()
    }

    func duplicateSelectedTab() {
        guard let tab = selectedTab else { return }
        if tab.isStartPage {
            _ = newTab(focusAddress: false)
        } else if let url = tab.webView.url?.absoluteString {
            _ = newTab(url: url)
        } else {
            showVimiumToast("Nothing to duplicate.")
        }
    }

    func vimiumFocusChanged(tabID: UUID, editable: Bool) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tab.vimium?.pageFocusChanged(editable)
    }

    func showVimiumToast(_ text: String) {
        vimiumToastView?.removeFromSuperview()
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.colors.raised.cgColor
        container.layer?.cornerRadius = Chrome.Radius.card
        container.layer?.borderWidth = Chrome.hairline
        container.layer?.borderColor = theme.colors.borderStrong.cgColor

        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = ChromeFont.label
        label.textColor = theme.colors.textPrimary
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        container.addSubview(label)
        rootView.addSubview(container)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            container.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -28),
            container.heightAnchor.constraint(equalToConstant: 32),
            container.widthAnchor.constraint(lessThanOrEqualTo: rootView.widthAnchor, constant: -48),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        vimiumToastView = container
        Task { @MainActor [weak container] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            container?.removeFromSuperview()
        }
    }

    func presentVimiumPrompt(initialText: String, newTab: Bool) {
        guard let window else { return }
        if vimiumPromptPanel.isVisible {
            vimiumPromptPanel.dismiss()
        }
        vimiumPromptPanel.apply(theme: theme)
        vimiumPromptPanel.show(
            relativeTo: window,
            initialText: initialText,
            placeholder: "Open URL, bookmark, or search"
        ) { [weak self] value in
            guard let self else { return }
            if newTab {
                _ = self.newTab(url: value)
            } else {
                self.navigateCurrent(to: value)
            }
            self.focusPage()
        } onCancel: { [weak self] in
            self?.focusPage()
        }
    }

    func showVimiumBookmarks(newTab: Bool) {
        guard let window else { return }
        guard !bookmarks.bookmarks.isEmpty else {
            showVimiumToast("No bookmarks yet.")
            return
        }
        let items = bookmarks.bookmarks.map { bookmark in
            CommandItem(
                id: "vimium-bookmark-\(bookmark.id)",
                icon: "bookmark",
                label: bookmark.displayTitle,
                description: bookmark.url
            ) { [weak self] in
                guard let self else { return }
                if newTab {
                    _ = self.newTab(url: bookmark.url)
                } else {
                    self.navigateCurrent(to: bookmark.url)
                }
                self.focusPage()
            }
        }
        palette.show(
            relativeTo: window,
            commands: items,
            placeholder: "Search bookmarks…"
        )
    }

    func showVimiumTabs() {
        guard let window else { return }
        let items = tabs.enumerated().map { index, tab in
            CommandItem(
                id: "vimium-tab-\(tab.id)",
                icon: "rectangle.on.rectangle",
                label: "\(index + 1). \(tab.displayTitle)",
                description: tab.isStartPage
                    ? "about:start"
                    : (tab.webView.url?.absoluteString ?? "")
            ) { [weak self] in
                self?.selectTab(id: tab.id, focus: true)
            }
        }
        palette.show(
            relativeTo: window,
            commands: items,
            placeholder: "Search tabs…"
        )
    }

    func showVimiumHelp() {
        showVimiumText(title: "Vimium Help", text: VimiumKeyMap.helpText)
    }

    func showVimiumText(title: String, text: String) {
        guard let window else { return }
        if vimiumTextPanel.isVisible {
            vimiumTextPanel.dismiss()
        }
        vimiumTextPanel.apply(theme: theme)
        vimiumTextPanel.show(
            relativeTo: window,
            title: title,
            text: text
        ) { [weak self] in
            self?.focusPage()
        }
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

    func windowWillClose(_ notification: Notification) {
        saveSession()
    }

    // MARK: - WebKit navigation

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.vimium?.pageDidStart()
        if tab.isShowingErrorPage {
            tab.isShowingErrorPage = false
        } else {
            tab.errorMessage = nil
            tab.failedURL = nil
        }
        if webView.url?.scheme?.lowercased() == BrowserStartPageSchemeHandler.scheme {
            tab.isStartPage = true
        }
        if tab.id == selectedTab?.id {
            updateChrome()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        webView.pageZoom = tab.zoom
        tab.isStartPage = webView.url?.scheme?.lowercased() == BrowserStartPageSchemeHandler.scheme
        if tab.id == selectedTab?.id {
            updateChrome()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.isStartPage = webView.url?.scheme?.lowercased() == BrowserStartPageSchemeHandler.scheme
        if let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty
        {
            tab.title = title
        }
        tab.pendingURL = nil
        tab.vimium?.pageDidFinish()
        resolveLoadWaiters(
            for: tab,
            result: .success(webView.url?.absoluteString ?? "")
        )
        if tab.suppressNextHistoryRecord {
            tab.suppressNextHistoryRecord = false
        } else if !tab.isStartPage,
                  let address = webView.url?.absoluteString,
                  ["http", "https", "file"].contains(webView.url?.scheme?.lowercased() ?? "")
        {
            history.record(url: address, title: tab.displayTitle)
        }
        if tab.id == selectedTab?.id {
            updateChrome()
        }
        updateTabStrip()
        saveSession()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleFailure(webView, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleFailure(webView, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
    ) {
        guard let tab = tab(for: webView), tab.id == selectedTab?.id else { return }
        updateChrome()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func handleFailure(_ webView: WKWebView, error: Error) {
        let nsError = error as NSError
        // A navigation that becomes a download ends with "Frame load
        // interrupted" by policy; it is not a page failure.
        if nsError.code == NSURLErrorCancelled
            || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
        {
            return
        }
        guard let tab = tab(for: webView) else { return }
        let failedURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
            ?? nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
            ?? tab.pendingURL
            ?? tab.failedURL
            ?? ""
        tab.errorMessage = nsError.localizedDescription
        tab.failedURL = failedURL.isEmpty ? nil : failedURL
        tab.isShowingErrorPage = true
        tab.title = "Can’t Open Page"
        tab.suppressNextHistoryRecord = true
        webView.loadHTMLString(
            BrowserErrorPage.html(
                theme: theme,
                url: failedURL,
                message: nsError.localizedDescription
            ),
            baseURL: nil
        )
        updateTabStrip()
        updateChrome()
        resolveLoadWaiters(
            for: tab,
            result: .failure(BrowserAutomationError.unavailable(nsError.localizedDescription))
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "file", "about", "blob", "data", BrowserStartPageSchemeHandler.scheme]
            .contains(scheme)
        {
            if navigationAction.targetFrame?.isMainFrame != false {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if navigationAction.targetFrame?.isMainFrame != false,
           let tab = tab(for: webView),
           ["http", "https", "file"].contains(scheme)
        {
            tab.pendingURL = url.absoluteString
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let tab = makeTab(configuration: configuration)
        tab.isStartPage = false
        tabs.append(tab)
        selectTab(index: tabs.count - 1, focus: true)
        updateTabStrip()
        saveSession()
        return tab.webView
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            presentDialog(
                title: frame.request.url?.host ?? "Page",
                message: message,
                confirm: nil
            ) { _ in
                continuation.resume()
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            presentDialog(
                title: frame.request.url?.host ?? "Page",
                message: message,
                confirm: "OK"
            ) { confirmed in
                continuation.resume(returning: confirmed)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        guard let window else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let alert = NSAlert()
            alert.messageText = frame.request.url?.host ?? "Page"
            alert.informativeText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.stringValue = defaultText ?? ""
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { response in
                continuation.resume(
                    returning: response == .alertFirstButtonReturn ? field.stringValue : nil
                )
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        guard let window else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[URL]?, Never>) in
            let panel = NSOpenPanel()
            panel.canChooseFiles = !parameters.allowsDirectories
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.urls : nil)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        await withCheckedContinuation { continuation in
            let name: String = switch type {
            case .camera: "camera"
            case .microphone: "microphone"
            case .cameraAndMicrophone: "camera and microphone"
            @unknown default: "camera and microphone"
            }
            presentDialog(
                title: origin.host,
                message: "This page wants to use the \(name).",
                confirm: "Allow"
            ) { allowed in
                continuation.resume(returning: allowed ? .grant : .deny)
            }
        }
    }

    private func presentDialog(
        title: String,
        message: String,
        confirm: String?,
        completion: @escaping (Bool) -> Void
    ) {
        guard let window else {
            completion(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm ?? "OK")
        if confirm != nil {
            alert.addButton(withTitle: "Cancel")
        }
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    // MARK: - Downloads

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        let key = ObjectIdentifier(download)
        let directory = settingsStore.settings.downloadDirectoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = sanitizedFilename(suggestedFilename)
        let destination = uniqueDestination(in: directory, filename: filename)
        let record = downloads.begin(
            url: download.originalRequest?.url?.absoluteString ?? response.url?.absoluteString ?? "",
            filename: destination.lastPathComponent
        )
        recordsByDownload[key] = record.id
        destinationsByDownload[key] = destination
        downloadsByRecord[record.id] = download
        startProgressTimer()
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let recordID = recordsByDownload[key] else {
            recordsByDownload[key] = nil
            destinationsByDownload[key] = nil
            return
        }
        let path = destinationsByDownload[key]?.path ?? ""
        downloads.finish(id: recordID, path: path)
        downloadsByRecord.removeValue(forKey: recordID)
        recordsByDownload.removeValue(forKey: key)
        destinationsByDownload.removeValue(forKey: key)
        stopProgressTimerIfIdle()
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        let key = ObjectIdentifier(download)
        guard let recordID = recordsByDownload[key] else { return }
        downloads.fail(id: recordID, message: error.localizedDescription)
        downloadsByRecord.removeValue(forKey: recordID)
        recordsByDownload.removeValue(forKey: key)
        destinationsByDownload.removeValue(forKey: key)
        stopProgressTimerIfIdle()
    }

    func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        let timer = Timer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(progressTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimerIfIdle() {
        guard downloadsByRecord.isEmpty else { return }
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func waitForLoad(
        _ tab: BrowserTab,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        if !tab.webView.isLoading, tab.pendingURL == nil {
            completion(.success(tab.webView.url?.absoluteString ?? ""))
            return
        }
        let id = UUID()
        let timer = Timer(
            timeInterval: 10,
            target: self,
            selector: #selector(loadWaiterTimedOut(_:)),
            userInfo: id.uuidString,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        loadWaiters[id] = LoadWaiter(tabID: tab.id, timer: timer, completion: completion)
    }

    @objc private func loadWaiterTimedOut(_ timer: Timer) {
        guard let raw = timer.userInfo as? String,
              let id = UUID(uuidString: raw),
              let waiter = loadWaiters.removeValue(forKey: id)
        else { return }
        waiter.completion(.failure(
            BrowserAutomationError.unavailable("Timed out waiting for the page to load.")
        ))
    }

    private func resolveLoadWaiters(for tab: BrowserTab, result: Result<String, Error>) {
        let ids = loadWaiters.compactMap { id, waiter in
            waiter.tabID == tab.id ? id : nil
        }
        for id in ids {
            guard let waiter = loadWaiters.removeValue(forKey: id) else { continue }
            waiter.timer.invalidate()
            waiter.completion(result)
        }
    }

    @objc private func progressTimerFired(_ timer: Timer) {
        var hasActiveRecord = false
        for (recordID, download) in downloadsByRecord {
            downloads.updateProgress(id: recordID, fraction: download.progress.fractionCompleted)
            if downloads.records.contains(where: { $0.id == recordID && $0.state == .inProgress }) {
                hasActiveRecord = true
            }
        }
        if !hasActiveRecord {
            stopProgressTimerIfIdle()
        }
    }

    private func sanitizedFilename(_ value: String) -> String {
        let name = URL(fileURLWithPath: value).lastPathComponent
        return name.isEmpty ? "Download" : name
    }

    private func uniqueDestination(in directory: URL, filename: String) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var index = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let next = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: next.path) {
                return next
            }
            index += 1
        }
    }

    private func tab(for webView: WKWebView) -> BrowserTab? {
        tabs.first { $0.webView === webView }
    }
}
