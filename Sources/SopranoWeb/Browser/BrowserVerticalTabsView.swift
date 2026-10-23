import AppKit

/// Arc-style vertical tab rail. Tabs stack down the left edge, with the new-tab
/// button in the header; the rail keeps the window controls clear at the top.
@MainActor
final class BrowserVerticalTabsView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?

    private var theme: AppTheme
    private var buttons: [UUID: BrowserTabButton] = [:]
    private var order: [UUID] = []
    private var rowWidthConstraints: [UUID: NSLayoutConstraint] = [:]
    private var selectedID: UUID?
    private let headerLabel = NSTextField(labelWithString: "")
    private let newTabButton: ChromeIconButton
    private let scrollView = NSScrollView()
    private let documentView = FlippedDocumentView()
    private let stack = BrowserVerticalTabStack()
    private let divider: ChromeRuleView

    static let preferredWidth: CGFloat = 232
    private static let controlsTop: CGFloat = 46

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
        self.divider = ChromeRuleView(axis: .vertical, color: theme.colors.borderSubtle)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.lineBreakMode = .byClipping
        headerLabel.usesSingleLineMode = true
        addSubview(headerLabel)

        newTabButton.target = self
        newTabButton.action = #selector(newTabPressed)
        newTabButton.toolTip = "New tab (⌘T)"
        addSubview(newTabButton)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.distribution = .fill
        documentView.addSubview(stack)

        addSubview(divider)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.controlsTop),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: newTabButton.leadingAnchor, constant: -8),

            newTabButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -8),

            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: Chrome.hairline),
        ])

        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(tabs: [BrowserTabItem], selectedID: UUID) {
        let ids = tabs.map(\.id)
        if ids != order {
            rebuild(tabs: tabs)
        } else {
            for tab in tabs {
                buttons[tab.id]?.item = tab
            }
        }
        self.selectedID = selectedID
        for (id, button) in buttons {
            button.isSelected = id == selectedID
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let button = buttons[selectedID] {
            button.scrollToVisible(button.bounds)
        }
    }

    func clear() {
        for constraint in rowWidthConstraints.values {
            constraint.isActive = false
        }
        rowWidthConstraints.removeAll()
        for button in buttons.values {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons.removeAll()
        order.removeAll()
        selectedID = nil
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        headerLabel.attributedStringValue = ChromeText.eyebrow(
            "Tabs",
            color: theme.colors.textMuted
        )
        newTabButton.apply(theme: theme)
        divider.color = theme.colors.borderSubtle
        for button in buttons.values {
            button.apply(theme: theme)
        }
        needsDisplay = true
    }

    private func rebuild(tabs: [BrowserTabItem]) {
        for constraint in rowWidthConstraints.values {
            constraint.isActive = false
        }
        rowWidthConstraints.removeAll()
        for button in buttons.values {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons.removeAll()
        order = tabs.map(\.id)

        for tab in tabs {
            let button = BrowserTabButton(item: tab, theme: theme)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.onSelect = { [weak self] id in self?.onSelect?(id) }
            button.onClose = { [weak self] id in self?.onClose?(id) }
            stack.addArrangedSubview(button)
            let width = button.widthAnchor.constraint(equalTo: stack.widthAnchor)
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: 32),
                width,
            ])
            rowWidthConstraints[tab.id] = width
            buttons[tab.id] = button
        }
        needsLayout = true
    }

    @objc private func newTabPressed() {
        onNewTab?()
    }
}


/// A flipped stack makes the scroll view document start at its top edge; an
/// unflipped document view pins the first tab to the bottom.
private final class BrowserVerticalTabStack: NSStackView {
    override var isFlipped: Bool { true }
}


/// The scroll document is flipped so the first row starts at the top; pinning
/// the rail stack to this plain container keeps its leading/trailing insets.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
