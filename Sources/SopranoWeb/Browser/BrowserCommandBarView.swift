import AppKit

/// The Command Bar's state and keys (⌘T, ⌘L, ⇧⌘P): the query, the
/// site-search engine, the grouped results and the selection. The window
/// supplies the sources (`makeInput`) and acts on the chosen row
/// (`onChoose`); `BrowserCommandBarView` draws it inside the window.
@MainActor
final class BrowserCommandBarController {
    let view: BrowserCommandBarView

    var makeInput: ((String, BrowserCommandBarMode, BrowserSearchEngineID?) -> BrowserCommandBarInput)?
    /// A row was chosen (Return or a click); the bar has closed.
    var onChoose: ((BrowserCommandBarRow, BrowserCommandBarMode) -> Void)?
    /// Closed without choosing (Esc, a click outside).
    var onDismiss: (() -> Void)?

    private(set) var mode = BrowserCommandBarMode.newTab
    private(set) var siteSearch: BrowserSearchEngine?
    private(set) var groups: [BrowserCommandBarGroup] = []
    private(set) var selection = 0

    init(theme: AppTheme) {
        view = BrowserCommandBarView(theme: theme)
        view.onTextChange = { [weak self] text in self?.refresh(text: text) }
        view.onCommand = { [weak self] selector in self?.handle(selector) ?? false }
        view.onClickRow = { [weak self] index in
            self?.selection = index
            self?.chooseSelected()
        }
        view.onClickOutside = { [weak self] in self?.dismiss() }
    }

    var isOpen: Bool { !view.isHidden }
    var text: String { view.text }
    var rows: [BrowserCommandBarRow] { groups.flatMap(\.rows) }

    func apply(theme: AppTheme) {
        view.apply(theme: theme)
    }

    /// Opens (or re-opens) the bar with `text` in the field, selected when
    /// `selectAll` (⌘L's address), the caret at the end otherwise.
    func open(mode: BrowserCommandBarMode, text: String, selectAll: Bool) {
        self.mode = mode
        siteSearch = nil
        view.setChip(nil)
        view.setPlaceholder(mode == .actions ? "Search actions" : "Search or enter address")
        view.isHidden = false
        view.text = text
        view.focus(selectAll: selectAll)
        refresh(text: text)
    }

    func close() {
        guard isOpen else { return }
        view.isHidden = true
        view.resignField()
        siteSearch = nil
        groups = []
        selection = 0
    }

    /// The field's text changed (typing, or the harness).
    func refresh(text: String) {
        let input = makeInput?(text, mode, siteSearch?.id) ?? BrowserCommandBarInput(query: text, mode: mode)
        groups = BrowserCommandBarEngine.groups(for: input)
        selection = 0
        view.show(groups: groups, selection: selection)
    }

    /// Types `text` as if the user had (the harness): the caret ends up
    /// after it.
    func type(_ text: String) {
        view.text = text
        view.focus(selectAll: false)
        refresh(text: text)
    }

