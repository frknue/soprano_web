import AppKit
import WebKit

/// The Mini Player's content: the hosted web view filling it, and Folio
/// controls over it while the pointer is inside (always in the harness's
/// capture): "Back to Tab" and the title in a top bar that moves the
/// panel, Close (pauses and puts the page back) and play/pause.
@MainActor
final class BrowserMiniPlayerView: NSView {
    var onReturn: (() -> Void)?
    var onClose: (() -> Void)?
    var onPlayPause: (() -> Void)?

    /// Holds the web view, edge to edge.
    let host = NSView()
    let controls = NSView()
    let topBar = BrowserMiniPlayerDragBar()
    let titleLabel = NSTextField(labelWithString: "")
    let returnButton: ChromeIconButton
    let closeButton: ChromeIconButton
    let playButton: ChromeIconButton
    private var pills: [NSView] = []
    private var theme: AppTheme
    private var hoverArea: NSTrackingArea?
    /// Controls stay shown (the harness, keyboard focus).
    var pinsControls = false {
        didSet { controls.alphaValue = pinsControls ? 1 : controls.alphaValue }
    }

    init(theme: AppTheme) {
        self.theme = theme
        returnButton = ChromeIconButton(symbolName: "arrow.up.left.and.arrow.down.right", accessibilityLabel: "Back to Tab", pointSize: 11, target: nil, action: nil)
        closeButton = ChromeIconButton(symbolName: "xmark", accessibilityLabel: "Close Mini Player", pointSize: 11, target: nil, action: nil)
        playButton = ChromeIconButton(symbolName: "pause.fill", accessibilityLabel: "Pause", pointSize: 16, size: 36, target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = Chrome.Radius.panel
        layer?.masksToBounds = true

        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(host)
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.alphaValue = 0
        addSubview(controls)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(topBar)

        returnButton.target = self
        returnButton.action = #selector(returnPressed)
        returnButton.toolTip = "Back to Tab"
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.toolTip = "Close (pauses)"
        playButton.target = self
        playButton.action = #selector(playPressed)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = ChromeFont.labelStrong
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let returnPill = pill(returnButton)
        let closePill = pill(closeButton)
        let titlePill = pill(titleLabel, inset: Chrome.Space.s8)
        let playPill = pill(playButton)
        playPill.layer?.cornerRadius = 22
        for view in [returnPill, titlePill, closePill] {
            topBar.addSubview(view)
        }
        controls.addSubview(playPill)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor),
            topBar.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: controls.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            returnPill.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: Chrome.Space.s8),
            returnPill.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titlePill.leadingAnchor.constraint(equalTo: returnPill.trailingAnchor, constant: Chrome.Space.s4),
            titlePill.trailingAnchor.constraint(lessThanOrEqualTo: closePill.leadingAnchor, constant: -Chrome.Space.s4),
            titlePill.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titlePill.heightAnchor.constraint(equalTo: returnPill.heightAnchor),
            closePill.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -Chrome.Space.s8),
            closePill.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            playPill.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            playPill.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A raised Folio pill around `view` (legible over any video).
    private func pill(_ view: NSView, inset: CGFloat = 2) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = Chrome.Radius.control
        pill.layer?.borderWidth = Chrome.hairline
        view.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -inset),
            view.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            pill.heightAnchor.constraint(greaterThanOrEqualTo: view.heightAnchor, constant: 4),
        ])
        pills.append(pill)
        return pill
    }

    /// Puts `webView` in, filling the panel and shown.
    func host(_ webView: WKWebView) {
        clear()
        webView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        webView.isHidden = false
    }

    /// Takes every hosted view out.
    func clear() {
        host.subviews.forEach { $0.removeFromSuperview() }
    }

    func update(title: String, isPlaying: Bool) {
        titleLabel.stringValue = title
        playButton.setSymbol(isPlaying ? "pause.fill" : "play.fill", accessibilityLabel: isPlaying ? "Pause" : "Play", pointSize: 16)
        playButton.toolTip = isPlaying ? "Pause" : "Play"
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        titleLabel.textColor = colors.textPrimary
        for pill in pills {
            pill.layer?.backgroundColor = colors.raised.cgColor
            pill.layer?.borderColor = colors.borderSubtle.cgColor
        }
        for button in [returnButton, closeButton, playButton] {
            button.apply(theme: theme)
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setControlsShown(true)
    }

    override func mouseExited(with event: NSEvent) {
        setControlsShown(pinsControls)
    }

    private func setControlsShown(_ shown: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            controls.animator().alphaValue = shown ? 1 : 0
        }
    }

    /// Clicks reach the page except on the controls while they show.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit, hit === controls || (controls.alphaValue == 0 && hit.isDescendant(of: controls)) else {
            return hit
        }
        return host.hitTest(convert(point, from: superview))
    }

    @objc func returnPressed() {
        onReturn?()
    }

    @objc func closePressed() {
        onClose?()
    }

    @objc func playPressed() {
        onPlayPause?()
    }
}

/// The Mini Player's top bar: dragging it moves the panel.
final class BrowserMiniPlayerDragBar: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
