import AppKit

/// One Agent chat while something shows it (a window's Agent panel, a
/// chats page) and the omp behind it: what the user sends goes to omp,
/// omp's events update the transcript, and omp's `browser` tool calls run
/// as `browser` CLI commands on the window the last message came from
/// (`BrowserAutomationRouter`, that window as the default target). A new
/// conversation becomes a saved chat with its first message
/// (`BrowserAgentChatStore`): omp then keeps the chat's session in the
/// chat's folder, and the next omp for it (after a restart, a resume)
/// continues that session file. omp starts with the first message sent
/// and stays until `BrowserAgentChats` ends it (nothing shows the chat
/// and its session settled, the chat was deleted) or the app quits
/// (its stdin closes with the app).
@MainActor
final class BrowserAgentConversation {
    /// Nil until the first message makes it a saved chat.
    private(set) var chatID: UUID?
    private(set) var transcript: BrowserAgentTranscript
    /// Every change to the transcript or the chat's state.
    let changes = BrowserObservers<Void>()
    /// The window the agent's `browser` commands act on: the one the last
    /// message came from.
    private(set) weak var window: BrowserWindowController?
    /// From a message sent until omp reports the session settled (or it
    /// ended): omp may still be working, even after the answer.
    private(set) var isBusy = false
    private let session: BrowserAgentSession
    private unowned let chats: BrowserAgentChats

    init(chats: BrowserAgentChats, chatID: UUID? = nil, transcript: BrowserAgentTranscript = BrowserAgentTranscript(), launch: BrowserAgentLaunch) {
        self.chats = chats
        self.chatID = chatID
        self.transcript = transcript
        session = BrowserAgentSession(
            launch: launch,
            hostTool: BrowserAgentProtocol.hostToolDefinition(help: BrowserCommand.help)
        )
        session.onEvent = { [weak self] event in self?.handle(event) }
        session.onExit = { [weak self] message in self?.exited(message) }
    }

    var isRunning: Bool { session.isRunning }

    /// How the running omp started, or how the next one will.
    var launch: BrowserAgentLaunch { session.launch }

    /// One line on the chat's state (`browser agent`).
    var statusLine: String {
        guard transcript.isWorking else { return "idle" }
        return "working: \(transcript.activity ?? "Working")"
    }

    /// While no omp runs, Settings ▸ Agent is read again, so the next
    /// message starts omp the way it says, in the chat's folder and
    /// continuing its session file.
    func syncLaunch(_ settings: BrowserSettings) {
        guard !session.isRunning else { return }
        var launch = BrowserAgentLaunch(settings: settings)
        if let chatID {
            launch.sessionDirectory = chats.store.directory(for: chatID).path
            launch.resume = chats.store.sessionFile(for: chatID)?.path
        }
        session.launch = launch
    }

    func send(_ text: String, page: BrowserAgentPage?, from window: BrowserWindowController) {
        self.window = window
        var created = false
        if let chatID {
            chats.store.touch(chatID)
        } else {
            chatID = chats.store.create(firstMessage: text).id
            created = true
            chats.register(self)
        }
        transcript.addUser(text, page: page)
        do {
            syncLaunch(window.settingsStore.settings)
            try session.startIfNeeded()
            isBusy = true
            session.send(BrowserAgentProtocol.prompt(BrowserAgentProtocol.message(text, page: page)))
        } catch {
            transcript.addNote(error.localizedDescription)
            transcript.endWork()
            // A chat whose first message never reached omp has nothing saved.
            if created, let chatID {
                self.chatID = nil
                chats.forget(chatID)
            }
        }
        changes.notify()
    }

    /// Aborts the run; omp's `prompt_result` ends it in the transcript.
    func stop() {
        guard transcript.isWorking || isBusy else { return }
        if session.isRunning {
            session.send(["type": "abort"])
        } else {
            transcript.endWork()
            isBusy = false
            changes.notify()
        }
    }

    /// Ends omp (the run aborts); the transcript stays. `completion` runs
    /// once the process is gone.
    func shutdown(then completion: (@MainActor () -> Void)? = nil) {
        session.stop(then: completion)
        if transcript.isWorking {
            transcript.endWork()
        }
        isBusy = false
        changes.notify()
    }

    private func handle(_ event: BrowserAgentEvent) {
        switch event {
        case let .hostToolCall(id, toolName, arguments):
            runHostTool(id: id, toolName: toolName, arguments: arguments)
            return
        case let .promptResult(_, _, settled) where settled:
            isBusy = false
        case .settled:
            isBusy = false
        case let .commandFailed(command, _) where command == "prompt":
            isBusy = false
        default:
            break
        }
        let wasWorking = transcript.isWorking
        transcript.apply(event)
        if wasWorking, !transcript.isWorking, let chatID {
            chats.store.touch(chatID)
        }
        changes.notify()
        if !isBusy {
            chats.sweep()
        }
    }

