import AppKit
import WebKit

/// Settings ▸ Extensions ▸ Manage…: install from a Chrome Web Store link
/// or id, load an unpacked folder, and for each installed extension its
/// switch, "Allow in private windows", site access and Remove. Presented
/// as a sheet on the Settings window.
@MainActor
final class BrowserExtensionsSheet: NSWindowController, NSTextFieldDelegate {
    private let extensions: BrowserExtensions
    /// The host of the active window's page, for "Allow on <host>".
    private let currentHost: () -> String?
    private var theme: AppTheme
    private var observation: BrowserObservation?

    private let rootView = NSView()
    private let header = NSTextField(labelWithString: "Extensions")
    private let subtitle = NSTextField(
        wrappingLabelWithString: "Chrome extensions run in every Space; private windows only when you allow it. "
            + "Install from the Chrome Web Store with its link or id, or load an unpacked folder."
    )
    private let inputFrame: ChromeFieldView
    let inputField = NSTextField()
    private let installButton: ChromeButton
    private let unpackedButton: ChromeButton
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No extensions installed")
    private let topRule: ChromeRuleView
    private let bottomRule: ChromeRuleView
    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private let stack = NSStackView()
    private let doneButton: ChromeButton
    private var rowViews: [RowView] = []

    init(extensions: BrowserExtensions, theme: AppTheme, currentHost: @escaping () -> String?) {
        self.extensions = extensions
        self.currentHost = currentHost
        self.theme = theme
        inputFrame = ChromeFieldView(theme: theme)
        installButton = ChromeButton(title: "Install", theme: theme, kind: .standard)
        unpackedButton = ChromeButton(title: "Load Unpacked…", theme: theme, kind: .standard)
        topRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        bottomRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        doneButton = ChromeButton(title: "Done", theme: theme, kind: .ink, keycap: "esc")
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Extensions"
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        rootView.wantsLayer = true

        header.font = ChromeFont.headline
        subtitle.font = ChromeFont.meta
        subtitle.preferredMaxLayoutWidth = 592
        emptyLabel.font = ChromeFont.label
        statusLabel.font = ChromeFont.meta
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        inputField.isBordered = false
        inputField.isBezeled = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.usesSingleLineMode = true
        inputField.cell?.isScrollable = true
        inputField.delegate = self
        inputField.target = self
        inputField.action = #selector(installPressed)
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputFrame.translatesAutoresizingMaskIntoConstraints = false
        inputFrame.addSubview(inputField)

        installButton.target = self
        installButton.action = #selector(installPressed)
        unpackedButton.target = self
        unpackedButton.action = #selector(loadUnpackedPressed)
        doneButton.target = self
        doneButton.action = #selector(donePressed)
        doneButton.keyEquivalent = "\u{1b}"

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.addSubview(stack)
        scrollView.documentView = listView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        for view in [header, subtitle, inputFrame, installButton, unpackedButton, statusLabel, topRule, scrollView,
                     emptyLabel, bottomRule, doneButton] as [NSView]
        {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            subtitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),

            inputFrame.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            inputFrame.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            inputFrame.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),
            inputField.leadingAnchor.constraint(equalTo: inputFrame.leadingAnchor, constant: 8),
            inputField.trailingAnchor.constraint(equalTo: inputFrame.trailingAnchor, constant: -8),
            inputField.centerYAnchor.constraint(equalTo: inputFrame.centerYAnchor),
            installButton.leadingAnchor.constraint(equalTo: inputFrame.trailingAnchor, constant: 8),
            installButton.centerYAnchor.constraint(equalTo: inputFrame.centerYAnchor),
            installButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            unpackedButton.leadingAnchor.constraint(equalTo: installButton.trailingAnchor, constant: 8),
            unpackedButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            unpackedButton.centerYAnchor.constraint(equalTo: inputFrame.centerYAnchor),
            statusLabel.topAnchor.constraint(equalTo: inputFrame.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),

