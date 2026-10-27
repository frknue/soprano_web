import AppKit

/// What the New Space / Edit Space sheet saves.
struct BrowserSpaceSheetValues: Equatable {
    var name: String
    var icon: BrowserSpaceIcon
    var color: BrowserProfileColor
    var profileID: UUID
}

/// The rail switcher's "+" (New Space) and a Space's Edit Space…: its
/// name, an icon (an emoji or an SF Symbol name, with a few to pick from),
/// its color mark (the Folio tokens of `BrowserProfileColor`) and its
/// profile. Presented as a sheet on the browser window. `onSave` returns
/// nil when the Space was saved, else why not (shown in the sheet).
@MainActor
final class BrowserSpaceSheet: NSWindowController, NSTextFieldDelegate {
    var onSave: ((BrowserSpaceSheetValues) -> String?)?

    static let suggestedIcons: [BrowserSpaceIcon] = [
        .symbol("house"), .symbol("briefcase"), .symbol("book"), .symbol("cart"),
        .symbol("star"), .emoji("🌱"), .emoji("🎧"), .emoji("✈️"),
    ]

    private(set) var values: BrowserSpaceSheetValues
    let isNew: Bool
    private var theme: AppTheme
    private let rootView = NSView()
    private let header = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "Name")
    private let nameFrame: ChromeFieldView
    let nameField = NSTextField()
    private let iconLabel = NSTextField(labelWithString: "Icon")
    private let iconPreview = BrowserSpaceIconPreview()
    private let iconFrame: ChromeFieldView
    let iconField = NSTextField()
    private let iconChoices = NSStackView()
    private let colorLabel = NSTextField(labelWithString: "Color")
    private let colorChoices = NSStackView()
    private var colorButtons: [BrowserSpaceColorButton] = []
    private let profileLabel = NSTextField(labelWithString: "Profile")
    let profilePicker: BrowserProfilePicker
    private let profileNote = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let rule: ChromeRuleView
    private let cancelButton: ChromeButton
    let saveButton: ChromeButton

    /// `space` nil: New Space (in `profileID`'s profile, the next color).
    /// `profileLocked`: the Space is its profile's last one, so it can't
    /// move to another profile.
    init(
        space: BrowserSpace?,
        profileID: UUID,
        color: BrowserProfileColor,
        profileLocked: Bool,
        profiles: BrowserProfileStore,
        theme: AppTheme
    ) {
        isNew = space == nil
        values = BrowserSpaceSheetValues(
            name: space?.name ?? "",
            icon: space?.icon ?? .none,
            color: space?.color ?? color,
            profileID: space?.profileID ?? profileID
        )
        self.theme = theme
        nameFrame = ChromeFieldView(theme: theme)
        iconFrame = ChromeFieldView(theme: theme)
        profilePicker = BrowserProfilePicker(profiles: profiles, selected: values.profileID, theme: theme)
        rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        cancelButton = ChromeButton(title: "Cancel", theme: theme, kind: .text, keycap: "esc")
        saveButton = ChromeButton(title: space == nil ? "Create Space" : "Save", theme: theme, kind: .ink, keycap: "↵")
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 330),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = isNew ? "New Space" : "Edit Space"
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        rootView.wantsLayer = true

        header.stringValue = isNew ? "New Space" : "Edit “\(space?.displayName ?? "")”"
        header.font = ChromeFont.headline
        for label in [nameLabel, iconLabel, colorLabel, profileLabel] {
            label.font = ChromeFont.label
            label.alignment = .right
        }
        profileNote.font = ChromeFont.meta
        messageLabel.font = ChromeFont.meta
        messageLabel.preferredMaxLayoutWidth = 372

        for (frame, field, placeholder) in [
            (nameFrame, nameField, "Space name"),
            (iconFrame, iconField, "Emoji or SF Symbol name"),
        ] {
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.delegate = self
            field.placeholderString = placeholder
            field.translatesAutoresizingMaskIntoConstraints = false
            frame.translatesAutoresizingMaskIntoConstraints = false
            frame.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
                frame.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),
            ])
        }
        nameField.stringValue = values.name
        nameField.setAccessibilityLabel("Space name")
        iconField.stringValue = values.icon.fieldText
        iconField.setAccessibilityLabel("Space icon")

        iconChoices.orientation = .horizontal
        iconChoices.spacing = 4
        for icon in Self.suggestedIcons {
            let button = BrowserSpaceIconChoice(icon: icon, theme: theme)
            button.onPress = { [weak self] icon in self?.choose(icon: icon) }
            iconChoices.addArrangedSubview(button)
        }
        colorChoices.orientation = .horizontal
        colorChoices.spacing = 6
        for color in BrowserProfileColor.allCases {
            let button = BrowserSpaceColorButton(color: color, theme: theme)
            button.onPress = { [weak self] color in self?.choose(color: color) }
            colorButtons.append(button)
            colorChoices.addArrangedSubview(button)
        }
        if profileLocked {
            profilePicker.button.isEnabled = false
            profileNote.stringValue = "The profile's only Space stays in it."
        }
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(savePressed)
        saveButton.keyEquivalent = "\r"

        let views: [NSView] = [
            header, nameLabel, nameFrame, iconLabel, iconPreview, iconFrame, iconChoices, colorLabel,
            colorChoices, profileLabel, profilePicker.button, profileNote, messageLabel, rule, cancelButton, saveButton,
        ]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }
        let labelWidth: CGFloat = 56
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),

            nameLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            nameLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            nameLabel.centerYAnchor.constraint(equalTo: nameFrame.centerYAnchor),
            nameFrame.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            nameFrame.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 12),
            nameFrame.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),

            iconLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            iconLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            iconLabel.centerYAnchor.constraint(equalTo: iconFrame.centerYAnchor),
            iconPreview.leadingAnchor.constraint(equalTo: nameFrame.leadingAnchor),
            iconPreview.centerYAnchor.constraint(equalTo: iconFrame.centerYAnchor),
            iconPreview.widthAnchor.constraint(equalToConstant: Chrome.fieldHeight),
            iconPreview.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),
            iconFrame.topAnchor.constraint(equalTo: nameFrame.bottomAnchor, constant: 12),
            iconFrame.leadingAnchor.constraint(equalTo: iconPreview.trailingAnchor, constant: 8),
            iconFrame.trailingAnchor.constraint(equalTo: nameFrame.trailingAnchor),
            iconChoices.topAnchor.constraint(equalTo: iconFrame.bottomAnchor, constant: 8),
            iconChoices.leadingAnchor.constraint(equalTo: nameFrame.leadingAnchor),

            colorLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            colorLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            colorLabel.centerYAnchor.constraint(equalTo: colorChoices.centerYAnchor),
            colorChoices.topAnchor.constraint(equalTo: iconChoices.bottomAnchor, constant: 14),
            colorChoices.leadingAnchor.constraint(equalTo: nameFrame.leadingAnchor),

            profileLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            profileLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            profileLabel.centerYAnchor.constraint(equalTo: profilePicker.button.centerYAnchor),
            profilePicker.button.topAnchor.constraint(equalTo: colorChoices.bottomAnchor, constant: 14),
            profilePicker.button.leadingAnchor.constraint(equalTo: nameFrame.leadingAnchor),
            profileNote.leadingAnchor.constraint(equalTo: profilePicker.button.trailingAnchor, constant: 8),
            profileNote.centerYAnchor.constraint(equalTo: profilePicker.button.centerYAnchor),
            profileNote.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),

            messageLabel.topAnchor.constraint(equalTo: profilePicker.button.bottomAnchor, constant: 12),
            messageLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),

            rule.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -14),
            saveButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            saveButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])
        profilePicker.onChange = { [weak self] id in self?.values.profileID = id }
        // One profile: the picker hides; so does its label.
        profileLabel.isHidden = profilePicker.button.isHidden
        apply(theme: theme)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        rootView.layer?.backgroundColor = colors.bgBase.cgColor
        window?.backgroundColor = colors.bgBase
        header.textColor = colors.textPrimary
        for label in [nameLabel, iconLabel, colorLabel, profileLabel] {
            label.textColor = colors.textMuted
        }
        profileNote.textColor = colors.textMuted
        messageLabel.textColor = colors.danger
        rule.color = colors.borderSubtle
        nameFrame.apply(theme: theme)
        iconFrame.apply(theme: theme)
        for field in [nameField, iconField] {
            ChromeFieldView.styleEmbedded(field, colors: colors, font: ChromeFont.label)
            field.placeholderAttributedString = NSAttributedString(
                string: field.placeholderString ?? "",
                attributes: [.foregroundColor: colors.textMuted, .font: ChromeFont.label]
            )
        }
        profilePicker.apply(theme: theme)
        cancelButton.apply(theme: theme)
        saveButton.apply(theme: theme)
        iconPreview.theme = theme
        colorButtons.forEach { $0.theme = theme }
    }

    func controlTextDidChange(_ notification: Notification) {
        values.name = nameField.stringValue
        values.icon = Self.icon(from: iconField.stringValue)
        refresh()
    }

    /// The icon field's text as an icon (`BrowserSpaceIcon.parse` with the
    /// system's SF Symbols).
    static func icon(from text: String) -> BrowserSpaceIcon {
        BrowserSpaceIcon.parse(text) { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    }

    /// Fills the sheet as typing and clicking would (the harness).
    func fill(name: String?, icon: String?, color: BrowserProfileColor?, profileID: UUID?) {
        if let name {
            nameField.stringValue = name
            values.name = name
        }
        if let icon {
            iconField.stringValue = icon
            values.icon = Self.icon(from: icon)
        }
        if let color {
            choose(color: color)
        }
        if let profileID, profilePicker.button.isEnabled {
            profilePicker.select(profileID)
            values.profileID = profilePicker.selectedID
        }
        refresh()
    }

    private func choose(icon: BrowserSpaceIcon) {
        values.icon = icon
        iconField.stringValue = icon.fieldText
        refresh()
    }

    private func choose(color: BrowserProfileColor) {
        values.color = color
        refresh()
    }

    private func refresh() {
        iconPreview.icon = values.icon
        iconPreview.color = values.color
        for button in colorButtons {
            button.isChosen = button.color == values.color
        }
        saveButton.isEnabled = !values.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func cancelPressed() {
        close(from: nil)
    }

    /// Create Space / Save; the sheet stays with the reason when refused.
    @objc func savePressed() {
        values.name = nameField.stringValue
        values.icon = Self.icon(from: iconField.stringValue)
        guard !values.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let problem = onSave?(values) {
            messageLabel.stringValue = problem
            return
        }
        close(from: nil)
    }

    /// The text shown when saving was refused.
    var message: String { messageLabel.stringValue }

    private func close(from sender: Any?) {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }
}

/// The icon as the rail will show it, with the color mark.
@MainActor
private final class BrowserSpaceIconPreview: NSView {
    var icon: BrowserSpaceIcon = .none {
        didSet { needsDisplay = true }
    }
    var color: BrowserProfileColor = .blue {
        didSet { needsDisplay = true }
    }
    var theme: AppTheme = .folioPaper {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        let tile = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Chrome.Radius.control,
            yRadius: Chrome.Radius.control
        )
        colors.raised.setFill()
        tile.fill()
        colors.borderSubtle.setStroke()
        tile.lineWidth = Chrome.hairline
        tile.stroke()
        let center = NSPoint(x: bounds.midX, y: bounds.midY + 2)
        if case .none = icon {
            color.color(in: colors).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)).fill()
        } else {
            BrowserSpaceIconDrawing.draw(icon, at: center, size: 13, color: colors.textPrimary, dimmed: false)
            color.color(in: colors).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 2, y: bounds.minY + 3, width: 4, height: 4)).fill()
        }
    }
}