    private func exited(_ message: String) {
        transcript.addNote(message)
        transcript.processEnded()
        isBusy = false
        changes.notify()
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
        var request: BrowserCommandRequest
        do {
            request = try Self.toolRequest(arguments, workingDirectory: session.workingDirectory)
        } catch {
            reply(.failure(error))
            return
        }
        // `site`, `reader`, `translate` and `devtools` act on a Peek when
        // one is open; the agent's messages name the selected tab under it.
        if request.windowIndex == nil, request.tabIndex == nil, window.peek != nil,
           Self.peekCommands.contains(request.command),
           let selected = window.selectedTab,
           let index = window.visibleTabs.firstIndex(where: { $0 === selected })
        {
            request = BrowserCommandRequest(
                command: request.command,
                arguments: request.arguments,
                tabIndex: index + 1,
                windowIndex: nil,
                timeout: request.timeout,
                space: request.space
            )
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

    /// The `browser` CLI request for a tool call's words. A relative
    /// screenshot path is under omp's folder. A command that reads the
    /// CLI's standard input (`boost css|js <host> -`, wherever `--window`
    /// or `--tab` sit) is refused: the agent has none, and an empty read
    /// would replace the Boost with nothing.
    nonisolated static func toolRequest(_ arguments: [String], workingDirectory: String) throws -> BrowserCommandRequest {
        var readsStandardInput = false
        let parsed = try BrowserCommandRequest.parse(
            ["soprano-web", "browser"] + arguments,
            environment: ["PWD": workingDirectory],
            standardInput: {
                readsStandardInput = true
                return Data()
            }
        )
        if readsStandardInput {
            throw BrowserAutomationError.invalidArguments(
                "`-` reads standard input, which the agent has none of; write the code to a file and pass its path."
            )
        }
        guard let parsed else { throw BrowserAutomationError.invalidArguments(BrowserCommand.help) }
        return parsed
    }

    /// Commands that act on a Peek, without `--tab`, instead of the
    /// selected tab.
    private static let peekCommands: Set<String> = ["site", "reader", "translate", "devtools"]

    // MARK: - The harness

    /// Feeds `events` as if omp sent them (`--agent` seeds a chat).
    func replay(user text: String, page: BrowserAgentPage?, events: [BrowserAgentEvent]) {
        transcript.addUser(text, page: page)
        for event in events {
            transcript.apply(event)
        }
        changes.notify()
    }
}

/// Every Agent chat of the app: the saved list (`store`) and the chats
/// open now, one `BrowserAgentConversation` (and at most one omp) per
/// chat however many panels and pages show it. A chat not open is read
/// from its session file when something shows it. `isShown` (set by the
/// window manager) says whether a panel or a chats page shows a
/// conversation; `sweep` ends the omp of every open chat nothing shows
/// once its session settled, and forgets it.
@MainActor
final class BrowserAgentChats {
    let store: BrowserAgentChatStore
    /// Any open chat changed (`nil`: a chat was removed), and the list.
    let changes = BrowserObservers<UUID?>()
    var isShown: (BrowserAgentConversation) -> Bool = { _ in false }
    /// The launch a chat starts with before a message syncs it.
    var defaultLaunch: () -> BrowserAgentLaunch = {
        BrowserAgentLaunch(workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    private var open: [UUID: BrowserAgentConversation] = [:]
    private var observations: [UUID: BrowserObservation] = [:]
    private var storeObservation: BrowserObservation?

    init(store: BrowserAgentChatStore) {
        self.store = store
        storeObservation = store.changes.observe { [weak self] in self?.changes.notify(nil) }
    }

    /// A chat not saved yet: it becomes one with its first message.
    func newConversation() -> BrowserAgentConversation {
        BrowserAgentConversation(chats: self, launch: defaultLaunch())
    }

    /// Open chats whose agent is working now.
    var workingChats: Set<UUID> {
        Set(open.compactMap { $1.transcript.isWorking ? $0 : nil })
    }

    /// The saved chat `id`, open or read from its session file; nil when
    /// the list has no such chat.
    func conversation(for id: UUID) -> BrowserAgentConversation? {
        if let conversation = open[id] { return conversation }
        guard store.record(id) != nil else { return nil }
        let transcript = store.sessionFile(for: id).flatMap(BrowserAgentSessionFile.transcript(at:)) ?? BrowserAgentTranscript()
        let conversation = BrowserAgentConversation(chats: self, chatID: id, transcript: transcript, launch: defaultLaunch())
        register(conversation)
        return conversation
    }

    /// Open chats, for the panel and the page to show their state.
    func openConversation(_ id: UUID) -> BrowserAgentConversation? {
        open[id]
    }

    func register(_ conversation: BrowserAgentConversation) {
        guard let id = conversation.chatID, open[id] == nil else { return }
        open[id] = conversation
        observations[id] = conversation.changes.observe { [weak self] in self?.changes.notify(id) }
    }

    /// Takes a chat out of the open ones without ending its omp (a first
    /// message that never reached omp).
    func forget(_ id: UUID) {
        open[id] = nil
        observations[id] = nil
        store.delete(id)
    }

    /// Ends the chat's omp, takes it off the list and moves its folder to
    /// the Trash once omp is gone (it writes the session file until then,
    /// and would bring the folder back).
    func delete(_ id: UUID) {
        let conversation = open.removeValue(forKey: id)
        observations[id] = nil
        store.delete(id, keepingFolder: true)
        let store = store
        if let conversation {
            conversation.shutdown { store.discardFolder(of: id) }
        } else {
            store.discardFolder(of: id)
        }
        changes.notify(nil)
    }

    /// Ends the omp of every open chat nothing shows whose session
    /// settled, and forgets those chats (they reopen from their file).
    func sweep() {
        for (id, conversation) in open where !conversation.isBusy && !isShown(conversation) {
            conversation.shutdown()
            open[id] = nil
            observations[id] = nil
        }
    }

    /// The window closed: chats whose `browser` commands acted on it and
    /// that nothing else shows end now, settled or not.
    func windowClosed(_ window: BrowserWindowController) {
        for (id, conversation) in open where !isShown(conversation) {
            if conversation.window == nil || conversation.window === window || !conversation.isBusy {
                conversation.shutdown()
                open[id] = nil
                observations[id] = nil
            }
        }
    }
}
