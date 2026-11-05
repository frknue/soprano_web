import Foundation

/// The Agent panel's chat, built from what the user sent and omp's events
/// (`apply`). Pure, so the reducer is testable without omp or a view. Each
/// entry has a stable `id` and a `revision` that grows with every change,
/// so the view re-renders only entries that changed.
struct BrowserAgentTranscript: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case user
        case assistant
        case tool
        /// What went wrong (omp's error, a crash, a stop): shown as a note.
        case note
    }

    enum ToolState: Equatable, Sendable {
        case running
        case done
        case failed
    }

    struct Entry: Equatable, Sendable {
        let id: Int
        let kind: Kind
        /// When the entry was added.
        let date: Date
        /// The user's or assistant's text, the tool's title line, the note.
        var text: String
        /// A tool call's intent.
        var detail: String?
        /// The tab a user message went with.
        var page: BrowserAgentPage?
        /// On the last user message of a run (a steer is one more), once
        /// the run ended: how long the agent worked since the run's first
        /// message ("Worked for 16s").
        var duration: TimeInterval?
        /// When that run ended.
        var runEnd: Date?
        var toolState: ToolState = .done
        /// A failed tool's output, its first lines.
        var failure: String?
        /// omp's message id (assistant) or tool call id (tool).
        var key: String?
        var revision = 0
    }

    private(set) var entries: [Entry] = []
    /// From a send until the agent answers (its message without tool
    /// calls) or omp reports the run ended; again while omp acts after
    /// the answer (its advisor's review sends it back to work).
    private(set) var isWorking = false
    /// What the agent is doing now ("Thinking", "Running browser"); nil
    /// while idle.
    private(set) var activity: String?
    private var nextID = 1
    /// When the run in progress started: its first message's send.
    private var runStart: Date?
    /// Streaming assistant text by message id, then by content index.
    private var streaming: [String: [Int: String]] = [:]

    var isEmpty: Bool { entries.isEmpty }

    mutating func addUser(_ text: String, page: BrowserAgentPage?, at date: Date = Date()) {
        append(Entry(id: takeID(), kind: .user, date: date, text: text, page: page))
        if !isWorking || runStart == nil {
            runStart = date
        }
        isWorking = true
        activity = "Starting"
    }

    mutating func addNote(_ text: String, at date: Date = Date()) {
        append(Entry(id: takeID(), kind: .note, date: date, text: text))
    }

    /// The run ended without omp saying so (stop, crash): nothing works
    /// any more, running tools stop.
    mutating func endWork(at date: Date = Date()) {
        // An answered run keeps the time it took to answer.
        if isWorking {
            recordDuration(at: date)
        }
        runStart = nil
        isWorking = false
        activity = nil
        for index in entries.indices where entries[index].kind == .tool && entries[index].toolState == .running {
            entries[index].toolState = .failed
            entries[index].revision += 1
        }
        streaming.removeAll()
    }

    /// The chat as the panel lays it out: each user message and note on
    /// its own, and the agent's entries between them as one run.
    enum Block: Equatable, Sendable {
        case user(Entry)
        case note(Entry)
        case run(Run)
    }

    /// The agent's entries between two user messages or notes: its steps
    /// (tool calls and the text between them, under "Worked for 16s") and
    /// its answer (the text after the last tool call).
    struct Run: Equatable, Sendable {
        /// Its first entry's id.
        var id: Int
        var steps: [Entry]
        var answer: [Entry]
        /// How long the agent worked until it answered, on the run that
        /// ended its work.
        var duration: TimeInterval?
        /// When the run ended, or its last entry was added.
        var end: Date
    }

    var blocks: [Block] {
        var blocks: [Block] = []
        var run: [Entry] = []
        var user: Entry?
        func closeRun() {
            guard let first = run.first, let last = run.last else { return }
            let split = run.lastIndex { $0.kind == .tool }.map { $0 + 1 } ?? 0
            let duration = user?.duration
            blocks.append(.run(Run(
                id: first.id,
                steps: Array(run[..<split]),
                answer: Array(run[split...]),
                duration: duration,
                end: user?.runEnd ?? last.date
            )))
            run = []
            user = nil
        }
        for entry in entries {
            switch entry.kind {
            case .assistant, .tool:
                run.append(entry)
            case .user:
                closeRun()
                user = entry
                blocks.append(.user(entry))
            case .note:
                closeRun()
                blocks.append(.note(entry))
            }
        }
        closeRun()
        return blocks
    }

    /// omp's process ended: work stops, and its message and tool call ids
    /// no longer match anything, since the next process numbers its
    /// messages from `msg-1` again.
    mutating func processEnded(at date: Date = Date()) {
        endWork(at: date)
        for index in entries.indices {
            entries[index].key = nil
        }
    }

    mutating func clear() {
        self = BrowserAgentTranscript()
    }

    mutating func apply(_ event: BrowserAgentEvent, at date: Date = Date()) {
        switch event {
        case .ready, .hostToolCall:
            break
        case .agentStart:
            isWorking = true
            activity = "Thinking"
        case .thinking:
            isWorking = true
            activity = "Thinking"
        case let .textDelta(messageID, index, text):
            isWorking = true
            activity = "Writing"
            var message = streaming[messageID] ?? [:]
            message[index, default: ""] += text
            streaming[messageID] = message
            let joined = message.keys.sorted().compactMap { message[$0] }.joined(separator: "\n\n")
            upsertAssistant(messageID, text: joined, at: date)
        case let .assistantEnd(messageID, text, callsTools):
            streaming.removeValue(forKey: messageID)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // No text: tool calls only, or a failed or aborted reply.
                entries.removeAll { $0.kind == .assistant && $0.key == messageID }
            } else {
                upsertAssistant(messageID, text: trimmed, at: date)
            }
            // The answer: omp can still spend a while before it yields
            // (its advisor reviews the turn), and none of that is writing.
            if !callsTools {
                answered(at: date)
            }
        case let .toolStart(callID, title, intent):
            isWorking = true
            activity = "Running \(title.split(separator: " ").first.map(String.init) ?? title)"
            if let index = entries.firstIndex(where: { $0.kind == .tool && $0.key == callID }) {
                entries[index].text = title
                entries[index].detail = intent
                entries[index].toolState = .running
                entries[index].revision += 1
            } else {
                append(Entry(id: takeID(), kind: .tool, date: date, text: title, detail: intent, toolState: .running, key: callID))
            }
        case let .toolEnd(callID, error):
            activity = "Thinking"
            guard let index = entries.firstIndex(where: { $0.kind == .tool && $0.key == callID }) else { return }
            entries[index].toolState = error == nil ? .done : .failed
            if let error {
                entries[index].failure = Self.firstLines(error)
            }
            entries[index].revision += 1
        case let .promptResult(status, error, settled):
            if status == "error" {
                addNote(error ?? "omp stopped with an error.", at: date)
            } else if status == "aborted" {
                addNote("Stopped.", at: date)
            }
            if settled {
                endWork(at: date)
            }
        case .settled:
            endWork(at: date)
        case let .commandFailed(command, error):
            // A refused prompt never runs; other refusals are setup noise.
            if command == "prompt" {
                addNote(error, at: date)
                endWork(at: date)
            }
        }
    }

    /// The chat as plain text (`browser agent`).
    var plainText: String {
        entries.map { entry in
            switch entry.kind {
            case .user:
                "you: \(entry.text)"
            case .assistant:
                "agent: \(entry.text)"
            case .tool:
                "tool \(entry.toolState): \(entry.text)" + (entry.detail.map { " (\($0))" } ?? "")
                    + (entry.failure.map { ": \($0)" } ?? "")
            case .note:
                "note: \(entry.text)"
            }
        }.joined(separator: "\n")
    }

    private mutating func upsertAssistant(_ messageID: String, text: String, at date: Date) {
        if let index = entries.lastIndex(where: { $0.kind == .assistant && $0.key == messageID }) {
            guard entries[index].text != text else { return }
            entries[index].text = text
            entries[index].revision += 1
        } else {
            append(Entry(id: takeID(), kind: .assistant, date: date, text: text, key: messageID))
        }
    }

    /// The agent answered: the run shows as done, timed to the answer.
    /// `runStart` stays, so work that resumes counts from the same start.
    private mutating func answered(at date: Date) {
        recordDuration(at: date)
        isWorking = false
        activity = nil
    }

    private mutating func recordDuration(at date: Date) {
        guard let runStart, let index = entries.lastIndex(where: { $0.kind == .user }) else { return }
        entries[index].duration = max(0, date.timeIntervalSince(runStart))
        entries[index].runEnd = date
        entries[index].revision += 1
    }

    private mutating func append(_ entry: Entry) {
        entries.append(entry)
    }

    private mutating func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    /// A failed tool's output, cut to what fits under its row.
    static func firstLines(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(3)
        let joined = lines.joined(separator: "\n")
        return joined.count > 300 ? String(joined.prefix(299)) + "…" : joined
    }
}
