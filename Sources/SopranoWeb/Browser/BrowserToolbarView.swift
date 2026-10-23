import AppKit

/// The address bar row: address field, bookmark, downloads and the sidebar
/// toggle, with a 2 pt loading line along its bottom edge.
@MainActor
final class BrowserToolbarView: NSView, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onBookmark: (() -> Void)?
    var onDownloads: (() -> Void)?
    var onSidebar: (() -> Void)?
    var onToggleVerticalSidebar: (() -> Void)?
    var onAddressFocusChange: ((Bool) -> Void)?

    let addressField = NSTextField()
    private let addressFrame: ChromeFieldView
    private let securityIcon = NSImageView()
    private let progressBar = BrowserProgressBar()
    private let verticalTabsButton: ChromeIconButton
    private let bookmarkButton: ChromeIconButton
    private let downloadsButton: ChromeIconButton
    private let sidebarButton: ChromeIconButton

    private var theme: AppTheme
    private var isSecure = true
    private var isLocal = false

    static let preferredHeight: CGFloat = 46

    init(theme: AppTheme) {
        self.theme = theme
        self.addressFrame = ChromeFieldView(theme: theme)
        self.verticalTabsButton = ChromeIconButton(
            symbolName: "sidebar.left",
            accessibilityLabel: "Vertical Tabs",
            pointSize: 12,
            target: nil,
            action: nil
        )
        self.bookmarkButton = ChromeIconButton(
            symbolName: "star",
            accessibilityLabel: "Bookmark This Page",
            pointSize: 12,
            target: nil,
            action: nil
        )
        self.downloadsButton = ChromeIconButton(
            symbolName: "arrow.down.circle",
            accessibilityLabel: "Downloads",
            pointSize: 12,
            target: nil,
            action: nil
        )
        self.sidebarButton = ChromeIconButton(
            symbolName: "sidebar.right",
            accessibilityLabel: "Toggle Sidebar",
            pointSize: 12,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        for button in [verticalTabsButton, bookmarkButton, downloadsButton, sidebarButton] {
            button.target = self
            addSubview(button)
        }
        verticalTabsButton.action = #selector(verticalTabsPressed)
        bookmarkButton.action = #selector(bookmarkPressed)
        downloadsButton.action = #selector(downloadsPressed)
        sidebarButton.action = #selector(sidebarPressed)

        verticalTabsButton.toolTip = "Vertical tabs (⌘S)"
        bookmarkButton.toolTip = "Bookmark this page (⌘D)"
        downloadsButton.toolTip = "Downloads (⌥⌘L)"
        sidebarButton.toolTip = "Sidebar (⇧⌘H)"

        addSubview(addressFrame)
        securityIcon.translatesAutoresizingMaskIntoConstraints = false
        securityIcon.imageScaling = .scaleProportionallyDown
        addressFrame.addSubview(securityIcon)

        addressField.isBordered = false
        addressField.isBezeled = false
        addressField.drawsBackground = false
        addressField.focusRingType = .none
        addressField.usesSingleLineMode = true
        addressField.cell?.isScrollable = true
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(addressSubmitted)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressFrame.addSubview(addressField)
        ChromeFieldView.styleEmbedded(addressField, colors: theme.colors, font: ChromeFont.row)
        addressField.placeholderAttributedString = NSAttributedString(
            string: "Search or enter address",
            attributes: [
                .foregroundColor: theme.colors.textMuted,
                .font: ChromeFont.row,
            ]
        )

        addSubview(progressBar)
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            verticalTabsButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            verticalTabsButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),

            sidebarButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sidebarButton.centerYAnchor.constraint(equalTo: verticalTabsButton.centerYAnchor),
            downloadsButton.trailingAnchor.constraint(equalTo: sidebarButton.leadingAnchor, constant: -2),
            downloadsButton.centerYAnchor.constraint(equalTo: sidebarButton.centerYAnchor),
            bookmarkButton.trailingAnchor.constraint(equalTo: downloadsButton.leadingAnchor, constant: -2),
            bookmarkButton.centerYAnchor.constraint(equalTo: sidebarButton.centerYAnchor),

            addressFrame.leadingAnchor.constraint(equalTo: verticalTabsButton.trailingAnchor, constant: 8),
            addressFrame.trailingAnchor.constraint(equalTo: bookmarkButton.leadingAnchor, constant: -8),
            addressFrame.centerYAnchor.constraint(equalTo: verticalTabsButton.centerYAnchor),
            addressFrame.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),

            securityIcon.leadingAnchor.constraint(equalTo: addressFrame.leadingAnchor, constant: 8),
            securityIcon.centerYAnchor.constraint(equalTo: addressFrame.centerYAnchor),
            securityIcon.widthAnchor.constraint(equalToConstant: 14),
            securityIcon.heightAnchor.constraint(equalToConstant: 14),

            addressField.leadingAnchor.constraint(equalTo: securityIcon.trailingAnchor, constant: 6),
            addressField.trailingAnchor.constraint(equalTo: addressFrame.trailingAnchor, constant: -8),
            addressField.centerYAnchor.constraint(equalTo: addressFrame.centerYAnchor),

            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
        ])

        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var isEditingAddress: Bool {
        addressField.currentEditor() != nil
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        for button in [verticalTabsButton, bookmarkButton, downloadsButton, sidebarButton] {
            button.apply(theme: theme)
        }
        addressFrame.apply(theme: theme)
        ChromeFieldView.styleEmbedded(addressField, colors: theme.colors, font: ChromeFont.row)
        addressField.placeholderAttributedString = NSAttributedString(
            string: "Search or enter address",
            attributes: [
                .foregroundColor: theme.colors.textMuted,
                .font: ChromeFont.row,
            ]
        )
        progressBar.color = theme.colors.blue
        refreshSecurityIcon()
        needsDisplay = true
    }

    func setAddress(_ text: String, secure: Bool, local: Bool) {
        if !isEditingAddress {
            addressField.stringValue = text
        }
        isSecure = secure
        isLocal = local
        refreshSecurityIcon()
    }

    func setBookmarked(_ bookmarked: Bool) {
        bookmarkButton.setSymbol(
            bookmarked ? "star.fill" : "star",
            accessibilityLabel: bookmarked ? "Remove Bookmark" : "Bookmark This Page",
            pointSize: 12
        )
        bookmarkButton.isToggledOn = bookmarked
        bookmarkButton.toolTip = bookmarked ? "Remove bookmark (⌘D)" : "Bookmark this page (⌘D)"
    }

    func setBookmarkEnabled(_ enabled: Bool) {
        bookmarkButton.isEnabled = enabled
    }

    func setProgress(_ progress: Double, isLoading: Bool) {
        progressBar.progress = max(0, min(1, progress))
        progressBar.isHidden = !isLoading || progress >= 1
    }

    func focusAddress(selectAll: Bool) {
        window?.makeFirstResponder(addressField)
        if selectAll {
            addressField.currentEditor()?.selectAll(nil)
        }
    }

    func setSidebarToggle(_ on: Bool) {
        sidebarButton.isToggledOn = on
    }

    func setVerticalTabsToggle(_ on: Bool) {
        verticalTabsButton.isToggledOn = on
        verticalTabsButton.toolTip = on ? "Hide vertical tabs (⌘S)" : "Show vertical tabs (⌘S)"
    }

    func setDownloadsToggle(_ on: Bool) {
        downloadsButton.isToggledOn = on
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        addressFrame.isFocused = true
        ChromeFieldView.styleEditor(of: addressField, colors: theme.colors)
        onAddressFocusChange?(true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        addressFrame.isFocused = false
        addressFrame.needsDisplay = true
        onAddressFocusChange?(false)
    }

    @objc private func addressSubmitted() {
        onSubmit?(addressField.stringValue)
    }

    @objc private func verticalTabsPressed() {
        onToggleVerticalSidebar?()
    }

    @objc private func bookmarkPressed() {
        onBookmark?()
    }

    @objc private func downloadsPressed() {
        onDownloads?()
    }

    @objc private func sidebarPressed() {
        onSidebar?()
    }

    private func refreshSecurityIcon() {
        let symbol: String
        let tooltip: String
        if isLocal {
            symbol = "globe"
            tooltip = "Local page"
        } else if isSecure {
            symbol = "lock.fill"
            tooltip = "Secure connection"
        } else {
            symbol = "exclamationmark.triangle.fill"
            tooltip = "Connection is not secure"
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        securityIcon.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: tooltip
        )?.withSymbolConfiguration(configuration)
        securityIcon.contentTintColor = theme.colors.textMuted
        securityIcon.toolTip = tooltip
    }
}

/// A 2 pt loading line. It is the only non-hairline rule in the chrome and
/// uses the theme's informational blue, never the keyboard accent.
private final class BrowserProgressBar: NSView {
    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }
    var color: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard progress > 0 else { return }
        color.setFill()
        NSRect(
            x: 0,
            y: 0,
            width: floor(bounds.width * CGFloat(progress)),
            height: bounds.height
        ).fill()
    }
}
