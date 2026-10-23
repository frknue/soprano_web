import AppKit

/// Covers a tab's web view after its page crashed twice in a row, in the
/// error page's layout. Reload (or ⌘R) tries once more.
@MainActor
final class BrowserCrashView: NSView {
    var onReload: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "This page keeps crashing")
    private let urlChip = NSView()
    private let urlLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(
        wrappingLabelWithString: "Its web content quit again right after a reload, so Soprano Web stopped reloading it."
    )
    private let reloadButton: ChromeButton

    init(url: String, theme: AppTheme) {
        reloadButton = ChromeButton(title: "Reload", theme: theme, kind: .ink, keycap: "⌘R")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        titleLabel.font = ChromeFont.serif(size: 26)
        urlLabel.font = ChromeFont.monoSmall
        urlLabel.stringValue = url.isEmpty ? "about:blank" : url
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.usesSingleLineMode = true
        urlChip.wantsLayer = true
        urlChip.layer?.cornerRadius = Chrome.Radius.control
        urlChip.layer?.borderWidth = Chrome.hairline
        messageLabel.font = ChromeFont.row
        reloadButton.target = self
        reloadButton.action = #selector(reload)

        let column = NSView()
        for view in [titleLabel, urlChip, urlLabel, messageLabel, column] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        urlChip.addSubview(urlLabel)
        column.addSubview(titleLabel)
        column.addSubview(urlChip)
        column.addSubview(messageLabel)
        column.addSubview(reloadButton)
        addSubview(column)

        let columnWidth = column.widthAnchor.constraint(equalToConstant: 496)
        columnWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 96),
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Chrome.Space.s32),
            columnWidth,

            titleLabel.topAnchor.constraint(equalTo: column.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),

            urlChip.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Chrome.Space.s12),
            urlChip.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            urlChip.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
            urlLabel.topAnchor.constraint(equalTo: urlChip.topAnchor, constant: Chrome.Space.s4),
            urlLabel.bottomAnchor.constraint(equalTo: urlChip.bottomAnchor, constant: -Chrome.Space.s4),
            urlLabel.leadingAnchor.constraint(equalTo: urlChip.leadingAnchor, constant: Chrome.Space.s8),
            urlLabel.trailingAnchor.constraint(equalTo: urlChip.trailingAnchor, constant: -Chrome.Space.s8),

            messageLabel.topAnchor.constraint(equalTo: urlChip.bottomAnchor, constant: Chrome.Space.s12),
            messageLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            reloadButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: Chrome.Space.s24),
            reloadButton.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            reloadButton.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        let colors = theme.colors
        layer?.backgroundColor = colors.bgBase.cgColor
        titleLabel.textColor = colors.textPrimary
        urlChip.layer?.backgroundColor = colors.bgRaised.cgColor
        urlChip.layer?.borderColor = colors.borderSubtle.cgColor
        urlLabel.textColor = colors.textMuted
        messageLabel.textColor = colors.textMuted
        reloadButton.apply(theme: theme)
    }

    @objc private func reload() {
        onReload?()
    }
}
