import AppKit

/// Settings ▸ Search engine ▸ Manage…: every engine with its keyword and
/// URL; Add, Edit and Delete for custom engines, Edit (the keyword only) for
/// the built-ins, which have no keyword until the user gives one.
/// Presented as a sheet on the Settings window; an engine is added or edited
/// in an alert sheet on it whose Save stays off until the engine is valid.
/// The default engine is chosen with Settings ▸ Search engine.
@MainActor
final class BrowserSearchEnginesSheet: NSWindowController {
    private let settingsStore: BrowserSettingsStore
    private var theme: AppTheme
    private var observation: BrowserObservation?
    /// The open Add/Edit form, kept while its alert is up.
    private var form: BrowserSearchEngineForm?

    private let rootView = NSView()
    private let header = NSTextField(labelWithString: "Search Engines")
    private let subtitle = NSTextField(
        wrappingLabelWithString: "Give an engine a keyword, then type the keyword, a space and your search in the "
            + "address field, for example “w cats”. A site's search URL has %s where the search terms go."
    )
    private let topRule: ChromeRuleView
    private let bottomRule: ChromeRuleView
    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private let stack = NSStackView()
    private let addButton: ChromeButton
    private let doneButton: ChromeButton
    private var rowViews: [RowView] = []

    init(settingsStore: BrowserSettingsStore, theme: AppTheme) {
        self.settingsStore = settingsStore
        self.theme = theme
        self.topRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        self.bottomRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        self.addButton = ChromeButton(title: "Add Search Engine…", theme: theme, kind: .standard)
        self.doneButton = ChromeButton(title: "Done", theme: theme, kind: .ink, keycap: "esc")
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Search Engines"
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        rootView.wantsLayer = true

        header.font = ChromeFont.headline
        subtitle.font = ChromeFont.meta
        subtitle.preferredMaxLayoutWidth = 572
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
        for view in [header, subtitle, topRule, scrollView, bottomRule, addButton, doneButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }
        addButton.target = self
        addButton.action = #selector(addPressed)
        doneButton.target = self
        doneButton.action = #selector(donePressed)
        doneButton.keyEquivalent = "\u{1b}"

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            subtitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),

