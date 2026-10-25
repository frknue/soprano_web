import AppKit
import WebKit

/// Settings ▸ Website Data…: every site with stored data
/// (`WKWebsiteDataStore.fetchDataRecords`), searchable, with Remove and
/// Remove All.
@MainActor
final class BrowserWebsiteDataSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate
{
    private let dataStore: WKWebsiteDataStore
    private var theme: AppTheme
    private var records: [WKWebsiteDataRecord] = []
    private var rows: [WKWebsiteDataRecord] = []
    private var isLoading = true
    private var onClose: (() -> Void)?

    private let rootView = NSView()
    private let header = NSTextField(labelWithString: "Website Data")
    private let subtitle = NSTextField(
        labelWithString: "Cookies, storage and caches that websites keep on this Mac."
    )
    private let searchFrame: ChromeFieldView
    private let searchField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let topRule: ChromeRuleView
    private let bottomRule: ChromeRuleView
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let removeButton: ChromeButton
    private let removeAllButton: ChromeButton
    private let doneButton: ChromeButton

    init(theme: AppTheme, dataStore: WKWebsiteDataStore = .default()) {
        self.theme = theme
        self.dataStore = dataStore
        self.searchFrame = ChromeFieldView(theme: theme)
        self.topRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        self.bottomRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        self.removeButton = ChromeButton(title: "Remove", theme: theme, kind: .standard)
        self.removeAllButton = ChromeButton(title: "Remove All", theme: theme, kind: .danger)
        self.doneButton = ChromeButton(title: "Done", theme: theme, kind: .ink, keycap: "esc")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Website Data"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        rootView.wantsLayer = true
        window.contentView = rootView
        buildLayout()
        apply(theme: theme)
        refreshRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the list as a sheet on `parent` and loads the records.
    func present(on parent: NSWindow, onClose: (() -> Void)? = nil) {
        guard let window else { return }
        self.onClose = onClose
        parent.beginSheet(window)
        window.makeFirstResponder(searchField)
        reload()
    }

    private func buildLayout() {
        header.translatesAutoresizingMaskIntoConstraints = false
        header.font = ChromeFont.headline
        rootView.addSubview(header)

        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = ChromeFont.meta
        rootView.addSubview(subtitle)

        searchFrame.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(searchFrame)
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchFrame.addSubview(searchField)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = ChromeFont.count
        countLabel.alignment = .right
        rootView.addSubview(countLabel)

        topRule.translatesAutoresizingMaskIntoConstraints = false
        bottomRule.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(topRule)
        rootView.addSubview(bottomRule)

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("site"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        rootView.addSubview(scrollView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = ChromeFont.empty
        emptyLabel.alignment = .center
        rootView.addSubview(emptyLabel)

        removeButton.target = self
        removeButton.action = #selector(removePressed)
        removeAllButton.target = self
        removeAllButton.action = #selector(removeAllPressed)
        doneButton.target = self
        doneButton.action = #selector(donePressed)
        doneButton.keyEquivalent = "\u{1b}"
        for button in [removeButton, removeAllButton, doneButton] {
            rootView.addSubview(button)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            subtitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),

            searchFrame.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            searchFrame.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            searchFrame.widthAnchor.constraint(equalToConstant: 260),
            searchFrame.heightAnchor.constraint(equalToConstant: 26),
            searchField.leadingAnchor.constraint(equalTo: searchFrame.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchFrame.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchFrame.centerYAnchor),

            countLabel.centerYAnchor.constraint(equalTo: searchFrame.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: searchFrame.trailingAnchor, constant: 12),

            topRule.topAnchor.constraint(equalTo: searchFrame.bottomAnchor, constant: 12),
            topRule.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            topRule.heightAnchor.constraint(equalToConstant: Chrome.hairline),

            scrollView.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            bottomRule.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -14),
            bottomRule.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            bottomRule.heightAnchor.constraint(equalToConstant: Chrome.hairline),

            removeButton.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            removeButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            removeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            removeAllButton.leadingAnchor.constraint(equalTo: removeButton.trailingAnchor, constant: 8),
            removeAllButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            removeAllButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),

            doneButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            doneButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        window?.backgroundColor = theme.colors.bgBase
        rootView.layer?.backgroundColor = theme.colors.bgBase.cgColor
        header.textColor = theme.colors.textPrimary
        subtitle.textColor = theme.colors.textMuted
        countLabel.textColor = theme.colors.textMuted
        emptyLabel.textColor = theme.colors.textMuted
        topRule.color = theme.colors.borderSubtle
        bottomRule.color = theme.colors.borderSubtle
        searchFrame.apply(theme: theme)
        ChromeFieldView.styleEmbedded(searchField, colors: theme.colors, font: ChromeFont.label)
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search websites",
            attributes: [.foregroundColor: theme.colors.textMuted, .font: ChromeFont.label]
        )
        for button in [removeButton, removeAllButton, doneButton] {
            button.apply(theme: theme)
        }
        tableView.reloadData()
    }

