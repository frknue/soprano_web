import AppKit

/// The toast a capture leaves at the page's bottom-right corner: its
/// thumbnail, where it went and that it is on the pasteboard. A click
/// shows the file in Finder.
final class BrowserCaptureToast: NSView {
    static let lifetime: TimeInterval = 5
    static let thumbnailHeight: CGFloat = 56

    let fileURL: URL
    var onReveal: ((URL) -> Void)?
    let thumbnail = NSImageView()
    let titleLabel: NSTextField
    let detailLabel: NSTextField

    init(fileURL: URL?, fallbackName: String, thumbnail image: NSImage?, note: String?, theme: AppTheme) {
        self.fileURL = fileURL ?? URL(fileURLWithPath: "/")
        let folder = fileURL?.deletingLastPathComponent().lastPathComponent
        titleLabel = NSTextField(labelWithString: folder.map { "Copied and saved to \($0)" } ?? "Copied to the clipboard")
        detailLabel = NSTextField(labelWithString: [fileURL?.lastPathComponent ?? fallbackName, note]
            .compactMap { $0 }.joined(separator: " · "))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        let colors = theme.colors
        layer?.backgroundColor = colors.raised.cgColor
        layer?.cornerRadius = Chrome.Radius.popover
        layer?.borderWidth = Chrome.hairline
        layer?.borderColor = colors.borderStrong.cgColor
        toolTip = fileURL == nil ? nil : "Show in Finder"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(titleLabel.stringValue), \(detailLabel.stringValue)")

        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.image = image
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.borderWidth = Chrome.hairline
        thumbnail.layer?.borderColor = colors.borderSubtle.cgColor
        thumbnail.layer?.cornerRadius = Chrome.Radius.control
        thumbnail.layer?.masksToBounds = true
        let aspect = image.map { $0.size.height > 0 ? min(max($0.size.width / $0.size.height, 0.4), 2.5) : 1 } ?? 1

        for (label, font, color) in [
            (titleLabel, ChromeFont.labelStrong, colors.textPrimary),
            (detailLabel, ChromeFont.meta, colors.textMuted),
        ] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = font
            label.textColor = color
            label.lineBreakMode = .byTruncatingMiddle
            label.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }
        addSubview(thumbnail)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumbnail.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            thumbnail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailHeight),
            thumbnail.widthAnchor.constraint(equalTo: thumbnail.heightAnchor, multiplier: aspect),
            titleLabel.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            detailLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        reveal()
    }

    override func accessibilityPerformPress() -> Bool {
        reveal()
        return true
    }

    private func reveal() {
        guard fileURL.path != "/" else { return }
        onReveal?(fileURL)
        removeFromSuperview()
    }
}