            topRule.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            topRule.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),

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

            addButton.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            addButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            doneButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])

        observation = settingsStore.changes.observe { [weak self] _ in self?.reload() }
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
        topRule.color = theme.colors.borderSubtle
        bottomRule.color = theme.colors.borderSubtle
        addButton.apply(theme: theme)
        doneButton.apply(theme: theme)
        rowViews.forEach { $0.apply(theme: theme) }
    }

    /// Rebuilds the list; called on every settings change.
    func reload() {
        let engines = settingsStore.settings.searchEngines
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = engines.all.map { engine in
            let view = RowView(engine: engine, isDefault: engine.id == engines.defaultID, theme: theme)
            view.onEdit = { [weak self] id in self?.edit(id) }
            view.onDelete = { [weak self] id in self?.delete(id) }
            return view
        }
        for view in rowViews {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        rootView.layoutSubtreeIfNeeded()
    }

    // MARK: - Actions

    @objc private func addPressed() {
        showForm(for: nil)
    }

    private func edit(_ id: BrowserSearchEngineID) {
        guard let engine = settingsStore.settings.searchEngines.engine(id: id) else { return }
        showForm(for: engine)
    }

    /// Deleting the default engine makes DuckDuckGo the default.
    private func delete(_ id: BrowserSearchEngineID) {
        settingsStore.update { $0.searchEngines.remove(id: id) }
    }

    /// The Add/Edit alert sheet. Save is enabled only while the engine is
    /// valid; the form says what is missing.
    private func showForm(for engine: BrowserSearchEngine?) {
        guard let window, form == nil else { return }
        let alert = NSAlert()
        alert.messageText = engine.map { "Edit “\($0.name)”" } ?? "New Search Engine"
        alert.informativeText = engine?.isBuiltIn == true
            ? "Type the keyword and a space before a search to use this engine. Leave it empty for none."
            : "Type the keyword and a space before a search to use this engine."
        alert.addButton(withTitle: engine == nil ? "Add Search Engine" : "Save")
        alert.addButton(withTitle: "Cancel")
        let form = BrowserSearchEngineForm(engine: engine, theme: theme)
        let saveButton = alert.buttons[0]
        let validate: () -> Void = { [weak self, weak form, weak saveButton] in
            guard let self, let form else { return }
            let problem = self.settingsStore.settings.searchEngines.problem(
                name: form.name,
                keyword: form.keyword,
                template: form.template,
                editing: engine?.id
            )
            form.show(problem)
            saveButton?.isEnabled = problem == nil
        }
        form.onChange = validate
        validate()
        alert.accessoryView = form.view
        alert.window.initialFirstResponder = engine?.isBuiltIn == true ? form.keywordField : form.nameField
        self.form = form
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.form = nil
            guard response == .alertFirstButtonReturn else { return }
            let saved = BrowserSearchEngine(
                id: engine?.id ?? .makeCustom(),
                name: form.name,
                keyword: form.keyword,
                template: form.template
            )
            self.settingsStore.update { _ = $0.searchEngines.save(saved) }
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

    /// One engine: name, keyword chip and "Default", its URL under them,
    /// Edit, and Delete for a custom one ("Built in" for the others).
    private final class RowView: NSView {
        var onEdit: ((BrowserSearchEngineID) -> Void)?
        var onDelete: ((BrowserSearchEngineID) -> Void)?

        private let engine: BrowserSearchEngine
        private let nameLabel: NSTextField
        private let keywordChip: ChromeChip
        private let detailLabel: NSTextField
        private let templateLabel: NSTextField
        private let editButton: ChromeButton
        private let deleteButton: ChromeButton
        private let rule: ChromeRuleView

        init(engine: BrowserSearchEngine, isDefault: Bool, theme: AppTheme) {
            self.engine = engine
            nameLabel = NSTextField(labelWithString: engine.name)
            keywordChip = ChromeChip(text: engine.keyword, theme: theme, style: .outline)
            let detail = [isDefault ? "Default" : nil, engine.isBuiltIn ? "Built in" : nil]
                .compactMap { $0 }
                .joined(separator: " · ")
            detailLabel = NSTextField(labelWithString: detail)
            templateLabel = NSTextField(labelWithString: engine.template)
            editButton = ChromeButton(title: "Edit…", theme: theme, kind: .standard)
            deleteButton = ChromeButton(title: "Delete", theme: theme, kind: .standard)
            rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            nameLabel.font = ChromeFont.label
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            keywordChip.isHidden = engine.keyword.isEmpty
            keywordChip.setAccessibilityLabel("Keyword \(engine.keyword)")
            detailLabel.font = ChromeFont.meta
            templateLabel.font = ChromeFont.monoSmall
            templateLabel.lineBreakMode = .byTruncatingMiddle
            templateLabel.usesSingleLineMode = true
            templateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            templateLabel.toolTip = engine.template
            editButton.target = self
            editButton.action = #selector(editPressed)
            editButton.setAccessibilityLabel("Edit \(engine.name)")
            deleteButton.target = self
            deleteButton.action = #selector(deletePressed)
            deleteButton.setAccessibilityLabel("Delete \(engine.name)")
            // A built-in engine's keyword is all that can change.
            deleteButton.isHidden = engine.isBuiltIn

            let views: [NSView] = [
                nameLabel, keywordChip, detailLabel, templateLabel, editButton, deleteButton, rule,
            ]
            for view in views {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 54),
                nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                keywordChip.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
                keywordChip.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
                detailLabel.leadingAnchor.constraint(
                    equalTo: engine.keyword.isEmpty ? nameLabel.trailingAnchor : keywordChip.trailingAnchor,
                    constant: 8
                ),
                detailLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
                detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: editButton.leadingAnchor, constant: -12),
                templateLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
                templateLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
                templateLabel.trailingAnchor.constraint(lessThanOrEqualTo: editButton.leadingAnchor, constant: -12),
                deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                deleteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
                editButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
                editButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                editButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
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
            keywordChip.apply(theme: theme)
            detailLabel.textColor = theme.colors.textMuted
            templateLabel.textColor = theme.colors.textMuted
            rule.color = theme.colors.borderSubtle
            editButton.apply(theme: theme)
            deleteButton.apply(theme: theme)
        }

        @objc private func editPressed() {
            onEdit?(engine.id)
        }

        @objc private func deletePressed() {
            onDelete?(engine.id)
        }
    }
}

