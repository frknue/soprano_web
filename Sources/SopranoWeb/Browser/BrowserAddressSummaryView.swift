import AppKit

/// What the address bar shows while it isn't edited, as in Aside: the
/// site (`github.com`), then the page's title, muted. Editing shows the
/// full address again.
struct BrowserAddressSummary: Equatable {
    /// The host without `www.` (and its port) for web pages, else the
    /// whole address.
    let site: String
    /// The page's title; empty when it only repeats the site or address.
    let title: String

    /// Nil for an empty address (the start page shows the placeholder).
    static func make(address: String, title: String) -> BrowserAddressSummary? {
        guard !address.isEmpty else { return nil }
        var site = address
        var host = ""
        if let components = URLComponents(string: address),
           let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
           let rawHost = components.host, !rawHost.isEmpty
        {
            host = rawHost.lowercased()
            site = host.hasPrefix("www.") && host.count > 4 ? String(host.dropFirst(4)) : host
            if let port = components.port {
                site += ":\(port)"
            }
        }
        var shownTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if [site, host, address].contains(where: { $0.caseInsensitiveCompare(shownTitle) == .orderedSame }) {
            shownTitle = ""
        }
        return BrowserAddressSummary(site: site, title: shownTitle)
    }
}

/// The site and title over the unfocused address field. Clicks fall
/// through to the field underneath, which stays the control.
@MainActor
final class BrowserAddressSummaryView: NSView {
    private let siteLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    /// Space between the site and the title.
    static let gap: CGFloat = 20

    init(theme: AppTheme) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        for label in [siteLabel, titleLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = ChromeFont.row
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        // The title gives way first, then the site.
        siteLabel.setContentHuggingPriority(.required, for: .horizontal)
        siteLabel.setContentCompressionResistancePriority(.init(740), for: .horizontal)
        titleLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        NSLayoutConstraint.activate([
            siteLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            siteLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: siteLabel.trailingAnchor, constant: Self.gap),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            siteLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        siteLabel.textColor = theme.colors.textPrimary
        titleLabel.textColor = theme.colors.textMuted
    }

    func set(_ summary: BrowserAddressSummary) {
        if siteLabel.stringValue != summary.site { siteLabel.stringValue = summary.site }
        if titleLabel.stringValue != summary.title { titleLabel.stringValue = summary.title }
        titleLabel.isHidden = summary.title.isEmpty
    }

    var shownSite: String { siteLabel.stringValue }
    var shownTitle: String { titleLabel.isHidden ? "" : titleLabel.stringValue }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
