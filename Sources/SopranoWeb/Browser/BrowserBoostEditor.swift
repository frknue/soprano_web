import AppKit

/// The Boost editor: a sheet with the Boost's name, an enabled switch and
/// monospace text views for its CSS, JavaScript and zapped selectors (one
/// per line). Save writes the Boost; CSS and hidden elements apply to open
/// pages at once, JavaScript from the next load.
@MainActor
final class BrowserBoostEditor: NSObject {
    var onSave: ((BrowserBoost) -> Void)?
    var onDelete: ((String) -> Void)?
    var onZap: (() -> Void)?
    var onClose: (() -> Void)?

    let host: String
    let window: NSWindow
    let nameField = NSTextField()
    let enabledSwitch = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    let cssView = BrowserBoostEditor.codeView()
    let jsView = BrowserBoostEditor.codeView()
    let zapView = BrowserBoostEditor.codeView()
    private var original: BrowserBoost

    init(boost: BrowserBoost, theme: AppTheme) {
        host = boost.host
        original = boost
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.appearance = theme.appearance.nsAppearance
        window.contentView = makeContent()
        load(boost)
    }

    /// The Boost as edited.
    var edited: BrowserBoost {
        var boost = original
        boost.name = nameField.stringValue
        boost.isEnabled = enabledSwitch.state == .on
        boost.css = cssView.string
        boost.js = jsView.string
        boost.zaps = zapView.string.split(whereSeparator: \.isNewline).map(String.init)
        return boost
    }

    func present(on parent: NSWindow) {
        parent.beginSheet(window) { [weak self] _ in
            self?.onClose?()
        }
        window.makeFirstResponder(cssView)
    }

    /// The store changed (a zap, the CLI): the zap list follows; other
    /// fields keep the user's edits.
    func refreshZaps(_ zaps: [String]) {
        original.zaps = zaps
        zapView.string = zaps.joined(separator: "\n")
    }

    func save() {
        onSave?(edited)
        end()
    }

    @objc private func savePressed() { save() }
    @objc private func cancelPressed() { end() }

    @objc private func deletePressed() {
        onDelete?(host)
        end()
    }

    @objc private func zapPressed() {
        onSave?(edited)
        end()
        onZap?()
    }

    private func end() {
        window.sheetParent?.endSheet(window)
    }

    private func load(_ boost: BrowserBoost) {
        nameField.stringValue = boost.name
        enabledSwitch.state = boost.isEnabled ? .on : .off
        cssView.string = boost.css
        jsView.string = boost.js
        zapView.string = boost.zaps.joined(separator: "\n")
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: "Boost for \(host)")
        title.font = .boldSystemFont(ofSize: 13)
        nameField.placeholderString = "Name"
        nameField.setAccessibilityLabel("Boost name")
        let header = NSStackView(views: [nameField, enabledSwitch])
        header.spacing = 12

        let zap = button("Zap Elements…", #selector(zapPressed))
        let delete = button("Delete Boost", #selector(deletePressed))
        let cancel = button("Cancel", #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let save = button("Save", #selector(savePressed))
        save.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [zap, delete, spacer, cancel, save])
        buttons.spacing = 8

        let stack = NSStackView(views: [
            title, header,
            caption("CSS (added to the page at document start)"), scroll(cssView, height: 150, label: "CSS"),
            caption("JavaScript (runs from the next page load)"), scroll(jsView, height: 150, label: "JavaScript"),
            caption("Zapped elements (one CSS selector per line, hidden)"), scroll(zapView, height: 70, label: "Zapped elements"),
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        for view in stack.arrangedSubviews where view is NSScrollView {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 560),
        ])
        return content
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func scroll(_ textView: NSTextView, height: CGFloat, label: String) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        textView.setAccessibilityLabel(label)
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private static func codeView() -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 4, height: 4)
        return view
    }
}