/// One of the suggested icons.
@MainActor
private final class BrowserSpaceIconChoice: NSView {
    var onPress: ((BrowserSpaceIcon) -> Void)?
    private let icon: BrowserSpaceIcon
    private let theme: AppTheme

    init(icon: BrowserSpaceIcon, theme: AppTheme) {
        self.icon = icon
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        toolTip = icon.fieldText
        setAccessibilityRole(.button)
        setAccessibilityLabel(icon.fieldText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        onPress?(icon)
    }

    override func draw(_ dirtyRect: NSRect) {
        let tile = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Chrome.Radius.control,
            yRadius: Chrome.Radius.control
        )
        theme.colors.borderSubtle.setStroke()
        tile.lineWidth = Chrome.hairline
        tile.stroke()
        BrowserSpaceIconDrawing.draw(
            icon,
            at: NSPoint(x: bounds.midX, y: bounds.midY),
            size: 12,
            color: theme.colors.textMuted,
            dimmed: false
        )
    }
}

/// One color mark to choose: a dot, ringed when chosen.
@MainActor
private final class BrowserSpaceColorButton: NSView {
    var onPress: ((BrowserProfileColor) -> Void)?
    let color: BrowserProfileColor
    var theme: AppTheme {
        didSet { needsDisplay = true }
    }
    var isChosen = false {
        didSet { needsDisplay = true }
    }

    init(color: BrowserProfileColor, theme: AppTheme) {
        self.color = color
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        toolTip = color.name
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(color.name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        onPress?(color)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        color.color(in: colors).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6)).fill()
        if isChosen {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.5
            colors.textPrimary.setStroke()
            ring.stroke()
        }
    }
}