    // MARK: - Data

    /// Fetches the records again (also how the snapshot harness fills the
    /// list without presenting it).
    func reload() {
        isLoading = true
        refreshRows()
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            guard let self else { return }
            self.records = records.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            self.isLoading = false
            self.refreshRows()
        }
    }

    private func refreshRows() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        rows = query.isEmpty ? records : records.filter { $0.displayName.lowercased().contains(query) }
        countLabel.stringValue = isLoading
            ? ""
            : "\(rows.count) \(rows.count == 1 ? "website" : "websites")"
        emptyLabel.stringValue = isLoading
            ? "Loading…"
            : (query.isEmpty ? "No website data" : "No matches")
        emptyLabel.isHidden = !rows.isEmpty
        tableView.reloadData()
        updateButtons()
    }

    private func updateButtons() {
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
        removeAllButton.isEnabled = !records.isEmpty
    }

    private func remove(_ targets: [WKWebsiteDataRecord]) {
        guard !targets.isEmpty else { return }
        let types = targets.reduce(into: Set<String>()) { $0.formUnion($1.dataTypes) }
        dataStore.removeData(ofTypes: types, for: targets) { [weak self] in
            self?.reload()
        }
    }

    // MARK: - Actions

    @objc private func removePressed() {
        remove(tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil })
    }

    @objc private func removeAllPressed() {
        guard let window, !records.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Remove all website data?"
        alert.informativeText = "Every website loses its cookies, storage and caches. "
            + "You will be signed out of most sites."
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.remove(self.records)
        }
    }

    @objc private func donePressed() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        onClose?()
        onClose = nil
    }

    func controlTextDidChange(_ notification: Notification) {
        refreshRows()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        BrowserWebsiteDataRowView(theme: theme)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("BrowserWebsiteDataCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BrowserWebsiteDataCellView
            ?? BrowserWebsiteDataCellView()
        cell.identifier = identifier
        let record = rows[row]
        cell.configure(
            name: record.displayName,
            kinds: BrowserWebsiteDataKinds.labels(for: record.dataTypes).joined(separator: ", "),
            theme: theme
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}

@MainActor
private final class BrowserWebsiteDataRowView: NSTableRowView {
    private let theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func drawSelection(in dirtyRect: NSRect) {
        ChromeSelectionPill.draw(
            isEmphasized ? .selected : .selectedUnfocused,
            in: bounds,
            colors: theme.colors
        )
    }
}

@MainActor
private final class BrowserWebsiteDataCellView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let kindsLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = ChromeFont.row
        nameLabel.lineBreakMode = .byTruncatingTail
        kindsLabel.translatesAutoresizingMaskIntoConstraints = false
        kindsLabel.font = ChromeFont.meta
        kindsLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)
        addSubview(kindsLabel)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            kindsLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            kindsLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            kindsLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(name: String, kinds: String, theme: AppTheme) {
        nameLabel.stringValue = name
        nameLabel.textColor = theme.colors.textPrimary
        kindsLabel.stringValue = kinds
        kindsLabel.textColor = theme.colors.textMuted
        setAccessibilityLabel("\(name), \(kinds)")
    }
}
