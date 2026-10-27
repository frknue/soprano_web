import AppKit

/// What one extension's toolbar button shows for the selected tab.
struct BrowserExtensionToolbarItem: Equatable {
    var id: String
    var icon: NSImage?
    var label: String
    /// Empty: no badge.
    var badge: String
    var isEnabled: Bool
}

/// An extension's toolbar button: its action icon in a 24 pt box with a
/// `hover` fill like `ChromeIconButton`, and the badge text in a small ink
/// capsule over its bottom-right corner. Right-click shows its menu.
@MainActor
final class BrowserExtensionActionButton: NSButton {
    private(set) var item: BrowserExtensionToolbarItem
    private var theme: AppTheme
    /// The button's context menu (the action's items, options, Settings).
    var menuProvider: ((String) -> NSMenu?)?
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    init(item: BrowserExtensionToolbarItem, theme: AppTheme) {
        self.item = item
        self.theme = theme
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ChromeIconButton.defaultSize),
            heightAnchor.constraint(equalToConstant: ChromeIconButton.defaultSize),
        ])
        apply(item)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(_ item: BrowserExtensionToolbarItem) {
        self.item = item
        toolTip = item.badge.isEmpty ? item.label : "\(item.label) (\(item.badge))"
        setAccessibilityLabel(item.label)
        isEnabled = item.isEnabled
        needsDisplay = true
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        let isHot = isEnabled && (isHovered || isHighlighted)
        if isHot {
            colors.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Chrome.Radius.control, yRadius: Chrome.Radius.control).fill()
        }
        let iconRect = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        if let icon = item.icon {
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.45)
        } else if let symbol = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [colors.textMuted]))
            )
        {
            symbol.draw(in: iconRect.insetBy(dx: 1, dy: 1), from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.45)
        }
        drawBadge(colors: colors)
    }

    private func drawBadge(colors: ThemeColors) {
        let text = String(item.badge.prefix(4))
        guard !text.isEmpty else { return }
        let string = NSAttributedString(string: text, attributes: [
            .font: ChromeFont.sans(size: 8, weight: .semibold, tabular: true),
            .foregroundColor: colors.inkButtonLabel,
        ])
        let size = string.size()
        let height: CGFloat = 11
        let width = max(height, ceil(size.width) + 5)
        let capsule = NSRect(x: bounds.maxX - width, y: isFlipped ? bounds.maxY - height : 0, width: width, height: height)
        colors.inkButtonFill.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: height / 2, yRadius: height / 2).fill()
        string.draw(at: NSPoint(x: capsule.midX - size.width / 2, y: capsule.midY - size.height / 2))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(item.id) ?? super.menu(for: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .inVisibleRect, .activeInActiveApp],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }
}
