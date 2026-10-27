import AppKit

/// History ▸ Clear Browsing Data…: an alert sheet with a time range and one
/// checkbox per kind of data. It acts on the window's Space and names it
/// when there are several.
@MainActor
enum BrowserClearBrowsingDataSheet {
    /// Shows the sheet on `window`; `completion` gets the chosen options, or
    /// nil when cancelled. `spaceName` is the Space it clears (nil while
    /// only one Space exists).
    static func present(
        on window: NSWindow,
        theme: AppTheme,
        spaceName: String?,
        initial: BrowserClearOptions = BrowserClearOptions(),
        completion: @escaping @MainActor (BrowserClearOptions?) -> Void
    ) {
        let (alert, accessory) = makeAlert(theme: theme, spaceName: spaceName, initial: initial)
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn ? accessory.options : nil)
        }
    }

    /// The laid-out alert, not yet shown (the snapshot harness captures it
    /// offscreen).
    static func makeAlert(
        theme: AppTheme,
        spaceName: String?,
        initial: BrowserClearOptions = BrowserClearOptions()
    ) -> (NSAlert, BrowserClearDataAccessoryView) {
        let alert = NSAlert()
        alert.messageText = title(spaceName: spaceName)
        alert.informativeText = message(spaceName: spaceName)
        let clear = alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        let accessory = BrowserClearDataAccessoryView(options: initial, theme: theme)
        accessory.onChange = { options in
            clear.isEnabled = !options.isEmpty
        }
        alert.accessoryView = accessory
        alert.layout()
        return (alert, accessory)
    }

    /// "Clear Browsing Data", or "… of “Work”" when there are several
    /// Spaces.
    nonisolated static func title(spaceName: String?) -> String {
        spaceName.map { "Clear Browsing Data of “\($0)”" } ?? "Clear Browsing Data"
    }

    nonisolated static func message(spaceName: String?) -> String {
        let tail = "Open tabs keep their back and forward history."
        guard let spaceName else {
            return "Removes the chosen data from this Mac for the selected time range. \(tail)"
        }
        return "Removes the chosen data of the \(spaceName) Space from this Mac for the selected "
            + "time range; other Spaces keep theirs. \(tail)"
    }
}

@MainActor
final class BrowserClearDataAccessoryView: NSView {
    private(set) var options: BrowserClearOptions
    var onChange: ((BrowserClearOptions) -> Void)?

    private let theme: AppTheme
    private let rangeButton: ChromeButton
    private let historyBox: ChromeCheckbox
    private let siteDataBox: ChromeCheckbox
    private let cacheBox: ChromeCheckbox
    private let downloadsBox: ChromeCheckbox

    init(options: BrowserClearOptions, theme: AppTheme) {
        self.options = options
        self.theme = theme
        self.rangeButton = ChromeButton(title: options.range.title, theme: theme, kind: .standard)
        self.historyBox = ChromeCheckbox(isChecked: options.history, theme: theme)
        self.siteDataBox = ChromeCheckbox(isChecked: options.cookiesAndSiteData, theme: theme)
        self.cacheBox = ChromeCheckbox(isChecked: options.cachedFiles, theme: theme)
        self.downloadsBox = ChromeCheckbox(isChecked: options.downloadList, theme: theme)
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 176))

        rangeButton.target = self
        rangeButton.action = #selector(rangePressed)
        for box in [historyBox, siteDataBox, cacheBox, downloadsBox] {
            box.target = self
            box.action = #selector(boxChanged)
        }

        let rangeLabel = label("Time range", font: ChromeFont.label, color: theme.colors.textMuted)
        let rangeRow = NSStackView(views: [rangeLabel, rangeButton])
        rangeRow.orientation = .horizontal
        rangeRow.spacing = 10
        rangeRow.alignment = .centerY

        let stack = NSStackView(views: [
            rangeRow,
            checkboxRow(historyBox, title: "Browsing history", detail: "History list and recently closed tabs"),
            checkboxRow(siteDataBox, title: "Cookies and website data", detail: "Signs you out of most sites"),
            checkboxRow(cacheBox, title: "Cached files", detail: "Pages load from the network again"),
            checkboxRow(downloadsBox, title: "Download list", detail: "Downloaded files stay on disk"),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: rangeRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            rangeButton.widthAnchor.constraint(equalToConstant: 170),
            rangeButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        return field
    }

    private func checkboxRow(_ box: ChromeCheckbox, title: String, detail: String) -> NSView {
        let titleLabel = label(title, font: ChromeFont.label, color: theme.colors.textPrimary)
        let detailLabel = label(detail, font: ChromeFont.meta, color: theme.colors.textMuted)
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [box, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        box.setAccessibilityLabel(title)
        // The label toggles the box, like a checkbox title.
        let click = BrowserLabelClick(target: self, action: #selector(labelClicked(_:)))
        click.box = box
        text.addGestureRecognizer(click)
        return row
    }

    @objc private func labelClicked(_ sender: BrowserLabelClick) {
        _ = sender.box?.accessibilityPerformPress()
    }

    @objc private func boxChanged() {
        options.history = historyBox.isChecked
        options.cookiesAndSiteData = siteDataBox.isChecked
        options.cachedFiles = cacheBox.isChecked
        options.downloadList = downloadsBox.isChecked
        onChange?(options)
    }

    @objc private func rangePressed() {
        let menu = NSMenu()
        for range in BrowserClearRange.allCases {
            let item = NSMenuItem(title: range.title, action: #selector(rangeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = range.rawValue
            item.state = range == options.range ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: rangeButton.bounds.height + 4), in: rangeButton)
    }

    @objc private func rangeChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let range = BrowserClearRange(rawValue: raw)
        else { return }
        options.range = range
        rangeButton.title = range.title
        onChange?(options)
    }
}

private final class BrowserLabelClick: NSClickGestureRecognizer {
    weak var box: ChromeCheckbox?
}