    /// Key commands from the field editor; true when handled. ⌃N and ⌃P
    /// arrive as moveDown: and moveUp:.
    func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            move(by: -1)
        case #selector(NSResponder.insertTab(_:)):
            if siteSearch == nil, let engine = BrowserCommandBarEngine.siteSearchEngine(
                for: view.text,
                engines: makeInput?("", mode, nil).searchEngines ?? .default
            ) {
                enterSiteSearch(engine)
            } else {
                move(by: 1)
            }
        case #selector(NSResponder.insertNewline(_:)):
            chooseSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        case #selector(NSResponder.deleteBackward(_:)):
            // Backspace on the empty field leaves site search.
            guard siteSearch != nil, view.text.isEmpty else { return false }
            siteSearch = nil
            view.setChip(nil)
            refresh(text: "")
        default:
            return false
        }
        return true
    }

    func enterSiteSearch(_ engine: BrowserSearchEngine) {
        siteSearch = engine
        view.setChip(engine.name)
        view.text = ""
        refresh(text: "")
    }

    func chooseSelected() {
        let rows = rows
        guard rows.indices.contains(selection) else { return }
        let row = rows[selection]
        let mode = mode
        close()
        onChoose?(row, mode)
    }

    private func dismiss() {
        close()
        onDismiss?()
    }

    private func move(by delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = min(max(0, selection + delta), count - 1)
        view.select(selection)
    }

    /// The bar as one JSON object (the harness's `--print-command-bar`).
    func dump() -> [String: Any] {
        var flat = 0
        let groups: [[String: Any]] = groups.map { group in
            [
                "title": group.title,
                "rows": group.rows.map { row -> [String: Any] in
                    defer { flat += 1 }
                    return [
                        "kind": row.kind.rawValue,
                        "title": row.title,
                        "detail": row.detail,
                        "shortcut": row.shortcut,
                        "target": Self.describe(row.target),
                        "selected": flat == selection,
                    ]
                },
            ]
        }
        return [
            "open": isOpen,
            "mode": mode.rawValue,
            "text": view.text,
            "chip": siteSearch?.name ?? NSNull(),
            "selection": selection,
            "groups": groups,
        ]
    }

    static func describe(_ target: BrowserCommandBarRow.Target) -> String {
        switch target {
        case let .url(url): "url \(url)"
        case let .search(engine, query): "search \(engine.rawValue) \(query)"
        case let .tab(id): "tab \(id.uuidString)"
        case let .pin(id): "pin \(id.uuidString)"
        case let .favorite(id): "favorite \(id.uuidString)"
        case let .space(id): "space \(id.uuidString)"
        case let .command(id): "command \(id.rawValue)"
        case let .extensionCommand(extensionID, commandID): "extension-command \(extensionID) \(commandID)"
        case let .extensionAction(id): "extension-action \(id)"
        case let .settings(page): "settings \(page.rawValue)"
        case .startPage: "start page"
        }
    }
}

