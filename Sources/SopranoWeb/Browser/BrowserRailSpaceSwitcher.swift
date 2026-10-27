import AppKit

/// One Space in the rail's switcher.
struct BrowserRailSpace: Equatable {
    let id: UUID
    var name: String
    var icon: BrowserSpaceIcon
    var color: BrowserProfileColor
    var isCurrent: Bool
}

/// The bottom of the rail: one icon per Space in display order (its emoji
/// or SF Symbol, else a dot, with its color mark under it), the current one
/// on a raised tile, then "+" for a new Space. Each icon's menu has Edit
/// Space… and Delete Space.
@MainActor
final class BrowserRailSpaceSwitcher: NSView {
    static let height: CGFloat = 44
    static let cellSize: CGFloat = 28

    var onSelect: ((UUID) -> Void)?
    var onNewSpace: (() -> Void)?
    var menuProvider: ((UUID) -> NSMenu?)?

    private(set) var items: [BrowserRailSpace] = []
    private var cells: [BrowserRailSpaceCell] = []
    private let newButton: ChromeIconButton
    /// The Spaces that don't fit, in a menu.
    private let moreButton: ChromeIconButton
    private(set) var overflow: [BrowserRailSpace] = []
    private let rule: ChromeRuleView
    private var theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        newButton = ChromeIconButton(
            symbolName: "plus",
            accessibilityLabel: "New Space",
            pointSize: 11,
            size: 24,
            target: nil,
            action: nil
        )
        moreButton = ChromeIconButton(
            symbolName: "chevron.up",
            accessibilityLabel: "More Spaces",
            pointSize: 10,
            size: 24,
            target: nil,
            action: nil
        )
        rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        newButton.translatesAutoresizingMaskIntoConstraints = true
        newButton.target = self
        newButton.action = #selector(newPressed)
        newButton.toolTip = "New Space…"
        addSubview(newButton)
        moreButton.translatesAutoresizingMaskIntoConstraints = true
        moreButton.target = self
        moreButton.action = #selector(morePressed)
        moreButton.toolTip = "More Spaces"
        moreButton.isHidden = true
        addSubview(moreButton)
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: Chrome.hairline),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ items: [BrowserRailSpace]) {
        guard items != self.items else { return }
        self.items = items
        while cells.count < items.count {
            let cell = BrowserRailSpaceCell(theme: theme)
            cell.onClick = { [weak self] id in self?.onSelect?(id) }
            cell.menuProvider = { [weak self] id in self?.menuProvider?(id) }
            addSubview(cell)
            cells.append(cell)
        }
        while cells.count > items.count {
            cells.removeLast().removeFromSuperview()
        }
        for (cell, item) in zip(cells, items) {
            cell.item = item
        }
        needsLayout = true
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        rule.color = theme.colors.borderSubtle
        newButton.apply(theme: theme)
        moreButton.apply(theme: theme)
        cells.forEach { $0.theme = theme }
    }

    /// Icons left to right from the rail's inset, closer together as
    /// Spaces are added; when even that runs out of room, the rest go into
    /// a "More Spaces" menu (the current Space always keeps its icon), and
    /// "+" follows.
    override func layout() {
        super.layout()
        let inset: CGFloat = 12
        let gap: CGFloat = 4
        let minimumStep: CGFloat = 22
        let buttonSize = newButton.intrinsicContentSize
        let available = bounds.width - inset * 2 - buttonSize.width - gap
        var shown = Array(cells.indices)
        var showsMore = false
        if CGFloat(cells.count) * minimumStep > available {
            showsMore = true
            let fitting = max(1, Int((available - buttonSize.width - gap) / minimumStep))
            shown = Array(cells.indices.prefix(fitting))
            if let current = items.firstIndex(where: \.isCurrent), !shown.contains(current) {
                shown[shown.count - 1] = current
            }
        }
        let room = available - (showsMore ? buttonSize.width + gap : 0)
        let step = min(Self.cellSize + gap, room / CGFloat(max(shown.count, 1)))
        let size = min(Self.cellSize, step - 2)
        let y = floor((bounds.height - size) / 2)
        var x = inset
        for (index, cell) in cells.enumerated() {
            guard shown.contains(index) else {
                cell.isHidden = true
                continue
            }
            cell.isHidden = false
            cell.frame = NSRect(x: x, y: y, width: size, height: size)
            x += step
        }
        overflow = items.indices.filter { !shown.contains($0) }.map { items[$0] }
        moreButton.isHidden = !showsMore
        let buttonY = floor((bounds.height - buttonSize.height) / 2)
        if showsMore {
            moreButton.frame = NSRect(x: x + 2, y: buttonY, width: buttonSize.width, height: buttonSize.height)
            x += buttonSize.width + gap
        }
        newButton.frame = NSRect(
            x: min(x + 2, bounds.width - buttonSize.width - inset),
            y: buttonY,
            width: buttonSize.width,
            height: buttonSize.height
        )
    }

    /// The Spaces in the "More Spaces" menu, each with its icon; choosing
    /// one switches to it.
    func overflowMenu() -> NSMenu {
        let menu = NSMenu(title: "More Spaces")
        for space in overflow {
            let prefix: String = if case let .emoji(emoji) = space.icon { "\(emoji) " } else { "" }
            let item = NSMenuItem(title: prefix + space.name, action: #selector(overflowChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = space.id
            if case let .symbol(name) = space.icon {
                item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func morePressed() {
        overflowMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height + 4), in: moreButton)
    }

    @objc private func overflowChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onSelect?(id)
    }

    /// The icon of Space `id`, for its menu and sheet to hang from.
    func cell(for id: UUID) -> NSView? {
        cells.first { $0.item?.id == id }
    }

    @objc private func newPressed() {
        onNewSpace?()
    }
}

