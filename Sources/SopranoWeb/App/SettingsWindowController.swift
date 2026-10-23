import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let settingsStore: BrowserSettingsStore
    private let themeManager: ThemeManager
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
    private lazy var autoplayButton: ChromeButton = {
        let button = ChromeButton(title: settingsStore.settings.autoplay.name, theme: theme, kind: .standard)
        button.target = self
        button.action = #selector(autoplayPressed)
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
    private let askDownloadSwitch: ChromeSwitch
    private let websiteDataButton: ChromeButton
    private let defaultBrowserLabel = NSTextField(labelWithString: "")
    private let defaultBrowserButton: ChromeButton
    private var websiteDataSheet: BrowserWebsiteDataSheet?

    init(settingsStore: BrowserSettingsStore, themeManager: ThemeManager) {
        self.settingsStore = settingsStore
        self.themeManager = themeManager
        self.theme = themeManager.currentTheme
        self.engineButton = ChromeButton(
            title: settingsStore.settings.searchEngine.name,
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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 768),
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
        window.minSize = NSSize(width: 620, height: 768)

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
            [rowLabel("Search engine"), engineButton],
            [rowLabel("Include search engine suggestions"), suggestionsSwitch],
            [rowLabel("Homepage"), homepageFrame],
            [rowLabel("Theme"), themeButton],
            [rowLabel("Appearance"), appearanceButton],
            [rowLabel("Restore session"), restoreSwitch],
            [rowLabel("Vertical tabs"), verticalTabsSwitch],
            [rowLabel("Downloads"), downloadRow()],
            [rowLabel("Ask where to save"), askDownloadSwitch],
            [rowLabel("Autoplay"), autoplayButton],
            [rowLabel("Notifications"), notificationsRow()],
            [rowLabel("Websites"), websitesButton],
            [rowLabel("Website data"), websiteDataButton],
            [rowLabel("Default browser"), defaultBrowserRow()],
        ]
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 16
        grid.columnSpacing = 18
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        rootView.addSubview(grid)

        rootView.addSubview(pathLabel)
        rootView.addSubview(doneButton)
        refreshDownloadLabel()
        refreshDefaultBrowser()

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
        notificationsSwitch.apply(theme: theme)
        notificationsLabel.textColor = theme.colors.textPrimary
        websitesButton.apply(theme: theme)
        askDownloadSwitch.apply(theme: theme)
        websiteDataButton.apply(theme: theme)
        defaultBrowserButton.apply(theme: theme)
        defaultBrowserLabel.textColor = theme.colors.textPrimary
        websiteDataSheet?.apply(theme: theme)
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
        engineButton.title = settingsStore.settings.searchEngine.name
        themeButton.title = AppTheme.options.first { $0.id == settingsStore.settings.themeID }?.name
            ?? settingsStore.settings.themeID
        appearanceButton.title = settingsStore.settings.appearance.name
        homepageField.stringValue = settingsStore.settings.homepage
        restoreSwitch.isOn = settingsStore.settings.restoreSession
        verticalTabsSwitch.isOn = settingsStore.settings.usesVerticalTabs
        suggestionsSwitch.isOn = settingsStore.settings.includeSearchSuggestions
        autoplayButton.title = settingsStore.settings.autoplay.name
        notificationsSwitch.isOn = settingsStore.settings.allowsNotificationRequests
        askDownloadSwitch.isOn = settingsStore.settings.askDownloadLocation
        refreshDefaultBrowser()
        refreshDownloadLabel()
        needsLayout()
    }

    @objc private func enginePressed() {
        let current = settingsStore.settings.searchEngine
        showMenu(
            from: engineButton,
            items: SearchEngine.allCases.map { engine in
                (engine.name, engine == current, { [weak self] in
                    self?.settingsStore.update { $0.searchEngine = engine }
                    self?.refresh()
                })
            }
        )
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
        guard let window, websiteDataSheet == nil else { return }
        let sheet = BrowserWebsiteDataSheet(theme: theme)
        websiteDataSheet = sheet
        sheet.present(on: window) { [weak self] in
            self?.websiteDataSheet = nil
        }
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

    @objc private func notificationsChanged() {
        let value = notificationsSwitch.isOn
        settingsStore.update { $0.allowsNotificationRequests = value }
    }

    @objc private func websitesPressed() {
        guard let window else { return }
        onShowWebsites?(window)
    }
}

private final class MenuAction: NSObject {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}
