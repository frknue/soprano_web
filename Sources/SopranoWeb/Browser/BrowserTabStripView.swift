import AppKit

/// The row of tabs above the toolbar. Tabs share the available width down to
/// a readable minimum; when they no longer fit, the strip keeps the selected
/// tab visible and puts the rest behind an overflow menu.
@MainActor
final class BrowserTabStripView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?

    private var theme: AppTheme
    private var order: [UUID] = []
    private var titles: [UUID: String] = [:]
    private var selectedID: UUID?
    private var buttons: [UUID: BrowserTabButton] = [:]
    private var visibleIDs: [UUID] = []
    private var overflowIDs: [UUID] = []

    private let newTabButton: ChromeIconButton
    private let overflowButton: ChromeIconButton

    static let trafficLightInset: CGFloat = 76
    static let preferredHeight: CGFloat = 40
    private static let minimumTabWidth: CGFloat = 58
    private static let readableTabWidth: CGFloat = 96
    private static let maximumTabWidth: CGFloat = 220
    private static let controlsWidth: CGFloat = 58

    init(theme: AppTheme) {
        self.theme = theme
        self.newTabButton = ChromeIconButton(
            symbolName: "plus",
            accessibilityLabel: "New Tab",
            pointSize: 11,
            size: 22,
            target: nil,
            action: nil
        )
        self.overflowButton = ChromeIconButton(
            symbolName: "chevron.down",
            accessibilityLabel: "All Tabs",
            pointSize: 10,
            size: 22,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(newTabButton)
        addSubview(overflowButton)
        newTabButton.target = self
        newTabButton.action = #selector(newTabPressed)
        overflowButton.target = self
        overflowButton.action = #selector(overflowPressed)
        overflowButton.isHidden = true
        newTabButton.toolTip = "New tab (⌘T)"
        overflowButton.toolTip = "All tabs"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(tabs: [(id: UUID, title: String)], selectedID: UUID) {
        let ids = tabs.map(\.id)
        if ids != order {
            rebuild(tabs: tabs)
        } else {
            for tab in tabs {
                buttons[tab.id]?.title = tab.title
            }
        }
        self.titles = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.title) })
        self.selectedID = selectedID
        for (id, button) in buttons {
            button.isSelected = id == selectedID
        }
        needsLayout = true
    }

    func clear() {
        for button in buttons.values {
            button.removeFromSuperview()
        }
        buttons.removeAll()
        order.removeAll()
        titles.removeAll()
        selectedID = nil
        visibleIDs = []
        overflowIDs = []
        overflowButton.isHidden = true
        needsLayout = true
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        newTabButton.apply(theme: theme)
        overflowButton.apply(theme: theme)
        for button in buttons.values {
            button.apply(theme: theme)
        }
    }

    override func layout() {
        super.layout()

        let left = Self.trafficLightInset
        let right = Self.controlsWidth
        let available = max(0, bounds.width - left - right)

        let newTabSize: CGFloat = 22
        let overflowSize: CGFloat = 22

        guard !order.isEmpty else {
            newTabButton.frame = NSRect(
                x: left + 6,
                y: floor((bounds.height - newTabSize) / 2),
                width: newTabSize,
                height: newTabSize
            )
            overflowButton.isHidden = true
            overflowButton.frame = .zero
            visibleIDs = []
            overflowIDs = []
            return
        }

        var width = min(Self.maximumTabWidth, available / CGFloat(order.count))
        if width < Self.readableTabWidth {
            width = max(Self.minimumTabWidth, available / CGFloat(order.count))
        }

        var visibleCount = order.count
        if width <= Self.minimumTabWidth, CGFloat(order.count) * Self.minimumTabWidth > available {
            visibleCount = max(1, Int(available / Self.minimumTabWidth))
            width = max(0, available / CGFloat(visibleCount))
        }

        let selectedIndex = selectedID.flatMap { order.firstIndex(of: $0) } ?? 0
        let start: Int
        if visibleCount >= order.count {
            start = 0
        } else {
            start = min(max(0, selectedIndex - visibleCount + 1), order.count - visibleCount)
        }
        let visibleRange = start..<(start + visibleCount)
        visibleIDs = Array(order[visibleRange])
        overflowIDs = Array(order[..<start]) + Array(order[(start + visibleCount)...])
        overflowButton.isHidden = overflowIDs.isEmpty

        let controlsStart = left + width * CGFloat(visibleCount) + 6
        newTabButton.frame = NSRect(
            x: controlsStart,
            y: floor((bounds.height - newTabSize) / 2),
            width: newTabSize,
            height: newTabSize
        )
        overflowButton.frame = NSRect(
            x: controlsStart + newTabSize + 2,
            y: floor((bounds.height - overflowSize) / 2),
            width: overflowSize,
            height: overflowSize
        )

        let tabHeight: CGFloat = 30
        for (index, id) in order.enumerated() {
            guard let button = buttons[id] else { continue }
            if visibleRange.contains(index) {
                let slot = index - start
                button.isHidden = false
                button.frame = NSRect(
                    x: left + CGFloat(slot) * width,
                    y: floor((bounds.height - tabHeight) / 2),
                    width: max(0, width - 2),
                    height: tabHeight
                )
            } else {
                button.isHidden = true
            }
        }
    }

    private func rebuild(tabs: [(id: UUID, title: String)]) {
        for button in buttons.values {
            button.removeFromSuperview()
        }
        buttons.removeAll()
        order = tabs.map(\.id)

        for tab in tabs {
            let button = BrowserTabButton(id: tab.id, title: tab.title, theme: theme)
            button.onSelect = { [weak self] id in self?.onSelect?(id) }
            button.onClose = { [weak self] id in self?.onClose?(id) }
            addSubview(button)
            buttons[tab.id] = button
        }
        needsLayout = true
    }

    @objc private func newTabPressed() {
        onNewTab?()
    }

    @objc private func overflowPressed() {
        let menu = NSMenu(title: "All Tabs")
        for id in order {
            let item = NSMenuItem(
                title: titles[id] ?? "Untitled",
                action: #selector(selectFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = id
            item.state = id == selectedID ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Tab", action: #selector(closeSelected), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: overflowButton.frame.minX, y: bounds.minY),
            in: self
        )
    }

    @objc private func selectFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onSelect?(id)
    }

    @objc private func closeSelected() {
        guard let selectedID else { return }
        onClose?(selectedID)
    }
}
