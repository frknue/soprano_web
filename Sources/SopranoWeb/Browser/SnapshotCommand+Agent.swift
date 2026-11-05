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
struct SnapshotAgentOptions {
    var shows = false
    var draft: String?
    var expandsSteps = false
    var buttonPresses = 0
    var pressesGear = false

    var isActive: Bool { shows || buttonPresses > 0 }

    static let usage = """
                               [--agent] [--agent-draft <text>] [--agent-steps] [--agent-button]... [--agent-gear]
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
            callsTools: false
        ),
        .promptResult(status: "completed", error: nil, settled: true),
    ]
}
