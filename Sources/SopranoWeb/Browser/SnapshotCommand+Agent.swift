import AppKit

/// Snapshot flags for the Agent panel, which never starts omp here:
/// - `--agent`: the panel shown with a seeded chat (a message, tool calls
///   that worked and one that failed, a Markdown answer), fed through the
///   transcript as omp's events would; the chat prints as `agent:` lines.
/// - `--agent-draft <text>`: text typed into the composer.
struct SnapshotAgentOptions {
    var shows = false
    var draft: String?

    static let usage = """
                               [--agent] [--agent-draft <text>]
    """

    /// True when `option` is one of these flags (its value read).
    static func parse(_ option: String, value: () throws -> String, into options: inout SnapshotAgentOptions) throws -> Bool {
        switch option {
        case "--agent":
            options.shows = true
        case "--agent-draft":
            options.shows = true
            options.draft = try value()
        default:
            return false
        }
        return true
    }

    @MainActor
    func run(controller: BrowserWindowController) {
        guard shows else { return }
        guard controller.canShowAgent else {
            print("agent: this window has no Agent panel")
            return
        }
        controller.showAgent(focus: false)
        guard let chat = controller.agentChat else { return }
        chat.replay(
            user: "What is this page about? Then open its link.",
            page: controller.agentPage,
            events: Self.seededEvents
        )
        if let draft {
            chat.view.setDraft(draft)
        }
        for line in chat.transcript.plainText.split(separator: "\n") {
            print("agent: \(line)")
        }
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

            I opened its only link, *Learn more*, which goes to [iana.org](https://www.iana.org/help/example-domains).
            """
        ),
        .promptResult(status: "completed", error: nil, settled: true),
    ]
}
