import AppKit

/// ⇧⌘2's overlay over the page the user looks at (the Peek's, the focused
/// pane's): the page dimmed, a drag selects an area (shown undimmed), a
/// click takes the visible page, "Full Page" the whole document, Esc
/// cancels. It covers its web view exactly, so its points are the web
/// view's (`BrowserCaptureGeometry.areaRect`).
final class BrowserCaptureOverlay: NSView {
    enum Choice: Equatable {
        case area(CGRect)
        case visible
        case fullPage
        case cancel
    }

    /// The tab whose page it covers.
    let tabID: UUID
    var onChoice: ((Choice) -> Void)?
    private(set) var selection: CGRect?
    private var dragStart: CGPoint?
    private var theme: AppTheme
    let hint = NSView()
    private let label = NSTextField(labelWithString: "Drag to capture an area, or click for the visible page")
    private(set) lazy var fullPageButton = ChromeButton(
        title: "Full Page", theme: theme, target: self, action: #selector(captureFullPage)
    )
    private(set) lazy var cancelButton = ChromeButton(
        title: "Cancel", theme: theme, kind: .text, keycap: "esc", target: self, action: #selector(cancel)
    )

    init(tabID: UUID, theme: AppTheme) {
        self.tabID = tabID
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Capture")

        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.wantsLayer = true
        hint.layer?.cornerRadius = Chrome.Radius.popover
        hint.layer?.borderWidth = Chrome.hairline
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = ChromeFont.label
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.addSubview(label)
        hint.addSubview(fullPageButton)
        hint.addSubview(cancelButton)
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            hint.heightAnchor.constraint(equalToConstant: Chrome.controlHeight + 16),
            label.leadingAnchor.constraint(equalTo: hint.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            fullPageButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            fullPageButton.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: fullPageButton.trailingAnchor, constant: 4),
            cancelButton.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: hint.trailingAnchor, constant: -8),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The overlay lives only while it has the keyboard (Esc must reach
    /// it): ⌘L, ⌘T or a click elsewhere that takes focus cancels it. Async,
    /// so a focus change that comes straight back doesn't.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            Task { @MainActor [weak self] in
                guard let self, self.superview != nil, self.window?.firstResponder !== self else { return }
                self.onChoice?(.cancel)
            }
        }
        return resigned
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        hint.layer?.backgroundColor = colors.raised.cgColor
        hint.layer?.borderColor = colors.borderStrong.cgColor
        label.textColor = colors.textPrimary
        fullPageButton.apply(theme: theme)
        cancelButton.apply(theme: theme)
        needsDisplay = true
    }

    /// Shows `rect` as the selection (the harness's drawn drag).
    func select(_ rect: CGRect?) {
        selection = rect
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        let dim = NSBezierPath(rect: bounds)
        if let selection {
            dim.appendRect(selection)
            dim.windingRule = .evenOdd
        }
        colors.scrim.setFill()
        dim.fill()
        guard let selection else { return }
        colors.raised.setStroke()
        let edge = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = 1
        edge.stroke()
        let size = "\(Int(selection.width)) × \(Int(selection.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ChromeFont.count,
            .foregroundColor: colors.textPrimary,
        ]
        let text = NSAttributedString(string: size, attributes: attributes)
        let textSize = text.size()
        var badge = CGRect(
            x: selection.minX,
            y: selection.maxY + 6,
            width: ceil(textSize.width) + 12,
            height: ceil(textSize.height) + 6
        )
        if badge.maxY > bounds.maxY { badge.origin.y = selection.maxY - badge.height - 6 }
        colors.raised.setFill()
        NSBezierPath(roundedRect: badge, xRadius: Chrome.Radius.control, yRadius: Chrome.Radius.control).fill()
        text.draw(at: CGPoint(x: badge.minX + 6, y: badge.minY + 3))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        addCursorRect(hint.frame, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The hint bar's text and padding aren't page.
        dragStart = hint.frame.contains(point) ? nil : point
        select(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        select(BrowserCaptureGeometry.areaRect(from: dragStart, to: point, in: bounds))
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        dragStart = nil
        let end = convert(event.locationInWindow, from: nil)
        if let rect = BrowserCaptureGeometry.areaRect(from: start, to: end, in: bounds) {
            onChoice?(.area(rect))
        } else {
            onChoice?(.visible)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onChoice?(.cancel)
    }

    override func scrollWheel(with event: NSEvent) {}

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onChoice?(.cancel)
        } else if event.charactersIgnoringModifiers == "\r" {
            onChoice?(.visible)
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onChoice?(.cancel)
    }

    @objc func captureFullPage() {
        onChoice?(.fullPage)
    }

    @objc func cancel() {
        onChoice?(.cancel)
    }
}
