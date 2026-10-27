import AppKit

/// ⌃Tab's switcher, drawn in the window over the page: the window's most
/// recent tabs as cards (favicon, title, address, and the Space of a tab
/// in another one), the one ⌃Tab has reached selected.
@MainActor
final class BrowserRecentTabsOverlay: NSView {
    struct Item {
        var title: String
        var detail: String
        var favicon: NSImage?
        var space: String?
    }

    static let cardSize = NSSize(width: 168, height: 116)
    static let gap: CGFloat = 8
    static let padding: CGFloat = 12

    private var theme: AppTheme
    private var cards: [Card] = []
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.cardSize.height + Self.padding * 2)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        setAccessibilityRole(.list)
        setAccessibilityLabel("Recent Tabs")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func apply(theme: AppTheme) {
        self.theme = theme
        cards.forEach { $0.apply(theme: theme) }
        applyShadow()
        needsDisplay = true
    }

    func show(_ items: [Item], selected: Int) {
        cards.forEach { $0.removeFromSuperview() }
        cards = items.enumerated().map { index, item in
            let card = Card(item: item, theme: theme)
            card.frame = NSRect(
                x: Self.padding + CGFloat(index) * (Self.cardSize.width + Self.gap),
                y: Self.padding,
                width: Self.cardSize.width,
                height: Self.cardSize.height
            )
            addSubview(card)
            return card
        }
        widthConstraint.constant = Self.padding * 2 + CGFloat(items.count) * Self.cardSize.width
            + CGFloat(max(0, items.count - 1)) * Self.gap
        select(selected)
        applyShadow()
    }

    func select(_ index: Int) {
        for (offset, card) in cards.enumerated() {
            card.isSelected = offset == index
        }
    }

    /// The cards' titles with the selected one marked (the harness prints
    /// it).
    var dump: [String] {
        cards.map { ($0.isSelected ? "▸ " : "") + $0.item.title }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Drawn, not a layer color, so the offscreen harness captures it.
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Chrome.Radius.panel,
            yRadius: Chrome.Radius.panel
        )
        theme.colors.raised.setFill()
        shape.fill()
        theme.colors.borderSubtle.setStroke()
        shape.lineWidth = Chrome.hairline
        shape.stroke()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyShadow()
    }

    private func applyShadow() {
        guard let layer else { return }
        layer.cornerRadius = Chrome.Radius.panel
        theme.colors.shadowE3.apply(to: layer)
    }

    /// One tab: favicon, title (two lines), address, and its Space.
    private final class Card: NSView {
        let item: Item
        var isSelected = false {
            didSet { refresh() }
        }

        private let background: ChromeRowBackgroundView
        private let icon = NSImageView()
        private let titleLabel = NSTextField(wrappingLabelWithString: "")
        private let detailLabel = NSTextField(labelWithString: "")
        private let spaceLabel = NSTextField(labelWithString: "")
        private var theme: AppTheme

        init(item: Item, theme: AppTheme) {
            self.item = item
            self.theme = theme
            background = ChromeRowBackgroundView(theme: theme)
            super.init(frame: .zero)
            background.inset = 0
            background.translatesAutoresizingMaskIntoConstraints = true
            background.autoresizingMask = [.width, .height]
            addSubview(background)
            icon.image = item.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            icon.imageScaling = .scaleProportionallyUpOrDown
            titleLabel.maximumNumberOfLines = 2
            titleLabel.lineBreakMode = .byTruncatingTail
            detailLabel.lineBreakMode = .byTruncatingTail
            spaceLabel.lineBreakMode = .byTruncatingTail
            for view in [icon, titleLabel, detailLabel, spaceLabel] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                icon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                icon.widthAnchor.constraint(equalToConstant: 20),
                icon.heightAnchor.constraint(equalToConstant: 20),
                spaceLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
                spaceLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                spaceLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
                titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
                detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            ])
            titleLabel.preferredMaxLayoutWidth = BrowserRecentTabsOverlay.cardSize.width - 28
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(item.title)
            refresh()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func apply(theme: AppTheme) {
            self.theme = theme
            background.apply(theme: theme)
            refresh()
        }

        private func refresh() {
            let colors = theme.colors
            background.style = isSelected ? .selected : .none
            // The globe stands in for a missing favicon; favicons keep
            // their colors.
            icon.contentTintColor = item.favicon == nil ? colors.textMuted : nil
            titleLabel.setChromeText(item.title, font: ChromeFont.row, color: colors.textPrimary)
            detailLabel.setChromeText(item.detail, font: ChromeFont.monoSmall, color: colors.textMuted)
            spaceLabel.setChromeText(item.space ?? "", font: ChromeFont.meta, color: colors.textMuted)
            setAccessibilityValue(isSelected ? "selected" : nil)
        }
    }
}
