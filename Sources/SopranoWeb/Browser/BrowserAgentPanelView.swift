import AppKit

/// The Agent panel at the window's right edge (⌘E): the chat with omp
/// over the window's pages, and the composer. The header names the chat
/// (its first message). The chat is one selectable text view
/// (`BrowserAgentRenderer`): the user's messages in bubbles with their tab
/// as a card, each agent run as "Worked for 16s ›" over its answer, the
/// steps shown on a click. The composer sends on Return (⇧Return is a new
/// line) along with the selected tab, unless the page chip is off; its
/// model chip opens Settings ▸ Agent, and its round button sends, or stops
/// a run while nothing is typed.
@MainActor
final class BrowserAgentPanelView: NSView, NSTextViewDelegate {
    static let width: CGFloat = 380

    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onClose: (() -> Void)?
    /// The model chip: Settings ▸ Agent.
    var onSettings: (() -> Void)?

    /// Whether a message carries the selected tab (the page chip).
    private(set) var includesPage = true
    /// The selected tab's title on the page chip; nil hides it.
    var pageTitle: String? {
        didSet { updatePageButton() }
    }

    private var theme: AppTheme
    private let divider: ChromeRuleView
    private let titleLabel = NSTextField(labelWithString: "Agent")
    private let newChatButton: ChromeIconButton
    private let closeButton: ChromeIconButton
    private let scrollView = NSScrollView()
    /// TextKit 1, so `BrowserAgentLayoutManager` draws the bubbles and
    /// cards; the storage owns the layout manager and its container.
    private let transcriptStorage = NSTextStorage()
    private let transcriptView: NSTextView
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let composerFrame = BrowserAgentComposerFrame()
    private let composerScroll = NSScrollView()
    let composer = BrowserAgentComposerView()
    private let placeholderLabel = NSTextField(labelWithString: "Ask the agent…")
    private let pageButton: ChromeButton
    private let modelButton: ChromeButton
    private let spinner = NSProgressIndicator()
    private let sendButton = BrowserAgentSendButton()
    private var composerHeight: NSLayoutConstraint!

    private var transcript = BrowserAgentTranscript()
    /// The tabs' icons by address, for the cards over the messages.
    private var pageIcons: [String: NSImage] = [:]
    /// Runs whose steps show, by run id.
    private var expandedRuns = Set<Int>()
    /// The run whose answer was just copied (its footer shows a check).
    private var copiedRun: Int?
    /// Each run's answer as Copy puts it on the pasteboard.
    private var answers: [Int: String] = [:]
    /// The click a link and its attachment both report, handled once.
    private var lastAction: (url: URL, time: TimeInterval)?
    private var cache = RenderCache(width: 0)
    private var renderScheduled = false

    private static let composerFont = ChromeFont.sans(size: 14)
    private static let composerInset = NSSize(width: 4, height: 2)
    private static let composerMaxHeight: CGFloat = 160
    /// A message after this long a pause gets the time over it.
    private static let stampPause: TimeInterval = 15 * 60

    /// Rendered pieces by entry, revision and placement; a render keeps
    /// the ones it used.
    private struct RenderCache {
        struct Key: Hashable {
            var id: Int
            var revision: Int
            var part: Int
            var before: CGFloat
        }

        let width: CGFloat
        var pieces: [Key: NSAttributedString] = [:]
    }

