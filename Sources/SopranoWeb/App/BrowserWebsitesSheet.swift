import AppKit

/// Settings ▸ Websites: every host with remembered decisions (camera,
/// microphone, notifications, pop-ups, external apps), each removable, and
/// Remove All. Presented as a sheet on the Settings window.
@MainActor
final class BrowserWebsitesSheet: NSWindowController {
    private let store: BrowserSitePermissionStore
    private var theme: AppTheme

    private let rootView = NSView()
    private let header = NSTextField(labelWithString: "Websites")
    private let subtitle = NSTextField(labelWithString: "Decisions Soprano Web remembers for each site.")
    private let topRule: ChromeRuleView
    private let bottomRule: ChromeRuleView
    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No remembered decisions")
    private let removeAllButton: ChromeButton
    private let doneButton: ChromeButton
    private var rowViews: [RowView] = []

    init(store: BrowserSitePermissionStore, theme: AppTheme) {
        self.store = store
        self.theme = theme
        self.topRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        self.bottomRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        self.removeAllButton = ChromeButton(title: "Remove All", theme: theme, kind: .danger)
        self.doneButton = ChromeButton(title: "Done", theme: theme, kind: .ink, keycap: "esc")
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Websites"
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        rootView.wantsLayer = true

        header.font = ChromeFont.headline
        subtitle.font = ChromeFont.meta
        emptyLabel.font = ChromeFont.empty
        emptyLabel.alignment = .center
        for view in [header, subtitle, topRule, scrollView, emptyLabel, bottomRule, removeAllButton, doneButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }

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

        removeAllButton.target = self
        removeAllButton.action = #selector(removeAllPressed)
        doneButton.target = self
        doneButton.action = #selector(donePressed)
        doneButton.keyEquivalent = "\u{1b}"

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            subtitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),

            topRule.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            topRule.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),

            listView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            listView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: listView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: listView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: listView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: listView.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            bottomRule.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -14),

            removeAllButton.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            removeAllButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            doneButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])

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
        removeAllButton.apply(theme: theme)
        doneButton.apply(theme: theme)
        rowViews.forEach { $0.apply(theme: theme) }
    }

    /// Rebuilds the list from the store; called on every store change.
    func reload() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = BrowserWebsiteRow.rows(from: store.sites).map { row in
            let view = RowView(row: row, theme: theme)
            view.onRemove = { [weak self] host in self?.store.removeAll(host: host) }
            return view
        }
        for view in rowViews {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        emptyLabel.isHidden = !rowViews.isEmpty
        removeAllButton.isEnabled = !rowViews.isEmpty
        rootView.layoutSubtreeIfNeeded()
    }

    @objc private func removeAllPressed() {
        store.removeAll()
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

    /// One host: name, its decisions, and Remove.
    private final class RowView: NSView {
        var onRemove: ((String) -> Void)?

        private let host: String
        private let hostLabel: NSTextField
        private let summaryLabel: NSTextField
        private let removeButton: ChromeButton
        private let rule: ChromeRuleView

        init(row: BrowserWebsiteRow, theme: AppTheme) {
            self.host = row.host
            self.hostLabel = NSTextField(labelWithString: row.host)
            self.summaryLabel = NSTextField(labelWithString: row.summary)
            self.removeButton = ChromeButton(title: "Remove", theme: theme, kind: .standard)
            self.rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            hostLabel.font = ChromeFont.mono
            hostLabel.lineBreakMode = .byTruncatingMiddle
            summaryLabel.font = ChromeFont.meta
            summaryLabel.lineBreakMode = .byTruncatingTail
            for label in [hostLabel, summaryLabel] {
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            removeButton.target = self
            removeButton.action = #selector(removePressed)
            removeButton.setAccessibilityLabel("Remove decisions for \(row.host)")
            for view in [hostLabel, summaryLabel, removeButton, rule] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 54),
                hostLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                hostLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
                hostLabel.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -12),
                summaryLabel.leadingAnchor.constraint(equalTo: hostLabel.leadingAnchor),
                summaryLabel.topAnchor.constraint(equalTo: hostLabel.bottomAnchor, constant: 3),
                summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -12),
                removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
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
            hostLabel.textColor = theme.colors.textPrimary
            summaryLabel.textColor = theme.colors.textMuted
            rule.color = theme.colors.borderSubtle
            removeButton.apply(theme: theme)
        }

        @objc private func removePressed() {
            onRemove?(host)
        }
    }
}