/// The Command Bar: a Folio panel over the window's content (never a window
/// of its own, so it takes no focus from other apps). The transparent
/// overlay catches clicks outside the panel.
@MainActor
final class BrowserCommandBarView: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 640
    static let topOffset: CGFloat = 84
    static let searchHeight: CGFloat = 48
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 36
    static let listPadding: CGFloat = 6
    static let footerHeight: CGFloat = 28
    static let maxListHeight: CGFloat = 430

    var onTextChange: ((String) -> Void)?
    var onCommand: ((Selector) -> Bool)?
    var onClickRow: ((Int) -> Void)?
    var onClickOutside: (() -> Void)?

    /// The panel (fill, radius, shadow); the harness draws it over the page.
    let surface = BrowserCommandBarSurface()
    let field = NSTextField(string: "")
    private let searchIcon = NSImageView()
    private let chip: ChromeChip
    private let searchRule = ChromeRuleView(axis: .horizontal)
    private let footerRule = ChromeRuleView(axis: .horizontal)
    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private var hintViews: [(ChromeKeycapView, NSTextField)] = []
    private var rowViews: [BrowserCommandBarRowView] = []
    private var headerViews: [ChromeEyebrowView] = []
    private var listHeight: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint!
    private var fieldLeadingToIcon: NSLayoutConstraint!
    private var fieldLeadingToChip: NSLayoutConstraint!
    private var theme: AppTheme
    private var placeholder = ""

    private static let hints: [(String, String)] = [("↑↓", "Select"), ("↩", "Open"), ("⇥", "Site search"), ("esc", "Close")]

    init(theme: AppTheme) {
        self.theme = theme
        chip = ChromeChip(text: "", theme: theme, style: .filled)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        searchIcon.imageScaling = .scaleNone
        field.delegate = self
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Command Bar")
        // Below the bar's width (490): a long address (⌘L) scrolls in the
        // field instead of widening the bar toward the window.
        field.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 480), for: .horizontal)
        chip.isHidden = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = listView
        let hintStack = NSStackView()
        hintStack.orientation = .horizontal
        hintStack.spacing = 14
        for (cap, word) in Self.hints {
            let keycap = ChromeKeycapView(legend: cap, theme: theme, style: .small, tone: .muted)
            let label = NSTextField(labelWithString: word)
            let pair = NSStackView(views: [keycap, label])
            pair.orientation = .horizontal
            pair.spacing = 5
            hintStack.addArrangedSubview(pair)
            hintViews.append((keycap, label))
        }
        for view in [searchIcon, chip, field, searchRule, scrollView, footerRule, hintStack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(view)
        }

        listHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        widthConstraint = surface.widthAnchor.constraint(equalToConstant: Self.width)
        // Below `windowSizeStayPut`: a narrow window (a Little Arc, a
        // pop-up) narrows the bar instead of growing to fit it.
        widthConstraint.priority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 10)
        fieldLeadingToIcon = field.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10)
        fieldLeadingToChip = field.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor, constant: Self.topOffset),
            surface.centerXAnchor.constraint(equalTo: centerXAnchor),
            surface.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            widthConstraint,

            searchIcon.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: surface.topAnchor, constant: Self.searchHeight / 2),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            chip.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            chip.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            fieldLeadingToIcon,
            field.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            field.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),

            searchRule.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            searchRule.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            searchRule.topAnchor.constraint(equalTo: surface.topAnchor, constant: Self.searchHeight),

            scrollView.topAnchor.constraint(equalTo: searchRule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            listHeight,

            footerRule.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footerRule.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            hintStack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            hintStack.centerYAnchor.constraint(equalTo: footerRule.bottomAnchor, constant: Self.footerHeight / 2),
            surface.bottomAnchor.constraint(equalTo: footerRule.bottomAnchor, constant: Self.footerHeight),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Command Bar")
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        surface.colors = colors
        searchIcon.contentTintColor = colors.textMuted
        ChromeFieldView.styleEmbedded(field, colors: colors, font: ChromeFont.paletteQuery)
        ChromeFieldView.styleEditor(of: field, colors: colors)
        showPlaceholder()
        chip.apply(theme: theme)
        searchRule.color = colors.borderSubtle
        footerRule.color = colors.borderSubtle
        for (cap, label) in hintViews {
            cap.apply(theme: theme)
            label.setChromeText(label.stringValue, font: ChromeFont.meta, color: colors.textMuted)
        }
        headerViews.forEach { $0.apply(theme: theme) }
        rowViews.forEach { $0.apply(theme: theme) }
    }

    func setPlaceholder(_ text: String) {
        placeholder = text
        showPlaceholder()
    }

    /// The placeholder, or "Search <Engine>" in site search.
    private func showPlaceholder() {
        field.placeholderAttributedString = ChromeText.attributed(
            chip.isHidden ? placeholder : "Search \(chip.text)",
            font: ChromeFont.paletteQuery,
            color: theme.colors.textMuted
        )
    }

    /// The site-search chip (the engine's name), or none.
    func setChip(_ title: String?) {
        chip.text = title ?? ""
        chip.isHidden = title == nil
        // Off before on, so the two never hold at once.
        if title == nil {
            fieldLeadingToChip.isActive = false
            fieldLeadingToIcon.isActive = true
        } else {
            fieldLeadingToIcon.isActive = false
            fieldLeadingToChip.isActive = true
        }
        showPlaceholder()
    }

    func focus(selectAll: Bool) {
        window?.makeFirstResponder(field)
        ChromeFieldView.styleEditor(of: field, colors: theme.colors)
        guard let editor = field.currentEditor() else { return }
        if selectAll {
            editor.selectAll(nil)
        } else {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    func resignField() {
        if let editor = field.currentEditor(), window?.firstResponder === editor {
            window?.makeFirstResponder(nil)
        }
    }

    func show(groups: [BrowserCommandBarGroup], selection: Int) {
        rowViews.forEach { $0.removeFromSuperview() }
        headerViews.forEach { $0.removeFromSuperview() }
        rowViews = []
        headerViews = []
        // The bar narrows in a narrow window (a Little Arc): rows take its
        // laid-out width, never the full 640.
        layoutSubtreeIfNeeded()
        let width = surface.bounds.width > 0
            ? surface.bounds.width
            : (bounds.width > 48 ? min(Self.width, bounds.width - 48) : Self.width)
        var y = groups.isEmpty ? 0 : Self.listPadding
        for group in groups {
            if !group.title.isEmpty {
                let header = ChromeEyebrowView(title: group.title, theme: theme)
                header.translatesAutoresizingMaskIntoConstraints = true
                header.frame = NSRect(x: 18, y: y + 9, width: width - 36, height: 14)
                listView.addSubview(header)
                headerViews.append(header)
                y += Self.headerHeight
            }
            for row in group.rows {
                let index = rowViews.count
                let view = BrowserCommandBarRowView(row: row, theme: theme)
                view.frame = NSRect(x: 0, y: y, width: width, height: Self.rowHeight)
                view.autoresizingMask = [.width]
                view.onClick = { [weak self] in self?.onClickRow?(index) }
                listView.addSubview(view)
                rowViews.append(view)
                y += Self.rowHeight
            }
        }
        if !groups.isEmpty { y += Self.listPadding }
        listView.frame = NSRect(x: 0, y: 0, width: width, height: y)
        listView.autoresizingMask = [.width]
        listHeight.constant = min(y, Self.maxListHeight)
        select(selection)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func select(_ index: Int) {
        for (offset, view) in rowViews.enumerated() {
            view.isSelected = offset == index
        }
        guard rowViews.indices.contains(index) else { return }
        listView.scrollToVisible(rowViews[index].frame.insetBy(dx: 0, dy: -Self.listPadding))
    }

    // MARK: Field

    func controlTextDidChange(_ notification: Notification) {
        onTextChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        onCommand?(commandSelector) ?? false
    }

    // MARK: Clicks

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !surface.frame.contains(point) {
            onClickOutside?()
        }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

/// The Command Bar's panel: raised fill, panel radius, e3 shadow. The fill
/// is drawn (not a layer color) so the offscreen harness captures it.
@MainActor
final class BrowserCommandBarSurface: NSView {
    var colors: ThemeColors? {
        didSet { applyShadow() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors else { return }
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Chrome.Radius.panel,
            yRadius: Chrome.Radius.panel
        )
        colors.raised.setFill()
        shape.fill()
        colors.borderSubtle.setStroke()
        shape.lineWidth = Chrome.hairline
        shape.stroke()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyShadow()
    }

    private func applyShadow() {
        guard let layer, let colors else { return }
        layer.cornerRadius = Chrome.Radius.panel
        colors.shadowE3.apply(to: layer)
        needsDisplay = true
    }
}

/// One Command Bar row: icon, title, detail (addresses in SF Mono), and a
/// `/` action's shortcut or "Switch to Tab" on the right.
@MainActor
final class BrowserCommandBarRowView: NSView {
    var onClick: (() -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            refresh()
        }
    }

    private let row: BrowserCommandBarRow
    private let background: ChromeRowBackgroundView
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private let keycaps: ChromeKeycapGroupView
    private var theme: AppTheme

    init(row: BrowserCommandBarRow, theme: AppTheme) {
        self.row = row
        self.theme = theme
        background = ChromeRowBackgroundView(theme: theme)
        keycaps = ChromeKeycapGroupView(caps: row.shortcut.isEmpty ? [] : [row.shortcut], theme: theme, style: .standard, tone: .muted)
        super.init(frame: .zero)
        background.inset = 6
        background.translatesAutoresizingMaskIntoConstraints = true
        background.autoresizingMask = [.width, .height]
        addSubview(background)
        icon.image = NSImage(systemSymbolName: row.symbol.isEmpty ? "circle" : row.symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.imageScaling = .scaleNone
        for label in [titleLabel, detailLabel, trailingLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        keycaps.isHidden = row.shortcut.isEmpty
        for view in [icon, titleLabel, detailLabel, trailingLabel, keycaps] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let trailingAnchorView: NSView = row.shortcut.isEmpty ? trailingLabel : keycaps
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.55),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            detailLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchorView.leadingAnchor, constant: -10),
            trailingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            trailingLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            keycaps.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            keycaps.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.detail.isEmpty ? row.title : "\(row.title), \(row.detail)")
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        background.frame = bounds
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        background.apply(theme: theme)
        keycaps.apply(theme: theme)
        refresh()
    }

    private func refresh() {
        let colors = theme.colors
        background.style = isSelected ? .selected : .none
        icon.contentTintColor = isSelected ? colors.textPrimary : colors.textMuted
        titleLabel.setChromeText(row.title, font: ChromeFont.row, color: colors.textPrimary)
        let mono = [.open, .tab, .pin, .favorite, .history].contains(row.kind) && !row.detail.contains(" ")
        detailLabel.setChromeText(row.detail, font: mono ? ChromeFont.monoSmall : ChromeFont.meta, color: colors.textMuted)
        let trailing = row.kind == .tab ? "Switch to Tab" : ""
        trailingLabel.setChromeText(trailing, font: ChromeFont.meta, color: colors.textMuted)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
