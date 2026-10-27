import AppKit

/// File ▸ Import Browser Data…: pick a source on the left (Arc and Chrome
/// when found on this Mac, a Safari export ZIP or a bookmarks file chosen
/// with an open panel), check what to bring in on the right, Import. Arc's
/// Spaces each become a Space of their own; a Chrome, Safari or bookmarks
/// file import goes into the Space chosen at the top of the checklist
/// (the importing window's at first). The footer shows progress
/// (History, the long part, can be cancelled) and then what the import
/// did. A sheet on the importing window; its Today tabs open there and it
/// switches to the first imported Space.
@MainActor
final class BrowserImportSheet: NSWindowController {
    enum State: Equatable {
        case choosing
        case loading
        case ready
        case importing
        case done
        case failed(String)
    }

    private(set) var state: State = .choosing
    private(set) var request: BrowserImportLoader.Request?
    private(set) var plan: BrowserImportPlan?
    private(set) var progress: BrowserImporter.Progress?
    private(set) var summary: BrowserImporter.Summary?

    private weak var manager: BrowserWindowManager?
    private weak var controller: BrowserWindowController?
    private var theme: AppTheme
    private let detected: [BrowserImportLoader.Request]
    private var cancellation: BrowserImportCancellation?

    private let rootView = NSView()
    private let header = NSTextField(labelWithString: "Import Browser Data")
    private let subtitle = NSTextField(
        wrappingLabelWithString: "Spaces, pinned tabs, favorites, archived tabs, History and link rules. "
            + "The other browser's files are only read, never changed."
    )
    private let topRule: ChromeRuleView
    private let sourceRule: ChromeRuleView
    private let bottomRule: ChromeRuleView
    private let sourceStack = NSStackView()
    private var sourceRows: [SourceRow] = []
    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private let stack = NSStackView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let progressBar: ProgressBar
    private let statusLabel = NSTextField(labelWithString: "")
    private let cancelButton: ChromeButton
    private let importButton: ChromeButton
    private var checklistViews: [NSView] = []

    init(manager: BrowserWindowManager, controller: BrowserWindowController?, detected: [BrowserImportLoader.Request]? = nil) {
        self.manager = manager
        self.controller = controller
        theme = manager.themeManager.currentTheme
        self.detected = detected ?? BrowserImportLoader.detected()
        topRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        sourceRule = ChromeRuleView(axis: .vertical, color: theme.colors.borderSubtle)
        bottomRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        progressBar = ProgressBar(theme: theme)
        cancelButton = ChromeButton(title: "Cancel", theme: theme, kind: .standard, keycap: "esc")
        importButton = ChromeButton(title: "Import", theme: theme, kind: .ink)
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Import Browser Data"
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        rootView.wantsLayer = true

        header.font = ChromeFont.headline
        subtitle.font = ChromeFont.meta
        subtitle.preferredMaxLayoutWidth = 700
        placeholder.font = ChromeFont.label
        placeholder.preferredMaxLayoutWidth = 480
        statusLabel.font = ChromeFont.meta
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 2
        for kind in BrowserImportSourceKind.allCases {
            let found = self.detected.first { $0.kind == kind }
            let detail: String = switch kind {
            case .arc, .chrome: found == nil ? "Not found on this Mac" : "Found on this Mac"
            case .safari: "File ▸ Export Browsing Data ZIP"
            case .html: "A bookmarks .html file"
            }
            let row = SourceRow(kind: kind, detail: detail, theme: theme)
            row.isEnabled = found != nil || kind == .safari || kind == .html
            row.target = self
            row.action = #selector(sourcePressed(_:))
            sourceRows.append(row)
            sourceStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 196).isActive = true
        }

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

