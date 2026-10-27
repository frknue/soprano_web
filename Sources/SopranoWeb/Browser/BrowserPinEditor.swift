import AppKit

/// What the pin editor shows: a heading, the name, the address (only when
/// editing a pin from the sidebar), the folder picker and an optional
/// Remove button.
struct BrowserPinEditorContent: Equatable {
    var heading: String
    var name: String
    var namePlaceholder: String
    /// Nil hides the address field.
    var url: String?
    var folderID: UUID
    /// The folders the item may go to (a folder's own subtree excluded).
    var folders: [BrowserPinFolderEntry]
    /// "Remove" / "Delete"; nil hides the button.
    var removeTitle: String?

    /// The address an edited field saves: trimmed, `https://` added when it
    /// names no scheme (`example.com`, `localhost:8080`); nil (keep the
    /// old one) when empty.
    static func address(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let hasScheme = lower.contains("://")
            || ["about:", "mailto:", "data:", "file:", "javascript:"].contains { lower.hasPrefix($0) }
        return hasScheme ? trimmed : "https://" + trimmed
    }
}

/// The Folio popover body of ⌘D and the sidebar's Edit Bookmark, Rename
/// and New Folder. The folder picker applies at once; Done or Return saves
/// the name (and address), Esc closes without saving them.
@MainActor
final class BrowserPinEditorView: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 300

    var onFolderChange: ((UUID) -> Void)?
    var onDone: ((_ name: String, _ url: String?) -> Void)?
    var onRemove: (() -> Void)?
    var onCancel: (() -> Void)?

    private var theme: AppTheme
    private(set) var content: BrowserPinEditorContent
    private let heading: ChromeEyebrowView
    private let nameFrame: ChromeFieldView
    let nameField = NSTextField()
    private let urlFrame: ChromeFieldView
    private let urlField = NSTextField()
    private let folderLabel = NSTextField(labelWithString: "Folder")
    let folderButton: ChromeButton
    private let removeButton: ChromeButton
    private let doneButton: ChromeButton
    private var urlConstraints: [NSLayoutConstraint] = []
    private var noURLConstraints: [NSLayoutConstraint] = []

    init(theme: AppTheme, content: BrowserPinEditorContent) {
        self.theme = theme
        self.content = content
        heading = ChromeEyebrowView(title: content.heading, theme: theme)
        nameFrame = ChromeFieldView(theme: theme)
        urlFrame = ChromeFieldView(theme: theme)
        folderButton = ChromeButton(title: "", theme: theme, kind: .standard)
        removeButton = ChromeButton(title: "Remove", theme: theme, kind: .text)
        doneButton = ChromeButton(title: "Done", theme: theme, kind: .ink, keycap: "↵")
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 160))
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(heading)
        for (frame, field) in [(nameFrame, nameField), (urlFrame, urlField)] {
            addSubview(frame)
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            frame.addSubview(field)
            NSLayoutConstraint.activate([
                frame.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),
                frame.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.panel),
                frame.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Chrome.Space.panel),
                field.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
            ])
        }
        nameField.setAccessibilityLabel("Name")
        urlField.setAccessibilityLabel("Address")

        folderLabel.translatesAutoresizingMaskIntoConstraints = false
        folderLabel.font = ChromeFont.meta
        addSubview(folderLabel)

        folderButton.target = self
        folderButton.action = #selector(folderPressed)
        folderButton.setAccessibilityLabel("Folder")
        folderButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(folderButton)

        removeButton.target = self
        removeButton.action = #selector(removePressed)
        addSubview(removeButton)
        doneButton.target = self
        doneButton.action = #selector(donePressed)
        addSubview(doneButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.panel),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Chrome.Space.panel),

            nameFrame.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            urlFrame.topAnchor.constraint(equalTo: nameFrame.bottomAnchor, constant: 8),

            folderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.panel),
            folderLabel.centerYAnchor.constraint(equalTo: folderButton.centerYAnchor),
            folderButton.leadingAnchor.constraint(equalTo: folderLabel.trailingAnchor, constant: 10),
            folderButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Chrome.Space.panel),

            doneButton.topAnchor.constraint(equalTo: folderButton.bottomAnchor, constant: 14),
            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Chrome.Space.panel),
            doneButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            removeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.panel - ChromeButton.horizontalPadding),
            removeButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
        ])
        urlConstraints = [folderButton.topAnchor.constraint(equalTo: urlFrame.bottomAnchor, constant: 10)]
        noURLConstraints = [folderButton.topAnchor.constraint(equalTo: nameFrame.bottomAnchor, constant: 10)]

        configure(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ content: BrowserPinEditorContent) {
        self.content = content
        heading.title = content.heading
        nameField.stringValue = content.name
        let showsURL = content.url != nil
        urlField.stringValue = content.url ?? ""
        urlFrame.isHidden = !showsURL
        NSLayoutConstraint.deactivate(showsURL ? noURLConstraints : urlConstraints)
        NSLayoutConstraint.activate(showsURL ? urlConstraints : noURLConstraints)
        removeButton.isHidden = content.removeTitle == nil
        removeButton.title = content.removeTitle ?? ""
        refreshFolderTitle()
        apply(theme: theme)
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        heading.apply(theme: theme)
        nameFrame.apply(theme: theme)
        urlFrame.apply(theme: theme)
        for (field, placeholder) in [(nameField, content.namePlaceholder), (urlField, "Address")] {
            ChromeFieldView.styleEmbedded(field, colors: colors, font: ChromeFont.label)
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: colors.textMuted, .font: ChromeFont.label]
            )
        }
        folderLabel.textColor = colors.textMuted
        for button in [folderButton, removeButton, doneButton] {
            button.apply(theme: theme)
        }
        needsDisplay = true
    }

    /// The popover surface, drawn rather than a layer so an offscreen
    /// capture shows it.
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Chrome.Radius.popover,
            yRadius: Chrome.Radius.popover
        )
        theme.colors.raised.setFill()
        shape.fill()
        theme.colors.borderStrong.setStroke()
        shape.lineWidth = Chrome.hairline
        shape.stroke()
    }

    private var folderName: String {
        content.folders.first { $0.id == content.folderID }?.name ?? BrowserPinTree.rootName
    }

    private func refreshFolderTitle() {
        folderButton.title = "\(folderName) ▾"
    }

    /// The folder menu: every folder indented under "Bookmarks", the
    /// current one checked.
    func folderMenu() -> NSMenu {
        let menu = NSMenu()
        let image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        for folder in content.folders {
            let item = NSMenuItem(title: folder.name, action: #selector(folderChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = folder.id
            item.indentationLevel = min(folder.depth, 15)
            item.image = image
            item.state = folder.id == content.folderID ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func folderPressed() {
        folderMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: folderButton.bounds.height + 4), in: folderButton)
    }

    @objc private func folderChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, id != content.folderID else { return }
        content.folderID = id
        refreshFolderTitle()
        onFolderChange?(id)
    }

    @objc private func removePressed() {
        onRemove?()
    }

    @objc func donePressed() {
        onDone?(nameField.stringValue, content.url == nil ? nil : urlField.stringValue)
    }

    func cancel() {
        onCancel?()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        ChromeFieldView.styleEditor(of: field, colors: theme.colors)
        (field === nameField ? nameFrame : urlFrame).isFocused = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        (field === nameField ? nameFrame : urlFrame).isFocused = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            donePressed()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    /// Where the popover goes: under `anchor` (both in the same unflipped
    /// coordinates), its trailing edge on the anchor's, kept inside
    /// `bounds`.
    static func frame(size: NSSize, below anchor: NSRect, within bounds: NSRect) -> NSRect {
        var x = anchor.maxX - size.width + 6
        x = min(max(x, bounds.minX + 8), bounds.maxX - size.width - 8)
        return NSRect(x: x, y: anchor.minY - 4 - size.height, width: size.width, height: size.height).integral
    }
}

