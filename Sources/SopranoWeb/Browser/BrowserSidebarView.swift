import AppKit

enum BrowserSidebarSection: String, CaseIterable, Sendable {
    case history
    case bookmarks
    case downloads

    var title: String {
        switch self {
        case .history: "History"
        case .bookmarks: "Bookmarks"
        case .downloads: "Downloads"
        }
    }

    var symbol: String {
        switch self {
        case .history: "clock"
        case .bookmarks: "bookmark"
        case .downloads: "arrow.down.circle"
        }
    }

    var emptyText: String {
        switch self {
        case .history: "No history yet"
        case .bookmarks: "No bookmarks yet"
        case .downloads: "No downloads yet"
        }
    }
}

enum BrowserSidebarRow {
    case history(BrowserHistoryEntry)
    case bookmark(BrowserBookmark)
    case download(BrowserDownloadRecord)

    var url: String? {
        switch self {
        case let .history(entry): entry.url
        case let .bookmark(bookmark): bookmark.url
        case let .download(download): download.url
        }
    }

    var id: UUID {
        switch self {
        case let .history(entry): entry.id
        case let .bookmark(bookmark): bookmark.id
        case let .download(download): download.id
        }
    }
}

/// The right sidebar: history, bookmarks and downloads share one searchable
/// list. It is deliberately one surface, not three panels.
@MainActor
final class BrowserSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSMenuDelegate
{
    var onOpenURL: ((String) -> Void)?
    var onOpenFile: ((String) -> Void)?
    var onRevealFile: ((String) -> Void)?
    var onRemoveHistory: ((UUID) -> Void)?
    var onRemoveBookmark: ((UUID) -> Void)?
    var onRemoveDownload: ((UUID) -> Void)?
    var onCancelDownload: ((UUID) -> Void)?
    var onResumeDownload: ((UUID) -> Void)?
    var onRetryDownload: ((UUID) -> Void)?
    var onClear: ((BrowserSidebarSection) -> Void)?
    var onClose: (() -> Void)?
    /// The cached favicon for a history or bookmark address.
    var faviconProvider: ((String) -> NSImage?)?

    private(set) var section: BrowserSidebarSection = .history
    private var theme: AppTheme
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton: ChromeIconButton
    private var sectionButtons: [BrowserSidebarSection: ChromeButton] = [:]
    private let sectionBar = NSStackView()
    private let searchFrame: ChromeFieldView
    private let searchField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footerButton: ChromeButton
    private var footerTrailing: NSTextField?
    private var rows: [BrowserSidebarRow] = []
    private var contextRow = -1

    let history: BrowserHistoryStore
    let bookmarks: BrowserBookmarkStore
    let downloads: BrowserDownloadStore
    /// A private window's data context: its own download rows are listed
    /// along with the saved ones.
    var privateDownloadContextID: UUID?

    init(
        theme: AppTheme,
        history: BrowserHistoryStore,
        bookmarks: BrowserBookmarkStore,
        downloads: BrowserDownloadStore
    ) {
        self.theme = theme
        self.history = history
        self.bookmarks = bookmarks
        self.downloads = downloads
        self.searchFrame = ChromeFieldView(theme: theme)
        self.closeButton = ChromeIconButton(
            symbolName: "xmark",
            accessibilityLabel: "Close Sidebar",
            pointSize: 10,
            size: 22,
            target: nil,
            action: nil
        )
        self.footerButton = ChromeButton(
            title: "Clear History…",
            theme: theme,
            kind: .text,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = ChromeFont.screen
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        closeButton.target = self
        closeButton.action = #selector(closePressed)
        addSubview(closeButton)

        sectionBar.translatesAutoresizingMaskIntoConstraints = false
        sectionBar.orientation = .horizontal
        sectionBar.spacing = 4
        sectionBar.distribution = .fillEqually
        for section in BrowserSidebarSection.allCases {
            let button = ChromeButton(
                title: section.title,
                theme: theme,
                kind: .text,
                target: self,
                action: #selector(sectionPressed(_:))
            )
            button.tag = BrowserSidebarSection.allCases.firstIndex(of: section) ?? 0
            sectionButtons[section] = button
            sectionBar.addArrangedSubview(button)
        }
        addSubview(sectionBar)

        searchFrame.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchFrame)

        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchFrame.addSubview(searchField)
        ChromeFieldView.styleEmbedded(searchField, colors: theme.colors, font: ChromeFont.label)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = ChromeFont.count
        countLabel.textColor = theme.colors.textMuted
        addSubview(countLabel)

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.autoresizingMask = [.width]
        tableView.target = self
        tableView.doubleAction = #selector(openClickedRow)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        addSubview(scrollView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = ChromeFont.empty
        emptyLabel.textColor = theme.colors.textMuted
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 0
        addSubview(emptyLabel)

        footerButton.target = self
        footerButton.action = #selector(footerPressed)
        addSubview(footerButton)

        let footerCount = NSTextField(labelWithString: "")
        footerCount.translatesAutoresizingMaskIntoConstraints = false
        footerCount.font = ChromeFont.count
        footerCount.textColor = theme.colors.textMuted
        footerCount.alignment = .right
        addSubview(footerCount)
        footerTrailing = footerCount

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),

            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            sectionBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            sectionBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sectionBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sectionBar.heightAnchor.constraint(equalToConstant: 24),

