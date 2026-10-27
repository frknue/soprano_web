import AppKit

/// Settings ▸ Profiles: every profile with its color and name, Add, Rename,
/// color and Delete (Default can't be deleted). Presented as a sheet on the
/// Settings window; names are asked for and deletion confirmed in alert
/// sheets on it.
@MainActor
final class BrowserProfilesSheet: NSWindowController {
    /// How many tabs of a profile are open, in any window or Space (for
    /// the delete confirmation).
    var tabCount: ((UUID) -> Int)?
    /// Deletes a profile after the user confirmed it.
    var onDelete: ((UUID) -> Void)?

    private let profiles: BrowserProfileStore
    private var theme: AppTheme
    private var observation: BrowserObservation?

    private let rootView = NSView()
    private let header = NSTextField(labelWithString: "Profiles")
    private let subtitle = NSTextField(
        wrappingLabelWithString: "Each profile keeps its own cookies, website data, history, site decisions "
            + "and bookmarks. Downloads and settings are shared."
    )
    private let topRule: ChromeRuleView
    private let bottomRule: ChromeRuleView
    private let stack = NSStackView()
    private let addButton: ChromeButton
    private let doneButton: ChromeButton
    private var rowViews: [RowView] = []

    init(profiles: BrowserProfileStore, theme: AppTheme) {
        self.profiles = profiles
        self.theme = theme
        self.topRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        self.bottomRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        self.addButton = ChromeButton(title: "Add Profile…", theme: theme, kind: .standard)
        self.doneButton = ChromeButton(title: "Done", theme: theme, kind: .ink, keycap: "esc")
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Profiles"
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        rootView.wantsLayer = true

        header.font = ChromeFont.headline
        subtitle.font = ChromeFont.meta
        subtitle.preferredMaxLayoutWidth = 512
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for view in [header, subtitle, topRule, stack, bottomRule, addButton, doneButton] as [NSView] {
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

            stack.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomRule.topAnchor),

            bottomRule.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -14),

