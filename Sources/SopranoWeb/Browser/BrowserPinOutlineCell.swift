import AppKit

/// What the rail's pinned outline shows for one row: the outline row and,
/// for a pin, its live tab's state.
struct BrowserRailPinRow: Equatable {
    var row: BrowserPinOutline.Row
    var favicon: NSImage?
    /// The pin has a live tab in the window.
    var isLive = false
    /// That tab is the selected one.
    var isSelected = false
    /// That tab's page left the pin's address: the "/" mark.
    var isAway = false
    /// The live tab's title (its current page), shown instead of the pin's.
    var liveTitle: String?
    /// A live folder's status line (loading, signed out, …); nil when
    /// its count says it all.
    var liveStatus: String?
    /// A live folder's last fetch failed.
    var liveFailed = false

    var id: UUID { row.node.id }

    static func == (lhs: BrowserRailPinRow, rhs: BrowserRailPinRow) -> Bool {
        lhs.row == rhs.row
            && lhs.favicon === rhs.favicon
            && lhs.isLive == rhs.isLive
            && lhs.isSelected == rhs.isSelected
            && lhs.isAway == rhs.isAway
            && lhs.liveTitle == rhs.liveTitle
            && lhs.liveStatus == rhs.liveStatus
            && lhs.liveFailed == rhs.liveFailed
    }
}

/// One row of the rail's pinned outline, indented by depth: a folder (its
/// icon, name, pin count and a disclosure chevron at the end) or a pin (its
/// favicon, then "/" when its live tab moved on, then the title). A pin
/// without a live tab reads muted; the selected one is raised like a tab.
/// The outline (`BrowserRailPinsView`) takes every click, so the row only
/// draws.
@MainActor
final class BrowserPinOutlineCellView: NSView {
    static let rowHeight: CGFloat = 32
    static let indent: CGFloat = 14
    /// The icon's leading inset at depth 0, the same as a tab's favicon.
    static let iconInset: CGFloat = 10
    static let iconSize: CGFloat = 16

    private let iconView = NSImageView()
    private let awayLabel = NSTextField(labelWithString: "/")
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var iconLeading: NSLayoutConstraint!
    private var titleAfterIcon: NSLayoutConstraint!
    private var titleAfterAway: NSLayoutConstraint!
    private var theme: AppTheme
    private(set) var content: BrowserRailPinRow?
    var isHovered = false {
        didSet { refreshSurface() }
    }
    /// A pin dragged over this folder would drop into it.
    var isDropTarget = false {
        didSet { refreshSurface() }
    }

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Chrome.Radius.control

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        awayLabel.translatesAutoresizingMaskIntoConstraints = false
        awayLabel.font = ChromeFont.labelStrong
        awayLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(awayLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = ChromeFont.count
        countLabel.alignment = .right
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(countLabel)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.imageScaling = .scaleProportionallyDown
        addSubview(chevron)

        iconLeading = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.iconInset)
        titleAfterIcon = titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8)
        titleAfterAway = titleLabel.leadingAnchor.constraint(equalTo: awayLabel.trailingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            iconLeading,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

            awayLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            awayLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleAfterIcon,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -6),

            countLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -4),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Where the icon sits (the pin's reset target), in the row.
    var iconFrame: NSRect {
        NSRect(
            x: iconLeading.constant - 3,
            y: (bounds.height - Self.iconSize) / 2 - 3,
            width: Self.iconSize + 6,
            height: Self.iconSize + 6
        )
    }

    func configure(_ content: BrowserRailPinRow, theme: AppTheme) {
        self.theme = theme
        self.content = content
        let row = content.row
        iconLeading.constant = Self.iconInset + CGFloat(row.depth) * Self.indent
        switch row.node {
        case let .folder(folder):
            if let source = folder.source {
                // A live folder: the pull request mark, the fetched count
                // ("!" after a failed fetch), its source and status.
                iconView.image = symbol("arrow.triangle.pull", size: 12)
                let count = folder.allPins.count
                countLabel.stringValue = content.liveFailed ? "!" : (count == 0 ? "" : "\(count)")
                toolTip = [source.summary, content.liveStatus].compactMap { $0 }.joined(separator: "\n")
            } else {
                iconView.image = symbol(row.isExpanded ? "folder.fill" : "folder", size: 12)
                let count = folder.allPins.count
                countLabel.stringValue = count == 0 ? "" : "\(count)"
                toolTip = nil
            }
            titleLabel.stringValue = folder.displayName
            chevron.image = symbol(row.isExpanded ? "chevron.down" : "chevron.right", size: 9)
            chevron.isHidden = false
            awayLabel.isHidden = true
            setAccessibilityLabel(row.isExpanded ? "\(folder.displayName), expanded" : "\(folder.displayName), collapsed")
        case let .pin(pin):
            iconView.image = content.favicon ?? symbol("globe", size: 12)
            titleLabel.stringValue = content.isLive ? (content.liveTitle ?? pin.displayTitle) : pin.displayTitle
            countLabel.stringValue = ""
            chevron.image = nil
            chevron.isHidden = true
            awayLabel.isHidden = !content.isAway
            toolTip = content.isAway
                ? "\(pin.displayTitle)\n\(pin.url)\nClick the icon to go back; ⌘-click keeps this page in a new tab"
                : "\(pin.displayTitle)\n\(pin.url)"
            setAccessibilityLabel(content.isAway ? "\(titleLabel.stringValue), moved on from \(pin.displayTitle)" : titleLabel.stringValue)
        }
        titleAfterIcon.isActive = awayLabel.isHidden
        titleAfterAway.isActive = !awayLabel.isHidden
        apply(theme: theme)
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        let isFolder = content?.row.node.isFolder ?? false
        let live = isFolder || (content?.isLive ?? false)
        let selected = content?.isSelected ?? false
        titleLabel.font = selected ? ChromeFont.labelStrong : ChromeFont.label
        titleLabel.textColor = live || isHovered ? colors.textPrimary : colors.textMuted
        awayLabel.textColor = colors.textMuted
        countLabel.textColor = colors.textMuted
        iconView.contentTintColor = colors.textMuted
        chevron.contentTintColor = colors.textMuted
        // A pin without a live tab reads as unloaded.
        iconView.alphaValue = live ? 1 : 0.55
        refreshSurface()
    }

    private func refreshSurface() {
        let colors = theme.colors
        let selected = content?.isSelected ?? false
        let fill = selected ? colors.raised : (isHovered || isDropTarget ? colors.hover : nil)
        layer?.backgroundColor = fill?.cgColor
        layer?.borderWidth = selected || isDropTarget ? Chrome.hairline : 0
        layer?.borderColor = colors.borderSubtle.cgColor
        titleLabel.textColor = (content?.row.node.isFolder ?? false) || (content?.isLive ?? false) || isHovered
            ? colors.textPrimary
            : colors.textMuted
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}
