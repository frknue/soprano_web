import AppKit

/// The Folio popover body of the lock / site chip: the page's site, its
/// connection (the details sheet behind the row), camera, microphone,
/// notification and pop-up decisions, zoom, "Block ads on this site",
/// extensions' access and "Clear site data". The controller rebuilds it
/// with `configure` after every change.
@MainActor
final class BrowserSiteControlView: NSView {
    static let width: CGFloat = 320

    enum ZoomAction {
        case zoomOut
        case zoomIn
        case reset
    }

    enum ExtensionAction: Equatable {
        case access(BrowserExtensionRecord.SiteAccess)
        case allowHere(Bool)
    }

    var onConnection: (() -> Void)?
    var onPermission: ((SitePermission, BrowserSiteChoice) -> Void)?
    var onZoom: ((ZoomAction) -> Void)?
    var onBlocksAds: ((Bool) -> Void)?
    var onExtension: ((String, ExtensionAction) -> Void)?
    var onClearData: (() -> Void)?

    private var theme: AppTheme
    private(set) var state: BrowserSiteControlState
    private let stack = NSStackView()
    /// The rows' controls, for the harness and tests.
    private(set) var connectionButton: ChromeButton?
    private(set) var permissionButtons: [SitePermission: ChromeButton] = [:]
    private(set) var zoomLabel: NSTextField?
    private(set) var blockingAccessory: BrowserSiteBlockingAccessory?
    private(set) var clearButton: ChromeButton?

