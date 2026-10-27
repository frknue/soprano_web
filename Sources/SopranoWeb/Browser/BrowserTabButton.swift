import AppKit
import QuartzCore

/// One tab in the strip or the rail: favicon (a spinner while loading), title,
/// an audio glyph while the tab plays sound or is muted, and the close button
/// on the active tab and under the pointer. Selection is a raised surface; a
/// sleeping tab's favicon and title are dimmed. A split's row shows every
/// pane's favicon, the focused pane's title.
@MainActor
final class BrowserTabButton: NSView {
    enum DragPhase {
        case began
        case moved
        case ended
    }

    let tabID: UUID
    var item: BrowserTabItem {
        didSet {
            guard item != oldValue else { return }
            refreshContent()
        }
    }
    var isSelected = false {
        didSet { refresh() }
    }
    /// A pinned or favorite tab in the strip: the favicon alone, centered.
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            refreshContent()
            needsLayout = true
        }
    }

    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onToggleMute: ((UUID) -> Void)?
    /// A drag past the threshold; the container reorders live.
    var onDrag: ((UUID, DragPhase, NSEvent) -> Void)?
    var contextMenuProvider: ((UUID) -> NSMenu?)?

    private let iconView = NSImageView()
    /// A split's other panes' favicons, after the first pane's.
    private let paneIcons = NSStackView()
    private var labelAfterIcon: NSLayoutConstraint!
    private var labelAfterPanes: NSLayoutConstraint!
    private let spinner = BrowserTabSpinner()
    /// "/" on a compact pinned tab whose page moved on.
    private let awayBadge = NSTextField(labelWithString: "/")
    private let label = NSTextField(labelWithString: "")
    private let audioButton: ChromeIconButton
    private let closeButton: ChromeIconButton
    private let accessories = NSStackView()
    private var theme: AppTheme
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var dragOrigin: NSPoint?
    private var iconLeading: NSLayoutConstraint!
    private(set) var isDragging = false

    private static let dragThreshold: CGFloat = 4

    init(item: BrowserTabItem, theme: AppTheme) {
        self.tabID = item.id
        self.item = item
        self.theme = theme
        self.closeButton = ChromeIconButton(
            symbolName: "xmark",
            accessibilityLabel: "Close Tab",
            pointSize: 9,
            size: 16,
            target: nil,
            action: nil
        )
        self.audioButton = ChromeIconButton(
            symbolName: "speaker.wave.2.fill",
            accessibilityLabel: "Mute Tab",
            pointSize: 9,
            size: 16,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Chrome.Radius.control

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true
        addSubview(spinner)

        awayBadge.translatesAutoresizingMaskIntoConstraints = false
        awayBadge.font = ChromeFont.labelStrong
        awayBadge.isHidden = true
        addSubview(awayBadge)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.alignment = .left
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        paneIcons.translatesAutoresizingMaskIntoConstraints = false
        paneIcons.orientation = .horizontal
        paneIcons.spacing = 3
        paneIcons.isHidden = true
        addSubview(paneIcons)

        audioButton.target = self
        audioButton.action = #selector(audioPressed)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.toolTip = "Close tab"

        accessories.translatesAutoresizingMaskIntoConstraints = false
        accessories.orientation = .horizontal
        accessories.spacing = 2
        accessories.detachesHiddenViews = true
        accessories.addArrangedSubview(audioButton)
        accessories.addArrangedSubview(closeButton)
        accessories.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(accessories)

        iconLeading = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        labelAfterIcon = label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8)
        labelAfterPanes = label.leadingAnchor.constraint(equalTo: paneIcons.trailingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            iconLeading,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            spinner.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),

            awayBadge.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 1),
            awayBadge.centerYAnchor.constraint(equalTo: iconView.bottomAnchor, constant: -1),

            labelAfterIcon,
            paneIcons.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 3),
            paneIcons.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: accessories.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            accessories.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            accessories.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        closeButton.apply(theme: theme)
        audioButton.apply(theme: theme)
        refreshContent()
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

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            }
            return
        }
        dragOrigin = event.locationInWindow
        isDragging = false
        onSelect?(tabID)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        if !isDragging {
            let dx = event.locationInWindow.x - dragOrigin.x
            let dy = event.locationInWindow.y - dragOrigin.y
            guard hypot(dx, dy) >= Self.dragThreshold else { return }
            isDragging = true
            onDrag?(tabID, .began, event)
        }
        onDrag?(tabID, .moved, event)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = isDragging
        dragOrigin = nil
        isDragging = false
        if wasDragging {
            onDrag?(tabID, .ended, event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onClose?(tabID)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(tabID)
    }

    /// The pointer drag became a system drag session, which owns the rest
    /// of the gesture: forget it here.
    func cancelPointerDrag() {
        dragOrigin = nil
        isDragging = false
    }

    /// The tab as it looks now, for the drag session's image.
    func dragImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    @objc private func closePressed() {
        onClose?(tabID)
    }

    @objc private func audioPressed() {
        onToggleMute?(tabID)
    }

    /// Favicon, spinner, title, audio glyph and tooltip from `item`.
    private func refreshContent() {
        let colors = theme.colors
        label.stringValue = item.title
        let isSplit = item.panes.count > 1
        setIcon(iconView, isSplit ? item.panes[0].favicon : item.favicon)
        refreshPaneIcons(isSplit ? Array(item.panes.dropFirst()) : [])
        iconView.isHidden = item.isLoading
        spinner.color = colors.textMuted
        spinner.isAnimating = item.isLoading

        audioButton.isHidden = !(item.isPlayingAudio || item.isMuted)
        audioButton.setSymbol(
            item.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            accessibilityLabel: item.isMuted ? "Unmute Tab" : "Mute Tab",
            pointSize: 9
        )
        audioButton.toolTip = item.isMuted ? "Unmute tab" : "Mute tab"
        audioButton.apply(theme: theme)

        if isSplit {
            toolTip = "Split View\n" + item.panes.map { ($0.isFocused ? "▸ " : "   ") + $0.title }.joined(separator: "\n")
        } else if let url = item.url?.absoluteString, !url.isEmpty {
            toolTip = "\(item.title)\n\(url)"
        } else {
            toolTip = item.title
        }
        if item.isAway {
            toolTip = (toolTip ?? item.title) + "\nMoved on from its pinned page"
        }
        if item.isAsleep {
            toolTip = (toolTip ?? item.title) + "\nAsleep to save memory; reloads when you open it"
        }
        // Asleep: the page was released; the tab reads as inactive.
        iconView.alphaValue = item.isAsleep ? 0.4 : 1
        paneIcons.alphaValue = item.isAsleep ? 0.4 : 1
        label.alphaValue = item.isAsleep ? 0.55 : 1
        label.isHidden = isCompact
        accessories.isHidden = isCompact
        awayBadge.isHidden = !(isCompact && item.isAway)
        awayBadge.textColor = colors.textMuted
        refresh()
    }

    /// `image`, else a globe in the muted color.
    private func setIcon(_ view: NSImageView, _ image: NSImage?) {
        if let image {
            view.image = image
            view.contentTintColor = nil
        } else {
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            view.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            view.contentTintColor = theme.colors.textMuted
        }
    }

    /// The favicons after the first pane's; the label follows the last.
    private func refreshPaneIcons(_ panes: [BrowserTabPaneItem]) {
        while paneIcons.arrangedSubviews.count > panes.count {
            let view = paneIcons.arrangedSubviews[paneIcons.arrangedSubviews.count - 1]
            paneIcons.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        while paneIcons.arrangedSubviews.count < panes.count {
            let view = NSImageView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.imageScaling = .scaleProportionallyUpOrDown
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: 16),
                view.heightAnchor.constraint(equalToConstant: 16),
            ])
            paneIcons.addArrangedSubview(view)
        }
        for (view, pane) in zip(paneIcons.arrangedSubviews, panes) {
            if let view = view as? NSImageView {
                setIcon(view, pane.favicon)
            }
        }
        let shows = !panes.isEmpty && !isCompact
        paneIcons.isHidden = !shows
        labelAfterIcon.isActive = !shows
        labelAfterPanes.isActive = shows
    }

    override func layout() {
        super.layout()
        let leading = isCompact ? floor((bounds.width - 16) / 2) : 10
        if iconLeading.constant != leading {
            iconLeading.constant = leading
        }
    }

    private func refresh() {
        let colors = theme.colors
        layer?.backgroundColor = (isSelected ? colors.raised : (isHovered ? colors.hover : nil))?.cgColor
        layer?.borderWidth = isSelected ? Chrome.hairline : 0
        layer?.borderColor = colors.borderSubtle.cgColor
        label.font = isSelected ? ChromeFont.labelStrong : ChromeFont.label
        label.textColor = isSelected || isHovered ? colors.textPrimary : colors.textMuted
        closeButton.isHidden = !(isSelected || isHovered)
        closeButton.apply(theme: theme)
        setAccessibilityLabel(item.isAsleep ? "\(item.title), asleep" : item.title)
    }
}

/// A 14 pt loading ring: a three-quarter arc that turns while the tab
/// loads, and holds still under Reduce Motion.
@MainActor
private final class BrowserTabSpinner: NSView {
    var color: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }
    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            isHidden = !isAnimating
            updateAnimation()
        }
    }

    private var frameLink: CADisplayLink?
    /// Degrees; advanced by the display link.
    private var phase: CGFloat = 90
    private var lastTimestamp: CFTimeInterval?

    private static let degreesPerSecond: CGFloat = 400

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        path.appendArc(
            withCenter: center,
            radius: min(bounds.width, bounds.height) / 2 - 1.5,
            startAngle: phase,
            endAngle: phase + 270
        )
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    private func updateAnimation() {
        frameLink?.invalidate()
        frameLink = nil
        lastTimestamp = nil
        guard isAnimating, window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        if let lastTimestamp {
            phase -= CGFloat(link.timestamp - lastTimestamp) * Self.degreesPerSecond
            phase = phase.truncatingRemainder(dividingBy: 360)
        }
        lastTimestamp = link.timestamp
        needsDisplay = true
    }
}
