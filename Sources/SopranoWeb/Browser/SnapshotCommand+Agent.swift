import AppKit

/// Snapshot flags for the Agent panel, which never starts omp here:
/// - `--agent`: the panel shown with a seeded chat (a message, tool calls
///   that worked and one that failed, a Markdown answer with a list), fed
///   through the transcript as omp's events would; the chat prints as
///   `agent:` lines.
/// - `--agent-draft <text>`: text typed into the composer.
/// - `--agent-steps`: every run's steps shown, as a click on "Worked for
///   …" does; prints `agent-steps: <runs> shown`.
/// - `--agent-button` (repeatable): presses the toolbar's Agent button
///   through its accessibility press, as a click does; after each press
///   prints `agent-button: panel shown|hidden, button on|off`.
/// - `--agent-gear`: after `--settings-search`, presses the composer's
///   model chip (Settings ▸ Agent) and prints `agent-gear: pressed`;
///   `--print-settings` then shows where the Settings page went.
/// - `--agent-chats`: saves two chats as omp session files in the run's
///   support folder (one pinned, from 9 days ago), opens the chats page
///   (`soprano-web://chats`) at the newer one, as it reads them from
///   disk, and prints `agent-chats:` lines (each listed chat, then what the
///   page shows).
struct SnapshotAgentOptions {
    var shows = false
    var draft: String?
    var expandsSteps = false
    var buttonPresses = 0
    var pressesGear = false
    var showsChats = false

    var isActive: Bool { shows || buttonPresses > 0 }

    static let usage = """
                               [--agent] [--agent-draft <text>] [--agent-steps] [--agent-button]... [--agent-gear] [--agent-chats]
    """

    /// True when `option` is one of these flags (its value read).
    static func parse(_ option: String, value: () throws -> String, into options: inout SnapshotAgentOptions) throws -> Bool {
        switch option {
        case "--agent":
            options.shows = true
        case "--agent-draft":
            options.shows = true
            options.draft = try value()
        case "--agent-steps":
            options.shows = true
            options.expandsSteps = true
        case "--agent-button":
            options.buttonPresses += 1
        case "--agent-gear":
            options.pressesGear = true
        case "--agent-chats":
            options.showsChats = true
        default:
            return false
        }
        return true
    }

    @MainActor
    func run(controller: BrowserWindowController) {
        pressButton(controller: controller)
        guard shows else { return }
        guard controller.canShowAgent else {
            print("agent: this window has no Agent panel")
            return
        }
        controller.showAgent(focus: false)
        guard let chat = controller.agentChat else { return }
        let page = controller.agentPage
        print("agent: page \(page.map { "\($0.title) — \($0.url)" } ?? "none")")
        chat.replay(
            user: "What is this page about? Then open its link.",
            page: page,
            events: Self.seededEvents
        )
        if let draft {
            chat.view.setDraft(draft)
        }
        if expandsSteps {
            print("agent-steps: \(chat.view.expandAllSteps()) shown")
        }
        for line in chat.transcript.plainText.split(separator: "\n") {
            print("agent: \(line)")
        }
    }

    @MainActor
    private func pressButton(controller: BrowserWindowController) {
        guard buttonPresses > 0 else { return }
        let button = Self.buttons(in: controller.toolbar).first { $0.accessibilityLabel() == "Agent" }
        guard let button, !button.isHiddenOrHasHiddenAncestor else {
            print("agent-button: none in this window")
            return
        }
        for _ in 0..<buttonPresses {
            _ = button.accessibilityPerformPress()
            let on = (button as? ChromeIconButton)?.isToggledOn == true
            print("agent-button: panel \(controller.isAgentVisible ? "shown" : "hidden"), button \(on ? "on" : "off")")
        }
    }

    /// `--agent-gear`: the composer's model chip, pressed as a click does.
    @MainActor
    func pressGear(controller: BrowserWindowController) {
        guard pressesGear else { return }
        controller.showAgent(focus: false)
        guard let view = controller.agentChat?.view,
              let gear = Self.buttons(in: view).first(where: { $0.accessibilityLabel() == "Agent Settings" })
        else {
            print("agent-gear: no panel")
            return
        }
        _ = gear.accessibilityPerformPress()
        print("agent-gear: pressed")
    }