@MainActor
private final class BrowserRailSpaceCell: NSView {
    var item: BrowserRailSpace? {
        didSet {
            toolTip = item?.name
            setAccessibilityLabel(item.map { $0.isCurrent ? "\($0.name), current Space" : $0.name })
            needsDisplay = true
        }
    }
    var theme: AppTheme {
        didSet { needsDisplay = true }
    }
    var onClick: ((UUID) -> Void)?
    var menuProvider: ((UUID) -> NSMenu?)?
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        if let id = item?.id {
            onClick?(id)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        item.flatMap { menuProvider?($0.id) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let colors = theme.colors
        if item.isCurrent || isHovered {
            let tile = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: Chrome.Radius.control,
                yRadius: Chrome.Radius.control
            )
            (item.isCurrent ? colors.raised : colors.hover).setFill()
            tile.fill()
            if item.isCurrent {
                colors.borderSubtle.setStroke()
                tile.lineWidth = Chrome.hairline
                tile.stroke()
            }
        }
        let ink = item.isCurrent ? colors.textPrimary : colors.textMuted
        let center = NSPoint(x: bounds.midX, y: bounds.midY + 2)
        BrowserSpaceIconDrawing.draw(item.icon, at: center, size: 13, color: ink, dimmed: !item.isCurrent)
        if case .none = item.icon {
            // No icon: the color mark is the icon.
            let dot = NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
            item.color.color(in: colors).setFill()
            NSBezierPath(ovalIn: dot).fill()
        } else {
            let dot = NSRect(x: bounds.midX - 2, y: bounds.minY + 3, width: 4, height: 4)
            item.color.color(in: colors).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}

/// Draws a Space's icon (an emoji or an SF Symbol) centered on a point.
@MainActor
enum BrowserSpaceIconDrawing {
    static func image(_ icon: BrowserSpaceIcon, size: CGFloat, color: NSColor) -> NSImage? {
        guard case let .symbol(name) = icon else { return nil }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))?
            .tinted(color)
    }

    static func draw(_ icon: BrowserSpaceIcon, at center: NSPoint, size: CGFloat, color: NSColor, dimmed: Bool) {
        switch icon {
        case .none:
            return
        case let .emoji(emoji):
            // Emoji take the row font; they ignore its color.
            let font = size >= 13 ? ChromeFont.row : ChromeFont.label
            let text = NSAttributedString(string: emoji, attributes: [.font: font])
            let textSize = text.size()
            let origin = NSPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2)
            if dimmed {
                // Emoji ignore the text color; fade them instead.
                NSGraphicsContext.current?.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setAlpha(0.6)
                text.draw(at: origin)
                NSGraphicsContext.current?.restoreGraphicsState()
            } else {
                text.draw(at: origin)
            }
        case .symbol:
            guard let image = image(icon, size: size, color: color) else { return }
            let rect = NSRect(
                x: center.x - image.size.width / 2,
                y: center.y - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            )
            image.draw(in: rect)
        }
    }
}

/// The rail's Today section head: a hairline, "TODAY" and the "+ New
/// Tab" row (in a window without Spaces only the row).
@MainActor
final class BrowserRailTodayHeader: NSView {
    var onNewTab: (() -> Void)?

    private let rule: ChromeRuleView
    private let label = NSTextField(labelWithString: "")
    private let newTabRow = BrowserRailNewTabRow()
    private var theme: AppTheme
    private var labelConstraints: [NSLayoutConstraint] = []
    private var plainConstraints: [NSLayoutConstraint] = []

    init(theme: AppTheme) {
        self.theme = theme
        rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for view in [rule, label, newTabRow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        newTabRow.onPress = { [weak self] in self?.onNewTab?() }
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: Chrome.hairline),
            label.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            newTabRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            newTabRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            newTabRow.heightAnchor.constraint(equalToConstant: 32),
            newTabRow.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        labelConstraints = [newTabRow.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6)]
        plainConstraints = [newTabRow.topAnchor.constraint(equalTo: topAnchor)]
        setShowsLabel(true)
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// "TODAY" and its rule show in a window with Spaces.
    func setShowsLabel(_ shows: Bool) {
        rule.isHidden = !shows
        label.isHidden = !shows
        NSLayoutConstraint.deactivate(shows ? plainConstraints : labelConstraints)
        NSLayoutConstraint.activate(shows ? labelConstraints : plainConstraints)
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        rule.color = theme.colors.borderSubtle
        label.attributedStringValue = ChromeText.eyebrow("Today", color: theme.colors.textMuted)
        newTabRow.theme = theme
    }

    /// "+ New Tab", as the mouse presses it (the harness too).
    func pressNewTab() {
        onNewTab?()
    }
}

@MainActor
private final class BrowserRailNewTabRow: NSView {
    var onPress: (() -> Void)?
    var theme: AppTheme = .folioPaper {
        didSet { refresh() }
    }
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "New Tab")
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Chrome.Radius.control
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = ChromeFont.label
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "New tab (⌘T)"
        setAccessibilityRole(.button)
        setAccessibilityLabel("New Tab")
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
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
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refresh()
    }

    private func refresh() {
        let colors = theme.colors
        layer?.backgroundColor = isHovered ? colors.hover.cgColor : nil
        icon.contentTintColor = colors.textMuted
        label.textColor = isHovered ? colors.textPrimary : colors.textMuted
    }
}
