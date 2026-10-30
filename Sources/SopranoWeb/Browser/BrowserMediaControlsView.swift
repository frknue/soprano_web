import AppKit

/// The playing tab's controls: its artwork (else favicon), title and
/// artist, play/pause, next track and mute. `.rail` sits at the rail's
/// bottom above the Space switcher; `.toolbar` is a compact chip in the
/// toolbar when there is no rail. A click outside the buttons selects the
/// tab. Hidden while there is no item.
@MainActor
final class BrowserMediaControlsView: NSView {
    enum Style {
        case rail
        case toolbar
    }

    static let railHeight: CGFloat = 52
    static let toolbarTitleWidth: CGFloat = 140

    var onSelect: ((UUID) -> Void)?
    var onPlayPause: ((UUID) -> Void)?
    var onNext: ((UUID) -> Void)?
    var onMute: ((UUID) -> Void)?

    let style: Style
    private(set) var item: BrowserMediaControlItem?
    let artworkView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    let playButton: ChromeIconButton
    let nextButton: ChromeIconButton
    let muteButton: ChromeIconButton
    private let rule: ChromeRuleView
    private var theme: AppTheme
    private var hiddenWidth: NSLayoutConstraint?

    init(style: Style, theme: AppTheme) {
        self.style = style
        self.theme = theme
        let size: CGFloat = style == .rail ? Chrome.iconButtonSize : 22
        let point: CGFloat = style == .rail ? 12 : 11
        playButton = ChromeIconButton(symbolName: "pause.fill", accessibilityLabel: "Pause", pointSize: point, size: size, target: nil, action: nil)
        nextButton = ChromeIconButton(symbolName: "forward.fill", accessibilityLabel: "Next Track", pointSize: point, size: size, target: nil, action: nil)
        muteButton = ChromeIconButton(symbolName: "speaker.wave.2.fill", accessibilityLabel: "Mute Tab", pointSize: point, size: size, target: nil, action: nil)
        rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        for (button, action) in [
            (playButton, #selector(playPressed)),
            (nextButton, #selector(nextPressed)),
            (muteButton, #selector(mutePressed)),
        ] {
            button.target = self
            button.action = action
        }
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = Chrome.Radius.cap
        artworkView.layer?.masksToBounds = true
        for (label, font) in [
            (titleLabel, style == .rail ? ChromeFont.labelStrong : ChromeFont.label),
            (subtitleLabel, ChromeFont.meta),
        ] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = font
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let buttons = NSStackView(views: [playButton, nextButton, muteButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.orientation = .horizontal
        buttons.spacing = style == .rail ? 2 : 0
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [artworkView, titleLabel, buttons] as [NSView] {
            addSubview(view)
        }
        switch style {
        case .rail:
            addSubview(subtitleLabel)
            addSubview(rule)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: Self.railHeight),
                rule.topAnchor.constraint(equalTo: topAnchor),
                rule.leadingAnchor.constraint(equalTo: leadingAnchor),
                rule.trailingAnchor.constraint(equalTo: trailingAnchor),
                artworkView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.s16),
                artworkView.centerYAnchor.constraint(equalTo: centerYAnchor),
                artworkView.widthAnchor.constraint(equalToConstant: 32),
                artworkView.heightAnchor.constraint(equalToConstant: 32),
                titleLabel.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: Chrome.Space.s8),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -Chrome.Space.s4),
                titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
                subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -Chrome.Space.s4),
                subtitleLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
                buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Chrome.Space.s8),
                buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        case .toolbar:
            layer?.cornerRadius = Chrome.Radius.control
            layer?.borderWidth = Chrome.hairline
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),
                artworkView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.s4),
                artworkView.centerYAnchor.constraint(equalTo: centerYAnchor),
                artworkView.widthAnchor.constraint(equalToConstant: 18),
                artworkView.heightAnchor.constraint(equalToConstant: 18),
                titleLabel.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: Chrome.Space.s4 + 2),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.toolbarTitleWidth),
                buttons.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: Chrome.Space.s4),
                buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            let zero = widthAnchor.constraint(equalToConstant: 0)
            zero.isActive = true
            hiddenWidth = zero
        }
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `item` (nil hides the controls).
    func update(_ item: BrowserMediaControlItem?) {
        guard item != self.item || isHidden != (item == nil) else { return }
        self.item = item
        isHidden = item == nil
        hiddenWidth?.isActive = item == nil
        guard let item else { return }
        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = item.subtitle
        artworkView.image = item.image ?? NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil)
        playButton.setSymbol(
            item.isPlaying ? "pause.fill" : "play.fill",
            accessibilityLabel: item.isPlaying ? "Pause" : "Play",
            pointSize: style == .rail ? 12 : 11
        )
        playButton.toolTip = item.isPlaying ? "Pause" : "Play"
        nextButton.isEnabled = item.canSkip
        muteButton.setSymbol(
            item.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            accessibilityLabel: item.isMuted ? "Unmute Tab" : "Mute Tab",
            pointSize: style == .rail ? 12 : 11
        )
        muteButton.toolTip = item.isMuted ? "Unmute Tab" : "Mute Tab"
        let place = item.inMiniPlayer ? " (in the Mini Player)" : ""
        toolTip = "Go to \(item.title)\(place)"
        setAccessibilityLabel([item.title, item.subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        titleLabel.textColor = colors.textPrimary
        subtitleLabel.textColor = colors.textMuted
        rule.color = colors.borderSubtle
        artworkView.layer?.backgroundColor = colors.hover.cgColor
        artworkView.contentTintColor = colors.textMuted
        if style == .toolbar {
            layer?.backgroundColor = colors.raised.cgColor
            layer?.borderColor = colors.borderSubtle.cgColor
        }
        for button in [playButton, nextButton, muteButton] {
            button.apply(theme: theme)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let item, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSelect?(item.tabID)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let item else { return false }
        onSelect?(item.tabID)
        return true
    }

    @objc func playPressed() {
        if let item { onPlayPause?(item.tabID) }
    }

    @objc func nextPressed() {
        if let item { onNext?(item.tabID) }
    }

    @objc func mutePressed() {
        if let item { onMute?(item.tabID) }
    }
}