    @MainActor
    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
    }

    /// `--agent-chats`: two saved chats, the chats page at the newer.
    @MainActor
    func runChats(controller: BrowserWindowController, manager: BrowserWindowManager, wait: (TimeInterval) -> Void) {
        guard showsChats, let tab = controller.selectedTab else { return }
        let store = manager.agentChats.store
        let now = Date()
        let older = store.create(firstMessage: "Summarize the release notes", at: now.addingTimeInterval(-9 * 86_400))
        store.setPinned(older.id, true)
        Self.writeSession(store: store, id: older.id, at: now.addingTimeInterval(-9 * 86_400), lines: [
            Self.message(role: "user", content: [["type": "text", "text": "Summarize the release notes"]]),
            Self.message(role: "assistant", content: [["type": "text", "text": "Three fixes and one new shortcut."]], stopReason: "stop"),
        ])
        let newer = store.create(firstMessage: "What is this page about? Then open its link.", at: now)
        Self.writeSession(store: store, id: newer.id, at: now, lines: [
            Self.message(role: "user", content: [[
                "type": "text",
                "text": BrowserAgentProtocol.message(
                    "What is this page about? Then open its link.",
                    page: BrowserAgentPage(title: "Example Domain", url: "https://example.com/")
                ),
            ]]),
            Self.message(role: "assistant", content: [
                ["type": "toolCall", "id": "t1", "name": "browser", "arguments": ["args": ["get", "text", "body"], "i": "Reading the page"]],
            ], stopReason: "toolUse"),
            ["role": "toolResult", "toolCallId": "t1", "toolName": "browser", "content": [["type": "text", "text": "Example Domain…"]], "isError": false],
            Self.message(role: "assistant", content: [
                ["type": "toolCall", "id": "t2", "name": "browser", "arguments": ["args": ["click", "@e9"], "i": "Opening the link"]],
            ], stopReason: "toolUse"),
            ["role": "toolResult", "toolCallId": "t2", "toolName": "browser", "content": [["type": "text", "text": "Element not found: @e9"]], "isError": true],
            Self.message(role: "assistant", content: [["type": "text", "text": """
            It's **Example Domain**, a page reserved for documentation examples (`example.com`).

            **What's on it**

            - One heading and a short paragraph saying the domain is for examples.
            - A single link, *Learn more*, which goes to [iana.org](https://www.iana.org/help/example-domains).
            """]], stopReason: "stop"),
        ])
        controller.navigate(tab, to: BrowserAgentChatsPage.url(for: newer.id))
        let deadline = Date().addingTimeInterval(5)
        repeat {
            wait(0.05)
        } while (tab.webView.isLoading || !BrowserAgentChatsPage.isChats(tab.webView.url)) && Date() < deadline
        wait(0.3)
        for record in store.records {
            print("agent-chats: \(record.pinned ? "pinned " : "")\(record.title)")
        }
        var finished = false
        tab.webView.evaluateJavaScript(
            "[document.title, document.querySelectorAll('.chat').length, document.querySelectorAll('.tool').length, document.querySelectorAll('.answer').length].join(' | ')",
            in: nil,
            in: .page
        ) { result in
            if case let .success(value) = result, let line = value as? String {
                print("agent-chats: page \(line)")
            }
            finished = true
        }
        let printed = Date().addingTimeInterval(2)
        while !finished, Date() < printed {
            wait(0.05)
        }
    }

    private static func message(role: String, content: [[String: Any]], stopReason: String? = nil) -> [String: Any] {
        var message: [String: Any] = ["role": role, "content": content]
        message["stopReason"] = stopReason
        return message
    }

    /// A session file as omp writes it: a title slot, a header, then one
    /// message entry per line, a second apart from `date`.
    @MainActor
    private static func writeSession(store: BrowserAgentChatStore, id: UUID, at date: Date, lines: [[String: Any]]) {
        let folder = store.directory(for: id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var text = #"{"type":"title","v":1,"title":""}"# + "\n" + #"{"type":"session","version":3,"id":"harness"}"# + "\n"
        for (index, var message) in lines.enumerated() {
            message["timestamp"] = (date.timeIntervalSince1970 + Double(index)) * 1000
            let parent: Any = index == 0 ? NSNull() : "e\(index - 1)"
            let entry: [String: Any] = ["type": "message", "id": "e\(index)", "parentId": parent, "message": message]
            guard let data = try? JSONSerialization.data(withJSONObject: entry) else { continue }
            text += String(decoding: data, as: UTF8.self) + "\n"
        }
        try? Data(text.utf8).write(to: folder.appendingPathComponent("2026-01-01T00-00-00-000Z_harness.jsonl"))
    }

    static let seededEvents: [BrowserAgentEvent] = [
        .agentStart,
        .toolStart(callID: "t1", title: "browser get text body", intent: "Reading the page"),
        .toolEnd(callID: "t1", error: nil),
        .toolStart(callID: "t2", title: "browser snapshot --interactive", intent: "Finding the link"),
        .toolEnd(callID: "t2", error: nil),
        .toolStart(callID: "t3", title: "browser click @e9", intent: "Opening the link"),
        .toolEnd(callID: "t3", error: "Element not found: @e9"),
        .toolStart(callID: "t4", title: "browser click @e2", intent: "Opening the link"),
        .toolEnd(callID: "t4", error: nil),
        .textDelta(messageID: "m1", index: 0, text: "It's **Example Domain**, a page reserved for "),
        .textDelta(messageID: "m1", index: 0, text: "documentation examples (`example.com`).\n\n"),
        .assistantEnd(
            messageID: "m1",
            text: """
            It's **Example Domain**, a page reserved for documentation examples (`example.com`).

            **What's on it**

            - One heading and a short paragraph saying the domain is for examples.
            - A single link, *Learn more*, which goes to [iana.org](https://www.iana.org/help/example-domains).

            I opened that link; the tab now shows IANA's page on example domains.
            """,
            answers: true
        ),
        .promptResult(status: "completed", error: nil, settled: true),
    ]
}
