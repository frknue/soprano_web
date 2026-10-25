import AppKit

/// One row of the sidebar's Bookmarks outline: indented by depth, a
/// disclosure chevron and folder icon for a folder (with its bookmark
/// count), the favicon for a bookmark (address in the tooltip).
@MainActor
final class BrowserBookmarkOutlineCellView: NSTableCellView {
    static let rowHeight: CGFloat = 30
    static let indent: CGFloat = 16

    var onToggle: (() -> Void)?

    private let disclosure = NSButton()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!
    private var theme: AppTheme
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Chrome.Radius.control

        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.isBordered = false
        disclosure.title = ""
        disclosure.imagePosition = .imageOnly
        disclosure.target = self
        disclosure.action = #selector(togglePressed)
        addSubview(disclosure)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = ChromeFont.row
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = ChromeFont.count
        countLabel.alignment = .right
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(countLabel)

        leading = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            leading,
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 14),
            disclosure.heightAnchor.constraint(equalToConstant: 14),

            iconView.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),

            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(row: BrowserBookmarkOutline.Row, theme: AppTheme, favicon: NSImage?) {
        apply(theme: theme)
        leading.constant = 8 + CGFloat(row.depth) * Self.indent
        switch row.node {
        case let .folder(folder):
            disclosure.isHidden = false
            disclosure.image = symbol(row.isExpanded ? "chevron.down" : "chevron.right", size: 9)
            disclosure.setAccessibilityLabel(row.isExpanded ? "Collapse \(folder.displayName)" : "Expand \(folder.displayName)")
            iconView.image = symbol(row.isExpanded ? "folder.fill" : "folder", size: 12)
            titleLabel.stringValue = folder.displayName
            let count = folder.allBookmarks.count
            countLabel.stringValue = count == 0 ? "" : "\(count)"
            toolTip = nil
        case let .bookmark(bookmark):
            disclosure.isHidden = true
            iconView.image = favicon ?? symbol("bookmark", size: 12)
            titleLabel.stringValue = bookmark.displayTitle
            countLabel.stringValue = ""
            toolTip = bookmark.url
        }
        setAccessibilityLabel(titleLabel.stringValue)
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        titleLabel.textColor = theme.colors.textPrimary
        countLabel.textColor = theme.colors.textMuted
        iconView.contentTintColor = theme.colors.textMuted
        disclosure.contentTintColor = theme.colors.textMuted
        layer?.backgroundColor = isHovered ? theme.colors.hover.cgColor : nil
    }

    @objc private func togglePressed() {
        onToggle?()
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
        layer?.backgroundColor = theme.colors.hover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = nil
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}