/// The borderless child panel that floats the editor under its anchor.
/// Clicking elsewhere saves and closes it, like Done.
@MainActor
final class BrowserPinEditorPanel: NSPanel {
    private weak var hostWindow: NSWindow?
    private var editor: BrowserPinEditorView?
    private var isClosing = false
    /// When it last closed because another window took the click; the
    /// star ignores the click that closed it.
    private(set) var lastResignedAt: Date?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: BrowserPinEditorView.width, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        collectionBehavior = [.fullScreenAuxiliary]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var isShown: Bool { editor != nil }

    /// Floats `editor` under `anchor` in `hostWindow` and focuses the name.
    func show(_ editor: BrowserPinEditorView, below anchor: NSView, in hostWindow: NSWindow) {
        close(saving: false)
        isClosing = false
        self.editor = editor
        self.hostWindow = hostWindow
        contentView = editor
        editor.layoutSubtreeIfNeeded()
        let size = editor.fittingSize
        let anchorRect = hostWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        setFrame(
            BrowserPinEditorView.frame(size: size, below: anchorRect, within: hostWindow.frame),
            display: true
        )
        hostWindow.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(editor.nameField)
        editor.nameField.currentEditor()?.selectAll(nil)
    }

    /// Closes it; `saving` runs the editor's Done first.
    func close(saving: Bool) {
        guard let editor, !isClosing else { return }
        isClosing = true
        if saving {
            editor.donePressed()
        }
        self.editor = nil
        hostWindow?.removeChildWindow(self)
        orderOut(nil)
        contentView = nil
        hostWindow = nil
        isClosing = false
    }

    override func cancelOperation(_ sender: Any?) {
        editor?.cancel()
    }

    override func resignKey() {
        super.resignKey()
        guard editor != nil, !isClosing else { return }
        lastResignedAt = Date()
        close(saving: true)
    }
}
