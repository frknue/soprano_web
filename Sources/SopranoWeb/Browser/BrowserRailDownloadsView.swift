import AppKit

/// Downloads in progress at the bottom of the rail, above the Space
/// switcher, as in Arc: one row each (the newest `maxRows`), with the file
/// name, "12 MB of 45 MB · 2 min left", a progress line and a cancel
/// button. A click on a row shows the Downloads sidebar. Hidden while
/// nothing downloads.
@MainActor
final class BrowserRailDownloadsView: NSView {
    static let maxRows = 3
    static let rowHeight: CGFloat = 44

    var onOpen: (() -> Void)?
    var onCancel: ((UUID) -> Void)?

    private(set) var rows: [BrowserRailDownloadRow] = []
    private let stack = NSStackView()
    private let rule: ChromeRuleView
    private var theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Downloads in progress")
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(rule)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Chrome.Space.s4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Chrome.Space.s4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the downloads in progress, newest first (the first
    /// `maxRows`); none hides the view.
    func update(_ records: [BrowserDownloadRecord]) {
        let shown = Array(records.filter { $0.state == .inProgress }.prefix(Self.maxRows))
        isHidden = shown.isEmpty
        while rows.count < shown.count {
            let row = BrowserRailDownloadRow(theme: theme)
            row.onOpen = { [weak self] in self?.onOpen?() }
            row.onCancel = { [weak self] id in self?.onCancel?(id) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows.append(row)
        }
        while rows.count > shown.count {
            rows.removeLast().removeFromSuperview()
        }
        for (row, record) in zip(rows, shown) {
            row.show(record)
        }
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        rule.color = theme.colors.borderSubtle
        rows.forEach { $0.apply(theme: theme) }
    }
}

/// One download in the rail: name over its progress text, the cancel
/// button at the trailing edge, the progress line under both.
@MainActor
final class BrowserRailDownloadRow: NSView {
    var onOpen: (() -> Void)?
    var onCancel: ((UUID) -> Void)?

    private(set) var recordID: UUID?
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let cancelButton: ChromeIconButton
    let progressBar = BrowserDownloadProgressBar()

    init(theme: AppTheme) {
        cancelButton = ChromeIconButton(
            symbolName: "xmark",
            accessibilityLabel: "Cancel Download",
            pointSize: 10,
            size: 22,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.toolTip = "Cancel Download"
        for (label, font) in [(titleLabel, ChromeFont.label), (detailLabel, ChromeFont.meta)] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = font
            label.lineBreakMode = .byTruncatingMiddle
            label.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBar)
        addSubview(cancelButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: BrowserRailDownloadsView.rowHeight),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.s16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -Chrome.Space.s4),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -Chrome.Space.s4),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Chrome.Space.s8),
            cancelButton.centerYAnchor.constraint(equalTo: titleLabel.bottomAnchor),
            progressBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Chrome.Space.s16),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ record: BrowserDownloadRecord) {
        recordID = record.id
        titleLabel.stringValue = record.filename
        detailLabel.stringValue = BrowserDownloadProgressText.detail(record)
        progressBar.progress = record.fractionCompleted
        toolTip = record.filename
        setAccessibilityLabel("\(record.filename), \(detailLabel.stringValue)")
    }

    func apply(theme: AppTheme) {
        titleLabel.textColor = theme.colors.textPrimary
        detailLabel.textColor = theme.colors.textMuted
        progressBar.trackColor = theme.colors.borderSubtle
        progressBar.fillColor = theme.colors.blue
        cancelButton.apply(theme: theme)
    }

    override func mouseDown(with event: NSEvent) {
        onOpen?()
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }

    @objc private func cancelPressed() {
        guard let recordID else { return }
        onCancel?(recordID)
    }
}
