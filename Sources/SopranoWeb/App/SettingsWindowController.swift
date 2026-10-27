import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let settingsStore: BrowserSettingsStore
    private let themeManager: ThemeManager
    private let contentBlocker: BrowserContentBlocker
    private var contentBlockerObservation: BrowserObservation?
    private var theme: AppTheme

    private let rootView = NSView()
    private let header = NSTextField(labelWithString: "Settings")
    private let subtitle = NSTextField(labelWithString: "Soprano Web")
    private let engineButton: ChromeButton
    private let themeButton: ChromeButton
    private let appearanceButton: ChromeButton
    private let downloadButton: ChromeButton
    private let doneButton: ChromeButton
    private let homepageFrame: ChromeFieldView
    private let homepageField = NSTextField()
    private let restoreSwitch: ChromeSwitch
    private let verticalTabsSwitch: ChromeSwitch
    private let suggestionsSwitch: ChromeSwitch
    private let downloadLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private var rowLabels: [NSTextField] = []
    /// Presents Settings ▸ Websites as a sheet on the given window.
    var onShowWebsites: ((NSWindow) -> Void)?
    /// Presents Settings ▸ Website Data as a sheet on the given window.
    var onShowWebsiteData: ((NSWindow) -> Void)?
    /// Presents Settings ▸ Links from other apps as a sheet on the given window.
    var onShowLinkRouting: ((NSWindow) -> Void)?
    /// Presents Settings ▸ Extensions as a sheet on the given window.
    var onShowExtensions: ((NSWindow) -> Void)?
    /// Settings ▸ Search engine ▸ Manage…, while shown.
    private var searchEnginesSheet: BrowserSearchEnginesSheet?
    /// Settings ▸ Keyboard shortcuts ▸ Customize…, while shown.
    private var shortcutsSheet: BrowserShortcutsSheet?
    private lazy var shortcutsButton: ChromeButton = {
        let button = ChromeButton(title: "Customize…", theme: theme, kind: .standard)
        button.target = self
        button.action = #selector(shortcutsPressed)
        button.widthAnchor.constraint(equalToConstant: 112).isActive = true
        return button
    }()
    /// Keyboard shortcuts ▸ "New Little Arc from any app" (off by default)
    /// and its shortcut; a click on the shortcut records a new one.
    private lazy var globalLittleArcSwitch: ChromeSwitch = {
        let control = ChromeSwitch(
            isOn: settingsStore.settings.globalLittleArcEnabled,
            theme: theme,
            target: self,
            action: #selector(globalLittleArcChanged)
        )
        control.toolTip = "New Little Arc from any app"
        return control
    }()
    private lazy var globalLittleArcButton: ChromeButton = {
        let button = ChromeButton(title: globalLittleArcTitle, theme: theme, kind: .standard)
        button.target = self
        button.action = #selector(recordGlobalLittleArc)
        button.toolTip = "New Little Arc from any app: click, then type the shortcut (Esc cancels)"
        button.widthAnchor.constraint(equalToConstant: 168).isActive = true
        return button
    }()
    /// The key monitor and window observers while the global shortcut is
    /// being recorded.
    private var globalShortcutMonitor: Any?
    private var globalShortcutObservers: [NSObjectProtocol] = []
    /// The registered global hotkey (the app's; nil in the harness).
    var globalHotKey: BrowserGlobalHotKey?
    private lazy var searchEnginesButton: ChromeButton = {
        let button = ChromeButton(title: "Manage…", theme: theme, kind: .standard)
        button.target = self
        button.action = #selector(searchEnginesPressed)
        button.widthAnchor.constraint(equalToConstant: 92).isActive = true
        return button
    }()
    private lazy var autoplayButton: ChromeButton = {
        let button = ChromeButton(title: settingsStore.settings.autoplay.name, theme: theme, kind: .standard)
        button.target = self
        button.action = #selector(autoplayPressed)
        button.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return button
    }()
    private lazy var historyRetentionButton: ChromeButton = {
        let button = ChromeButton(title: settingsStore.settings.historyRetention.name, theme: theme, kind: .standard)
        button.target = self
        button.action = #selector(historyRetentionPressed)
        button.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return button
    }()
    private lazy var tabSleepButton: ChromeButton = {
        let button = ChromeButton(title: settingsStore.settings.tabSleep.name, theme: theme, kind: .standard)
        button.target = self
        button.action = #selector(tabSleepPressed)
        button.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return button
    }()
    private lazy var defaultZoomButton: ChromeButton = {
        let button = ChromeButton(
            title: BrowserZoom.percent(settingsStore.settings.defaultZoom),
            theme: theme,
            kind: .standard
        )
        button.target = self
        button.action = #selector(defaultZoomPressed)
        button.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return button
    }()
    private lazy var notificationsSwitch = ChromeSwitch(
        isOn: settingsStore.settings.allowsNotificationRequests,
        theme: theme,
        target: self,
        action: #selector(notificationsChanged)
    )
    private lazy var notificationsLabel = NSTextField(
        wrappingLabelWithString: "Allow websites to ask to send notifications"
    )
    private lazy var websitesButton: ChromeButton = {
        let button = ChromeButton(title: "Manage…", theme: theme, kind: .standard)
        button.target = self
        button.action = #selector(websitesPressed)
        button.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return button
    }()
    private lazy var linkRoutingButton: ChromeButton = {
        let button = ChromeButton(title: "Manage…", theme: theme, kind: .standard)
        button.target = self
        button.action = #selector(linkRoutingPressed)
        button.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return button
    }()
    private lazy var extensionsButton: ChromeButton = {
        let button = ChromeButton(title: "Manage…", theme: theme, kind: .standard)
        button.target = self
        button.action = #selector(extensionsPressed)
        button.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return button
    }()
    private lazy var blockAdsSwitch = ChromeSwitch(
        isOn: settingsStore.settings.blockAdsAndTrackers,
        theme: theme,
        target: self,
        action: #selector(blockAdsChanged)
    )
    private lazy var updateListsButton: ChromeButton = {
        let button = ChromeButton(title: "Update Now", theme: theme, kind: .standard)
        button.target = self
        button.action = #selector(updateListsPressed)
        return button
    }()
    /// "61,234 rules · updated 25 Oct 2026 at 14:02", "Updating lists…".
    private let blockerStatusLabel = NSTextField(labelWithString: "")
    private let askDownloadSwitch: ChromeSwitch
    private let websiteDataButton: ChromeButton
    private let defaultBrowserLabel = NSTextField(labelWithString: "")
    private let defaultBrowserButton: ChromeButton

    init(settingsStore: BrowserSettingsStore, themeManager: ThemeManager, contentBlocker: BrowserContentBlocker) {
        self.settingsStore = settingsStore
        self.themeManager = themeManager
        self.contentBlocker = contentBlocker
        self.theme = themeManager.currentTheme
        self.engineButton = ChromeButton(
            title: settingsStore.settings.defaultSearchEngine.name,
            theme: theme,
            kind: .standard,
            target: nil,
            action: nil
        )
        self.themeButton = ChromeButton(
            title: AppTheme.options.first { $0.id == settingsStore.settings.themeID }?.name ?? "Folio",
            theme: theme,
            kind: .standard,
            target: nil,
            action: nil
        )
        self.appearanceButton = ChromeButton(
            title: settingsStore.settings.appearance.name,
            theme: theme,
            kind: .standard,
            target: nil,
            action: nil
        )
        self.downloadButton = ChromeButton(
            title: "Choose…",
            theme: theme,
            kind: .standard,
            target: nil,
            action: nil
        )
        self.doneButton = ChromeButton(
            title: "Done",
            theme: theme,
            kind: .ink,
            target: nil,
            action: nil
        )
        self.homepageFrame = ChromeFieldView(theme: theme)
        self.restoreSwitch = ChromeSwitch(
            isOn: settingsStore.settings.restoreSession,
            theme: theme,
            target: nil,
            action: nil
        )
        self.verticalTabsSwitch = ChromeSwitch(
            isOn: settingsStore.settings.usesVerticalTabs,
            theme: theme,
            target: nil,
            action: nil
        )
        self.suggestionsSwitch = ChromeSwitch(
            isOn: settingsStore.settings.includeSearchSuggestions,
            theme: theme,
            target: nil,
            action: nil
        )
        self.askDownloadSwitch = ChromeSwitch(
            isOn: settingsStore.settings.askDownloadLocation,
            theme: theme,
            target: nil,
            action: nil
        )
        self.websiteDataButton = ChromeButton(title: "Manage…", theme: theme, kind: .standard)
        self.defaultBrowserButton = ChromeButton(title: "Make Default", theme: theme, kind: .standard)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 882),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = theme.colors.bgBase
        window.minSize = NSSize(width: 620, height: 882)

        rootView.wantsLayer = true
        window.contentView = rootView

        header.translatesAutoresizingMaskIntoConstraints = false
        header.font = ChromeFont.screen
        rootView.addSubview(header)

        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = ChromeFont.meta
        rootView.addSubview(subtitle)

        homepageField.isBordered = false
        homepageField.isBezeled = false
        homepageField.drawsBackground = false
        homepageField.focusRingType = .none
        homepageField.usesSingleLineMode = true
        homepageField.cell?.isScrollable = true
        homepageField.delegate = self
        homepageField.target = self
        homepageField.action = #selector(homepageSubmitted)
        homepageField.translatesAutoresizingMaskIntoConstraints = false
        homepageFrame.addSubview(homepageField)
        ChromeFieldView.styleEmbedded(homepageField, colors: theme.colors, font: ChromeFont.label)
        homepageField.stringValue = settingsStore.settings.homepage

        engineButton.target = self
        engineButton.action = #selector(enginePressed)
        themeButton.target = self
        themeButton.action = #selector(themePressed)
        appearanceButton.target = self
        appearanceButton.action = #selector(appearancePressed)
        downloadButton.target = self
        downloadButton.action = #selector(downloadPressed)
        doneButton.target = self
        doneButton.action = #selector(donePressed)
        restoreSwitch.target = self
        restoreSwitch.action = #selector(restoreChanged)
        verticalTabsSwitch.target = self
        verticalTabsSwitch.action = #selector(verticalTabsChanged)
        suggestionsSwitch.target = self
        suggestionsSwitch.action = #selector(suggestionsChanged)
        askDownloadSwitch.target = self
        askDownloadSwitch.action = #selector(askDownloadChanged)
        websiteDataButton.target = self
        websiteDataButton.action = #selector(websiteDataPressed)
        defaultBrowserButton.target = self
        defaultBrowserButton.action = #selector(makeDefaultPressed)
        defaultBrowserLabel.font = ChromeFont.label
        defaultBrowserLabel.lineBreakMode = .byTruncatingTail

        downloadLabel.translatesAutoresizingMaskIntoConstraints = false
        downloadLabel.font = ChromeFont.monoSmall
        downloadLabel.lineBreakMode = .byTruncatingMiddle
        downloadLabel.usesSingleLineMode = true
        downloadLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        downloadLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = ChromeFont.meta
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.usesSingleLineMode = true
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let rows: [[NSView]] = [
            [rowLabel("Search engine"), searchEngineRow()],
            [rowLabel("Include search engine suggestions"), suggestionsSwitch],
            [rowLabel("Homepage"), homepageFrame],
            [rowLabel("Theme"), themeButton],
            [rowLabel("Appearance"), appearanceButton],
            [rowLabel("Default page zoom"), defaultZoomButton],
            [rowLabel("Restore session"), restoreSwitch],
            [rowLabel("Remove history items"), historyRetentionButton],
            [rowLabel("Vertical tabs"), verticalTabsSwitch],
            [rowLabel("Put inactive tabs to sleep"), tabSleepButton],
            [rowLabel("Downloads"), downloadRow()],
            [rowLabel("Ask where to save"), askDownloadSwitch],
            [rowLabel("Autoplay"), autoplayButton],
            [rowLabel("Notifications"), notificationsRow()],
            [rowLabel("Block ads and trackers"), contentBlockingRow()],
            [rowLabel("Keyboard shortcuts"), shortcutsRow()],
            [rowLabel("Websites"), websitesButton],
            [rowLabel("Website data"), websiteDataButton],
            [rowLabel("Default browser"), defaultBrowserRow()],
            [rowLabel("Links from other apps"), linkRoutingButton],
            [rowLabel("Extensions"), extensionsButton],
        ]
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        // 21 rows; the window stays under 900 pt for small displays.
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        rootView.addSubview(grid)

        rootView.addSubview(pathLabel)
        rootView.addSubview(doneButton)
        refreshDownloadLabel()
        refreshDefaultBrowser()
        refreshContentBlocking()
        contentBlockerObservation = contentBlocker.changes.observe { [weak self] in
            self?.refreshContentBlocking()
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 42),
            header.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 28),
            subtitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),

            grid.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 26),
            grid.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -28),

            engineButton.widthAnchor.constraint(equalToConstant: 200),
            themeButton.widthAnchor.constraint(equalToConstant: 200),
            appearanceButton.widthAnchor.constraint(equalToConstant: 200),
            homepageFrame.widthAnchor.constraint(equalToConstant: 320),
            homepageFrame.heightAnchor.constraint(equalToConstant: 26),
            homepageField.leadingAnchor.constraint(equalTo: homepageFrame.leadingAnchor, constant: 8),
            homepageField.trailingAnchor.constraint(equalTo: homepageFrame.trailingAnchor, constant: -8),
            homepageField.centerYAnchor.constraint(equalTo: homepageFrame.centerYAnchor),

            downloadLabel.widthAnchor.constraint(equalToConstant: 240),
            downloadButton.widthAnchor.constraint(equalToConstant: 92),
            websiteDataButton.widthAnchor.constraint(equalToConstant: 200),
            defaultBrowserButton.widthAnchor.constraint(equalToConstant: 112),

            pathLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 28),
            pathLabel.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -16),
            pathLabel.widthAnchor.constraint(equalToConstant: 420),
            pathLabel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -24),

            doneButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            doneButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])

        applyTheme(theme)
    }

    /// The default browser can change outside the app between openings.
    override func showWindow(_ sender: Any?) {
        refreshDefaultBrowser()
        super.showWindow(sender)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func rowLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = ChromeFont.label
        label.textColor = theme.colors.textMuted
        label.alignment = .right
        rowLabels.append(label)
        return label
    }

    private func downloadRow() -> NSView {
        let stack = NSStackView(views: [downloadLabel, downloadButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    /// The default engine's menu and Manage… (custom engines and keywords).
    private func searchEngineRow() -> NSView {
        let stack = NSStackView(views: [engineButton, searchEnginesButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    private func defaultBrowserRow() -> NSView {
        let stack = NSStackView(views: [defaultBrowserLabel, defaultBrowserButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    private func refreshDefaultBrowser() {
        let handler = BrowserDefaultBrowser.currentHandler()
        let isDefault = BrowserDefaultBrowser.isDefault(handler: handler)
        defaultBrowserLabel.stringValue = BrowserDefaultBrowser.displayName(of: handler)
        defaultBrowserLabel.toolTip = handler?.path
        defaultBrowserButton.title = isDefault ? "Default" : "Make Default"
        defaultBrowserButton.isEnabled = !isDefault && BrowserDefaultBrowser.canBecomeDefault()
    }

    private func refreshDownloadLabel() {
        downloadLabel.stringValue = settingsStore.settings.downloadDirectoryURL.path
        downloadLabel.toolTip = settingsStore.settings.downloadDirectoryURL.path
    }

    private func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        rootView.layer?.backgroundColor = theme.colors.bgBase.cgColor
        window?.backgroundColor = theme.colors.bgBase
        header.textColor = theme.colors.textPrimary
        subtitle.textColor = theme.colors.textMuted
        for label in rowLabels {
            label.textColor = theme.colors.textMuted
        }
        engineButton.apply(theme: theme)
        searchEnginesButton.apply(theme: theme)
        searchEnginesSheet?.apply(theme: theme)
        shortcutsButton.apply(theme: theme)
        globalLittleArcSwitch.apply(theme: theme)
        globalLittleArcButton.apply(theme: theme)
        shortcutsSheet?.apply(theme: theme)
        themeButton.apply(theme: theme)
        appearanceButton.apply(theme: theme)
        downloadButton.apply(theme: theme)
        doneButton.apply(theme: theme)
        homepageFrame.apply(theme: theme)
        ChromeFieldView.styleEmbedded(homepageField, colors: theme.colors, font: ChromeFont.label)
        restoreSwitch.apply(theme: theme)
        verticalTabsSwitch.apply(theme: theme)
        suggestionsSwitch.apply(theme: theme)
        autoplayButton.apply(theme: theme)
        historyRetentionButton.apply(theme: theme)
        tabSleepButton.apply(theme: theme)
        defaultZoomButton.apply(theme: theme)
        notificationsSwitch.apply(theme: theme)
        notificationsLabel.textColor = theme.colors.textPrimary
        websitesButton.apply(theme: theme)
        linkRoutingButton.apply(theme: theme)
        extensionsButton.apply(theme: theme)
        askDownloadSwitch.apply(theme: theme)
        blockAdsSwitch.apply(theme: theme)
        updateListsButton.apply(theme: theme)
        blockerStatusLabel.textColor = theme.colors.textMuted
        websiteDataButton.apply(theme: theme)
        defaultBrowserButton.apply(theme: theme)
        defaultBrowserLabel.textColor = theme.colors.textPrimary
        downloadLabel.textColor = theme.colors.textPrimary
        pathLabel.textColor = theme.colors.textMuted
        pathLabel.stringValue = "Settings: \(settingsStore.displayPath)"
        pathLabel.toolTip = settingsStore.url.path
        needsLayout()
    }

    private func needsLayout() {
        rootView.needsLayout = true
        rootView.layoutSubtreeIfNeeded()
    }

    private func refresh() {
        engineButton.title = settingsStore.settings.defaultSearchEngine.name
        themeButton.title = AppTheme.options.first { $0.id == settingsStore.settings.themeID }?.name
            ?? settingsStore.settings.themeID
        appearanceButton.title = settingsStore.settings.appearance.name
        homepageField.stringValue = settingsStore.settings.homepage
        restoreSwitch.isOn = settingsStore.settings.restoreSession
        verticalTabsSwitch.isOn = settingsStore.settings.usesVerticalTabs
        suggestionsSwitch.isOn = settingsStore.settings.includeSearchSuggestions
        autoplayButton.title = settingsStore.settings.autoplay.name
        historyRetentionButton.title = settingsStore.settings.historyRetention.name
        tabSleepButton.title = settingsStore.settings.tabSleep.name
        defaultZoomButton.title = BrowserZoom.percent(settingsStore.settings.defaultZoom)
        notificationsSwitch.isOn = settingsStore.settings.allowsNotificationRequests
        askDownloadSwitch.isOn = settingsStore.settings.askDownloadLocation
        blockAdsSwitch.isOn = settingsStore.settings.blockAdsAndTrackers
        globalLittleArcSwitch.isOn = settingsStore.settings.globalLittleArcEnabled
        globalLittleArcButton.title = globalLittleArcTitle
        refreshContentBlocking()
        refreshDefaultBrowser()
        refreshDownloadLabel()
        needsLayout()
    }

    @objc private func enginePressed() {
        let engines = settingsStore.settings.searchEngines
        showMenu(
            from: engineButton,
            items: engines.all.map { engine in
                (engine.name, engine.id == engines.defaultID, { [weak self] in
                    self?.settingsStore.update { $0.searchEngines.setDefault(engine.id) }
                    self?.refresh()
                })
            }
        )
    }

    /// Opens Settings ▸ Search engine ▸ Manage… as a sheet on Settings.
    @objc func searchEnginesPressed() {
        guard let window, searchEnginesSheet == nil else { return }
        let sheet = BrowserSearchEnginesSheet(settingsStore: settingsStore, theme: theme)
        guard let sheetWindow = sheet.window else { return }
        searchEnginesSheet = sheet
        window.beginSheet(sheetWindow) { [weak self] _ in
            self?.searchEnginesSheet = nil
            // A deleted default engine fell back to DuckDuckGo.
            self?.refresh()
        }
    }

    /// Opens Settings ▸ Keyboard shortcuts ▸ Customize… as a sheet on
    /// Settings.
    @objc func shortcutsPressed() {
        guard let window, shortcutsSheet == nil else { return }
        let sheet = BrowserShortcutsSheet(settingsStore: settingsStore, theme: theme)
        guard let sheetWindow = sheet.window else { return }
        shortcutsSheet = sheet
        window.beginSheet(sheetWindow) { [weak self] _ in
            self?.shortcutsSheet = nil
        }
    }

    /// Customize…, then "New Little Arc from any app": its switch and
    /// shortcut.
    private func shortcutsRow() -> NSView {
        let stack = NSStackView(views: [shortcutsButton, globalLittleArcSwitch, globalLittleArcButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    /// "(unavailable)" when the switch is on but the system refused the
    /// shortcut (another app holds it, or no key types it).
    private var globalLittleArcTitle: String {
        let settings = settingsStore.settings
        let shortcut = BrowserShortcut(settings.globalLittleArcShortcut)?.display ?? "⌥⌘N"
        let unavailable = settings.globalLittleArcEnabled && globalShortcutMonitor == nil
            && globalHotKey.map { !$0.isRegistered } == true
        return "Little Arc anywhere: \(shortcut)" + (unavailable ? " (unavailable)" : "")
    }

    @objc private func globalLittleArcChanged() {
        let value = globalLittleArcSwitch.isOn
        settingsStore.update { $0.globalLittleArcEnabled = value }
        globalLittleArcButton.title = globalLittleArcTitle
    }

    /// The next acceptable shortcut typed in Settings (with ⌘ or ⌃, or ⌥
    /// on a named key; nothing the system, text editing or another command
    /// uses: `BrowserGlobalShortcut`) becomes the global one and turns it
    /// on; anything else beeps. Esc, leaving the window or closing it
    /// cancels. Keys typed in other windows pass by, and the registered
    /// hotkey lets go meanwhile so its own combination can be typed.
    @objc private func recordGlobalLittleArc() {
        guard globalShortcutMonitor == nil else { return }
        globalHotKey?.suspend()
        globalLittleArcButton.title = "Type a shortcut…"
        globalShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch BrowserGlobalShortcut.recorderAnswer(
                keyCode: event.keyCode,
                shortcut: BrowserShortcut(event: event),
                inRecorderWindow: event.window != nil && event.window === self.window,
                keymap: self.settingsStore.settings.keymap
            ) {
            case .pass:
                return event
            case .cancel:
                self.finishRecordingGlobalShortcut(nil)
            case .refuse:
                NSSound.beep()
            case let .accept(shortcut):
                self.finishRecordingGlobalShortcut(shortcut)
            }
            return nil
        }
        if let window {
            globalShortcutObservers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finishRecordingGlobalShortcut(nil) }
                }
            }
        }
    }

    private func finishRecordingGlobalShortcut(_ shortcut: BrowserShortcut?) {
        guard let monitor = globalShortcutMonitor else { return }
        NSEvent.removeMonitor(monitor)
        globalShortcutMonitor = nil
        globalShortcutObservers.forEach(NotificationCenter.default.removeObserver)
        globalShortcutObservers = []
        // The old shortcut comes back first; a new one replaces it.
        globalHotKey?.resume()
        if let shortcut {
            settingsStore.update {
                $0.globalLittleArcShortcut = shortcut.storageText
                $0.globalLittleArcEnabled = true
            }
        }
        refresh()
    }

    /// Shows `page`: the sheet it names on Settings (none for General).
    func show(_ page: BrowserSettingsPage) {
        guard let window, window.attachedSheet == nil else { return }
        switch page {
        case .general: break
        case .searchEngines: searchEnginesPressed()
        case .shortcuts: shortcutsPressed()
        case .websites: onShowWebsites?(window)
        case .websiteData: onShowWebsiteData?(window)
        case .extensions: onShowExtensions?(window)
        }
    }

    @objc private func themePressed() {
        let current = settingsStore.settings.themeID
        showMenu(
            from: themeButton,
            items: AppTheme.options.map { option in
                (option.name, option.id == current, { [weak self] in
                    guard let self else { return }
                    self.settingsStore.update { $0.themeID = option.id }
                    self.themeManager.update(
                        themeId: option.id,
                        appearance: self.settingsStore.settings.appearance
                    )
                    self.applyTheme(self.themeManager.currentTheme)
                    self.refresh()
                })
            }
        )
    }

    @objc private func appearancePressed() {
        let current = settingsStore.settings.appearance
        showMenu(
            from: appearanceButton,
            items: AppearancePreference.allCases.map { preference in
                (preference.name, preference == current, { [weak self] in
                    guard let self else { return }
                    self.settingsStore.update { $0.appearance = preference }
                    self.themeManager.setAppearance(preference)
                    self.applyTheme(self.themeManager.currentTheme)
                    self.refresh()
                })
            }
        )
    }

    @objc private func restoreChanged() {
        let value = restoreSwitch.isOn
        settingsStore.update { $0.restoreSession = value }
    }

    @objc private func verticalTabsChanged() {
        let value = verticalTabsSwitch.isOn
        settingsStore.update { $0.verticalTabs = value }
    }

    @objc private func suggestionsChanged() {
        let value = suggestionsSwitch.isOn
        settingsStore.update { $0.includeSearchSuggestions = value }
    }

    @objc private func askDownloadChanged() {
        let value = askDownloadSwitch.isOn
        settingsStore.update { $0.askDownloadLocation = value }
    }

    /// Opens the Website Data list as a sheet on Settings.
    @objc func websiteDataPressed() {
        guard let window else { return }
        onShowWebsiteData?(window)
    }

    @objc private func makeDefaultPressed() {
        BrowserDefaultBrowser.makeDefault { [weak self] _ in
            self?.refreshDefaultBrowser()
        }
    }

    @objc private func downloadPressed() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settingsStore.settings.downloadDirectoryURL
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.settingsStore.update { $0.downloadDirectory = url.path }
            self?.refreshDownloadLabel()
        }
    }

    @objc private func homepageSubmitted() {
        settingsStore.update {
            $0.homepage = homepageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === homepageField else { return }
        homepageSubmitted()
    }

    @objc private func donePressed() {
        window?.close()
    }

    private func showMenu(
        from button: ChromeButton,
        items: [(title: String, selected: Bool, run: () -> Void)]
    ) {
        let menu = NSMenu()
        for entry in items {
            let item = NSMenuItem(
                title: entry.title,
                action: #selector(menuItemSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = MenuAction(entry.run)
            item.state = entry.selected ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
    }

    @objc private func menuItemSelected(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }
}

extension SettingsWindowController {
    private func notificationsRow() -> NSView {
        notificationsLabel.font = ChromeFont.label
        // The control column is 200 pt wide; the sentence wraps beside the switch.
        notificationsLabel.preferredMaxLayoutWidth = 200 - Chrome.switchSize.width - 8
        notificationsSwitch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            notificationsSwitch.widthAnchor.constraint(equalToConstant: Chrome.switchSize.width),
            notificationsSwitch.heightAnchor.constraint(equalToConstant: Chrome.switchSize.height),
        ])
        let stack = NSStackView(views: [notificationsSwitch, notificationsLabel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    /// The switch and Update Now, with the lists' status under them.
    private func contentBlockingRow() -> NSView {
        blockAdsSwitch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            blockAdsSwitch.widthAnchor.constraint(equalToConstant: Chrome.switchSize.width),
            blockAdsSwitch.heightAnchor.constraint(equalToConstant: Chrome.switchSize.height),
            updateListsButton.widthAnchor.constraint(equalToConstant: 104),
            blockerStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])
        blockerStatusLabel.font = ChromeFont.meta
        // Two lines in the 200 pt control column; a longer status
        // truncates (the tooltip has it all).
        blockerStatusLabel.lineBreakMode = .byWordWrapping
        blockerStatusLabel.maximumNumberOfLines = 2
        blockerStatusLabel.preferredMaxLayoutWidth = 200
        blockerStatusLabel.cell?.wraps = true
        blockerStatusLabel.cell?.truncatesLastVisibleLine = true
        let controls = NSStackView(views: [blockAdsSwitch, updateListsButton])
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.alignment = .centerY
        let stack = NSStackView(views: [controls, blockerStatusLabel])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .leading
        return stack
    }

    private func refreshContentBlocking() {
        blockerStatusLabel.stringValue = contentBlocker.statusText
        blockerStatusLabel.toolTip = contentBlocker.statusText
        updateListsButton.isEnabled = contentBlocker.isEnabled && !contentBlocker.isUpdating
    }

    @objc private func blockAdsChanged() {
        let value = blockAdsSwitch.isOn
        settingsStore.update { $0.blockAdsAndTrackers = value }
    }

    /// Downloads both lists now (conditionally) and recompiles what changed.
    @objc func updateListsPressed() {
        let blocker = contentBlocker
        Task { await blocker.update() }
    }

    @objc private func autoplayPressed() {
        let current = settingsStore.settings.autoplay
        showMenu(
            from: autoplayButton,
            items: AutoplayPolicy.allCases.map { policy in
                (policy.name, policy == current, { [weak self] in
                    self?.settingsStore.update { $0.autoplay = policy }
                    self?.refresh()
                })
            }
        )
    }

    @objc private func historyRetentionPressed() {
        let current = settingsStore.settings.historyRetention
        showMenu(
            from: historyRetentionButton,
            items: BrowserHistoryRetention.allCases.map { retention in
                (retention.name, retention == current, { [weak self] in
                    self?.settingsStore.update { $0.historyRetention = retention }
                    self?.refresh()
                })
            }
        )
    }

    @objc private func tabSleepPressed() {
        let current = settingsStore.settings.tabSleep
        showMenu(
            from: tabSleepButton,
            items: BrowserTabSleepAfter.allCases.map { option in
                (option.name, option == current, { [weak self] in
                    self?.settingsStore.update { $0.tabSleep = option }
                    self?.refresh()
                })
            }
        )
    }

    @objc private func defaultZoomPressed() {
        let current = settingsStore.settings.defaultZoom
        showMenu(
            from: defaultZoomButton,
            items: BrowserZoom.steps.map { zoom in
                (BrowserZoom.percent(zoom), BrowserZoom.isSame(zoom, current), { [weak self] in
                    self?.settingsStore.update { $0.defaultZoom = zoom }
                    self?.refresh()
                })
            }
        )
    }

    @objc private func notificationsChanged() {
        let value = notificationsSwitch.isOn
        settingsStore.update { $0.allowsNotificationRequests = value }
    }

    @objc private func websitesPressed() {
        guard let window else { return }
        onShowWebsites?(window)
    }

    @objc private func linkRoutingPressed() {
        guard let window else { return }
        onShowLinkRouting?(window)
    }

    @objc func extensionsPressed() {
        guard let window else { return }
        onShowExtensions?(window)
    }
}

private final class MenuAction: NSObject {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}
