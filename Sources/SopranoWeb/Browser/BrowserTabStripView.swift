import AppKit

/// The row of tabs above the toolbar. Tabs share the available width down to
/// a readable minimum; when they no longer fit, the strip keeps the selected
/// tab visible and puts the rest behind an overflow menu. Dragging a tab
/// reorders the strip live and commits the move on release.
@MainActor
final class BrowserTabStripView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onReorder: ((UUID, Int) -> Void)?
    var onToggleMute: ((UUID) -> Void)?
    var contextMenuProvider: ((UUID) -> NSMenu?)?

    private struct Drag {
        let id: UUID
        var order: [UUID]
        let grabOffset: CGFloat
        var pointerX: CGFloat
    }

    private var theme: AppTheme
    private var order: [UUID] = []
    private var titles: [UUID: String] = [:]
    private var selectedID: UUID?
    private var buttons: [UUID: BrowserTabButton] = [:]
    private var visibleIDs: [UUID] = []
    private var overflowIDs: [UUID] = []
    private var drag: Drag?
    private var tabWidth: CGFloat = 0
    private var visibleStart = 0
    private var visibleCount = 0

    private let newTabButton: ChromeIconButton
    private let overflowButton: ChromeIconButton

    static let trafficLightInset: CGFloat = 76
    static let preferredHeight: CGFloat = 40
    private static let minimumTabWidth: CGFloat = 58
    private static let readableTabWidth: CGFloat = 96
    private static let maximumTabWidth: CGFloat = 220
    private static let controlsWidth: CGFloat = 58
    private static let tabHeight: CGFloat = 30

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

    func update(tabs: [BrowserTabItem], selectedID: UUID) {
        let ids = tabs.map(\.id)
        if ids != order {
            if ids.count == order.count, Set(ids) == Set(buttons.keys) {
                // A reorder: keep the buttons (one may be mid-drag).
                order = ids
            } else {
                rebuild(tabs: tabs)
            }
        }
        for tab in tabs {
            buttons[tab.id]?.item = tab
        }
        if var drag, Set(drag.order) != Set(order) {
            drag.order = order
            self.drag = drag
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
        drag = nil
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
        layoutTabs(animated: false)
    }

    private func layoutTabs(animated: Bool) {
        let left = Self.trafficLightInset
        let right = Self.controlsWidth
        let available = max(0, bounds.width - left - right)
        let displayOrder = drag?.order ?? order

        let newTabSize: CGFloat = 22
        let overflowSize: CGFloat = 22

        guard !displayOrder.isEmpty else {
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

        var width = min(Self.maximumTabWidth, available / CGFloat(displayOrder.count))
        if width < Self.readableTabWidth {
            width = max(Self.minimumTabWidth, available / CGFloat(displayOrder.count))
        }

        var visibleCount = displayOrder.count
        if width <= Self.minimumTabWidth, CGFloat(displayOrder.count) * Self.minimumTabWidth > available {
            visibleCount = max(1, Int(available / Self.minimumTabWidth))
            width = max(0, available / CGFloat(visibleCount))
        }

        let selectedIndex = selectedID.flatMap { displayOrder.firstIndex(of: $0) } ?? 0
        let start: Int
        if visibleCount >= displayOrder.count {
            start = 0
        } else {
            start = min(max(0, selectedIndex - visibleCount + 1), displayOrder.count - visibleCount)
        }
        tabWidth = width
        visibleStart = start
        self.visibleCount = visibleCount
        let visibleRange = start..<(start + visibleCount)
        visibleIDs = Array(displayOrder[visibleRange])
        overflowIDs = Array(displayOrder[..<start]) + Array(displayOrder[(start + visibleCount)...])
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

        let y = floor((bounds.height - Self.tabHeight) / 2)
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (index, id) in displayOrder.enumerated() {
            guard let button = buttons[id] else { continue }
            guard visibleRange.contains(index) else {
                button.isHidden = true
                continue
            }
            button.isHidden = false
            var frame = NSRect(
                x: left + CGFloat(index - start) * width,
                y: y,
                width: max(0, width - 2),
                height: Self.tabHeight
            )
            if let drag, drag.id == id {
                // The dragged tab follows the pointer inside the visible run.
                let minX = left
                let maxX = left + CGFloat(visibleCount - 1) * width
                frame.origin.x = min(max(minX, drag.pointerX - drag.grabOffset), maxX)
                button.frame = frame
            } else if animate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    button.animator().frame = frame
                }
            } else {
                button.frame = frame
            }
        }
    }

    private func rebuild(tabs: [BrowserTabItem]) {
        for button in buttons.values {
            button.removeFromSuperview()
        }
        buttons.removeAll()
        drag = nil
        order = tabs.map(\.id)

        for tab in tabs {
            let button = BrowserTabButton(item: tab, theme: theme)
            button.onSelect = { [weak self] id in self?.onSelect?(id) }
            button.onClose = { [weak self] id in self?.onClose?(id) }
            button.onToggleMute = { [weak self] id in self?.onToggleMute?(id) }
            button.contextMenuProvider = { [weak self] id in self?.contextMenuProvider?(id) }
            button.onDrag = { [weak self] id, phase, event in self?.handleDrag(id, phase, event) }
            addSubview(button)
            buttons[tab.id] = button
        }
        needsLayout = true
    }

    private func handleDrag(_ id: UUID, _ phase: BrowserTabButton.DragPhase, _ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        switch phase {
        case .began:
            guard let button = buttons[id] else { return }
            addSubview(button, positioned: .above, relativeTo: nil)
            drag = Drag(id: id, order: order, grabOffset: x - button.frame.minX, pointerX: x)
        case .moved:
            guard var drag, drag.id == id, visibleCount > 0 else { return }
            drag.pointerX = x
            let slot = BrowserTabReorder.slot(
                at: x - Self.trafficLightInset,
                pitch: tabWidth,
                count: visibleCount
            )
            drag.order = BrowserTabReorder.moving(id, to: visibleStart + slot, in: drag.order)
            self.drag = drag
            layoutTabs(animated: true)
        case .ended:
            guard let drag, drag.id == id else { return }
            self.drag = nil
            let changed = drag.order != order
            if changed {
                order = drag.order
            }
            layoutTabs(animated: true)
            if changed, let index = drag.order.firstIndex(of: id) {
                onReorder?(id, index)
            }
        }
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
