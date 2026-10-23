import AppKit

/// One tab in the window's tab strip. Selection is a raised surface; the
/// close button appears on the active tab and under the pointer.
@MainActor
final class BrowserTabButton: NSView {
    let tabID: UUID
    /// Only the title renders today; the other fields are for tab chrome
    /// (favicon, loading and audio indicators).
    var item: BrowserTabItem {
        didSet { label.stringValue = item.title }
    }
    var isSelected = false {
        didSet { refresh() }
    }

    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton: ChromeIconButton
    private var theme: AppTheme
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(item: BrowserTabItem, theme: AppTheme) {
        self.tabID = item.id
        self.item = item
        self.theme = theme
        self.closeButton = ChromeIconButton(
            symbolName: "xmark",
            accessibilityLabel: "Close Tab",
            pointSize: 9,
            size: 16,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Chrome.Radius.control

        label.stringValue = item.title
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.alignment = .left
        addSubview(label)

        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.toolTip = "Close tab"
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        closeButton.apply(theme: theme)
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(tabID)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onClose?(tabID)
    }

    @objc private func closePressed() {
        onClose?(tabID)
    }

    private func refresh() {
        let colors = theme.colors
        layer?.backgroundColor = (isSelected ? colors.raised : (isHovered ? colors.hover : nil))?.cgColor
        layer?.borderWidth = isSelected ? Chrome.hairline : 0
        layer?.borderColor = colors.borderSubtle.cgColor
        label.font = isSelected ? ChromeFont.labelStrong : ChromeFont.label
        label.textColor = isSelected || isHovered ? colors.textPrimary : colors.textMuted
        closeButton.isHidden = !(isSelected || isHovered)
        closeButton.apply(theme: theme)
        setAccessibilityLabel(item.title)
    }
}
