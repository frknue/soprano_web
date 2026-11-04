import AppKit

/// The Agent panel at the window's right edge (⌘E): the chat with omp
/// over the window's pages, and the composer. The chat is one selectable
/// text view, each entry rendered once per revision; the composer sends
/// on Return (⇧Return is a new line) along with the selected tab, unless
/// the page button is off.
@MainActor
final class BrowserAgentPanelView: NSView, NSTextViewDelegate {
    static let width: CGFloat = 380

    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onClose: (() -> Void)?
    /// The header's gear: Settings ▸ Agent.
    var onSettings: (() -> Void)?

    /// Whether a message carries the selected tab (the page button).
    private(set) var includesPage = true
    /// The selected tab's title on the page button; nil hides it.
    var pageTitle: String? {
        didSet { updatePageButton() }
    }

    private var theme: AppTheme
    private let divider: ChromeRuleView
    private let titleLabel = NSTextField(labelWithString: "Agent")
    private let statusLabel = NSTextField(labelWithString: "")
    private let settingsButton: ChromeIconButton
    private let newChatButton: ChromeIconButton
    private let closeButton: ChromeIconButton
    private let scrollView = NSScrollView()
    private let transcriptView = NSTextView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let composerFrame: ChromeFieldView
    private let composerScroll = NSScrollView()
    let composer = BrowserAgentComposerView()
    private let placeholderLabel = NSTextField(labelWithString: "Ask the agent…")
    private let pageButton: ChromeButton
    private let stopButton: ChromeButton
    private let sendButton: ChromeButton

    private var transcript = BrowserAgentTranscript()
    private var statusText = ""
    /// Each entry's rendering, by id, with the revision and lead it was
    /// rendered for.
    private var rendered: [Int: (revision: Int, lead: Bool, text: NSAttributedString)] = [:]
    private var renderScheduled = false

    init(theme: AppTheme) {
        self.theme = theme
        divider = ChromeRuleView(axis: .vertical, color: theme.colors.borderSubtle)
        settingsButton = ChromeIconButton(
            symbolName: "gearshape",
            accessibilityLabel: "Agent Settings",
            pointSize: 12,
            size: 22,
            target: nil,
            action: nil
        )
        newChatButton = ChromeIconButton(
            symbolName: "square.and.pencil",
            accessibilityLabel: "New Chat",
            pointSize: 12,
            size: 22,
            target: nil,
            action: nil
        )
        closeButton = ChromeIconButton(
            symbolName: "xmark",
            accessibilityLabel: "Close Agent",
            pointSize: 10,
            size: 22,
            target: nil,
            action: nil
        )
        composerFrame = ChromeFieldView(theme: theme)
        pageButton = ChromeButton(title: "", theme: theme, kind: .standard)
        stopButton = ChromeButton(title: "Stop", theme: theme, kind: .text)
        sendButton = ChromeButton(title: "Send", theme: theme, kind: .ink, keycap: "↵")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = ChromeFont.screen
        addSubview(titleLabel)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = ChromeFont.meta
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)