    init(theme: AppTheme, state: BrowserSiteControlState) {
        self.theme = theme
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.panel),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Chrome.Space.panel),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        configure(state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ state: BrowserSiteControlState) {
        self.state = state
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        permissionButtons = [:]

        add(ChromeEyebrowView(title: state.host, theme: theme))

        let connection = ChromeButton(title: "\(state.connectionTitle)  ›", theme: theme, kind: .standard)
        connection.target = self
        connection.action = #selector(connectionPressed)
        connection.setAccessibilityLabel("Connection")
        connection.toolTip = state.connectionDetail
        connectionButton = connection
        add(connection, fullWidth: true)

        add(rule())
        add(ChromeEyebrowView(title: "Permissions", theme: theme))
        for row in state.permissions {
            let button = ChromeButton(title: "\(row.choice.title) ▾", theme: theme, kind: .standard)
            button.identifier = NSUserInterfaceItemIdentifier(row.permission.rawValue)
            button.target = self
            button.action = #selector(permissionPressed(_:))
            button.isEnabled = row.isEnabled
            button.setAccessibilityLabel(row.label)
            permissionButtons[row.permission] = button
            add(line(label(row.label), [button]), fullWidth: true)
        }

        add(rule())
        let zoom = label(state.zoomPercent)
        zoom.alignment = .center
        zoom.widthAnchor.constraint(equalToConstant: 44).isActive = true
        zoomLabel = zoom
        let zoomOut = symbolButton("−", label: "Zoom Out", action: #selector(zoomOutPressed))
        let zoomIn = symbolButton("+", label: "Zoom In", action: #selector(zoomInPressed))
        let reset = ChromeButton(title: "Reset", theme: theme, kind: .text)
        reset.target = self
        reset.action = #selector(zoomResetPressed)
        add(line(label("Zoom"), [zoomOut, zoom, zoomIn, reset]), fullWidth: true)

        blockingAccessory = nil
        if let blocks = state.blocksAds {
            let accessory = BrowserSiteBlockingAccessory(host: state.host, isOn: blocks, theme: theme) { [weak self] on in
                self?.onBlocksAds?(on)
            }
            accessory.translatesAutoresizingMaskIntoConstraints = false
            accessory.heightAnchor.constraint(equalToConstant: 24).isActive = true
            blockingAccessory = accessory
            add(accessory, fullWidth: true)
        }

        if !state.extensions.isEmpty {
            add(rule())
            add(ChromeEyebrowView(title: "Extensions", theme: theme))
            for item in state.extensions {
                let button = ChromeButton(title: "\(item.summary) ▾", theme: theme, kind: .standard)
                button.identifier = NSUserInterfaceItemIdentifier(item.id)
                button.target = self
                button.action = #selector(extensionPressed(_:))
                button.setAccessibilityLabel("\(item.name) site access")
                let name = label(item.name)
                name.lineBreakMode = .byTruncatingTail
                name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                add(line(name, [button]), fullWidth: true)
            }
        }

        clearButton = nil
        if state.dataTarget != nil {
            add(rule())
            let clear = ChromeButton(title: "Clear site data…", theme: theme, kind: .danger)
            clear.target = self
            clear.action = #selector(clearPressed)
            clearButton = clear
            add(clear)
        }
        needsDisplay = true
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        configure(state)
    }

    // MARK: Building

    private func add(_ view: NSView, fullWidth: Bool = false) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        if fullWidth {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = ChromeFont.label
        field.textColor = theme.colors.textPrimary
        return field
    }

    private func rule() -> NSView {
        let rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: Self.width - 2 * Chrome.Space.panel).isActive = true
        return rule
    }

    private func symbolButton(_ title: String, label: String, action: Selector) -> ChromeButton {
        let button = ChromeButton(title: title, theme: theme, kind: .standard)
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        return button
    }

    /// A label on the leading edge, `controls` on the trailing one.
    private func line(_ title: NSView, _ controls: [NSView]) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [title, spacer] + controls)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    /// The popover surface, drawn rather than a layer so an offscreen
    /// capture shows it.
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

    // MARK: Menus

    /// Ask / Allow / Block for a permission, the current one checked.
    func permissionMenu(for permission: SitePermission) -> NSMenu {
        let current = state.permissions.first { $0.permission == permission }?.choice
        let menu = NSMenu()
        for choice in BrowserSiteChoice.allCases {
            let item = BrowserClosureMenuItem(title: choice.title) { [weak self] in
                self?.onPermission?(permission, choice)
            }
            item.state = choice == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// The extension's site access, and "Allow on <host>".
    func extensionMenu(for id: String) -> NSMenu {
        let menu = NSMenu()
        guard let item = state.extensions.first(where: { $0.id == id }) else { return menu }
        for access in BrowserExtensionRecord.SiteAccess.allCases {
            let entry = BrowserClosureMenuItem(title: access.title) { [weak self] in
                self?.onExtension?(id, .access(access))
            }
            entry.state = item.access == access ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let allowed = item.access == .specificSites && item.allowedHere
        let here = BrowserClosureMenuItem(title: "Allow on \(state.host)") { [weak self] in
            self?.onExtension?(id, .allowHere(!allowed))
        }
        here.state = allowed ? .on : .off
        menu.addItem(here)
        return menu
    }

    // MARK: Actions

    @objc private func connectionPressed() {
        onConnection?()
    }

    @objc private func permissionPressed(_ sender: ChromeButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        permissionMenu(for: SitePermission(rawValue: raw))
            .popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func extensionPressed(_ sender: ChromeButton) {
        guard let id = sender.identifier?.rawValue else { return }
        extensionMenu(for: id).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func zoomOutPressed() { onZoom?(.zoomOut) }
    @objc private func zoomInPressed() { onZoom?(.zoomIn) }
    @objc private func zoomResetPressed() { onZoom?(.reset) }

    @objc private func clearPressed() {
        onClearData?()
    }

    /// Where the popover goes: under `anchor` (both in the same unflipped
    /// coordinates), its leading edge near the anchor's, kept inside
    /// `bounds`.
    static func frame(size: NSSize, below anchor: NSRect, within bounds: NSRect) -> NSRect {
        var x = anchor.minX - 12
        x = min(max(x, bounds.minX + 8), bounds.maxX - size.width - 8)
        return NSRect(x: x, y: anchor.minY - 8 - size.height, width: size.width, height: size.height).integral
    }
}

/// The borderless child panel that floats the Site Control Center under
/// the lock. Clicking elsewhere or Esc closes it.
@MainActor
final class BrowserSiteControlPanel: NSPanel {
    private weak var hostWindow: NSWindow?
    private(set) var content: BrowserSiteControlView?
    private var isClosing = false
    /// When it last closed because another window took the click; the
    /// lock ignores the click that closed it.
    private(set) var lastResignedAt: Date?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: BrowserSiteControlView.width, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        collectionBehavior = [.fullScreenAuxiliary]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var isShown: Bool { content != nil }

    func show(_ view: BrowserSiteControlView, below anchor: NSView, in hostWindow: NSWindow) {
        close()
        isClosing = false
        content = view
        self.hostWindow = hostWindow
        contentView = view
        view.layoutSubtreeIfNeeded()
        let anchorRect = hostWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        setFrame(
            BrowserSiteControlView.frame(size: view.fittingSize, below: anchorRect, within: hostWindow.frame),
            display: true
        )
        hostWindow.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
    }

    /// Fits the panel to its rebuilt content, keeping the top edge.
    func refit() {
        guard let content else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = self.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        setFrame(frame, display: true)
    }

    override func close() {
        guard content != nil, !isClosing else { return }
        isClosing = true
        content = nil
        hostWindow?.removeChildWindow(self)
        orderOut(nil)
        contentView = nil
        hostWindow = nil
        isClosing = false
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func resignKey() {
        super.resignKey()
        guard content != nil, !isClosing else { return }
        lastResignedAt = Date()
        close()
    }
}
