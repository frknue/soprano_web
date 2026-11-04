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
        /// The user's or assistant's text, the tool's title line, the note.
        var text: String
        /// The user's tab title; a tool call's intent.
        var detail: String?
        var toolState: ToolState = .done
        /// A failed tool's output, its first lines.
        var failure: String?
        /// omp's message id (assistant) or tool call id (tool).
        var key: String?
        var revision = 0
    }

    private(set) var entries: [Entry] = []
    /// From a send until omp reports the session settled.
    private(set) var isWorking = false
    /// What the agent is doing now ("Thinking", "Running browser"); nil
    /// while idle.
    private(set) var activity: String?
    private var nextID = 1
    /// Streaming assistant text by message id, then by content index.
    private var blocks: [String: [Int: String]] = [:]

    var isEmpty: Bool { entries.isEmpty }

    mutating func addUser(_ text: String, page: BrowserAgentPage?) {
        append(Entry(id: takeID(), kind: .user, text: text, detail: page.map { $0.title.isEmpty ? $0.url : $0.title }))
        isWorking = true
        activity = "Starting"
    }

    mutating func addNote(_ text: String) {
        append(Entry(id: takeID(), kind: .note, text: text))
    }

    /// The run ended without omp saying so (stop, crash): nothing works
    /// any more, running tools stop.
    mutating func endWork() {
        isWorking = false
        activity = nil
        for index in entries.indices where entries[index].kind == .tool && entries[index].toolState == .running {
            entries[index].toolState = .failed
            entries[index].revision += 1
        }
        blocks.removeAll()
    }

    /// omp's process ended: work stops, and its message and tool call ids
    /// no longer match anything, since the next process numbers its
    /// messages from `msg-1` again.
    mutating func processEnded() {
        endWork()
        for index in entries.indices {
            entries[index].key = nil
        }
    }

    mutating func clear() {
        self = BrowserAgentTranscript()
    }

    mutating func apply(_ event: BrowserAgentEvent) {
        switch event {
        case .ready, .hostToolCall:
            break
        case .agentStart:
            isWorking = true
            activity = "Thinking"
        case .thinking:
            activity = "Thinking"
        case let .textDelta(messageID, index, text):
            activity = "Writing"
            var message = blocks[messageID] ?? [:]
            message[index, default: ""] += text
            blocks[messageID] = message
            let joined = message.keys.sorted().compactMap { message[$0] }.joined(separator: "\n\n")
            upsertAssistant(messageID, text: joined)
        case let .assistantEnd(messageID, text):
            blocks.removeValue(forKey: messageID)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // A message of tool calls only.
                entries.removeAll { $0.kind == .assistant && $0.key == messageID }
            } else {
                upsertAssistant(messageID, text: trimmed)
            }
        case let .toolStart(callID, title, intent):
            activity = "Running \(title.split(separator: " ").first.map(String.init) ?? title)"
            if let index = entries.firstIndex(where: { $0.kind == .tool && $0.key == callID }) {
                entries[index].text = title
                entries[index].detail = intent
                entries[index].toolState = .running
                entries[index].revision += 1
            } else {
                append(Entry(id: takeID(), kind: .tool, text: title, detail: intent, toolState: .running, key: callID))
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
                addNote(error ?? "omp stopped with an error.")
            } else if status == "aborted" {
                addNote("Stopped.")
            }
            if settled {
                endWork()
            }
        case .settled:
            endWork()
        case let .commandFailed(command, error):
            // A refused prompt never runs; other refusals are setup noise.
            if command == "prompt" {
                addNote(error)
                endWork()
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

    private mutating func upsertAssistant(_ messageID: String, text: String) {
        if let index = entries.lastIndex(where: { $0.kind == .assistant && $0.key == messageID }) {
            guard entries[index].text != text else { return }
            entries[index].text = text
            entries[index].revision += 1
        } else {
            append(Entry(id: takeID(), kind: .assistant, text: text, key: messageID))
        }
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