            searchFrame.topAnchor.constraint(equalTo: sectionBar.bottomAnchor, constant: 12),
            searchFrame.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchFrame.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchFrame.heightAnchor.constraint(equalToConstant: 26),

            searchField.leadingAnchor.constraint(equalTo: searchFrame.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchFrame.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchFrame.centerYAnchor),

            countLabel.topAnchor.constraint(equalTo: searchFrame.bottomAnchor, constant: 10),
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerButton.topAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),

            footerButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            footerButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            footerButton.heightAnchor.constraint(equalToConstant: 24),
            footerButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),

            footerCount.centerYAnchor.constraint(equalTo: footerButton.centerYAnchor),
            footerCount.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            footerCount.leadingAnchor.constraint(greaterThanOrEqualTo: footerButton.trailingAnchor, constant: 8),
        ])

        apply(theme: theme)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        titleLabel.textColor = theme.colors.textPrimary
        closeButton.apply(theme: theme)
        searchFrame.apply(theme: theme)
        ChromeFieldView.styleEmbedded(searchField, colors: theme.colors, font: ChromeFont.label)
        searchField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: theme.colors.textMuted,
                .font: ChromeFont.label,
            ]
        )
        countLabel.textColor = theme.colors.textMuted
        emptyLabel.textColor = theme.colors.textMuted
        footerButton.apply(theme: theme)
        footerTrailing?.textColor = theme.colors.textMuted
        for button in sectionButtons.values {
            button.apply(theme: theme)
        }
        tableView.reloadData()
        needsDisplay = true
    }

    func select(_ section: BrowserSidebarSection) {
        self.section = section
        searchField.stringValue = ""
        refresh()
    }

    func refresh() {
        let query = searchField.stringValue
        switch section {
        case .history:
            rows = history.matching(query).map(BrowserSidebarRow.history)
        case .bookmarks:
            rows = bookmarks.matching(query).map(BrowserSidebarRow.bookmark)
        case .downloads:
            rows = downloads.matching(query, privateContextID: privateDownloadContextID).map(BrowserSidebarRow.download)
        }

        titleLabel.stringValue = section.title
        sectionButtons.forEach { entry, button in
            button.kind = entry == section ? .standard : .text
        }
        searchField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: theme.colors.textMuted,
                .font: ChromeFont.label,
            ]
        )

        switch section {
        case .history:
            countLabel.stringValue = "\(rows.count) \(rows.count == 1 ? "page" : "pages")"
            footerButton.title = "Clear History…"
            footerButton.isEnabled = true
            footerButton.isHidden = false
        case .bookmarks:
            countLabel.stringValue = "\(rows.count) \(rows.count == 1 ? "bookmark" : "bookmarks")"
            footerButton.isHidden = true
        case .downloads:
            countLabel.stringValue = "\(rows.count) \(rows.count == 1 ? "download" : "downloads")"
            footerButton.title = "Clear Finished"
            footerButton.isEnabled = downloads.matching("", privateContextID: privateDownloadContextID)
                .contains { $0.state != .inProgress }
            footerButton.isHidden = false
        }

        footerTrailing?.stringValue = query.isEmpty ? "" : "Filtered"
        emptyLabel.stringValue = query.isEmpty ? section.emptyText : "No matches"
        emptyLabel.isHidden = !rows.isEmpty
        tableView.reloadData()
    }

    private var placeholder: String {
        switch section {
        case .history: "Search history"
        case .bookmarks: "Search bookmarks"
        case .downloads: "Search downloads"
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("BrowserSidebarRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BrowserSidebarCellView
            ?? BrowserSidebarCellView(theme: theme)
        cell.identifier = identifier
        cell.configure(row: rows[row], theme: theme, favicon: rows[row].url.flatMap { faviconProvider?($0) })
        cell.onAction = { [weak self] in
            guard let self, row < self.rows.count else { return }
            self.open(self.rows[row])
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        true
    }

    @objc private func openClickedRow() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        open(rows[row])
    }

    private func open(_ row: BrowserSidebarRow) {
        switch row {
        case let .history(entry):
            onOpenURL?(entry.url)
        case let .bookmark(bookmark):
            onOpenURL?(bookmark.url)
        case let .download(download):
            if download.state == .completed, let path = download.path {
                onOpenFile?(path)
            } else if download.canResume {
                onResumeDownload?(download.id)
            } else if download.canRetry {
                onRetryDownload?(download.id)
            }
        }
    }

    @objc private func sectionPressed(_ sender: ChromeButton) {
        guard sender.tag >= 0, sender.tag < BrowserSidebarSection.allCases.count else { return }
        select(BrowserSidebarSection.allCases[sender.tag])
    }

    @objc private func closePressed() {
        onClose?()
    }

    @objc private func footerPressed() {
        switch section {
        case .history:
            onClear?(.history)
        case .downloads:
            onClear?(.downloads)
        case .bookmarks:
            break
        }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        contextRow = tableView.clickedRow
        guard contextRow >= 0, contextRow < rows.count else { return }
        let row = rows[contextRow]

        switch row {
        case .history:
            menu.addItem(item("Open", #selector(menuOpen)))
            menu.addItem(item("Copy Link", #selector(menuCopyLink)))
            menu.addItem(.separator())
            menu.addItem(item("Remove from History", #selector(menuRemove)))
        case .bookmark:
            menu.addItem(item("Open", #selector(menuOpen)))
            menu.addItem(item("Copy Link", #selector(menuCopyLink)))
            menu.addItem(.separator())
            menu.addItem(item("Remove Bookmark", #selector(menuRemove)))
        case let .download(download):
            if download.state == .completed, download.path != nil {
                menu.addItem(item("Open", #selector(menuOpen)))
                menu.addItem(item("Reveal in Finder", #selector(menuReveal)))
                menu.addItem(.separator())
            } else if download.state == .inProgress {
                menu.addItem(item("Cancel Download", #selector(menuCancel)))
                menu.addItem(.separator())
            } else if download.canRetry {
                if download.canResume {
                    menu.addItem(item("Resume Download", #selector(menuResume)))
                }
                menu.addItem(item("Retry Download", #selector(menuRetry)))
                menu.addItem(item("Copy Link", #selector(menuCopyLink)))
                menu.addItem(.separator())
            }
            menu.addItem(item("Remove from List", #selector(menuRemove)))
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuOpen() {
        guard contextRow >= 0, contextRow < rows.count else { return }
        open(rows[contextRow])
    }

    @objc private func menuCopyLink() {
        guard contextRow >= 0, contextRow < rows.count, let url = rows[contextRow].url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func menuReveal() {
        guard contextRow >= 0, contextRow < rows.count else { return }
        guard case let .download(download) = rows[contextRow], let path = download.path else { return }
        onRevealFile?(path)
    }

    @objc private func menuResume() {
        guard contextRow >= 0, contextRow < rows.count else { return }
        guard case let .download(download) = rows[contextRow] else { return }
        onResumeDownload?(download.id)
    }

    @objc private func menuRetry() {
        guard contextRow >= 0, contextRow < rows.count else { return }
        guard case let .download(download) = rows[contextRow] else { return }
        onRetryDownload?(download.id)
    }

    @objc private func menuCancel() {
        guard contextRow >= 0, contextRow < rows.count else { return }
        guard case let .download(download) = rows[contextRow] else { return }
        onCancelDownload?(download.id)
    }

    @objc private func menuRemove() {
        guard contextRow >= 0, contextRow < rows.count else { return }
        switch rows[contextRow] {
        case let .history(entry):
            onRemoveHistory?(entry.id)
        case let .bookmark(bookmark):
            onRemoveBookmark?(bookmark.id)
        case let .download(download):
            onRemoveDownload?(download.id)
        }
    }
}

@MainActor
private final class BrowserSidebarCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let progressBar = BrowserDownloadProgressBar()
    /// Resume or Retry on a stopped download row.
    private let actionButton = ChromeIconButton(
        symbolName: "arrow.clockwise",
        accessibilityLabel: "Retry Download",
        pointSize: 11,
        size: 22,
        target: nil,
        action: nil
    )
    private var actionConstraints: [NSLayoutConstraint] = []
    var onAction: (() -> Void)?
    private var theme: AppTheme?
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(theme: AppTheme) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Chrome.Radius.control

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = ChromeFont.row
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = ChromeFont.meta
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.usesSingleLineMode = true
        addSubview(subtitleLabel)

        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.font = ChromeFont.count
        dateLabel.alignment = .right
        dateLabel.lineBreakMode = .byClipping
        addSubview(dateLabel)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.isHidden = true
        addSubview(progressBar)

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.isHidden = true
        actionButton.target = self
        actionButton.action = #selector(actionPressed)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -8),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            dateLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            dateLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 96),

            progressBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            progressBar.heightAnchor.constraint(equalToConstant: 2),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        actionConstraints = [
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -8),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -8),
        ]

        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(row: BrowserSidebarRow, theme: AppTheme, favicon: NSImage? = nil) {
        apply(theme: theme)
        setAction(nil)
        switch row {
        case let .history(entry):
            iconView.image = favicon ?? symbol("clock")
            titleLabel.stringValue = entry.displayTitle
            subtitleLabel.stringValue = entry.url
            dateLabel.stringValue = Self.date(entry.visitedAt)
        case let .bookmark(bookmark):
            iconView.image = favicon ?? symbol("bookmark")
            titleLabel.stringValue = bookmark.displayTitle
            subtitleLabel.stringValue = bookmark.url
            dateLabel.stringValue = Self.date(bookmark.addedAt)
        case let .download(download):
            iconView.image = symbol(download.state == .completed ? "doc" : "arrow.down.circle")
            titleLabel.stringValue = download.filename
            dateLabel.stringValue = Self.date(download.startedAt)
            if download.state == .inProgress {
                subtitleLabel.stringValue = "Downloading… \(Int((download.fractionCompleted * 100).rounded()))%"
                progressBar.progress = download.fractionCompleted
                progressBar.isHidden = false
            } else {
                subtitleLabel.stringValue = Self.stoppedText(download)
                progressBar.isHidden = true
                if download.canResume {
                    setAction(("play", "Resume Download"))
                } else if download.canRetry {
                    setAction(("arrow.clockwise", "Retry Download"))
                }
            }
        }
        setAccessibilityLabel(titleLabel.stringValue)
    }

    private func setAction(_ action: (symbol: String, label: String)?) {
        actionButton.isHidden = action == nil
        dateLabel.isHidden = action != nil
        if let action {
            actionButton.setSymbol(action.symbol, accessibilityLabel: action.label, pointSize: 11)
            actionButton.toolTip = action.label
            if let theme {
                actionButton.apply(theme: theme)
            }
        }
        if action == nil {
            NSLayoutConstraint.deactivate(actionConstraints)
        } else {
            NSLayoutConstraint.activate(actionConstraints)
        }
    }

    @objc private func actionPressed() {
        onAction?()
    }

    /// "Cancelled · 42% kept" for a resumable row, the error or state
    /// otherwise.
    private static func stoppedText(_ download: BrowserDownloadRecord) -> String {
        let status = download.errorMessage ?? download.state.label
        guard download.canResume, download.fractionCompleted > 0 else { return status }
        return "\(status) · \(Int((download.fractionCompleted * 100).rounded()))% kept"
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        titleLabel.textColor = theme.colors.textPrimary
        subtitleLabel.textColor = theme.colors.textMuted
        dateLabel.textColor = theme.colors.textMuted
        iconView.contentTintColor = theme.colors.textMuted
        progressBar.trackColor = theme.colors.borderSubtle
        progressBar.fillColor = theme.colors.blue
        layer?.backgroundColor = isHovered ? theme.colors.hover.cgColor : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = theme?.colors.hover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = nil
    }

    private func symbol(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    private static func date(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "now"
        }
        if interval < 3_600 {
            return "\(Int(interval / 60))m ago"
        }
        if interval < 86_400 {
            return "\(Int(interval / 3_600))h ago"
        }
        if interval < 604_800 {
            return "\(Int(interval / 86_400))d ago"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}


@MainActor
private final class BrowserDownloadProgressBar: NSView {
    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }
    var trackColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    var fillColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        trackColor.setFill()
        bounds.fill()
        guard progress > 0 else { return }
        fillColor.setFill()
        NSRect(
            x: 0,
            y: 0,
            width: floor(bounds.width * CGFloat(min(1, max(0, progress)))),
            height: bounds.height
        ).fill()
    }
}
