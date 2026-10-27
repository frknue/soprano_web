import AppKit

/// A window's mark as an eyebrow: its Space's color dot and icon (an
/// emoji, or an SF Symbol drawn inline) and the Space's name, "Private"
/// or "Private · Work". The tab
/// rail's header shows it (or `fallback`, "Tabs"); with horizontal tabs it
/// sits before the address field.
@MainActor
final class BrowserWindowMarkView: NSView {
    private let dot = ChromeStatusMark(shape: .dot)
    private let label = NSTextField(labelWithString: "")
    private let fallback: String?
    private var theme: AppTheme
    private var mark = BrowserWindowMark(kind: .normal, space: nil)
    private lazy var labelAfterDot = label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6)
    private lazy var labelAtEdge = label.leadingAnchor.constraint(equalTo: leadingAnchor)

    /// `fallback` is shown, muted, when the mark is empty; nil leaves the
    /// view empty.
    init(theme: AppTheme, fallback: String? = nil) {
        self.theme = theme
        self.fallback = fallback
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addSubview(dot)
        addSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Whether the mark has words of its own (not just the fallback).
    var hasMark: Bool { mark.text != nil }

    /// The words shown (an SF Symbol icon as `[name]`), for the harness.
    var text: String {
        guard case let .symbol(name) = mark.spaceIcon, let words = mark.text else { return label.stringValue }
        return "[\(name)] \(words.uppercased())"
    }

    func set(_ mark: BrowserWindowMark) {
        guard mark != self.mark else { return }
        self.mark = mark
        refresh()
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        refresh()
    }

    private func refresh() {
        let colors = theme.colors
        if let text = mark.text {
            let words = ChromeText.eyebrow(text, color: colors.textPrimary)
            if case let .symbol(name) = mark.spaceIcon,
               let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                   .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            {
                let attachment = NSTextAttachment()
                attachment.image = symbol.tinted(colors.textPrimary)
                attachment.bounds = NSRect(x: 0, y: -1.5, width: symbol.size.width, height: symbol.size.height)
                let line = NSMutableAttributedString(attachment: attachment)
                line.append(NSAttributedString(string: " ", attributes: [.font: ChromeFont.eyebrow]))
                line.append(words)
                label.attributedStringValue = line
            } else {
                label.attributedStringValue = words
            }
        } else {
            label.attributedStringValue = ChromeText.eyebrow(fallback ?? "", color: colors.textMuted)
        }
        let color = mark.color
        dot.isHidden = color == nil
        if let color {
            dot.color = color.color(in: colors)
        }
        // Deactivate before activating, so the two never conflict.
        if color == nil {
            labelAfterDot.isActive = false
            labelAtEdge.isActive = true
        } else {
            labelAtEdge.isActive = false
            labelAfterDot.isActive = true
        }
        toolTip = mark.toolTip
        setAccessibilityLabel(mark.text ?? fallback)
    }
}
