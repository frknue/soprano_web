import AppKit

/// The in-page find bar. It slides in above the page without changing the
/// web view's frame, so the page does not reflow.
@MainActor
final class BrowserFindBar: NSView, NSTextFieldDelegate {
    var onQueryChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let fieldFrame: ChromeFieldView
    private let resultLabel = NSTextField(labelWithString: "")
    private let previousButton: ChromeIconButton
    private let nextButton: ChromeIconButton
    private let closeButton: ChromeIconButton
    private var theme: AppTheme

    static let preferredHeight: CGFloat = 40

    init(theme: AppTheme) {
        self.theme = theme
        self.fieldFrame = ChromeFieldView(theme: theme)
        self.previousButton = ChromeIconButton(
            symbolName: "chevron.up",
            accessibilityLabel: "Previous Match",
            pointSize: 10,
            size: 22,
            target: nil,
            action: nil
        )
        self.nextButton = ChromeIconButton(
            symbolName: "chevron.down",
            accessibilityLabel: "Next Match",
            pointSize: 10,
            size: 22,
            target: nil,
            action: nil
        )
        self.closeButton = ChromeIconButton(
            symbolName: "xmark",
            accessibilityLabel: "Close Find Bar",
            pointSize: 10,
            size: 22,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderAttributedString = NSAttributedString(
            string: "Find in page",
            attributes: [
                .foregroundColor: theme.colors.textMuted,
                .font: ChromeFont.label,
            ]
        )

        resultLabel.translatesAutoresizingMaskIntoConstraints = false
        resultLabel.font = ChromeFont.meta
        resultLabel.textColor = theme.colors.textMuted
        resultLabel.lineBreakMode = .byTruncatingTail

        for button in [previousButton, nextButton, closeButton] {
            button.target = self
            addSubview(button)
        }
        previousButton.action = #selector(previousPressed)
        nextButton.action = #selector(nextPressed)
        closeButton.action = #selector(closePressed)
        previousButton.toolTip = "Previous match (⇧⏎)"
        nextButton.toolTip = "Next match (⏎)"
        closeButton.toolTip = "Close (esc)"

        addSubview(fieldFrame)
        fieldFrame.addSubview(field)
        addSubview(resultLabel)

        NSLayoutConstraint.activate([
            fieldFrame.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            fieldFrame.centerYAnchor.constraint(equalTo: centerYAnchor),
            fieldFrame.heightAnchor.constraint(equalToConstant: 26),
            fieldFrame.widthAnchor.constraint(equalToConstant: 280),

            field.leadingAnchor.constraint(equalTo: fieldFrame.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: fieldFrame.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: fieldFrame.centerYAnchor),

            resultLabel.leadingAnchor.constraint(equalTo: fieldFrame.trailingAnchor, constant: 8),
            resultLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            resultLabel.trailingAnchor.constraint(lessThanOrEqualTo: previousButton.leadingAnchor, constant: -8),

            previousButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -2),
            previousButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.colors.bgPanel.setFill()
        bounds.fill()
        theme.colors.borderSubtle.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Chrome.hairline).fill()
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        fieldFrame.apply(theme: theme)
        ChromeFieldView.styleEmbedded(field, colors: theme.colors, font: ChromeFont.label)
        field.placeholderAttributedString = NSAttributedString(
            string: "Find in page",
            attributes: [
                .foregroundColor: theme.colors.textMuted,
                .font: ChromeFont.label,
            ]
        )
        resultLabel.textColor = theme.colors.textMuted
        for button in [previousButton, nextButton, closeButton] {
            button.apply(theme: theme)
        }
        needsDisplay = true
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// The field's text, set without reporting a change.
    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    func setResult(found: Bool, hasQuery: Bool) {
        if !hasQuery {
            resultLabel.stringValue = ""
        } else {
            resultLabel.stringValue = found ? "Match found" : "No matches"
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        onQueryChanged?(field.stringValue)
    }

    @objc private func previousPressed() {
        onPrevious?()
    }

    @objc private func nextPressed() {
        onNext?()
    }

    @objc private func closePressed() {
        onClose?()
    }
}
