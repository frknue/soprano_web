import AppKit

/// A small floating URL/search entry, modeled on Vimium's omnibar.
@MainActor
final class VimiumPromptPanel: NSPanel, NSTextFieldDelegate {
    private let surface = NSView()
    private let fieldFrame: ChromeFieldView
    private let field = NSTextField()
    private var theme: AppTheme
    private weak var hostWindow: NSWindow?
    private var onSubmit: ((String) -> Void)?
    private var onCancel: (() -> Void)?
    private var isDismissing = false

    private static let width: CGFloat = 680

    init(theme: AppTheme) {
        self.theme = theme
        self.fieldFrame = ChromeFieldView(theme: theme)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 58),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        collectionBehavior = [.fullScreenAuxiliary]
        animationBehavior = .utilityWindow

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.wantsLayer = true
        contentView = surface

        fieldFrame.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(fieldFrame)

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false
        fieldFrame.addSubview(field)
        ChromeFieldView.styleEmbedded(field, colors: theme.colors, font: ChromeFont.paletteQuery)

        NSLayoutConstraint.activate([
            fieldFrame.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
            fieldFrame.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
            fieldFrame.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            fieldFrame.heightAnchor.constraint(equalToConstant: 34),

            field.leadingAnchor.constraint(equalTo: fieldFrame.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: fieldFrame.trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: fieldFrame.centerYAnchor),
        ])

        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func apply(theme: AppTheme) {
        self.theme = theme
        surface.layer?.backgroundColor = theme.colors.raised.cgColor
        surface.layer?.cornerRadius = Chrome.Radius.popover
        surface.layer?.borderWidth = Chrome.hairline
        surface.layer?.borderColor = theme.colors.borderStrong.cgColor
        fieldFrame.apply(theme: theme)
        ChromeFieldView.styleEmbedded(field, colors: theme.colors, font: ChromeFont.paletteQuery)
    }

    func show(
        relativeTo hostWindow: NSWindow,
        initialText: String,
        placeholder: String,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.hostWindow = hostWindow
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        isDismissing = false

        field.stringValue = initialText
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: theme.colors.textMuted,
                .font: ChromeFont.paletteQuery,
            ]
        )

        let parentFrame = hostWindow.frame
        let width = min(Self.width, parentFrame.width - 48)
        let x = parentFrame.midX - width / 2
        let y = parentFrame.maxY - 118
        setFrame(NSRect(x: x, y: y, width: width, height: 58), display: true)

        hostWindow.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func dismiss(cancelled: Bool = false) {
        guard !isDismissing else { return }
        isDismissing = true
        let cancel = onCancel
        onSubmit = nil
        onCancel = nil
        if let hostWindow {
            hostWindow.removeChildWindow(self)
        }
        orderOut(nil)
        hostWindow = nil
        if cancelled {
            cancel?()
        }
    }

    override func resignKey() {
        super.resignKey()
        dismiss(cancelled: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss(cancelled: true)
            return true
        }
        return false
    }

    @objc private func submit() {
        let value = field.stringValue
        let handler = onSubmit
        dismiss(cancelled: false)
        handler?(value)
    }
}

/// A Folio text sheet for Vimium help and view-source output.
@MainActor
final class VimiumTextPanel: NSPanel {
    private let surface = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton: ChromeIconButton
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private var theme: AppTheme
    private weak var hostWindow: NSWindow?
    private var keyMonitor: Any?
    private var onDismiss: (() -> Void)?
    private var isDismissing = false

    init(theme: AppTheme) {
        self.theme = theme
        self.closeButton = ChromeIconButton(
            symbolName: "xmark",
            accessibilityLabel: "Close",
            pointSize: 11,
            size: 22,
            target: nil,
            action: nil
        )
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.fullScreenAuxiliary]

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.wantsLayer = true
        contentView = surface

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(titleLabel)

        closeButton.target = self
        closeButton.action = #selector(closePressed)
        surface.addSubview(closeButton)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        surface.addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 14)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: surface.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),

            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -18),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -12),
        ])

        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func apply(theme: AppTheme) {
        self.theme = theme
        surface.layer?.backgroundColor = theme.colors.raised.cgColor
        surface.layer?.cornerRadius = Chrome.Radius.popover
        surface.layer?.borderWidth = Chrome.hairline
        surface.layer?.borderColor = theme.colors.borderStrong.cgColor
        titleLabel.font = ChromeFont.screen
        titleLabel.textColor = theme.colors.textPrimary
        closeButton.apply(theme: theme)
        textView.font = ChromeFont.mono
        textView.textColor = theme.colors.textPrimary
        textView.insertionPointColor = theme.colors.caret
        textView.selectedTextAttributes = [.backgroundColor: theme.colors.textSelection]
    }

    func show(
        relativeTo hostWindow: NSWindow,
        title: String,
        text: String,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.title = title
        self.hostWindow = hostWindow
        self.onDismiss = onDismiss
        isDismissing = false
        titleLabel.stringValue = title
        textView.string = text

        let size = NSSize(
            width: min(780, max(420, hostWindow.frame.width - 120)),
            height: min(600, max(320, hostWindow.frame.height - 160))
        )
        let frame = NSRect(
            x: hostWindow.frame.midX - size.width / 2,
            y: hostWindow.frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        setFrame(frame, display: true)

        hostWindow.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(textView)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.dismiss()
            return nil
        }
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let hostWindow {
            hostWindow.removeChildWindow(self)
        }
        orderOut(nil)
        hostWindow = nil
        let handler = onDismiss
        onDismiss = nil
        handler?()
    }

    @objc private func closePressed() {
        dismiss()
    }

    private func layoutTextView() {
        surface.layoutSubtreeIfNeeded()
        let width = max(1, scrollView.contentSize.width)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: .greatestFiniteMagnitude
        )
        textView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: max(1, scrollView.contentSize.height)
        )
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
            + textView.textContainerInset.height * 2
        textView.frame.size.height = max(scrollView.contentSize.height, used)
    }
}