/// The Add/Edit engine fields (Name, Keyword, URL with %s) and the line
/// that says what keeps the engine from being saved.
@MainActor
final class BrowserSearchEngineForm: NSObject, NSTextFieldDelegate {
    let view = NSGridView()
    let nameField = NSTextField()
    let keywordField = NSTextField()
    let templateField = NSTextField()
    /// Called on every edit.
    var onChange: (() -> Void)?

    private let nameFrame: ChromeFieldView
    private let keywordFrame: ChromeFieldView
    private let templateFrame: ChromeFieldView
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let theme: AppTheme

    init(engine: BrowserSearchEngine?, theme: AppTheme) {
        self.theme = theme
        nameFrame = ChromeFieldView(theme: theme)
        keywordFrame = ChromeFieldView(theme: theme)
        templateFrame = ChromeFieldView(theme: theme)
        super.init()

        let labels = ["Name", "Keyword", "URL"].map { title -> NSTextField in
            let label = NSTextField(labelWithString: title)
            label.font = ChromeFont.label
            label.textColor = theme.colors.textMuted
            label.alignment = .right
            return label
        }
        view.addRow(with: [labels[0], nameFrame])
        view.addRow(with: [labels[1], keywordFrame])
        view.addRow(with: [labels[2], templateFrame])
        view.addRow(with: [NSGridCell.emptyContentView, messageLabel])

        nameField.placeholderString = "Wikipedia"
        keywordField.placeholderString = "w"
        templateField.placeholderString = "https://en.wikipedia.org/w/index.php?search=%s"
        nameField.stringValue = engine?.name ?? ""
        keywordField.stringValue = engine?.keyword ?? ""
        templateField.stringValue = engine?.template ?? ""
        for (field, frame, width) in [
            (nameField, nameFrame, 200.0),
            (keywordField, keywordFrame, 120.0),
            (templateField, templateFrame, 320.0),
        ] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.delegate = self
            ChromeFieldView.styleEmbedded(
                field,
                colors: theme.colors,
                font: field === templateField ? ChromeFont.mono : ChromeFont.label
            )
            frame.addSubview(field)
            NSLayoutConstraint.activate([
                frame.widthAnchor.constraint(equalToConstant: width),
                frame.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),
                field.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
            ])
        }
        // A built-in engine's name and URL are fixed; only its keyword edits.
        if engine?.isBuiltIn == true {
            for field in [nameField, templateField] {
                field.isEditable = false
                field.isSelectable = true
                field.textColor = theme.colors.textMuted
            }
        }
        messageLabel.font = ChromeFont.meta
        messageLabel.textColor = theme.colors.textMuted
        messageLabel.preferredMaxLayoutWidth = 320
        messageLabel.stringValue = " "

        view.rowSpacing = 8
        view.columnSpacing = 8
        view.column(at: 0).xPlacement = .trailing
        // The fields sit in Folio frames, which have no text baseline.
        view.yPlacement = .center
        view.frame.size = view.fittingSize
    }

    var name: String {
        nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var keyword: String {
        BrowserSearchEngine.normalizedKeyword(keywordField.stringValue)
    }

    var template: String {
        templateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Marks the field `problem` is about and says it, once something is
    /// typed (an empty new engine shows no error yet).
    func show(_ problem: BrowserSearchEngineProblem?) {
        let started = !(name.isEmpty && keyword.isEmpty && template.isEmpty)
        let shown = started ? problem : nil
        nameFrame.isInvalid = shown == .emptyName
        templateFrame.isInvalid = shown == .invalidTemplate
        if case .keywordInUse = shown {
            keywordFrame.isInvalid = true
        } else {
            keywordFrame.isInvalid = false
        }
        // A space keeps the row's height, so the alert does not jump.
        messageLabel.stringValue = shown?.message ?? " "
        messageLabel.textColor = shown == nil ? theme.colors.textMuted : theme.colors.danger
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        ChromeFieldView.styleEditor(of: field, colors: theme.colors)
    }
}