        settingsButton.toolTip = "Agent settings: model, thinking, working folder"
        newChatButton.toolTip = "New chat (⇧⌘E)"
        for (button, action) in [
            (settingsButton, #selector(settingsPressed)),
            (newChatButton, #selector(newChatPressed)),
            (closeButton, #selector(closePressed)),
        ] {
            button.target = self
            button.action = action
            addSubview(button)
        }

        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.drawsBackground = false
        transcriptView.textContainerInset = NSSize(width: 12, height: 8)
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptView.setAccessibilityLabel("Agent chat")
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = transcriptView
        addSubview(scrollView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = ChromeFont.empty
        emptyLabel.alignment = .center
        emptyLabel.stringValue = "Ask about this page, or have the agent click, fill and browse for you."
        addSubview(emptyLabel)

        addSubview(composerFrame)
        composer.delegate = self
        composer.isRichText = false
        composer.allowsUndo = true
        composer.drawsBackground = false
        composer.font = ChromeFont.row
        composer.textContainerInset = NSSize(width: 4, height: 6)
        composer.isVerticallyResizable = true
        composer.isHorizontallyResizable = false
        composer.autoresizingMask = [.width]
        composer.textContainer?.widthTracksTextView = true
        composer.isAutomaticQuoteSubstitutionEnabled = false
        composer.isAutomaticDashSubstitutionEnabled = false
        composer.setAccessibilityLabel("Message")
        composer.onSubmit = { [weak self] in self?.submit() }
        composer.onFocusChange = { [weak self] focused in self?.composerFrame.isFocused = focused }
        composerScroll.translatesAutoresizingMaskIntoConstraints = false
        composerScroll.drawsBackground = false
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.documentView = composer
        composerFrame.addSubview(composerScroll)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = ChromeFont.row
        composerFrame.addSubview(placeholderLabel)

        pageButton.target = self
        pageButton.action = #selector(pagePressed)
        pageButton.lineBreakMode = .byTruncatingTail
        addSubview(pageButton)
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        addSubview(stopButton)
        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        addSubview(sendButton)

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.widthAnchor.constraint(equalToConstant: Chrome.hairline),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: settingsButton.leadingAnchor, constant: -8),

            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            newChatButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            newChatButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            settingsButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: newChatButton.leadingAnchor, constant: -4),

            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: composerFrame.topAnchor, constant: -10),

            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),

            composerFrame.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            composerFrame.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            composerFrame.heightAnchor.constraint(equalToConstant: 84),
            composerFrame.bottomAnchor.constraint(equalTo: sendButton.topAnchor, constant: -8),

            composerScroll.topAnchor.constraint(equalTo: composerFrame.topAnchor, constant: 2),
            composerScroll.leadingAnchor.constraint(equalTo: composerFrame.leadingAnchor, constant: 4),
            composerScroll.trailingAnchor.constraint(equalTo: composerFrame.trailingAnchor, constant: -2),
            composerScroll.bottomAnchor.constraint(equalTo: composerFrame.bottomAnchor, constant: -2),