            topRule.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            topRule.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),

            emptyLabel.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 18),
            emptyLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),

            listView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            listView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: listView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: listView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: listView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: listView.bottomAnchor),

            bottomRule.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -14),

            doneButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            doneButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])

        observation = extensions.changes.observe { [weak self] in self?.reload() }
        apply(theme: theme)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        rootView.layer?.backgroundColor = theme.colors.bgBase.cgColor
        window?.backgroundColor = theme.colors.bgBase
        header.textColor = theme.colors.textPrimary
        subtitle.textColor = theme.colors.textMuted
        emptyLabel.textColor = theme.colors.textMuted
        statusLabel.textColor = theme.colors.textMuted
        inputFrame.apply(theme: theme)
        ChromeFieldView.styleEmbedded(inputField, colors: theme.colors, font: ChromeFont.label)
        inputField.placeholderAttributedString = NSAttributedString(
            string: "Chrome Web Store link or extension id",
            attributes: [.foregroundColor: theme.colors.textMuted, .font: ChromeFont.label]
        )
        topRule.color = theme.colors.borderSubtle
        bottomRule.color = theme.colors.borderSubtle
        for button in [installButton, unpackedButton, doneButton] {
            button.apply(theme: theme)
        }
        rowViews.forEach { $0.apply(theme: theme) }
    }

    /// Every row as the sheet shows it, for the harness.
    var dump: [String] {
        rowViews.map(\.summary)
    }

    func reload() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = extensions.records.map { record in
            let context = extensions.context(id: record.id)
            let row = RowView(
                record: record,
                context: context,
                error: extensions.loadErrors[record.id] ?? context.flatMap(Self.firstError),
                isBusy: extensions.busy.contains(record.id),
                theme: theme
            )
            row.onEnabled = { [weak self] id, on in self?.run { try await $0.setEnabled(id, on) } }
            row.onPrivate = { [weak self] id, on in self?.run { try $0.setAllowsPrivate(id, on) } }
            row.onSiteAccess = { [weak self] id, view in self?.showSiteAccessMenu(id, from: view) }
            row.onRemove = { [weak self] id in self?.confirmRemove(id) }
            return row
        }
        for view in rowViews {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        emptyLabel.isHidden = !rowViews.isEmpty
        let busy = extensions.busy.compactMap { id in extensions.records.first { $0.id == id }?.name ?? id }
        installButton.isEnabled = true
        if !busy.isEmpty {
            setStatus("Installing \(busy.sorted().joined(separator: ", "))…")
        }
        rootView.layoutSubtreeIfNeeded()
    }

    private static func firstError(_ context: WKWebExtensionContext) -> String? {
        (context.errors.first ?? context.webExtension.errors.first).map { ($0 as NSError).localizedDescription }
    }

    private func setStatus(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
        statusLabel.textColor = isError ? theme.colors.danger : theme.colors.textMuted
    }

    private func run(_ work: @escaping @MainActor (BrowserExtensions) async throws -> Void) {
        let extensions = extensions
        Task { @MainActor [weak self] in
            do {
                try await work(extensions)
            } catch {
                self?.setStatus(error.localizedDescription, isError: true)
                self?.reload()
            }
        }
    }

    // MARK: Actions

    @objc func installPressed() {
        let input = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        install(input)
    }

    func install(_ input: String) {
        setStatus("Installing…")
        let extensions = extensions
        Task { @MainActor [weak self] in
            do {
                let record = try await extensions.install(input)
                self?.inputField.stringValue = ""
                self?.setStatus("Installed \(record.name) \(record.version).")
            } catch {
                self?.setStatus("Couldn’t install: \(error.localizedDescription)", isError: true)
            }
        }
    }

    @objc private func loadUnpackedPressed() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Load"
        panel.message = "Choose an extension folder (the one with manifest.json)."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.install(url.path) }
        }
    }

    private func showSiteAccessMenu(_ id: String, from view: NSView) {
        guard let record = extensions.store.record(id: id) else { return }
        let menu = NSMenu()
        for access in BrowserExtensionRecord.SiteAccess.allCases {
            let item = BrowserClosureMenuItem(title: access.title) { [weak self] in
                self?.run { try $0.setSiteAccess(id, access) }
            }
            item.state = record.siteAccess == access ? .on : .off
            menu.addItem(item)
        }
        let sites = record.allowedSites
        if let host = currentHost().map(BrowserExtensions.siteHost), !host.isEmpty, !sites.contains(host) {
            menu.addItem(.separator())
            menu.addItem(BrowserClosureMenuItem(title: "Allow on \(host)") { [weak self] in
                self?.run { try $0.setSite(id, host: host, allowed: true) }
            })
        }
        if !sites.isEmpty {
            menu.addItem(.separator())
            let heading = NSMenuItem(title: "Allowed sites (choose one to remove it)", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for site in sites {
                let item = BrowserClosureMenuItem(title: site) { [weak self] in
                    self?.run { try $0.setSite(id, host: site, allowed: false) }
                }
                item.state = .on
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private func confirmRemove(_ id: String) {
        guard let window, let record = extensions.store.record(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(record.name)”?"
        alert.informativeText = "Its settings and the data it stored are deleted."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.run { try await $0.remove(id) }
            }
        }
    }

    @objc private func donePressed() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// One extension: icon, name and version, id and source (or why it
    /// doesn't run), and its controls.
    private final class RowView: NSView {
        var onEnabled: ((String, Bool) -> Void)?
        var onPrivate: ((String, Bool) -> Void)?
        var onSiteAccess: ((String, NSView) -> Void)?
        var onRemove: ((String) -> Void)?

        private let id: String
        let summary: String
        private let iconView = NSImageView()
        private let nameLabel: NSTextField
        private let detailLabel: NSTextField
        private let errorLabel: NSTextField
        private let enabledSwitch: ChromeSwitch
        private let privateSwitch: ChromeSwitch
        private let privateLabel = NSTextField(labelWithString: "Allow in private windows")
        private let siteButton: ChromeButton
        private let removeButton: ChromeButton
        private let rule: ChromeRuleView

        init(record: BrowserExtensionRecord, context: WKWebExtensionContext?, error: String?, isBusy: Bool, theme: AppTheme) {
            id = record.id
            let forbidsPrivate = context.map { BrowserExtensions.forbidsPrivate($0.webExtension) } ?? false
            let state = isBusy ? "updating" : (!record.isEnabled ? "off" : (context == nil ? "not running" : "on"))
            summary = "\(record.name) \(record.version) [\(record.id)] \(state); "
                + "private \(record.allowsPrivate ? "allowed" : "off"); site access \(record.siteAccess.rawValue)"
                + (record.allowedSites.isEmpty ? "" : " \(record.allowedSites.joined(separator: ","))")
                + (error.map { "; error: \($0)" } ?? "")
            nameLabel = NSTextField(labelWithString: "\(record.name)  \(record.version)")
            detailLabel = NSTextField(labelWithString: "\(record.id) · \(record.source.title)")
            errorLabel = NSTextField(labelWithString: error ?? "")
            enabledSwitch = ChromeSwitch(isOn: record.isEnabled, theme: theme)
            privateSwitch = ChromeSwitch(isOn: record.allowsPrivate && !forbidsPrivate, theme: theme)
            siteButton = ChromeButton(title: record.siteAccess.title, theme: theme, kind: .standard)
            removeButton = ChromeButton(title: "Remove", theme: theme, kind: .standard)
            rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            iconView.image = context?.webExtension.icon(for: CGSize(width: 32, height: 32))
                ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            nameLabel.font = ChromeFont.labelStrong
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detailLabel.font = ChromeFont.monoSmall
            detailLabel.lineBreakMode = .byTruncatingMiddle
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            errorLabel.font = ChromeFont.meta
            errorLabel.lineBreakMode = .byTruncatingTail
            errorLabel.toolTip = error
            errorLabel.isHidden = error == nil
            errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            privateLabel.font = ChromeFont.label
            privateSwitch.isEnabled = !forbidsPrivate && !isBusy
            privateSwitch.toolTip = forbidsPrivate ? "This extension doesn't run in private windows." : nil
            enabledSwitch.isEnabled = !isBusy
            enabledSwitch.setAccessibilityLabel("Turn \(record.name) on or off")
            enabledSwitch.target = self
            enabledSwitch.action = #selector(enabledChanged)
            privateSwitch.target = self
            privateSwitch.action = #selector(privateChanged)
            siteButton.target = self
            siteButton.action = #selector(sitePressed)
            removeButton.target = self
            removeButton.action = #selector(removePressed)
            removeButton.isEnabled = !isBusy

            let controls = NSStackView(views: [siteButton, privateSwitch, privateLabel])
            controls.orientation = .horizontal
            controls.spacing = 8
            controls.alignment = .centerY
            controls.setCustomSpacing(16, after: siteButton)
            for view in [iconView, nameLabel, detailLabel, errorLabel, controls, enabledSwitch, removeButton, rule] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: error == nil ? 92 : 108),
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                iconView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
                iconView.widthAnchor.constraint(equalToConstant: 32),
                iconView.heightAnchor.constraint(equalToConstant: 32),
                nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
                nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: enabledSwitch.leadingAnchor, constant: -12),
                detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
                detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
                detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: enabledSwitch.leadingAnchor, constant: -12),
                errorLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
                errorLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 3),
                errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
                controls.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
                controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
                siteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
                enabledSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                enabledSwitch.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
                removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                removeButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
                removeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
                rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                rule.trailingAnchor.constraint(equalTo: trailingAnchor),
                rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            apply(theme: theme)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func apply(theme: AppTheme) {
            nameLabel.textColor = theme.colors.textPrimary
            detailLabel.textColor = theme.colors.textMuted
            errorLabel.textColor = theme.colors.danger
            privateLabel.textColor = theme.colors.textPrimary
            rule.color = theme.colors.borderSubtle
            enabledSwitch.apply(theme: theme)
            privateSwitch.apply(theme: theme)
            siteButton.apply(theme: theme)
            removeButton.apply(theme: theme)
        }

        @objc private func enabledChanged() {
            onEnabled?(id, enabledSwitch.isOn)
        }

        @objc private func privateChanged() {
            onPrivate?(id, privateSwitch.isOn)
        }

        @objc private func sitePressed() {
            onSiteAccess?(id, siteButton)
        }

        @objc private func removePressed() {
            onRemove?(id)
        }
    }
}

extension BrowserWindowManager {
    /// Settings ▸ Extensions, as a sheet on Settings.
    func showExtensions(on parent: NSWindow) {
        let sheet = extensionsSheet ?? makeExtensionsSheet()
        extensionsSheet = sheet
        sheet.apply(theme: themeManager.currentTheme)
        sheet.reload()
        guard let window = sheet.window, window.sheetParent == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.extensionsSheet = nil
        }
    }

    func makeExtensionsSheet() -> BrowserExtensionsSheet {
        BrowserExtensionsSheet(extensions: extensions, theme: themeManager.currentTheme) { [weak self] in
            self?.activeController?.selectedPageURL?.host
        }
    }
}
