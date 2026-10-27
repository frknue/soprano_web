import AppKit

/// Settings ▸ Keyboard shortcuts ▸ Customize… (also Help ▸ Keyboard
/// Shortcuts): every registry command by menu with its shortcut and
/// priority. Click a shortcut, then press the new one (Esc cancels, ⌫
/// removes it). A shortcut another command has opens an inline conflict
/// with Swap and Cancel; a fixed one (Quit, Copy, …) is refused. Reset
/// brings back the default and App wins. Saved in `settings.json` under
/// `shortcuts`.
@MainActor
final class BrowserShortcutsSheet: NSWindowController {
    struct Conflict: Equatable {
        var command: BrowserCommandID
        var shortcut: BrowserShortcut
        /// Who has the shortcut: a command's title, or the system, text
        /// editing or Vimium (`BrowserShortcut.reservedOwner`).
        var owner: String
        /// The owner's shortcut can't change: Cancel only.
        var refused: Bool
    }

    private let settingsStore: BrowserSettingsStore
    private var theme: AppTheme
    private var observation: BrowserObservation?
    private(set) var recording: BrowserCommandID?
    private(set) var conflict: Conflict?

    private let rootView = NSView()
    private let header = NSTextField(labelWithString: "Keyboard Shortcuts")
    private let subtitle = NSTextField(
        wrappingLabelWithString: "Click a shortcut and press the new one; ⌫ removes it. While a page has focus, "
            + "App wins runs the command at once, Site wins lets the page have the key first, and Press twice "
            + "needs the key twice within a second."
    )
    private let topRule: ChromeRuleView
    private let bottomRule: ChromeRuleView
    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private let stack = NSStackView()
    private let resetAllButton: ChromeButton
    private let doneButton: ChromeButton
    private var rowViews: [BrowserCommandID: RowView] = [:]
    private var sectionViews: [NSView] = []