    init(theme: AppTheme) {
        self.theme = theme
        divider = ChromeRuleView(axis: .vertical, color: theme.colors.borderSubtle)
        newChatButton = ChromeIconButton(
            symbolName: "square.and.pencil",
            accessibilityLabel: "New Chat",
            pointSize: 13,
            size: 26,
            target: nil,
            action: nil
        )
        closeButton = ChromeIconButton(
            symbolName: "xmark",
            accessibilityLabel: "Close Agent",
            pointSize: 11,
            size: 26,
            target: nil,
            action: nil
        )
        let layoutManager = BrowserAgentLayoutManager()
        transcriptStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        transcriptView = NSTextView(frame: .zero, textContainer: container)
        pageButton = ChromeButton(title: "", theme: theme, kind: .standard)
        modelButton = ChromeButton(title: "", theme: theme, kind: .text)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = ChromeFont.sans(size: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        newChatButton.toolTip = "New chat (⇧⌘E)"
        for (button, action) in [
            (newChatButton, #selector(newChatPressed)),
            (closeButton, #selector(closePressed)),
        ] {
            button.target = self
            button.action = action
            addSubview(button)
        }

        transcriptView.delegate = self
        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.drawsBackground = false
        transcriptView.textContainerInset = NSSize(width: 16, height: 12)
        transcriptView.minSize = .zero
        transcriptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]
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

        composerFrame.translatesAutoresizingMaskIntoConstraints = false
        composerFrame.onClick = { [weak self] in self?.focusComposer() }
        addSubview(composerFrame)
        composer.delegate = self
        composer.isRichText = false
        composer.allowsUndo = true
        composer.drawsBackground = false
        composer.font = Self.composerFont
        composer.textContainerInset = Self.composerInset
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
        placeholderLabel.font = Self.composerFont
        composerFrame.addSubview(placeholderLabel)

        pageButton.target = self
        pageButton.action = #selector(pagePressed)
        pageButton.lineBreakMode = .byTruncatingTail
        pageButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        composerFrame.addSubview(pageButton)

        modelButton.target = self
        modelButton.action = #selector(settingsPressed)
        modelButton.setAccessibilityLabel("Agent Settings")
        modelButton.toolTip = "Agent settings: model, thinking, working folder"
        modelButton.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        modelButton.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(251), for: .horizontal)
        spinner.setAccessibilityLabel("Working")
        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        let trailing = NSStackView(views: [modelButton, spinner, sendButton])
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = 6
        trailing.detachesHiddenViews = true
        composerFrame.addSubview(trailing)

        composerHeight = composerScroll.heightAnchor.constraint(equalToConstant: 22)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.widthAnchor.constraint(equalToConstant: Chrome.hairline),

            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            newChatButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            newChatButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),

            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: newChatButton.leadingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: composerFrame.topAnchor, constant: -8),

            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),

            composerFrame.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            composerFrame.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            composerFrame.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            composerScroll.topAnchor.constraint(equalTo: composerFrame.topAnchor, constant: 12),
            composerScroll.leadingAnchor.constraint(equalTo: composerFrame.leadingAnchor, constant: 10),
            composerScroll.trailingAnchor.constraint(equalTo: composerFrame.trailingAnchor, constant: -10),
            composerHeight,

            placeholderLabel.topAnchor.constraint(equalTo: composerScroll.topAnchor, constant: Self.composerInset.height),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: composerScroll.leadingAnchor,
                constant: Self.composerInset.width + (composer.textContainer?.lineFragmentPadding ?? 5)
            ),

            trailing.topAnchor.constraint(equalTo: composerScroll.bottomAnchor, constant: 10),
            trailing.trailingAnchor.constraint(equalTo: composerFrame.trailingAnchor, constant: -8),
            trailing.bottomAnchor.constraint(equalTo: composerFrame.bottomAnchor, constant: -8),

            pageButton.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
            pageButton.leadingAnchor.constraint(equalTo: composerFrame.leadingAnchor, constant: 8),
            pageButton.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
        ])

        apply(theme: theme)
        update(BrowserAgentTranscript(), model: "")
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
        emptyLabel.textColor = colors.textMuted
        placeholderLabel.textColor = colors.textMuted
        newChatButton.apply(theme: theme)
        closeButton.apply(theme: theme)
        composerFrame.apply(theme: theme)
        sendButton.apply(theme: theme)
        composer.textColor = colors.textPrimary
        composer.insertionPointColor = colors.caret
        composer.selectedTextAttributes = [.backgroundColor: colors.textSelection]
        transcriptView.selectedTextAttributes = [.backgroundColor: colors.textSelection]
        // Links style themselves (an answer's are underlined; the run's
        // row and Copy aren't).
        transcriptView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        for button in [pageButton, modelButton] {
            button.apply(theme: theme)
        }
        cache = RenderCache(width: 0)
        render()
    }

    /// Shows `transcript`; `model` is the model chip's title.
    func update(_ transcript: BrowserAgentTranscript, model: String) {
        self.transcript = transcript
        modelButton.title = model
        modelButton.isHidden = model.isEmpty
        let title = transcript.entries.first { $0.kind == .user }?.text
            .split(whereSeparator: \.isNewline).first.map(String.init)
        titleLabel.stringValue = title ?? "Agent"
        emptyLabel.isHidden = !transcript.isEmpty
        placeholderLabel.stringValue = transcript.isEmpty ? "Ask the agent…" : "Reply…"
        spinner.isHidden = !transcript.isWorking
        if transcript.isWorking {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        updateSendButton()
        scheduleRender()
    }

    /// The icon of the tab a message goes with, for its card.
    func setIcon(_ icon: NSImage?, for page: BrowserAgentPage) {
        pageIcons[page.url] = icon
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

    /// Every run's steps shown (the harness).
    func expandAllSteps() -> Int {
        for case let .run(run) in transcript.blocks where !run.steps.isEmpty {
            expandedRuns.insert(run.id)
        }
        render()
        return expandedRuns.count
    }

    override func layout() {
        super.layout()
        updateComposerHeight()
        if transcriptWidth != cache.width {
            scheduleRender()
        }
    }

    // MARK: Actions

    private func submit() {
        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composer.string = ""
        textDidChange(Notification(name: NSText.didChangeNotification, object: composer))
        onSend?(text)
    }

    @objc private func sendPressed() {
        if sendButton.showsStop {
            onStop?()
        } else {
            submit()
        }
    }

    @objc private func newChatPressed() {
        expandedRuns.removeAll()
        copiedRun = nil
        onNewChat?()
    }

    @objc private func settingsPressed() { onSettings?() }
    @objc private func closePressed() { onClose?() }

    /// The page chip's state for a new chat (Settings ▸ Agent).
    func setIncludesPage(_ on: Bool) {
        includesPage = on
        updatePageButton()
    }

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
        let short = pageTitle.count > 24 ? String(pageTitle.prefix(23)) + "…" : pageTitle
        pageButton.title = includesPage ? short : "No page"
        pageButton.kind = includesPage ? .standard : .text
        pageButton.toolTip = includesPage
            ? "The message includes this tab: \(pageTitle). Click to send without it."
            : "Click to include the selected tab with the message."
    }

    /// Stop while a run works and nothing is typed; Send otherwise, off
    /// while there's nothing to send.
    private func updateSendButton() {
        let typed = !composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.showsStop = transcript.isWorking && !typed
        sendButton.isEnabled = typed || sendButton.showsStop
    }

    func textDidChange(_ notification: Notification) {
        placeholderLabel.isHidden = !composer.string.isEmpty
        updateSendButton()
        updateComposerHeight()
    }

    /// One line to `composerMaxHeight`, then the composer scrolls.
    private func updateComposerHeight() {
        let padding = composer.textContainer?.lineFragmentPadding ?? 5
        let width = composerScroll.contentSize.width - Self.composerInset.width * 2 - padding * 2
        guard width > 20 else { return }
        var text = composer.string.isEmpty ? " " : composer.string
        if text.hasSuffix("\n") { text += " " }
        let used = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.composerFont]
        ).height
        let height = min(Self.composerMaxHeight, ceil(used) + Self.composerInset.height * 2)
        if composerHeight.constant != height {
            composerHeight.constant = height
        }
    }

    // MARK: Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)),
              url.scheme == BrowserAgentRenderer.actionScheme
        else { return false }
        perform(url)
        return true
    }

    /// The run row's chevron and Copy are attachments with a link.
    func textView(
        _ textView: NSTextView,
        clickedOn cell: any NSTextAttachmentCellProtocol,
        in cellFrame: NSRect,
        at charIndex: Int
    ) {
        guard let link = textView.textStorage?.attribute(.link, at: charIndex, effectiveRange: nil) else { return }
        _ = self.textView(textView, clickedOnLink: link, at: charIndex)
    }

    private func perform(_ url: URL) {
        let time = NSApp.currentEvent?.timestamp ?? 0
        if let lastAction, lastAction.url == url, lastAction.time == time { return }
        lastAction = (url, time)
        guard let id = Int(url.lastPathComponent) else { return }
        switch url.host() {
        case "steps":
            if expandedRuns.remove(id) == nil {
                expandedRuns.insert(id)
            }
            render(scrolls: false)
        case "copy":
            guard let answer = answers[id] else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer, forType: .string)
            copiedRun = id
            render(scrolls: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.copiedRun == id else { return }
                    self.copiedRun = nil
                    self.render(scrolls: false)
                }
            }
        default:
            break
        }
    }

    // MARK: Rendering

    private var transcriptWidth: CGFloat {
        let inset = transcriptView.textContainerInset.width * 2
        let width = transcriptView.bounds.width - inset
        return width > 100 ? width : Self.width - inset
    }

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

    private func render(scrolls: Bool = true) {
        let width = transcriptWidth
        let old = cache.width == width ? cache.pieces : [:]
        cache = RenderCache(width: width)
        let clip = scrollView.contentView
        let atBottom = clip.bounds.maxY >= transcriptView.frame.height - 24
        let renderer = BrowserAgentRenderer(colors: theme.colors, width: width)
        let output = NSMutableAttributedString()
        // A piece rendered before for the same entry, revision and spot.
        func piece(_ entry: BrowserAgentTranscript.Entry, _ part: Int, before: CGFloat, _ make: () -> NSAttributedString) {
            let key = RenderCache.Key(id: entry.id, revision: entry.revision, part: part, before: before)
            let text = old[key] ?? make()
            cache.pieces[key] = text
            output.append(text)
        }
        answers.removeAll()
        let blocks = transcript.blocks
        var lastDate: Date?
        for (index, block) in blocks.enumerated() {
            let gap: CGFloat = output.length == 0 ? 0 : 20
            switch block {
            case let .user(entry):
                var before = gap
                if lastDate.map({ entry.date.timeIntervalSince($0) >= Self.stampPause }) ?? true {
                    output.append(renderer.stamp(entry.date, before: before))
                    before = 12
                }
                if let page = entry.page {
                    piece(entry, 0, before: before) { renderer.card(page, icon: pageIcons[page.url], before: before) }
                    before = 20
                }
                piece(entry, 1, before: before) { renderer.user(entry.text, before: before) }
                lastDate = entry.date
            case let .note(entry):
                output.append(renderer.note(entry.text, before: gap == 0 ? 0 : 14))
                lastDate = entry.date
            case let .run(run):
                let live = transcript.isWorking && index == blocks.count - 1
                var before = gap
                if !run.steps.isEmpty || live {
                    let label = live
                        ? liveLabel(run)
                        : run.duration.map { "Worked for \(BrowserAgentRenderer.duration($0))" } ?? "Worked"
                    let expanded = expandedRuns.contains(run.id)
                    output.append(renderer.runRow(
                        label,
                        run: run.steps.isEmpty ? nil : run.id,
                        expanded: expanded,
                        before: before
                    ))
                    before = 10
                    if expanded {
                        for step in run.steps {
                            if step.kind == .tool {
                                piece(step, 2, before: 8) { renderer.tool(step, before: 8) }
                            } else {
                                piece(step, 3, before: 8) {
                                    renderer.markdown(step.text, size: 13, color: theme.colors.textMuted, before: 8)
                                }
                            }
                        }
                        before = 14
                    }
                }
                for (number, entry) in run.answer.enumerated() {
                    let spacing = number == 0 ? before : 12
                    piece(entry, 4, before: spacing) {
                        renderer.markdown(entry.text, size: 14, color: theme.colors.textPrimary, before: spacing)
                    }
                }
                if !live, !run.answer.isEmpty {
                    answers[run.id] = run.answer.map(\.text).joined(separator: "\n\n")
                    output.append(renderer.footer(run: run.id, copied: copiedRun == run.id, end: run.end, before: 12))
                }
                lastDate = run.end
            }
        }
        // Sent, and nothing back yet.
        if transcript.isWorking, blocks.last.map({ if case .run = $0 { false } else { true } }) ?? true {
            output.append(renderer.runRow("\(transcript.activity ?? "Working")…", run: nil, expanded: false, before: 20))
        }
        transcriptStorage.setAttributedString(output)
        if scrolls, atBottom || transcript.isWorking {
            transcriptView.scrollToEndOfDocument(nil)
        }
    }

    /// What a working run does now: its running tool's intent, else the
    /// agent's activity ("Thinking…").
    private func liveLabel(_ run: BrowserAgentTranscript.Run) -> String {
        let tool = run.steps.last { $0.kind == .tool && $0.toolState == .running }
        return "\(tool?.detail ?? transcript.activity ?? "Working")…"
    }
}