        let views: [NSView] = [
            header, subtitle, topRule, sourceStack, sourceRule, scrollView, placeholder, bottomRule,
            progressBar, statusLabel, cancelButton, importButton,
        ]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"
        importButton.target = self
        importButton.action = #selector(importPressed)
        importButton.keyEquivalent = "\r"

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            subtitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),

            topRule.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            topRule.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),

            sourceStack.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 12),
            sourceStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 12),
            sourceRule.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            sourceRule.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            sourceRule.leadingAnchor.constraint(equalTo: sourceStack.trailingAnchor, constant: 12),

            scrollView.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: sourceRule.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            placeholder.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 18),
            placeholder.leadingAnchor.constraint(equalTo: sourceRule.trailingAnchor, constant: 24),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),

            listView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            listView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: listView.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: listView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: listView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: listView.bottomAnchor, constant: -8),

            bottomRule.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: importButton.topAnchor, constant: -14),

            progressBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            progressBar.widthAnchor.constraint(equalToConstant: 160),
            progressBar.centerYAnchor.constraint(equalTo: importButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: progressBar.trailingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: importButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -16),

            importButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            importButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),
            importButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
            cancelButton.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: importButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])

        apply(theme: theme)
        refresh()
        if let first = self.detected.first {
            select(first)
        }
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
        placeholder.textColor = theme.colors.textMuted
        statusLabel.textColor = theme.colors.textMuted
        for rule in [topRule, sourceRule, bottomRule] {
            rule.color = theme.colors.borderSubtle
        }
        sourceRows.forEach { $0.apply(theme: theme) }
        progressBar.apply(theme: theme)
        cancelButton.apply(theme: theme)
        importButton.apply(theme: theme)
        rebuildChecklist()
    }

    // MARK: Driving it (buttons, the harness)

    /// Reads `request` and shows its checklist.
    func select(_ request: BrowserImportLoader.Request) {
        guard state != .importing, let manager else { return }
        self.request = request
        plan = nil
        summary = nil
        progress = nil
        state = .loading
        refresh()
        manager.planImport(request, for: controller) { [weak self] result in
            guard let self, self.request == request, self.state == .loading else { return }
            switch result {
            case let .success(plan):
                self.plan = plan
                self.state = .ready
            case let .failure(error):
                self.state = .failed("\(error)")
            }
            self.refresh()
        }
    }

    /// Checks or unchecks a checklist item.
    func setIncluded(_ item: BrowserImportChecklist.Item, _ included: Bool) {
        guard state == .ready, var plan else { return }
        BrowserImportChecklist.set(item, included: included, in: &plan)
        self.plan = plan
        refresh()
    }

    /// The Space menu at the top of a Chrome, Safari or bookmarks-file
    /// checklist: points the plan at Space `id`.
    func chooseTarget(_ id: UUID) {
        guard state == .ready, var plan, let manager else { return }
        BrowserImportPlanner.retarget(&plan, to: id, spaces: manager.spaces.list)
        self.plan = plan
        refresh()
    }

    /// The Space a Chrome, Safari or bookmarks-file import goes into.
    var targetSpaceName: String? {
        guard let plan, plan.source != .arc else { return nil }
        return plan.targetSpaceID.flatMap { manager?.spaces.space(id: $0) }?.displayName
    }

    /// Import: the plan as checked.
    func startImport() {
        guard state == .ready, let plan, let manager else { return }
        let cancellation = BrowserImportCancellation()
        self.cancellation = cancellation
        state = .importing
        progress = BrowserImporter.Progress(handled: 0, total: plan.includedVisitCount, item: "")
        refresh()
        manager.runImport(
            plan,
            in: controller,
            cancellation: cancellation,
            progress: { [weak self] progress in
                guard let self, self.state == .importing else { return }
                self.progress = progress
                self.refreshProgress()
            },
            completion: { [weak self] summary in
                guard let self else { return }
                self.summary = summary
                self.cancellation = nil
                self.state = .done
                self.refresh()
            }
        )
    }

    /// Cancel: stops History between batches while importing.
    func cancelImport() {
        cancellation?.cancel()
        statusLabel.stringValue = "Cancelling…"
    }

    /// The checklist (or the result) as text: what the harness prints.
    var dump: [String] {
        switch state {
        case .done:
            return summary.map(BrowserImportChecklist.resultLines) ?? []
        default:
            guard let plan else { return [placeholder.stringValue] }
            let target = targetSpaceName.map { ["Into Space | \($0)"] } ?? []
            return target + BrowserImportChecklist.rows(for: plan).map { row in
                "[\(row.isChecked ? "x" : " ")]\(row.isEnabled ? "" : " (off)") \(row.section) | \(row.title) | \(row.detail)"
            }
        }
    }

    var statusText: String { statusLabel.stringValue }

    // MARK: Actions

    @objc private func sourcePressed(_ sender: SourceRow) {
        if let found = detected.first(where: { $0.kind == sender.kind }) {
            select(found)
            return
        }
        guard let window, sender.kind == .safari || sender.kind == .html else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = sender.kind == .safari ? [.zip] : [.html]
        panel.message = sender.kind == .safari
            ? "Choose the ZIP from Safari ▸ File ▸ Export Browsing Data to File…"
            : "Choose a bookmarks file (Netscape HTML, what browsers export)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.select(sender.kind == .safari ? .safari(url) : .html(url))
        }
    }

    @objc private func cancelPressed() {
        if state == .importing {
            cancelImport()
        } else {
            close()
        }
    }

    @objc private func importPressed() {
        if state == .done {
            close()
        } else {
            startImport()
        }
    }

    override func close() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    // MARK: Showing state

    private func refresh() {
        for row in sourceRows {
            row.isSelected = row.kind == request?.kind
            row.isEnabled = state != .importing
                && (detected.contains { $0.kind == row.kind } || row.kind == .safari || row.kind == .html)
        }
        switch state {
        case .choosing:
            placeholder.stringValue = "Choose where to import from."
        case .loading:
            placeholder.stringValue = "Reading \(request?.kind.title ?? "")…"
        case let .failed(message):
            placeholder.stringValue = "Can't import: \(message)"
        case .ready, .importing, .done:
            placeholder.stringValue = ""
        }
        placeholder.isHidden = placeholder.stringValue.isEmpty
        importButton.title = state == .done ? "Done" : "Import"
        importButton.isEnabled = state == .done
            || (state == .ready && plan.map { BrowserImportChecklist.summary(of: $0) != "Nothing to import" } == true)
        cancelButton.title = state == .done ? "Close" : "Cancel"
        cancelButton.isHidden = state == .done
        rebuildChecklist()
        refreshProgress()
    }

    private func refreshProgress() {
        switch state {
        case .importing:
            progressBar.isHidden = false
            progressBar.fraction = progress?.fraction ?? 0
            if cancellation?.isCancelled == true {
                statusLabel.stringValue = "Cancelling…"
            } else if let progress, progress.total > 0 {
                statusLabel.stringValue = "\(progress.item): \(progress.handled.formatted()) of "
                    + "\(progress.total.formatted()) visits"
            } else {
                statusLabel.stringValue = "Importing…"
            }
        case .done:
            progressBar.isHidden = false
            progressBar.fraction = 1
            statusLabel.stringValue = summary?.cancelled == true ? "Import cancelled" : "Import finished"
        case .ready:
            progressBar.isHidden = true
            statusLabel.stringValue = plan.map(BrowserImportChecklist.summary) ?? ""
        default:
            progressBar.isHidden = true
            statusLabel.stringValue = ""
        }
    }

    private func rebuildChecklist() {
        checklistViews.forEach { $0.removeFromSuperview() }
        checklistViews = []
        if state == .done, let summary {
            add(SectionHead(title: "Imported", theme: theme))
            for line in BrowserImportChecklist.resultLines(summary) {
                add(ResultLine(text: line, theme: theme))
            }
        } else if let plan, state == .ready || state == .importing {
            if let name = targetSpaceName, let manager {
                let row = TargetRow(spaces: manager.spaces.spaces, selected: name, theme: theme, enabled: state == .ready)
                row.onChoose = { [weak self] id in self?.chooseTarget(id) }
                add(row)
            }
            var section = ""
            for row in BrowserImportChecklist.rows(for: plan) {
                if row.section != section {
                    section = row.section
                    add(SectionHead(title: section, theme: theme))
                }
                let view = ChecklistRow(row: row, theme: theme, enabled: state == .ready)
                view.onToggle = { [weak self] item, included in self?.setIncluded(item, included) }
                add(view)
            }
        }
        rootView.layoutSubtreeIfNeeded()
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        checklistViews.append(view)
    }

    // MARK: Views

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// A source in the left column: the raised pill when selected.
    private final class SourceRow: NSButton {
        let kind: BrowserImportSourceKind
        var isSelected = false {
            didSet { background.style = isSelected ? .raisedTab : .none }
        }

        private let background: ChromeRowBackgroundView
        private let titleLabel: NSTextField
        private let detailLabel: NSTextField

        init(kind: BrowserImportSourceKind, detail: String, theme: AppTheme) {
            self.kind = kind
            background = ChromeRowBackgroundView(theme: theme)
            titleLabel = NSTextField(labelWithString: kind == .safari || kind == .html ? kind.title + "…" : kind.title)
            detailLabel = NSTextField(labelWithString: detail)
            super.init(frame: .zero)
            title = ""
            isBordered = false
            setButtonType(.momentaryChange)
            translatesAutoresizingMaskIntoConstraints = false
            background.inset = 0
            titleLabel.font = ChromeFont.labelStrong
            detailLabel.font = ChromeFont.meta
            for view in [background, titleLabel, detailLabel] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 44),
                background.leadingAnchor.constraint(equalTo: leadingAnchor),
                background.trailingAnchor.constraint(equalTo: trailingAnchor),
                background.topAnchor.constraint(equalTo: topAnchor),
                background.bottomAnchor.constraint(equalTo: bottomAnchor),
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
                detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
                detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            ])
            setAccessibilityLabel(kind.title)
            apply(theme: theme)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override var isEnabled: Bool {
            didSet { alphaValue = isEnabled ? 1 : 0.45 }
        }

        func apply(theme: AppTheme) {
            background.apply(theme: theme)
            titleLabel.textColor = theme.colors.textPrimary
            detailLabel.textColor = theme.colors.textMuted
        }
    }

    private final class SectionHead: NSView {
        init(title: String, theme: AppTheme) {
            super.init(frame: .zero)
            let label = NSTextField(labelWithAttributedString: ChromeText.eyebrow(title, color: theme.colors.textMuted))
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 30),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
    }

    /// A checklist item: checkbox, title, counts and target.
    private final class ChecklistRow: NSView {
        var onToggle: ((BrowserImportChecklist.Item, Bool) -> Void)?

        private let item: BrowserImportChecklist.Item
        private let checkbox: ChromeCheckbox

        init(row: BrowserImportChecklist.Row, theme: AppTheme, enabled: Bool) {
            item = row.item
            checkbox = ChromeCheckbox(isChecked: row.isChecked, theme: theme)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            checkbox.isEnabled = enabled && row.isEnabled
            checkbox.target = self
            checkbox.action = #selector(toggled)
            checkbox.setAccessibilityLabel(row.title)
            let title = NSTextField(labelWithString: row.title)
            title.font = ChromeFont.label
            title.textColor = row.isEnabled ? theme.colors.textPrimary : theme.colors.textMuted
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let detail = NSTextField(labelWithString: row.detail)
            detail.font = ChromeFont.meta
            detail.textColor = theme.colors.textMuted
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            for view in [checkbox, title, detail] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 40),
                checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                checkbox.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                title.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 10),
                title.centerYAnchor.constraint(equalTo: checkbox.centerYAnchor),
                title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
                detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
                detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        @objc private func toggled() {
            onToggle?(item, checkbox.isChecked)
        }
    }

    /// "Into Space": the Space a Chrome, Safari or bookmarks-file import
    /// goes into, a menu of every Space.
    private final class TargetRow: NSView {
        var onChoose: ((UUID) -> Void)?

        private let spaces: [BrowserSpace]
        private let button: ChromeButton

        init(spaces: [BrowserSpace], selected: String, theme: AppTheme, enabled: Bool) {
            self.spaces = spaces
            button = ChromeButton(title: selected, theme: theme, kind: .standard)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: "Into Space")
            label.font = ChromeFont.label
            label.textColor = theme.colors.textPrimary
            button.target = self
            button.action = #selector(pressed)
            button.isEnabled = enabled
            button.setAccessibilityLabel("Import into Space")
            for view in [label, button] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 44),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                button.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
                button.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
                button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        @objc private func pressed() {
            let menu = NSMenu()
            for space in spaces {
                let item = NSMenuItem(title: space.displayName, action: #selector(chose(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = space.id
                item.state = space.displayName == button.title ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }

        @objc private func chose(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            onChoose?(id)
        }
    }

    private final class ResultLine: NSView {
        init(text: String, theme: AppTheme) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: text)
            label.font = ChromeFont.label
            label.textColor = theme.colors.textPrimary
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 26),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
    }

    /// The footer's progress: a `bgOverlay` track with an ink fill.
    private final class ProgressBar: NSView {
        var fraction: Double = 0 {
            didSet { needsDisplay = true }
        }

        private var theme: AppTheme

        init(theme: AppTheme) {
            self.theme = theme
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: 6).isActive = true
            setAccessibilityRole(.progressIndicator)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func apply(theme: AppTheme) {
            self.theme = theme
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let radius = bounds.height / 2
            theme.colors.bgOverlay.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            let filled = NSRect(x: 0, y: 0, width: bounds.width * min(1, max(0, fraction)), height: bounds.height)
            guard filled.width > 0 else { return }
            theme.colors.inkButtonFill.setFill()
            NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
            setAccessibilityValue(fraction)
        }
    }
}
