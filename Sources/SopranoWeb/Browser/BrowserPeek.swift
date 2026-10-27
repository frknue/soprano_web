import AppKit
import WebKit

/// A window's open Peek: a page over the selected tab in its own web view,
/// of the opener's data context (`BrowserWindowController.openPeek`). Its
/// tab is a full `BrowserTab` bound to the window (every WebKit callback
/// finds it through `tab(for:)`) but it is in no tab list, the session or
/// the strip until "Open as Tab".
@MainActor
final class BrowserPeek {
    let tab: BrowserTab
    /// The tab the Peek opened over.
    let openerID: UUID
    let view: BrowserPeekView

    init(tab: BrowserTab, openerID: UUID, view: BrowserPeekView) {
        self.tab = tab
        self.openerID = openerID
        self.view = view
    }
}

/// The Peek overlay over the page area: a dimmed backdrop (a click closes
/// the Peek) and a rounded Folio panel with a title bar (back, forward,
/// title and host, "Open as Tab" ⌘O, close) above the Peek's web view.
@MainActor
final class BrowserPeekView: NSView {
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onOpenAsTab: (() -> Void)?
    var onClose: (() -> Void)?

    static let titleBarHeight: CGFloat = 40
    /// The panel's gap to the page area's top and bottom edges.
    static let verticalInset: CGFloat = 24
    /// The panel's least gap to the page area's sides.
    static let horizontalInset: CGFloat = 48
    static let maximumWidth: CGFloat = 1200

    let backdrop = BrowserPeekBackdropView()
    /// Shadow and ring; `clip` inside it rounds the content.
    let panel = NSView()
    private let clip = NSView()
    private let titleBar = NSView()
    private let rule: ChromeRuleView
    /// Holds the Peek's web view, edge to edge.
    let content = NSView()
    let backButton: ChromeIconButton
    let forwardButton: ChromeIconButton
    let titleLabel = NSTextField(labelWithString: "")
    let hostLabel = NSTextField(labelWithString: "")
    let openButton: ChromeButton
    let closeButton: ChromeIconButton
    private var theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        backButton = ChromeIconButton(symbolName: "chevron.left", accessibilityLabel: "Back", target: nil, action: nil)
        forwardButton = ChromeIconButton(symbolName: "chevron.right", accessibilityLabel: "Forward", target: nil, action: nil)
        openButton = ChromeButton(title: "Open as Tab", theme: theme, kind: .standard, keycap: "⌘O")
        closeButton = ChromeIconButton(symbolName: "xmark", accessibilityLabel: "Close Peek", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("peek")

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.onClick = { [weak self] in self?.onClose?() }
        addSubview(backdrop)

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        addSubview(panel)
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Chrome.Radius.panel
        clip.layer?.masksToBounds = true
        panel.addSubview(clip)

        titleBar.translatesAutoresizingMaskIntoConstraints = false
        titleBar.wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        clip.addSubview(titleBar)
        clip.addSubview(rule)
        clip.addSubview(content)

        backButton.target = self
        backButton.action = #selector(backPressed)
        backButton.toolTip = "Back (⌘[)"
        forwardButton.target = self
        forwardButton.action = #selector(forwardPressed)
        forwardButton.toolTip = "Forward (⌘])"
        openButton.target = self
        openButton.action = #selector(openPressed)
        openButton.toolTip = "Open as a tab after this one (⌘O)"
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.heightAnchor.constraint(equalToConstant: Chrome.controlHeight).isActive = true
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.toolTip = "Close (esc, ⌘W)"

        for label in [titleLabel, hostLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        titleLabel.font = ChromeFont.labelStrong
        hostLabel.font = ChromeFont.meta
        hostLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        hostLabel.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        for view in [backButton, forwardButton, titleLabel, hostLabel, openButton, closeButton] as [NSView] {
            titleBar.addSubview(view)
        }

        let width = panel.widthAnchor.constraint(equalTo: widthAnchor, constant: -2 * Self.horizontalInset)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            panel.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * Self.horizontalInset),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumWidth),
            width,

            clip.topAnchor.constraint(equalTo: panel.topAnchor),
            clip.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            titleBar.topAnchor.constraint(equalTo: clip.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: Self.titleBarHeight),
            rule.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: Chrome.hairline),
            content.topAnchor.constraint(equalTo: rule.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: clip.bottomAnchor),

            backButton.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: Chrome.Space.s8),
            backButton.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: Chrome.Space.s2),
            forwardButton.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: Chrome.Space.s12),
            titleLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            hostLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: Chrome.Space.s8),
            hostLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            hostLabel.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -Chrome.Space.s12),
            openButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -Chrome.Space.s8),
            openButton.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -Chrome.Space.s8),
            closeButton.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The Peek's web view fills the panel under the title bar.
    func install(_ webView: WKWebView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        webView.isHidden = false
    }

    func update(title: String, host: String, url: String?, canGoBack: Bool, canGoForward: Bool) {
        titleLabel.stringValue = title
        hostLabel.stringValue = host
        titleBar.toolTip = url
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        backdrop.layer?.backgroundColor = colors.scrim.cgColor
        panel.layer?.cornerRadius = Chrome.Radius.panel
        panel.layer?.backgroundColor = colors.bgBase.cgColor
        clip.layer?.backgroundColor = colors.bgBase.cgColor
        titleBar.layer?.backgroundColor = colors.bgPanel.cgColor
        content.layer?.backgroundColor = colors.bgBase.cgColor
        rule.color = colors.borderSubtle
        titleLabel.textColor = colors.textPrimary
        hostLabel.textColor = colors.textMuted
        for button in [backButton, forwardButton, closeButton] {
            button.apply(theme: theme)
        }
        openButton.apply(theme: theme)
        if let layer = panel.layer {
            colors.shadowE3.apply(to: layer)
        }
    }

    /// Esc while the title bar (or nothing in the page) has focus.
    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    @objc private func backPressed() { onBack?() }
    @objc private func forwardPressed() { onForward?() }
    @objc private func openPressed() { onOpenAsTab?() }
    @objc private func closePressed() { onClose?() }
}

/// The dimmed page around the Peek: it takes clicks (closing the Peek) so
/// the page under it stays put.
@MainActor
final class BrowserPeekBackdropView: NSView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }

    override func scrollWheel(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
