import AppKit

/// A window's Agent panel and the omp behind it: what the user sends goes
/// to omp with the tab they look at, omp's events update the transcript,
/// and omp's `browser` tool calls run as `browser` CLI commands on this
/// window (`BrowserAutomationRouter`, the window as the default target).
/// The chat lasts while the window is open; New Chat ends the omp process
/// and the next message starts a fresh one (omp keeps each session's file
/// in its own folder, as in the terminal).
@MainActor
final class BrowserAgentChat {
    let view: BrowserAgentPanelView
    private(set) var transcript = BrowserAgentTranscript()
    private let session: BrowserAgentSession
    private weak var window: BrowserWindowController?

    init(window: BrowserWindowController, theme: AppTheme) {
        self.window = window
        view = BrowserAgentPanelView(theme: theme)
        session = BrowserAgentSession(hostTool: BrowserAgentProtocol.hostToolDefinition(help: BrowserCommand.help))
        session.onEvent = { [weak self] event in self?.handle(event) }
        session.onExit = { [weak self] message in self?.exited(message) }
        view.onSend = { [weak self] text in self?.send(text) }
        view.onStop = { [weak self] in self?.stop() }
        view.onNewChat = { [weak self] in self?.newChat() }
        view.onClose = { [weak window] in window?.hideAgent() }
        updatePage()
    }

    /// One line on the panel's state (`browser agent`).
    var statusLine: String {
        guard transcript.isWorking else { return "idle" }
        return "working: \(transcript.activity ?? "Working")"
    }

    func send(_ text: String) {
        let page = view.includesPage ? window?.agentPage : nil
        transcript.addUser(text, page: page)
        do {
            try session.startIfNeeded()
            session.send(BrowserAgentProtocol.prompt(BrowserAgentProtocol.message(text, page: page)))
        } catch {
            transcript.addNote(error.localizedDescription)
            transcript.endWork()
        }
        refresh()
    }

    /// Aborts the run; omp's `prompt_result` ends it in the transcript.
    func stop() {
        guard transcript.isWorking else { return }
        if session.isRunning {
            session.send(["type": "abort"])
        } else {
            transcript.endWork()
            refresh()
        }
    }

    func newChat() {
        session.stop()
        transcript.clear()
        refresh()
    }

    /// The window closed.
    func shutdown() {
        session.stop()
    }

    func updatePage() {
        view.pageTitle = window?.agentPage.map { $0.title.isEmpty ? $0.url : $0.title }
    }

    private func handle(_ event: BrowserAgentEvent) {
        if case let .hostToolCall(id, toolName, arguments) = event {
            runHostTool(id: id, toolName: toolName, arguments: arguments)
            return
        }
        transcript.apply(event)
        refresh()
    }

    private func exited(_ message: String) {
        transcript.addNote(message)
        transcript.endWork()
        refresh()
    }

    private func refresh() {
        let status = transcript.isWorking ? "omp · \(transcript.activity ?? "Working")…" : "omp"
        view.update(transcript, status: status)
    }

    // MARK: - The browser tool

    private func runHostTool(id: String, toolName: String, arguments: [String]?) {
        let generation = session.generation
        let reply: @MainActor (Result<String, Error>) -> Void = { [weak self] result in
            guard let self, self.session.generation == generation else { return }
            let frame: [String: Any] = switch result {
            case let .success(output):
                BrowserAgentProtocol.hostToolResult(id: id, text: output.isEmpty ? "Done." : output, isError: false)
            case let .failure(error):
                BrowserAgentProtocol.hostToolResult(id: id, text: error.localizedDescription, isError: true)
            }
            self.session.send(frame)
        }
        guard toolName == BrowserAgentProtocol.hostToolName, let arguments, !arguments.isEmpty else {
            reply(.failure(BrowserAutomationError.invalidArguments(
                "`browser` takes {\"args\": [command, arguments…]}, e.g. {\"args\": [\"goto\", \"https://example.com\"]}."
            )))
            return
        }
        guard let window else {
            reply(.failure(BrowserAutomationError.unavailable("The window closed.")))
            return
        }
        let request: BrowserCommandRequest
        do {
            // A relative screenshot path is under omp's folder; `boost
            // css|js <host> -` has no standard input here.
            guard let parsed = try BrowserCommandRequest.parse(
                ["soprano-web", "browser"] + arguments,
                environment: ["PWD": session.workingDirectory],
                standardInput: { Data() }
            ) else { return }
            request = parsed
        } catch {
            reply(.failure(error))
            return
        }
        if request.command == "help" {
            reply(.success(BrowserCommand.help))
            return
        }
        if request.command == "agent" {
            reply(.failure(BrowserAutomationError.unavailable("`agent` commands drive this panel; they aren't available to the agent.")))
            return
        }
        // The first answer wins: the command's, or the timeout's.
        let once = BrowserAutomationReplyOnce { response in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    reply(response.ok
                        ? .success(response.output ?? "")
                        : .failure(BrowserAutomationError.unavailable(response.error ?? "Failed.")))
                }
            }
        }
        let timeout = request.serverTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            once.send(BrowserAutomationResponse(result: .failure(BrowserAutomationError.unavailable(
                "Timed out after \(BrowserCommandRequest.seconds(timeout)) s waiting for `\(request.command)`."
            ))))
        }
        BrowserAutomationRouter.perform(request, in: window.manager, defaultWindow: window) { result in
            once.send(BrowserAutomationResponse(result: result))
        }
    }

    // MARK: - The harness

    /// Feeds `events` as if omp sent them (`--agent` seeds a chat).
    func replay(user text: String, page: BrowserAgentPage?, events: [BrowserAgentEvent]) {
        transcript.addUser(text, page: page)
        for event in events {
            transcript.apply(event)
        }
        refresh()
    }
}
