import AppKit

/// Back, forward and reload/stop, left of the address field. Back and
/// forward show the tab's history as a menu on long-press or right-click.
@MainActor
final class BrowserNavigationControls: NSView {
    enum Direction {
        case back
        case forward
    }

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReloadOrStop: (() -> Void)?
    /// The back or forward list as a menu; nil or empty shows nothing.
    var historyMenu: ((Direction) -> NSMenu?)?

    private let backButton: BrowserHistoryButton
    private let forwardButton: BrowserHistoryButton
    private let reloadButton: ChromeIconButton
    private var isLoading = false

    init(theme: AppTheme) {
        backButton = BrowserHistoryButton(
            symbolName: "chevron.left",
            accessibilityLabel: "Back",
            toolTip: "Back (⌘[) — hold for history"
        )
        forwardButton = BrowserHistoryButton(
            symbolName: "chevron.right",
            accessibilityLabel: "Forward",
            toolTip: "Forward (⌘]) — hold for history"
        )
        reloadButton = ChromeIconButton(
            symbolName: "arrow.clockwise",
            accessibilityLabel: "Reload",
            pointSize: 12,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        backButton.onPress = { [weak self] in self?.onBack?() }
        backButton.menuProvider = { [weak self] in self?.historyMenu?(.back) }
        forwardButton.onPress = { [weak self] in self?.onForward?() }
        forwardButton.menuProvider = { [weak self] in self?.historyMenu?(.forward) }
        reloadButton.target = self
        reloadButton.action = #selector(reloadPressed)

        let stack = NSStackView(views: [backButton, forwardButton, reloadButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 2
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        update(canGoBack: false, canGoForward: false, isLoading: false)
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        backButton.apply(theme: theme)
        forwardButton.apply(theme: theme)
        reloadButton.apply(theme: theme)
    }

    func update(canGoBack: Bool, canGoForward: Bool, isLoading: Bool) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        guard isLoading != self.isLoading || reloadButton.toolTip == nil else { return }
        self.isLoading = isLoading
        reloadButton.setSymbol(
            isLoading ? "xmark" : "arrow.clockwise",
            accessibilityLabel: isLoading ? "Stop" : "Reload",
            pointSize: 12
        )
        reloadButton.toolTip = isLoading ? "Stop loading" : "Reload this page (⌘R)"
    }

    @objc private func reloadPressed() {
        onReloadOrStop?()
    }
}

/// A Folio icon button that runs its action on click and shows a menu on
/// long-press, right-click or Control-click. The inner `ChromeIconButton`
/// draws the icon and hover state and keeps the accessibility press action;
/// this view takes the pointer so it can time the press.
@MainActor
final class BrowserHistoryButton: NSView {
    var onPress: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private let button: ChromeIconButton
    private var pressTimer: Timer?
    private var menuShown = false

    static let longPressDelay: TimeInterval = 0.4

    init(symbolName: String, accessibilityLabel: String, toolTip: String) {
        button = ChromeIconButton(
            symbolName: symbolName,
            accessibilityLabel: accessibilityLabel,
            pointSize: 12,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(accessibilityPressed)
        button.toolTip = toolTip
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var isEnabled: Bool {
        get { button.isEnabled }
        set { button.isEnabled = newValue }
    }

    func apply(theme: AppTheme) {
        button.apply(theme: theme)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.modifierFlags.contains(.control) {
            showMenu()
            return
        }
        menuShown = false
        button.isHighlighted = true
        pressTimer?.invalidate()
        let timer = Timer(timeInterval: Self.longPressDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.longPressFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pressTimer = timer
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressTimer != nil else { return }
        button.isHighlighted = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        pressTimer?.invalidate()
        pressTimer = nil
        button.isHighlighted = false
        guard isEnabled, !menuShown,
              bounds.contains(convert(event.locationInWindow, from: nil))
        else { return }
        onPress?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        showMenu()
    }

    private func longPressFired() {
        pressTimer = nil
        showMenu()
    }

    private func showMenu() {
        button.isHighlighted = false
        guard let menu = menuProvider?(), !menu.items.isEmpty else { return }
        menuShown = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
    }

    @objc private func accessibilityPressed() {
        onPress?()
    }
}