            placeholderLabel.topAnchor.constraint(equalTo: composerFrame.topAnchor, constant: 8),
            placeholderLabel.leadingAnchor.constraint(equalTo: composerFrame.leadingAnchor, constant: 13),

            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stopButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            stopButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),

            pageButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            pageButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            pageButton.trailingAnchor.constraint(lessThanOrEqualTo: stopButton.leadingAnchor, constant: -8),
        ])
        pageButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        apply(theme: theme)
        update(BrowserAgentTranscript(), status: "omp")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        layer?.backgroundColor = colors.bgPanel.cgColor
        divider.color = colors.borderSubtle
        titleLabel.textColor = colors.textPrimary
        statusLabel.textColor = colors.textMuted
        emptyLabel.textColor = colors.textMuted
        placeholderLabel.textColor = colors.textMuted
        settingsButton.apply(theme: theme)
        newChatButton.apply(theme: theme)
        closeButton.apply(theme: theme)
        composerFrame.apply(theme: theme)
        composer.textColor = colors.textPrimary
        composer.insertionPointColor = colors.caret
        composer.selectedTextAttributes = [.backgroundColor: colors.textSelection]
        transcriptView.selectedTextAttributes = [.backgroundColor: colors.textSelection]
        transcriptView.linkTextAttributes = [
            .foregroundColor: colors.textPrimary,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        for button in [pageButton, stopButton, sendButton] {
            button.apply(theme: theme)
        }
        rendered.removeAll()
        render()
    }

    /// Shows `transcript`; `status` is the line under the title (omp's
    /// state or what the agent does).
    func update(_ transcript: BrowserAgentTranscript, status: String) {
        self.transcript = transcript
        statusText = status
        statusLabel.stringValue = status
        stopButton.isHidden = !transcript.isWorking
        emptyLabel.isHidden = !transcript.isEmpty
        scheduleRender()
    }

    func focusComposer() {
        window?.makeFirstResponder(composer)
    }

    var isComposerFocused: Bool {
        window?.firstResponder === composer
    }

    /// Text typed into the composer (the harness).
    func setDraft(_ text: String) {
        composer.string = text
        textDidChange(Notification(name: NSText.didChangeNotification, object: composer))
    }

    // MARK: Actions

    private func submit() {
        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composer.string = ""
        placeholderLabel.isHidden = false
        onSend?(text)
    }

    @objc private func sendPressed() { submit() }
    @objc private func stopPressed() { onStop?() }
    @objc private func newChatPressed() { onNewChat?() }
    @objc private func settingsPressed() { onSettings?() }

    /// The page button's state for a new chat (Settings ▸ Agent).
    func setIncludesPage(_ on: Bool) {
        includesPage = on
        updatePageButton()
    }
    @objc private func closePressed() { onClose?() }

    @objc private func pagePressed() {
        includesPage.toggle()
        updatePageButton()
    }

    private func updatePageButton() {
        guard let pageTitle else {
            pageButton.isHidden = true
            return
        }
        pageButton.isHidden = false
        let short = pageTitle.count > 28 ? String(pageTitle.prefix(27)) + "…" : pageTitle
        pageButton.title = includesPage ? short : "No page"
        pageButton.kind = includesPage ? .standard : .text
        pageButton.toolTip = includesPage
            ? "The message includes this tab: \(pageTitle). Click to send without it."
            : "Click to include the selected tab with the message."
    }

    func textDidChange(_ notification: Notification) {
        placeholderLabel.isHidden = !composer.string.isEmpty
    }

    // MARK: Rendering

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        // Deltas arrive many times a second: one render per run loop turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.renderScheduled = false
                self?.render()
            }
        }
    }

    private func render() {
        let clip = scrollView.contentView
        let atBottom = clip.bounds.maxY >= transcriptView.frame.height - 24
        let output = NSMutableAttributedString()
        var previous: BrowserAgentTranscript.Kind?
        var live = Set<Int>()
        for entry in transcript.entries {
            // The speaker's eyebrow opens each turn: the user's message,
            // then the agent's text and tool calls together.
            let isAgent = entry.kind == .assistant || entry.kind == .tool
            let wasAgent = previous == .assistant || previous == .tool
            let lead = entry.kind == .user || (isAgent && !wasAgent)
            live.insert(entry.id)
            let piece: NSAttributedString
            if let cached = rendered[entry.id], cached.revision == entry.revision, cached.lead == lead {
                piece = cached.text
            } else {
                piece = BrowserAgentRenderer.render(entry, lead: lead, first: previous == nil, colors: theme.colors)
                rendered[entry.id] = (entry.revision, lead, piece)
            }
            output.append(piece)
            previous = entry.kind
        }
        rendered = rendered.filter { live.contains($0.key) }
        transcriptView.textStorage?.setAttributedString(output)
        if atBottom || transcript.isWorking {
            transcriptView.scrollToEndOfDocument(nil)
        }
    }

    /// The chat as the panel shows it (the harness).
    var renderedText: String { transcriptView.string }
}