/// The composer's rounded surface; a click on its padding focuses the
/// composer.
@MainActor
final class BrowserAgentComposerFrame: NSView {
    var onClick: (() -> Void)?
    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            needsDisplay = true
        }
    }
    private var theme: AppTheme?

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors = theme?.colors else { return }
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Chrome.Radius.panel,
            yRadius: Chrome.Radius.panel
        )
        colors.raised.setFill()
        shape.fill()
        shape.lineWidth = Chrome.hairline
        (isFocused ? colors.fieldFocusEdge : colors.borderStrong).setStroke()
        shape.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// The composer's round button: an arrow that sends, or a square that
/// stops the run.
@MainActor
final class BrowserAgentSendButton: NSButton {
    static let side: CGFloat = 28

    var showsStop = false {
        didSet {
            guard showsStop != oldValue else { return }
            refresh()
        }
    }
    private var theme: AppTheme?

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = Self.side / 2
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        refresh()
    }

    override var isEnabled: Bool {
        didSet { refresh() }
    }

    override var isHighlighted: Bool {
        didSet { refresh() }
    }

    private func refresh() {
        let label = showsStop ? "Stop" : "Send"
        setAccessibilityLabel(label)
        toolTip = showsStop ? "Stop" : "Send (↵)"
        guard let colors = theme?.colors else { return }
        let fill = !isEnabled ? colors.bgOverlay : (isHighlighted ? colors.inkButtonPressed : colors.inkButtonFill)
        layer?.backgroundColor = fill.cgColor
        let configuration = NSImage.SymbolConfiguration(pointSize: showsStop ? 10 : 13, weight: .semibold)
        image = NSImage(systemSymbolName: showsStop ? "stop.fill" : "arrow.up", accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
        contentTintColor = isEnabled ? colors.inkButtonLabel : colors.textMuted
    }
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
