import AppKit

/// Settings ▸ Links from other apps ▸ Manage…: the rules an import brought
/// in (Arc's Air Traffic Control), each "address contains … → Space" with
/// Delete. Rules are read-only otherwise. Presented as a sheet on the
/// Settings window.
@MainActor
final class BrowserLinkRoutingSheet: NSWindowController {
    private let store: BrowserLinkRoutingStore
    private let spaces: BrowserSpaceStore
    private var theme: AppTheme
    private var observations: [BrowserObservation] = []

    private let rootView = NSView()
    private let header = NSTextField(labelWithString: "Links from Other Apps")
    private let subtitle = NSTextField(
        wrappingLabelWithString: "A link another app opens goes to the Space of the first rule its address matches; "
            + "other links open in the most recent window. Import rules from Arc with File ▸ Import Browser Data…."
    )
    private let emptyLabel = NSTextField(labelWithString: "No rules")
    private let topRule: ChromeRuleView
    private let bottomRule: ChromeRuleView
    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private let stack = NSStackView()
    private let doneButton: ChromeButton
    private var rowViews: [RowView] = []

    init(store: BrowserLinkRoutingStore, spaces: BrowserSpaceStore, theme: AppTheme) {
        self.store = store
        self.spaces = spaces
        self.theme = theme
        topRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        bottomRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        doneButton = ChromeButton(title: "Done", theme: theme, kind: .ink, keycap: "esc")
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Links from Other Apps"
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        rootView.wantsLayer = true

        header.font = ChromeFont.headline
        subtitle.font = ChromeFont.meta
        subtitle.preferredMaxLayoutWidth = 512
        emptyLabel.font = ChromeFont.label
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.addSubview(stack)
        scrollView.documentView = listView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        for view in [header, subtitle, topRule, scrollView, emptyLabel, bottomRule, doneButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }
        doneButton.target = self
        doneButton.action = #selector(donePressed)
        doneButton.keyEquivalent = "\u{1b}"

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            subtitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),

            topRule.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            topRule.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),

            emptyLabel.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 18),
            emptyLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),

            listView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            listView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: listView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: listView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: listView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: listView.bottomAnchor),

            bottomRule.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -14),

            doneButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            doneButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])

        observations = [
            store.changes.observe { [weak self] in self?.reload() },
            spaces.changes.observe { [weak self] in self?.reload() },
        ]
        apply(theme: theme)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        rootView.layer?.backgroundColor = theme.colors.bgBase.cgColor
        window?.backgroundColor = theme.colors.bgBase
        header.textColor = theme.colors.textPrimary
        subtitle.textColor = theme.colors.textMuted
        emptyLabel.textColor = theme.colors.textMuted
        topRule.color = theme.colors.borderSubtle
        bottomRule.color = theme.colors.borderSubtle
        doneButton.apply(theme: theme)
        rowViews.forEach { $0.apply(theme: theme) }
    }

    /// Every rule as the sheet lists it: "contains meet.google.com → Most recent Space".
    var dump: [String] {
        store.rules.map { "\(Self.matchText($0)) → \(destinationText($0))" }
    }

    func reload() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = store.rules.map { rule in
            let view = RowView(
                rule: rule,
                match: Self.matchText(rule),
                destination: destinationText(rule),
                theme: theme
            )
            view.onDelete = { [weak self] id in self?.store.remove(id: id) }
            return view
        }
        for view in rowViews {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        emptyLabel.isHidden = !rowViews.isEmpty
        rootView.layoutSubtreeIfNeeded()
    }

    private static func matchText(_ rule: BrowserLinkRoutingRule) -> String {
        "Address \(rule.match.title) “\(rule.value)”"
    }

    private func destinationText(_ rule: BrowserLinkRoutingRule) -> String {
        switch rule.destination {
        case .mostRecentSpace:
            return "Most recent Space"
        case let .space(id):
            return spaces.space(id: id).map { "Space “\($0.displayName)”" } ?? "Most recent Space (its Space is gone)"
        }
    }

    @objc private func donePressed() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// One rule: what it matches, where it goes, Delete.
    private final class RowView: NSView {
        var onDelete: ((UUID) -> Void)?

        private let id: UUID
        private let matchLabel: NSTextField
        private let destinationLabel: NSTextField
        private let deleteButton: ChromeButton
        private let rule: ChromeRuleView

        init(rule routing: BrowserLinkRoutingRule, match: String, destination: String, theme: AppTheme) {
            id = routing.id
            matchLabel = NSTextField(labelWithString: match)
            destinationLabel = NSTextField(labelWithString: "→ \(destination)")
            deleteButton = ChromeButton(title: "Delete", theme: theme, kind: .standard)
            rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            matchLabel.font = ChromeFont.label
            matchLabel.lineBreakMode = .byTruncatingMiddle
            matchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            destinationLabel.font = ChromeFont.meta
            destinationLabel.lineBreakMode = .byTruncatingTail
            destinationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            deleteButton.target = self
            deleteButton.action = #selector(deletePressed)
            deleteButton.setAccessibilityLabel("Delete rule \(match)")
            for view in [matchLabel, destinationLabel, deleteButton, rule] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 54),
                matchLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                matchLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                matchLabel.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -12),
                destinationLabel.leadingAnchor.constraint(equalTo: matchLabel.leadingAnchor),
                destinationLabel.topAnchor.constraint(equalTo: matchLabel.bottomAnchor, constant: 3),
                destinationLabel.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -12),
                deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                deleteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
                rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                rule.trailingAnchor.constraint(equalTo: trailingAnchor),
                rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            apply(theme: theme)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func apply(theme: AppTheme) {
            matchLabel.textColor = theme.colors.textPrimary
            destinationLabel.textColor = theme.colors.textMuted
            rule.color = theme.colors.borderSubtle
            deleteButton.apply(theme: theme)
        }

        @objc private func deletePressed() {
            onDelete?(id)
        }
    }
}