/// The composer: Return sends, ⇧Return or ⌥Return types a new line, and
/// an input method's marked text keeps Return for itself.
@MainActor
final class BrowserAgentComposerView: NSTextView {
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isReturn, !hasMarkedText(), modifiers.isDisjoint(with: [.shift, .option, .command, .control]) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

/// One chat entry as styled text: the speaker's eyebrow at a turn's start,
/// the user's text, the agent's Markdown (inline: bold, italic, code,
/// links), a tool call as its intent over its command, a note in italics.
@MainActor
enum BrowserAgentRenderer {
    static func render(
        _ entry: BrowserAgentTranscript.Entry,
        lead: Bool,
        first: Bool,
        colors: ThemeColors
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let gap: CGFloat = first ? 0 : (lead ? 18 : 8)
        if lead {
            let speaker = entry.kind == .user ? "You" : "Agent"
            let head = NSMutableAttributedString(attributedString: ChromeText.eyebrow(speaker, color: colors.textMuted))
            if entry.kind == .user, let page = entry.detail, !page.isEmpty {
                head.append(ChromeText.attributed("  \(page)", font: ChromeFont.meta, color: colors.textMuted))
            }
            output.append(paragraph(head, before: gap, after: 4, wraps: false))
        }
        let before = lead ? 0 : gap
        switch entry.kind {
        case .user:
            output.append(paragraph(
                ChromeText.attributed(entry.text, font: ChromeFont.row, color: colors.textPrimary, lineBreakMode: .byWordWrapping),
                before: before
            ))
        case .assistant:
            output.append(paragraph(markdown(entry.text, colors: colors), before: before))
        case .tool:
            let mark: String
            let markColor: NSColor
            switch entry.toolState {
            case .running: mark = "◦"; markColor = colors.textMuted
            case .done: mark = "✓"; markColor = colors.success
            case .failed: mark = "✕"; markColor = colors.danger
            }
            let line = NSMutableAttributedString(attributedString: ChromeText.attributed(
                "\(mark) ",
                font: ChromeFont.label,
                color: markColor
            ))
            let failure = entry.toolState == .failed ? entry.failure : nil
            let intent = entry.detail
            if let intent {
                line.append(ChromeText.attributed(intent, font: ChromeFont.label, color: colors.textMuted))
                line.append(ChromeText.attributed(
                    Self.lineBreak + entry.text,
                    font: ChromeFont.monoSmall,
                    color: colors.textMuted,
                    lineBreakMode: .byCharWrapping
                ))
            } else {
                line.append(ChromeText.attributed(
                    entry.text,
                    font: ChromeFont.monoSmall,
                    color: colors.textMuted,
                    lineBreakMode: .byCharWrapping
                ))
            }
            if let failure {
                line.append(ChromeText.attributed(
                    Self.lineBreak + failure,
                    font: ChromeFont.monoSmall,
                    color: colors.danger,
                    lineBreakMode: .byCharWrapping
                ))
            }
            output.append(paragraph(line, before: before, indent: 14))
        case .note:
            output.append(paragraph(
                ChromeText.attributed(
                    entry.text,
                    font: italic(ChromeFont.label),
                    color: colors.textMuted,
                    lineBreakMode: .byWordWrapping
                ),
                before: first ? 0 : 12
            ))
        }
        return output
    }

    /// Inline Markdown with its line breaks kept (a blank line between
    /// paragraphs becomes paragraph spacing); text that isn't Markdown
    /// shows as written.
    static func markdown(_ text: String, colors: ThemeColors) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let text = text.replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return ChromeText.attributed(text, font: ChromeFont.row, color: colors.textPrimary, lineBreakMode: .byWordWrapping)
        }
        let output = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var font = ChromeFont.row
            if intent.contains(.code) {
                font = ChromeFont.mono
            } else if intent.contains(.stronglyEmphasized) && intent.contains(.emphasized) {
                font = italic(ChromeFont.sans(size: 13, weight: .semibold))
            } else if intent.contains(.stronglyEmphasized) {
                font = ChromeFont.sans(size: 13, weight: .semibold)
            } else if intent.contains(.emphasized) {
                font = italic(ChromeFont.row)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: colors.textPrimary,
            ]
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            // Web and mail links only: a `file:` link would open (or launch)
            // whatever it names.
            if let link = run.link, ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                attributes[.link] = link
            }
            output.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return output
    }

    /// A line break inside one paragraph (a tool call's lines keep its
    /// indent and spacing).
    private static let lineBreak = "\u{2028}"

    private static func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    /// `text` as its own paragraphs (a trailing newline): `before` over the
    /// first, 8 pt between the others, `after` under the last; lines after
    /// a tool call's mark indent by `indent`. A line that doesn't wrap is
    /// cut with an ellipsis.
    private static func paragraph(
        _ text: NSAttributedString,
        before: CGFloat = 0,
        after: CGFloat = 0,
        indent: CGFloat = 0,
        wraps: Bool = true
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: text)
        output.append(NSAttributedString(string: "\n", attributes: text.length > 0
            ? text.attributes(at: text.length - 1, effectiveRange: nil)
            : [:]))
        let string = output.string as NSString
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = location == 0 ? before : 8
            style.paragraphSpacing = NSMaxRange(range) >= string.length ? after : 0
            style.lineSpacing = 2
            style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
            style.headIndent = indent
            output.addAttribute(.paragraphStyle, value: style, range: range)
            location = NSMaxRange(range)
        }
        return output
    }
}
