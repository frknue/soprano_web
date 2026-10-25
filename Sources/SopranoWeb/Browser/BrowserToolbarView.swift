import AppKit

/// The address bar row: back, forward and reload, the address field,
/// bookmark, downloads and the sidebar toggle, with a 2 pt loading line
/// along its bottom edge.
@MainActor
final class BrowserToolbarView: NSView, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onBookmark: (() -> Void)?
    var onDownloads: (() -> Void)?
    var onSidebar: (() -> Void)?
    var onToggleVerticalSidebar: (() -> Void)?
    var onAddressFocusChange: ((Bool) -> Void)?
    var onSecurityInfo: (() -> Void)?
    /// The user changed the address text; carries the field's new text.
    var onAddressTextChange: ((String) -> Void)?
    /// A key command while the address is edited (↑, ↓, Return, Esc, …);
    /// returns true when handled.
    var onAddressCommand: ((Selector) -> Bool)?

    let addressField = BrowserAddressField()
    let navigationControls: BrowserNavigationControls
    private let addressFrame: ChromeFieldView
    private let securityIcon = NSImageView()
    /// Status controls at the address field's trailing edge (the pop-up
    /// blocked control). Hidden arranged views take no space.
    let addressAccessories = NSStackView()
    private let progressBar = BrowserProgressBar()
    /// Camera/microphone in-use mark between the address field and the
    /// bookmark button; hidden while the selected tab captures nothing.
    let captureIndicator: BrowserCaptureIndicator
    private let verticalTabsButton: ChromeIconButton
    private let bookmarkButton: ChromeIconButton
    private let downloadsButton: ChromeIconButton
    private let sidebarButton: ChromeIconButton

    private var theme: AppTheme
    private var security: BrowserSecurityState = .local
    /// The selected page's address, as last passed to `setAddress`.
    private(set) var pageAddress = ""
    /// The user changed the text since the field was last focused.
    private(set) var isAddressEdited = false

    static let preferredHeight: CGFloat = 46

    init(theme: AppTheme) {
        self.theme = theme
        self.addressFrame = ChromeFieldView(theme: theme)
        self.navigationControls = BrowserNavigationControls(theme: theme)
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
        self.captureIndicator = BrowserCaptureIndicator(theme: theme)
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
        sidebarButton.toolTip = "Sidebar (⇧⌘B)"

        addSubview(navigationControls)
        addSubview(addressFrame)
        securityIcon.translatesAutoresizingMaskIntoConstraints = false
        securityIcon.imageScaling = .scaleProportionallyDown
        addressFrame.addSubview(securityIcon)
        securityIcon.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(securityIconClicked))
        )

        addressField.isBordered = false
        addressField.isBezeled = false
        addressField.drawsBackground = false
        addressField.focusRingType = .none
        addressField.usesSingleLineMode = true
        addressField.cell?.isScrollable = true
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(addressSubmitted)
        addressField.onFocus = { [weak self] in self?.isAddressEdited = false }
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressFrame.addSubview(addressField)
        addressAccessories.orientation = .horizontal
        addressAccessories.spacing = 4
        addressAccessories.translatesAutoresizingMaskIntoConstraints = false
        addressAccessories.setHuggingPriority(.required, for: .horizontal)
        addressAccessories.setContentCompressionResistancePriority(.required, for: .horizontal)
        addressFrame.addSubview(addressAccessories)
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
        addSubview(captureIndicator)

        NSLayoutConstraint.activate([
            verticalTabsButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            verticalTabsButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),

            sidebarButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sidebarButton.centerYAnchor.constraint(equalTo: verticalTabsButton.centerYAnchor),
            downloadsButton.trailingAnchor.constraint(equalTo: sidebarButton.leadingAnchor, constant: -2),
            downloadsButton.centerYAnchor.constraint(equalTo: sidebarButton.centerYAnchor),
            bookmarkButton.trailingAnchor.constraint(equalTo: downloadsButton.leadingAnchor, constant: -2),
            bookmarkButton.centerYAnchor.constraint(equalTo: sidebarButton.centerYAnchor),

            navigationControls.leadingAnchor.constraint(equalTo: verticalTabsButton.trailingAnchor, constant: 4),
            navigationControls.centerYAnchor.constraint(equalTo: verticalTabsButton.centerYAnchor),
            addressFrame.leadingAnchor.constraint(equalTo: navigationControls.trailingAnchor, constant: 8),
            addressFrame.trailingAnchor.constraint(equalTo: captureIndicator.leadingAnchor, constant: -6),
            addressFrame.centerYAnchor.constraint(equalTo: verticalTabsButton.centerYAnchor),
            addressFrame.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),

            securityIcon.leadingAnchor.constraint(equalTo: addressFrame.leadingAnchor, constant: 8),
            securityIcon.centerYAnchor.constraint(equalTo: addressFrame.centerYAnchor),
            securityIcon.widthAnchor.constraint(equalToConstant: 14),
            securityIcon.heightAnchor.constraint(equalToConstant: 14),

            addressField.leadingAnchor.constraint(equalTo: securityIcon.trailingAnchor, constant: 6),
            addressField.trailingAnchor.constraint(equalTo: addressAccessories.leadingAnchor, constant: -4),
            addressAccessories.trailingAnchor.constraint(equalTo: addressFrame.trailingAnchor, constant: -4),
            addressAccessories.centerYAnchor.constraint(equalTo: addressFrame.centerYAnchor),
            addressField.centerYAnchor.constraint(equalTo: addressFrame.centerYAnchor),

            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),

            captureIndicator.trailingAnchor.constraint(equalTo: bookmarkButton.leadingAnchor, constant: -2),
            captureIndicator.centerYAnchor.constraint(equalTo: sidebarButton.centerYAnchor),
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
        navigationControls.apply(theme: theme)
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
        captureIndicator.apply(theme: theme)
        refreshSecurityIcon()
        needsDisplay = true
    }

    func setAddress(_ text: String, security: BrowserSecurityState) {
        pageAddress = text
        // A focused field follows navigation until the user edits it.
        if !isEditingAddress || !isAddressEdited {
            showAddress(text)
        }
        self.security = security
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

    /// The address frame the suggestion dropdown hangs from.
    var addressAnchorView: NSView {
        addressFrame
    }

    var addressEditor: NSTextView? {
        addressField.currentEditor() as? NSTextView
    }

    /// Drops the user's edits and shows the page's address again, selected.
    func revertAddress() {
        isAddressEdited = false
        showAddress(pageAddress)
        addressEditor?.selectAll(nil)
    }

    private func showAddress(_ text: String) {
        guard addressField.stringValue != text else { return }
        addressField.stringValue = text
        addressEditor?.selectAll(nil)
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
        isAddressEdited = false
        onAddressFocusChange?(false)
    }

    func controlTextDidChange(_ notification: Notification) {
        isAddressEdited = true
        onAddressTextChange?(addressField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        onAddressCommand?(commandSelector) ?? false
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

    @objc private func securityIconClicked() {
        onSecurityInfo?()
    }

    private func refreshSecurityIcon() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        securityIcon.image = NSImage(
            systemSymbolName: security.symbolName,
            accessibilityDescription: security.toolTip
        )?.withSymbolConfiguration(configuration)
        securityIcon.contentTintColor = security.tint(in: theme.colors)
        securityIcon.toolTip = security.toolTip
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
