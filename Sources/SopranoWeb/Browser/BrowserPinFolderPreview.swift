import AppKit

/// The preview that opens when the pointer rests on a pinned folder in the
/// rail (Arc's folder preview): the folder's name, a search field and its
/// pins (subfolders included, with their path), filtered as you type.
/// Clicking a pin opens it like its row. It is a Folio popover drawn in the
/// window beside the rail, not a separate window.
@MainActor
final class BrowserPinFolderPreview: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 280
    static let maximumRows = 10
    private static let rowHeight: CGFloat = 28

    var onOpenPin: ((UUID) -> Void)?
    /// The pointer left the preview.
    var onExit: (() -> Void)?

    private(set) var folderID: UUID
    private(set) var entries: [BrowserPinEntry]
    private(set) var shown: [BrowserPinEntry] = []
    private var theme: AppTheme
    private let heading: ChromeEyebrowView
    private let searchFrame: ChromeFieldView
    let searchField = NSTextField()
    private let list = NSStackView()
    /// "No matches", "This folder is empty" or "3 more", under the rows.
    private let footerLabel = NSTextField(labelWithString: "")
    private let favicons: (String) -> NSImage?
    private var trackingArea: NSTrackingArea?
    private(set) var isPointerInside = false

    /// `entries`: the folder's pins with their path below it.
    init(
        folder: BrowserPinFolder,
        entries: [BrowserPinEntry],
        theme: AppTheme,
        favicons: @escaping (String) -> NSImage?
    ) {
        self.folderID = folder.id
        self.entries = entries
        self.theme = theme
        self.favicons = favicons
        heading = ChromeEyebrowView(title: folder.displayName, theme: theme)
        searchFrame = ChromeFieldView(theme: theme)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
        translatesAutoresizingMaskIntoConstraints = false

        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel("Search \(folder.displayName)")
        searchFrame.addSubview(searchField)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        footerLabel.font = ChromeFont.meta
        footerLabel.lineBreakMode = .byTruncatingTail
        for view in [heading, searchFrame, list] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let inset = Chrome.Space.panel
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),

            searchFrame.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            searchFrame.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            searchFrame.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            searchFrame.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),
            searchField.leadingAnchor.constraint(equalTo: searchFrame.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchFrame.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchFrame.centerYAnchor),

            list.topAnchor.constraint(equalTo: searchFrame.bottomAnchor, constant: 8),
            list.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            list.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        apply(theme: theme)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        heading.apply(theme: theme)
        searchFrame.apply(theme: theme)
        ChromeFieldView.styleEmbedded(searchField, colors: colors, font: ChromeFont.label)
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search this folder",
            attributes: [.foregroundColor: colors.textMuted, .font: ChromeFont.label]
        )
        footerLabel.textColor = colors.textMuted
        needsDisplay = true
    }

    /// Types `text` into the search field (the harness).
    func setSearchText(_ text: String) {
        searchField.stringValue = text
        reload()
    }

    func controlTextDidChange(_ notification: Notification) {
        reload()
    }

    /// The folder's pins whose title, address or path match the search.
    private func reload() {
        let needle = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = needle.isEmpty ? entries : entries.filter {
            $0.pin.title.lowercased().contains(needle)
                || $0.pin.url.lowercased().contains(needle)
                || $0.path.contains { $0.lowercased().contains(needle) }
        }
        shown = Array(matches.prefix(Self.maximumRows))
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for entry in shown {
            let row = BrowserPinPreviewRow(entry: entry, favicon: favicons(entry.pin.url), theme: theme)
            row.onPress = { [weak self] in self?.onOpenPin?(entry.pin.id) }
            list.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: list.widthAnchor),
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            ])
        }
        let hidden = matches.count - shown.count
        footerLabel.stringValue = matches.isEmpty
            ? (needle.isEmpty ? "This folder is empty" : "No matches")
            : (hidden > 0 ? "\(hidden) more" : "")
        if !footerLabel.stringValue.isEmpty {
            list.addArrangedSubview(footerLabel)
            list.setCustomSpacing(4, after: list.arrangedSubviews[max(0, list.arrangedSubviews.count - 2)])
        }
        refit()
    }

    /// Once placed in the window, the preview keeps its top edge and
    /// grows or shrinks to fit its rows.
    private func refit() {
        guard superview != nil, translatesAutoresizingMaskIntoConstraints else { return }
        let top = frame.maxY
        layoutSubtreeIfNeeded()
        let height = fittingSize.height
        frame = NSRect(x: frame.minX, y: top - height, width: frame.width, height: height)
        layoutSubtreeIfNeeded()
    }

    /// The popover surface, drawn so an offscreen capture shows it.
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Chrome.Radius.popover,
            yRadius: Chrome.Radius.popover
        )
        theme.colors.raised.setFill()
        shape.fill()
        theme.colors.borderStrong.setStroke()
        shape.lineWidth = Chrome.hairline
        shape.stroke()
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
        isPointerInside = true
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        onExit?()
    }

    override func cancelOperation(_ sender: Any?) {
        onExit?()
    }
}

/// One pin in the folder preview: favicon, title and its path in the
/// folder.
@MainActor
private final class BrowserPinPreviewRow: NSView {
    var onPress: (() -> Void)?
    private let theme: AppTheme
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(entry: BrowserPinEntry, favicon: NSImage?, theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Chrome.Radius.control
        let icon = NSImageView()
        icon.image = favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        icon.contentTintColor = theme.colors.textMuted
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: entry.pin.displayTitle)
        title.font = ChromeFont.label
        title.textColor = theme.colors.textPrimary
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let path = NSTextField(labelWithString: entry.path.dropFirst().joined(separator: " / "))
        path.font = ChromeFont.meta
        path.textColor = theme.colors.textMuted
        path.lineBreakMode = .byTruncatingHead
        path.alignment = .right
        path.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        for view in [icon, title, path] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            path.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            path.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            path.centerYAnchor.constraint(equalTo: centerYAnchor),
            path.widthAnchor.constraint(lessThanOrEqualToConstant: 100),
        ])
        toolTip = entry.pin.url
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.pin.displayTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        onPress?()
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
}
