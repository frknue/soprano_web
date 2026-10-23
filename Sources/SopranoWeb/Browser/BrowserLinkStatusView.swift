import AppKit

/// The link-hover status bubble at the bottom-left of the web area: the URL
/// of the hovered or focused link in SF Mono, middle-truncated. It never
/// takes mouse events, so it cannot cover the link under the pointer.
@MainActor
final class BrowserLinkStatusView: NSView {
    /// The tab whose link is showing; nil while hidden.
    private(set) var tabID: UUID?
    private let label = NSTextField(labelWithString: "")
    private var colors: ThemeColors?
    private var generation = 0

    static let inset: CGFloat = 6
    static let maximumWidthFraction: CGFloat = 0.6
    private static let horizontalPadding: CGFloat = 8
    private static let height: CGFloat = 22
    private static let fadeDuration: TimeInterval = 0.12

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        alphaValue = 0

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = ChromeFont.monoSmall
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var text: String { label.stringValue }

    func apply(theme: AppTheme) {
        colors = theme.colors
        label.textColor = theme.colors.textMuted
        needsDisplay = true
    }

    func show(_ text: String, tabID: UUID) {
        self.tabID = tabID
        label.stringValue = String(text.prefix(2048))
        generation += 1
        guard isHidden || alphaValue < 1 else { return }
        isHidden = false
        fade(to: 1, completion: nil)
    }

    func hide() {
        guard tabID != nil || !isHidden else { return }
        tabID = nil
        generation += 1
        let current = generation
        fade(to: 0) { [weak self] in
            guard let self, self.generation == current else { return }
            self.isHidden = true
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors else { return }
        let rect = bounds.insetBy(dx: Chrome.hairline / 2, dy: Chrome.hairline / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: Chrome.Radius.control, yRadius: Chrome.Radius.control)
        colors.raised.setFill()
        path.fill()
        colors.borderSubtle.setStroke()
        path.lineWidth = Chrome.hairline
        path.stroke()
    }

    private func fade(to alpha: CGFloat, completion: (@MainActor () -> Void)?) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window == nil {
            alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            self.animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }
}
