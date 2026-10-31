import AppKit

/// ⌃Tab's switcher, drawn in the window over the page: the window's most
/// recent tabs as cards (a preview of the page — `BrowserTabPreview`, else
/// its favicon —, favicon and title, address, and the Space of a tab in
/// another one), the one ⌃Tab has reached selected.
@MainActor
final class BrowserRecentTabsOverlay: NSView {
    struct Item {
        var title: String
        var detail: String
        var favicon: NSImage?
        var preview: NSImage?
        var space: String?
    }

    /// Cards are as wide as `BrowserTabPreview.pointWidth` when the
    /// window has room, narrower down to `minimumCardWidth` when not.
    static let minimumCardWidth: CGFloat = 132
    static let gap: CGFloat = 8
    static let padding: CGFloat = 12
    /// The preview's height to width: the window's page area's, within
    /// these bounds (a split pane's or another window's page may differ).
    static let previewAspects: ClosedRange<CGFloat> = 0.45...0.8
    /// Lines the preview up with the text and clears the selection tick.
    static let previewInset: CGFloat = 10
    /// Below the preview: favicon and title, address, Space.
    static let textHeight: CGFloat = 66

    /// The card width for `count` cards in `maxWidth` points.
    static func cardWidth(count: Int, maxWidth: CGFloat) -> CGFloat {
        let count = CGFloat(max(1, count))
        let fitting = ((maxWidth - padding * 2 - gap * (count - 1)) / count).rounded(.down)
        return min(BrowserTabPreview.pointWidth, max(minimumCardWidth, fitting))
    }

    /// A card `width` points wide whose preview is `aspect` (height to
    /// width) of the page area.
    static func cardSize(width: CGFloat, aspect: CGFloat) -> NSSize {
        let aspect = aspect.isFinite ? min(max(aspect, previewAspects.lowerBound), previewAspects.upperBound) : 0.625
        let preview = ((width - previewInset * 2) * aspect).rounded()
        return NSSize(width: width, height: previewInset + preview + textHeight)
    }

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
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
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

    /// Shows `items` as cards fitting `maxWidth` points, their previews
    /// shaped like the page area (`previewAspect`, height to width).
    func show(_ items: [Item], selected: Int, maxWidth: CGFloat, previewAspect: CGFloat) {
        cards.forEach { $0.removeFromSuperview() }
        let size = Self.cardSize(width: Self.cardWidth(count: items.count, maxWidth: maxWidth), aspect: previewAspect)
        cards = items.enumerated().map { index, item in
            let card = Card(item: item, theme: theme, size: size)
            card.frame = NSRect(
                x: Self.padding + CGFloat(index) * (size.width + Self.gap),
                y: Self.padding,
                width: size.width,
                height: size.height
            )
            addSubview(card)
            return card
        }
        widthConstraint.constant = Self.padding * 2 + CGFloat(items.count) * size.width
            + CGFloat(max(0, items.count - 1)) * Self.gap
        heightConstraint.constant = Self.padding * 2 + size.height
        select(selected)
        applyShadow()
    }

    func select(_ index: Int) {
        for (offset, card) in cards.enumerated() {
            card.isSelected = offset == index
        }
    }

    /// A preview that arrived after the switcher opened.
    func setPreview(_ image: NSImage?, at index: Int) {
        guard cards.indices.contains(index) else { return }
        cards[index].setPreview(image)
    }

    /// The cards' titles with the selected one marked and whether each
    /// shows a page preview (the harness prints it).
    var dump: [String] {
        cards.map { ($0.isSelected ? "▸ " : "") + $0.item.title + ($0.item.preview == nil ? "" : " [preview]") }
    }

    /// Each card's size (the harness prints it).
    var cardSizes: [NSSize] {
        cards.map(\.frame.size)
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

    /// One tab: the page's preview, favicon and title, address, and its
    /// Space.
    private final class Card: NSView {
        private(set) var item: Item
        var isSelected = false {
            didSet { refresh() }
        }

        private let background: ChromeRowBackgroundView
        private let preview: PreviewView
        private let icon = NSImageView()
        private let titleLabel = NSTextField(labelWithString: "")
        private let detailLabel = NSTextField(labelWithString: "")
        private let spaceLabel = NSTextField(labelWithString: "")
        private var theme: AppTheme

        init(item: Item, theme: AppTheme, size: NSSize) {
            self.item = item
            self.theme = theme
            background = ChromeRowBackgroundView(theme: theme)
            preview = PreviewView(theme: theme)
            super.init(frame: NSRect(origin: .zero, size: size))
            background.inset = 0
            background.translatesAutoresizingMaskIntoConstraints = true
            background.frame = bounds
            background.autoresizingMask = [.width, .height]
            addSubview(background)
            preview.image = item.preview
            preview.favicon = item.favicon
            icon.image = item.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            icon.imageScaling = .scaleProportionallyUpOrDown
            for label in [titleLabel, detailLabel, spaceLabel] {
                label.lineBreakMode = .byTruncatingTail
                label.usesSingleLineMode = true
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            for view in [preview, icon, titleLabel, detailLabel, spaceLabel] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            let inset = BrowserRecentTabsOverlay.previewInset
            let previewHeight = size.height - inset - BrowserRecentTabsOverlay.textHeight
            NSLayoutConstraint.activate([
                preview.topAnchor.constraint(equalTo: topAnchor, constant: inset),
                preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                preview.heightAnchor.constraint(equalToConstant: previewHeight),
                icon.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 8),
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                titleLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
                titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
                detailLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
                detailLabel.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
                detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
                spaceLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 2),
                spaceLabel.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
                spaceLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            ])
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
            preview.theme = theme
            refresh()
        }

        func setPreview(_ image: NSImage?) {
            item.preview = image
            preview.image = image
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

    /// The page's preview filling its frame from the top (aspect fill),
    /// else the favicon on the page color. Drawn, not layer contents, so
    /// the offscreen harness captures it.
    private final class PreviewView: NSView {
        var image: NSImage? {
            didSet { needsDisplay = true }
        }
        var favicon: NSImage? {
            didSet { needsDisplay = true }
        }
        var theme: AppTheme {
            didSet { needsDisplay = true }
        }

        init(theme: AppTheme) {
            self.theme = theme
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let colors = theme.colors
            let shape = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: Chrome.Radius.control,
                yRadius: Chrome.Radius.control
            )
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            colors.bgBase.setFill()
            bounds.fill()
            if let image, image.size.width > 0, image.size.height > 0 {
                let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
                let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                // A page of another shape keeps its top left corner, where
                // pages start, in view.
                let rect = NSRect(x: 0, y: 0, width: size.width, height: size.height)
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            } else {
                let side: CGFloat = 32
                let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
                let symbol = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: side * 0.75, weight: .regular).applying(.init(paletteColors: [colors.textMuted])))
                (favicon ?? symbol)?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
            colors.borderSubtle.setStroke()
            shape.lineWidth = Chrome.hairline
            shape.stroke()
        }
    }
}