            addButton.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            addButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            doneButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])

        observation = profiles.changes.observe { [weak self] in self?.reload() }
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

    /// Rebuilds the list; called on every change to the profiles.
    func reload() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = profiles.profiles.map { profile in
            let view = RowView(profile: profile, theme: theme)
            view.onRename = { [weak self] id in self?.rename(id) }
            view.onColor = { [weak self] id, button in self?.chooseColor(id, from: button) }
            view.onDelete = { [weak self] id in self?.confirmDelete(id) }
            return view
        }
        for view in rowViews {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        rootView.layoutSubtreeIfNeeded()
    }

    /// The delete confirmation's title and message.
    nonisolated static func deleteConfirmation(name: String, tabCount: Int) -> (title: String, message: String) {
        let tabs: String
        switch tabCount {
        case 0: tabs = ""
        case 1: tabs = "Its open tab closes. "
        default: tabs = "Its \(tabCount) open tabs close. "
        }
        return (
            "Delete the profile “\(name)”?",
            tabs + "Its Spaces, pinned tabs, history, cookies, website data and site decisions are removed "
                + "from this Mac. Downloads and settings stay."
        )
    }

    // MARK: - Actions

    @objc private func addPressed() {
        askForName(title: "New Profile", button: "Add Profile", initial: profiles.list.uniqueName("Profile")) { [weak self] name in
            self?.profiles.add(name: name)
        }
    }

    private func rename(_ id: UUID) {
        guard let profile = profiles.profile(id: id) else { return }
        askForName(title: "Rename “\(profile.name)”", button: "Rename", initial: profile.name) { [weak self] name in
            self?.profiles.rename(id: id, to: name)
        }
    }

    private func chooseColor(_ id: UUID, from button: NSView) {
        guard let profile = profiles.profile(id: id) else { return }
        let menu = NSMenu()
        for color in BrowserProfileColor.allCases {
            let item = NSMenuItem(title: color.name, action: #selector(colorChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ColorChoice(id: id, color: color)
            item.state = color == profile.color ? .on : .off
            item.image = Self.swatch(color.color(in: theme.colors))
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func colorChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ColorChoice else { return }
        profiles.setColor(id: choice.id, choice.color)
    }

    private func confirmDelete(_ id: UUID) {
        guard let window, let profile = profiles.profile(id: id), !profile.isDefault else { return }
        let text = Self.deleteConfirmation(name: profile.name, tabCount: tabCount?(id) ?? 0)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Profile")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onDelete?(id)
        }
    }

    /// An alert sheet with a name field; `completion` gets the name unless
    /// cancelled or empty.
    private func askForName(title: String, button: String, initial: String, completion: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let frame = ChromeFieldView(theme: theme)
        frame.frame = NSRect(x: 0, y: 0, width: 260, height: Chrome.fieldHeight)
        let field = NSTextField(frame: NSRect(x: 8, y: 4, width: 244, height: 18))
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.stringValue = initial
        ChromeFieldView.styleEmbedded(field, colors: theme.colors, font: ChromeFont.label)
        frame.addSubview(field)
        alert.accessoryView = frame
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            completion(name)
        }
        alert.window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func donePressed() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    private final class ColorChoice: NSObject {
        let id: UUID
        let color: BrowserProfileColor

        init(id: UUID, color: BrowserProfileColor) {
            self.id = id
            self.color = color
        }
    }

    /// One profile: color dot, name, and its Color, Rename and Delete
    /// buttons.
    private final class RowView: NSView {
        var onRename: ((UUID) -> Void)?
        var onColor: ((UUID, NSView) -> Void)?
        var onDelete: ((UUID) -> Void)?

        private let profile: BrowserProfile
        private let dot = ChromeStatusMark(shape: .dot)
        private let nameLabel: NSTextField
        private let detailLabel: NSTextField
        private let colorButton: ChromeButton
        private let renameButton: ChromeButton
        private let deleteButton: ChromeButton
        private let rule: ChromeRuleView

        init(profile: BrowserProfile, theme: AppTheme) {
            self.profile = profile
            nameLabel = NSTextField(labelWithString: profile.name)
            detailLabel = NSTextField(labelWithString: profile.isDefault ? "Default profile" : "")
            colorButton = ChromeButton(title: profile.color.name, theme: theme, kind: .standard)
            renameButton = ChromeButton(title: "Rename…", theme: theme, kind: .standard)
            deleteButton = ChromeButton(title: "Delete…", theme: theme, kind: .standard)
            rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            nameLabel.font = ChromeFont.label
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detailLabel.font = ChromeFont.meta
            colorButton.target = self
            colorButton.action = #selector(colorPressed)
            colorButton.setAccessibilityLabel("Color of \(profile.name)")
            renameButton.target = self
            renameButton.action = #selector(renamePressed)
            renameButton.setAccessibilityLabel("Rename \(profile.name)")
            deleteButton.target = self
            deleteButton.action = #selector(deletePressed)
            deleteButton.setAccessibilityLabel("Delete \(profile.name)")
            // Default can't be deleted.
            deleteButton.isEnabled = !profile.isDefault

            for view in [dot, nameLabel, detailLabel, colorButton, renameButton, deleteButton, rule] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 48),
                dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
                nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
                nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                detailLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
                detailLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
                detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: colorButton.leadingAnchor, constant: -12),
                deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                deleteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
                renameButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
                renameButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                renameButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
                colorButton.trailingAnchor.constraint(equalTo: renameButton.leadingAnchor, constant: -8),
                colorButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                colorButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
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
            dot.color = profile.color.color(in: theme.colors)
            nameLabel.textColor = theme.colors.textPrimary
            detailLabel.textColor = theme.colors.textMuted
            rule.color = theme.colors.borderSubtle
            for button in [colorButton, renameButton, deleteButton] {
                button.apply(theme: theme)
            }
        }

        @objc private func colorPressed() {
            onColor?(profile.id, colorButton)
        }

        @objc private func renamePressed() {
            onRename?(profile.id)
        }

        @objc private func deletePressed() {
            onDelete?(profile.id)
        }
    }
}
