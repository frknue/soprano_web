import AppKit

/// The suggestion list under the address field: a raised popover surface
/// with one row per suggestion. Rows never take keyboard focus, so the field
/// keeps editing while the pointer chooses.
@MainActor
final class BrowserAddressDropdownView: NSView {
    static let rowHeight: CGFloat = 32
    static let verticalPadding: CGFloat = 6

    /// A row was clicked; the flags carry ⌘ for "open in a new tab".
    var onChoose: ((Int, NSEvent.ModifierFlags) -> Void)?

    private(set) var rows: [AddressSuggestion] = []
    private(set) var selectedIndex = 0
    private var rowViews: [BrowserAddressSuggestionRowView] = []
    private var theme: AppTheme
    private var heightConstraint: NSLayoutConstraint!

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isHidden = true
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
        setAccessibilityRole(.list)
        setAccessibilityLabel("Suggestions")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func apply(theme: AppTheme) {
        self.theme = theme
        for row in rowViews {
            row.apply(theme: theme)
        }
        applyShadow()
        needsDisplay = true
    }

    func update(rows: [AddressSuggestion], selectedIndex: Int) {
        self.rows = rows
        while rowViews.count < rows.count {
            let view = BrowserAddressSuggestionRowView(theme: theme)
            let index = rowViews.count
            view.onClick = { [weak self] flags in self?.onChoose?(index, flags) }
            addSubview(view)
            rowViews.append(view)
        }
        for (index, view) in rowViews.enumerated() {
            view.isHidden = index >= rows.count
            if index < rows.count {
                view.configure(rows[index])
            }
        }
        self.selectedIndex = min(max(0, selectedIndex), max(0, rows.count - 1))
        refreshSelection()
        heightConstraint.constant = rows.isEmpty
            ? 0
            : CGFloat(rows.count) * Self.rowHeight + Self.verticalPadding * 2
        needsLayout = true
    }

    func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        selectedIndex = index
        refreshSelection()
    }

    override func layout() {
        super.layout()
        for (index, view) in rowViews.enumerated() {
            view.frame = NSRect(
                x: 0,
                y: Self.verticalPadding + CGFloat(index) * Self.rowHeight,
                width: bounds.width,
                height: Self.rowHeight
            )
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyShadow()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyShadow()
    }

    override func draw(_ dirtyRect: NSRect) {
        // The fill is drawn rather than set on the layer so the offscreen
        // harness captures it; the layer only casts the shadow.
        theme.colors.raised.setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: Chrome.Radius.popover,
            yRadius: Chrome.Radius.popover
        ).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func applyShadow() {
        guard let layer else { return }
        layer.cornerRadius = Chrome.Radius.popover
        theme.colors.shadowE2.apply(to: layer)
    }

    private func refreshSelection() {
        for (index, view) in rowViews.enumerated() {
            view.isSelected = index == selectedIndex && index < rows.count
        }
    }
}

/// One suggestion: kind icon, title, URL in SF Mono, and "Switch to Tab" for
/// open tabs. The keyboard selection is the selection pill with its tick.
@MainActor
final class BrowserAddressSuggestionRowView: NSView {
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            refreshStyle()
        }
    }

    private let background: ChromeRowBackgroundView
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let switchLabel = NSTextField(labelWithString: "Switch to Tab")
    private var theme: AppTheme
    private var suggestion: AddressSuggestion?
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(theme: AppTheme) {
        self.theme = theme
        self.background = ChromeRowBackgroundView(theme: theme)
        super.init(frame: .zero)
        background.inset = 6
        background.translatesAutoresizingMaskIntoConstraints = true
        addSubview(background)

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.imageScaling = .scaleNone
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        for label in [titleLabel, detailLabel, switchLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            addSubview(label)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        switchLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        switchLabel.setContentHuggingPriority(.required, for: .horizontal)

        let titleWidth = titleLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.55)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6 + 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleWidth,

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            detailLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: switchLabel.leadingAnchor, constant: -10),

            switchLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(6 + 12)),
            switchLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        background.frame = bounds
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        background.apply(theme: theme)
        refreshStyle()
    }

    func configure(_ suggestion: AddressSuggestion) {
        self.suggestion = suggestion
        let symbol: String
        switch suggestion.kind {
        case .switchToTab: symbol = "square.on.square"
        case .history: symbol = "clock"
        case .bookmark: symbol = "star"
        case .url: symbol = "globe"
        case .search, .searchSuggestion: symbol = "magnifyingglass"
        }
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        switchLabel.isHidden = suggestion.kind != .switchToTab
        let label = suggestion.kind == .switchToTab ? "Switch to Tab: \(suggestion.title)" : suggestion.title
        setAccessibilityLabel(suggestion.detail.isEmpty ? label : "\(label), \(suggestion.detail)")
        refreshStyle()
    }

    private func refreshStyle() {
        guard let suggestion else { return }
        let colors = theme.colors
        background.style = isSelected ? .selected : (isHovered ? .hover : .none)
        iconView.contentTintColor = isSelected ? colors.textPrimary : colors.textMuted
        titleLabel.setChromeText(suggestion.title, font: ChromeFont.row, color: colors.textPrimary)
        // URLs are SF Mono; the search row's engine name is plain meta text.
        let detailFont = suggestion.kind == .search ? ChromeFont.meta : ChromeFont.monoSmall
        detailLabel.setChromeText(suggestion.detail, font: detailFont, color: colors.textMuted)
        switchLabel.setChromeText("Switch to Tab", font: ChromeFont.meta, color: colors.textMuted)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshStyle()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Swallow the press so nothing underneath reacts; choose on release.
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?(event.modifierFlags)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?([])
        return true
    }
}