    init(settingsStore: BrowserSettingsStore, theme: AppTheme) {
        self.settingsStore = settingsStore
        self.theme = theme
        topRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        bottomRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        resetAllButton = ChromeButton(title: "Reset All", theme: theme, kind: .standard)
        doneButton = ChromeButton(title: "Done", theme: theme, kind: .ink, keycap: "esc")
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        rootView.wantsLayer = true

        header.font = ChromeFont.headline
        subtitle.font = ChromeFont.meta
        subtitle.preferredMaxLayoutWidth = 612
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
        for view in [header, subtitle, topRule, scrollView, bottomRule, resetAllButton, doneButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }
        resetAllButton.target = self
        resetAllButton.action = #selector(resetAllPressed)
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

            resetAllButton.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            resetAllButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            doneButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])

        buildRows()
        observation = settingsStore.changes.observe { [weak self] _ in self?.refreshRows() }
        apply(theme: theme)
        refreshRows()
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
        resetAllButton.apply(theme: theme)
        doneButton.apply(theme: theme)
        for view in sectionViews {
            (view as? ChromeEyebrowView)?.apply(theme: theme)
        }
        rowViews.values.forEach { $0.apply(theme: theme) }
    }

    private var keymap: BrowserKeymap { settingsStore.settings.keymap }

    // MARK: - Editing

    /// Starts recording a new shortcut for `id` (a click on its keycap).
    func startRecording(_ id: BrowserCommandID) {
        guard id.isRemappable else { return }
        conflict = nil
        recording = id
        refreshRows()
        if let row = rowViews[id] {
            window?.makeFirstResponder(row.recorder)
        }
    }

    /// A key pressed while recording `id`: Esc cancels, ⌫ alone removes
    /// the shortcut, anything else is assigned (or opens a conflict).
    func recorded(_ event: NSEvent, for id: BrowserCommandID) {
        guard recording == id else { return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, flags.isEmpty {
            recording = nil
            refreshRows()
            return
        }
        if event.keyCode == 51, flags.isEmpty {
            recording = nil
            settingsStore.update { $0.keymap.assign(nil, to: id) }
            refreshRows()
            return
        }
        guard let shortcut = BrowserShortcut(event: event), shortcut.isAssignable else {
            NSSound.beep()
            return
        }
        record(shortcut, for: id)
    }

    /// Assigns `shortcut` to `id` as recording it does: saved when free,
    /// otherwise the row shows the conflict (Swap or Cancel) or the
    /// refusal. Returns what the keymap answered.
    @discardableResult
    func record(_ shortcut: BrowserShortcut, for id: BrowserCommandID) -> BrowserKeymap.Assignment {
        recording = nil
        var keymap = keymap
        let result = keymap.assign(shortcut, to: id)
        switch result {
        case .assigned:
            conflict = nil
            settingsStore.update { $0.keymap = keymap }
        case let .conflict(other):
            conflict = Conflict(command: id, shortcut: shortcut, owner: other.command.title, refused: false)
        case let .refused(other):
            conflict = Conflict(command: id, shortcut: shortcut, owner: other.command.title, refused: true)
        case let .reserved(owner):
            conflict = Conflict(command: id, shortcut: shortcut, owner: owner, refused: true)
        case .invalid:
            conflict = nil
            NSSound.beep()
        }
        refreshRows()
        if conflict != nil {
            scroll(to: id)
        }
        return result
    }

    /// The conflict's Swap (the other command takes this one's old
    /// shortcut) or Cancel.
    func resolveConflict(swap: Bool) {
        guard let conflict else { return }
        self.conflict = nil
        if swap, !conflict.refused {
            settingsStore.update { $0.keymap.assign(conflict.shortcut, to: conflict.command, swap: true) }
        }
        refreshRows()
    }

    func setPriority(_ priority: BrowserShortcutPriority, for id: BrowserCommandID) {
        settingsStore.update { $0.keymap.setPriority(priority, for: id) }
    }

    func reset(_ id: BrowserCommandID) {
        conflict = conflict?.command == id ? nil : conflict
        settingsStore.update { $0.keymap.reset(id) }
    }

    /// What the conflict line says.
    static func message(for conflict: Conflict) -> String {
        conflict.refused
            ? "\(conflict.shortcut.display) belongs to \(conflict.owner) and can't change."
            : "\(conflict.shortcut.display) is already \(conflict.owner)."
    }

    /// Scrolls the list so `id`'s row shows.
    func scroll(to id: BrowserCommandID) {
        guard let row = rowViews[id] else { return }
        rootView.layoutSubtreeIfNeeded()
        let frame = row.convert(row.bounds, to: listView)
        listView.scroll(NSPoint(x: 0, y: max(0, frame.minY - 120)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func resetAllPressed() {
        conflict = nil
        recording = nil
        settingsStore.update { $0.shortcuts = BrowserShortcutSettings() }
        refreshRows()
    }

    @objc private func donePressed() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    // MARK: - Rows

    private func buildRows() {
        for menu in BrowserAppCommand.Menu.allCases {
            let commands = BrowserAppCommand.all.filter { $0.menu == menu }
            guard !commands.isEmpty else { continue }
            let heading = ChromeEyebrowView(title: menu == .app ? "Soprano Web" : menu.rawValue, theme: theme)
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(heading)
            NSLayoutConstraint.activate([
                holder.heightAnchor.constraint(equalToConstant: 36),
                heading.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 24),
                heading.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -6),
            ])
            stack.addArrangedSubview(holder)
            holder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            sectionViews.append(heading)
            for command in commands {
                let row = RowView(command: command, theme: theme)
                row.onRecord = { [weak self] id in self?.startRecording(id) }
                row.onKey = { [weak self] event, id in self?.recorded(event, for: id) }
                row.onPriority = { [weak self] priority, id in self?.setPriority(priority, for: id) }
                row.onReset = { [weak self] id in self?.reset(id) }
                row.onSwap = { [weak self] in self?.resolveConflict(swap: true) }
                row.onCancelConflict = { [weak self] in self?.resolveConflict(swap: false) }
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                rowViews[command.id] = row
            }
        }
    }

    private func refreshRows() {
        let keymap = keymap
        for (id, row) in rowViews {
            row.update(
                shortcut: keymap.shortcut(for: id),
                priority: keymap.priority(for: id),
                isCustomized: keymap.isCustomized(id),
                isRecording: recording == id,
                conflict: conflict?.command == id ? conflict.map(Self.message) : nil,
                conflictRefused: conflict?.refused ?? false
            )
        }
        rootView.layoutSubtreeIfNeeded()
    }

    /// The list as text, one row per command (the harness prints it).
    var dump: [String] {
        let keymap = keymap
        return BrowserAppCommand.all.map { command in
            let shortcut = keymap.shortcut(for: command.id)?.display ?? "—"
            var line = "\(command.menu.rawValue) ▸ \(command.title)  [\(shortcut)]"
            if command.id.isRemappable {
                line += " \(keymap.priority(for: command.id).title)"
            } else {
                line += " fixed"
            }
            if keymap.isCustomized(command.id) { line += " (custom)" }
            if conflict?.command == command.id, let conflict { line += "  ! \(Self.message(for: conflict))" }
            return line
        }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// One command: title, priority menu, the shortcut's keycap (click to
    /// record) and Reset; a conflict line under it while one is open.
    private final class RowView: NSView {
        var onRecord: ((BrowserCommandID) -> Void)?
        var onKey: ((NSEvent, BrowserCommandID) -> Void)?
        var onPriority: ((BrowserShortcutPriority, BrowserCommandID) -> Void)?
        var onReset: ((BrowserCommandID) -> Void)?
        var onSwap: (() -> Void)?
        var onCancelConflict: (() -> Void)?

        let command: BrowserAppCommand
        let recorder: Recorder
        private let titleLabel: NSTextField
        private let priorityButton: ChromeButton
        private let resetButton: ChromeButton
        private let conflictLabel = NSTextField(labelWithString: "")
        private let swapButton: ChromeButton
        private let cancelButton: ChromeButton
        private let rule: ChromeRuleView
        private var heightConstraint: NSLayoutConstraint!
        private var theme: AppTheme
        private var priority = BrowserShortcutPriority.app

        init(command: BrowserAppCommand, theme: AppTheme) {
            self.command = command
            self.theme = theme
            recorder = Recorder(theme: theme)
            titleLabel = NSTextField(labelWithString: command.title)
            priorityButton = ChromeButton(title: BrowserShortcutPriority.app.title, theme: theme, kind: .standard)
            resetButton = ChromeButton(title: "Reset", theme: theme, kind: .standard)
            swapButton = ChromeButton(title: "Swap", theme: theme, kind: .ink)
            cancelButton = ChromeButton(title: "Cancel", theme: theme, kind: .standard)
            rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            titleLabel.font = ChromeFont.label
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            conflictLabel.font = ChromeFont.meta
            conflictLabel.lineBreakMode = .byTruncatingTail
            priorityButton.target = self
            priorityButton.action = #selector(priorityPressed)
            priorityButton.setAccessibilityLabel("Priority of \(command.title)")
            resetButton.target = self
            resetButton.action = #selector(resetPressed)
            resetButton.setAccessibilityLabel("Reset \(command.title)")
            swapButton.target = self
            swapButton.action = #selector(swapPressed)
            cancelButton.target = self
            cancelButton.action = #selector(cancelPressed)
            recorder.onClick = { [weak self] in
                guard let self else { return }
                self.onRecord?(self.command.id)
            }
            recorder.onKey = { [weak self] event in
                guard let self else { return }
                self.onKey?(event, self.command.id)
            }
            recorder.isEnabled = command.id.isRemappable
            priorityButton.isHidden = !command.id.isRemappable

            for view in [titleLabel, priorityButton, recorder, resetButton, conflictLabel, swapButton, cancelButton, rule]
                as [NSView]
            {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            heightConstraint = heightAnchor.constraint(equalToConstant: 38)
            NSLayoutConstraint.activate([
                heightConstraint,
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: 19),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: priorityButton.leadingAnchor, constant: -12),
                resetButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                resetButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                resetButton.widthAnchor.constraint(equalToConstant: 64),
                recorder.trailingAnchor.constraint(equalTo: resetButton.leadingAnchor, constant: -8),
                recorder.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                recorder.widthAnchor.constraint(equalToConstant: 112),
                recorder.heightAnchor.constraint(equalToConstant: Chrome.controlHeight),
                priorityButton.trailingAnchor.constraint(equalTo: recorder.leadingAnchor, constant: -8),
                priorityButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                priorityButton.widthAnchor.constraint(equalToConstant: 104),
                conflictLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: 0),
                conflictLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: 54),
                conflictLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -12),
                swapButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                swapButton.centerYAnchor.constraint(equalTo: conflictLabel.centerYAnchor),
                swapButton.widthAnchor.constraint(equalToConstant: 64),
                cancelButton.trailingAnchor.constraint(equalTo: swapButton.leadingAnchor, constant: -8),
                cancelButton.centerYAnchor.constraint(equalTo: conflictLabel.centerYAnchor),
                cancelButton.widthAnchor.constraint(equalToConstant: 72),
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
            self.theme = theme
            titleLabel.textColor = command.id.isRemappable ? theme.colors.textPrimary : theme.colors.textMuted
            conflictLabel.textColor = theme.colors.textPrimary
            rule.color = theme.colors.borderSubtle
            recorder.apply(theme: theme)
            for button in [priorityButton, resetButton, swapButton, cancelButton] {
                button.apply(theme: theme)
            }
        }

        func update(
            shortcut: BrowserShortcut?,
            priority: BrowserShortcutPriority,
            isCustomized: Bool,
            isRecording: Bool,
            conflict: String?,
            conflictRefused: Bool
        ) {
            self.priority = priority
            recorder.legend = isRecording ? "Type shortcut" : shortcut?.display ?? "—"
            recorder.isRecording = isRecording
            priorityButton.title = priority.title
            resetButton.isHidden = !isCustomized
            let showsConflict = conflict != nil
            conflictLabel.stringValue = conflict ?? ""
            conflictLabel.isHidden = !showsConflict
            swapButton.isHidden = !showsConflict || conflictRefused
            cancelButton.isHidden = !showsConflict
            cancelButton.title = conflictRefused ? "OK" : "Cancel"
            heightConstraint.constant = showsConflict ? 72 : 38
        }

        @objc private func priorityPressed() {
            let menu = NSMenu()
            for choice in BrowserShortcutPriority.allCases {
                let item = NSMenuItem(title: choice.title, action: #selector(priorityChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = choice.rawValue
                item.state = choice == priority ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: priorityButton.bounds.height + 4), in: priorityButton)
        }

        @objc private func priorityChosen(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let choice = BrowserShortcutPriority(rawValue: raw) else {
                return
            }
            onPriority?(choice, command.id)
        }

        @objc private func resetPressed() {
            onReset?(command.id)
        }

        @objc private func swapPressed() {
            onSwap?()
        }

        @objc private func cancelPressed() {
            onCancelConflict?()
        }
    }

    /// The shortcut's keycap; a click starts recording and, while
    /// recording, the next key press (⌘ shortcuts included) is the new
    /// shortcut.
    final class Recorder: NSView {
        var onClick: (() -> Void)?
        var onKey: ((NSEvent) -> Void)?
        var isEnabled = true
        var isRecording = false {
            didSet { keycap.tone = isRecording ? .accent : (isEnabled ? .primary : .muted) }
        }
        var legend: String {
            get { keycap.legend }
            set {
                keycap.legend = newValue
                setAccessibilityValue(newValue)
            }
        }

        private let keycap: ChromeKeycapView

        init(theme: AppTheme) {
            keycap = ChromeKeycapView(legend: "—", theme: theme, style: .field, tone: .primary)
            super.init(frame: .zero)
            addSubview(keycap)
            NSLayoutConstraint.activate([
                keycap.trailingAnchor.constraint(equalTo: trailingAnchor),
                keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("Shortcut")
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func apply(theme: AppTheme) {
            keycap.apply(theme: theme)
            keycap.tone = isRecording ? .accent : (isEnabled ? .primary : .muted)
        }

        override var acceptsFirstResponder: Bool { isRecording }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            onClick?()
        }

        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
            onClick?()
            return true
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording, window?.firstResponder === self, event.type == .keyDown else { return false }
            onKey?(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            onKey?(event)
        }
    }
}
