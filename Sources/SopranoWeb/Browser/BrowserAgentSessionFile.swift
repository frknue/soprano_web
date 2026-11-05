import Foundation

/// A chat's omp session file (`Agent Chats/<id>/<time>_<session id>.jsonl`,
/// omp's session format v3) read back into a transcript, so a chat shows
/// and resumes without omp running. The file is a title slot, a header and
/// then entries, a tree by `parentId`; the chat is the active branch, from
/// the leaf omp resumes at (`leaf`) back to the root, so turns omp moved
/// off it stay out. Its `{"type": "message", "id", "message": {role,
/// content, timestamp, …}}` entries are the chat: the user's messages
/// (their tab from the `[Current tab: …]` line,
/// `BrowserAgentProtocol.parseMessage`), the agent's text and tool calls,
/// and tool results. They are fed through `BrowserAgentTranscript` as
/// omp's events would be, so runs, steps and durations come out as they
/// did live. Anything else (other entry types, messages omp or an
/// extension injected, failed replies omp retried, lines that don't
/// parse) is skipped.
enum BrowserAgentSessionFile {
    /// The newest session file in `folder`: omp writes one per session,
    /// named by its start time, so the last name is the newest.
    static func latest(in folder: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasSuffix(".jsonl") && !$0.hasPrefix(".") }
            .max()
            .map { folder.appendingPathComponent($0) }
    }

    /// Nil when the file can't be read.
    static func transcript(at url: URL) -> BrowserAgentTranscript? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return transcript(data: data)
    }

    static func transcript(data: Data) -> BrowserAgentTranscript {
        let entries = data.split(separator: 0x0A).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
        }.filter { $0["id"] is String && $0["type"] as? String != "session" }
        let branch = activeBranch(entries)
        var transcript = BrowserAgentTranscript()
        var last: Date?
        for entry in entries {
            guard entry["type"] as? String == "message",
                  let id = entry["id"] as? String,
                  branch?.contains(id) ?? true,
                  let message = entry["message"] as? [String: Any],
                  // A failed reply omp retried: the retry is the reply.
                  message["retryRecovery"] == nil || message["retryRecovery"] is NSNull
            else { continue }
            let date = Self.date(of: message, entry: entry) ?? last ?? Date(timeIntervalSince1970: 0)
            last = date
            switch message["role"] as? String {
            case "user":
                // Messages an extension or the agent wrote for the user's
                // side aren't the user's.
                if let attribution = message["attribution"] as? String, attribution != "user" { continue }
                let parsed = BrowserAgentProtocol.parseMessage(text(of: message["content"]))
                transcript.addUser(parsed.text, page: parsed.page, at: date)
            case "assistant":
                let blocks = message["content"] as? [[String: Any]] ?? []
                let calls = blocks.filter { $0["type"] as? String == "toolCall" }
                let stopReason = message["stopReason"] as? String
                transcript.apply(.assistantEnd(
                    messageID: id,
                    text: text(of: blocks),
                    answers: stopReason == "stop" && calls.isEmpty
                ), at: date)
                for call in calls {
                    guard let callID = call["id"] as? String, let name = call["name"] as? String else { continue }
                    let arguments = call["arguments"] as? [String: Any] ?? [:]
                    let intent = (call["intent"] as? String ?? arguments["i"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    transcript.apply(.toolStart(
                        callID: callID,
                        title: BrowserAgentProtocol.toolTitle(name: name, arguments: arguments),
                        intent: intent
                    ), at: date)
                }
                if stopReason == "error" || stopReason == "aborted" {
                    transcript.apply(.promptResult(
                        status: stopReason ?? "",
                        error: message["errorMessage"] as? String,
                        settled: true
                    ), at: date)
                }
            case "toolResult":
                guard let callID = message["toolCallId"] as? String else { continue }
                let failed = message["isError"] as? Bool == true
                let output = text(of: message["content"], separator: "\n")
                transcript.apply(.toolEnd(callID: callID, error: failed ? (output.isEmpty ? "Failed" : output) : nil), at: date)
            default:
                continue
            }
        }
        // A run the file ends in the middle of (omp was stopped) ends there.
        transcript.processEnded(at: last ?? Date(timeIntervalSince1970: 0))
        return transcript
    }

    /// The ids on the active branch: from omp's leaf (the last entry, or
    /// the leaf an off-branch entry recorded) back along `parentId`. Nil
    /// (every entry) when the tree doesn't resolve.
    static func activeBranch(_ entries: [[String: Any]]) -> Set<String>? {
        guard let leaf = leaf(entries) else { return entries.isEmpty ? nil : [] }
        var parents: [String: String] = [:]
        for entry in entries {
            guard let id = entry["id"] as? String else { continue }
            if let parent = entry["parentId"] as? String { parents[id] = parent }
        }
        var branch: Set<String> = []
        var current: String? = leaf
        while let id = current, branch.insert(id).inserted {
            current = parents[id]
        }
        // An entry without a parent field (older writers) can't be placed.
        return entries.contains(where: { $0["parentId"] == nil }) ? nil : branch
    }

    /// omp's `resolveSessionLeafId`: the last entry's leaf (itself, or the
    /// active leaf it recorded when written off the branch); a recorded
    /// leaf that is gone falls back to the newest entry that is its own.
    private static func leaf(_ entries: [[String: Any]]) -> String? {
        func leaf(of entry: [String: Any]) -> String? {
            guard let recorded = entry["activeLeafId"] else { return entry["id"] as? String }
            return recorded as? String
        }
        guard let last = entries.last else { return nil }
        let ids = Set(entries.compactMap { $0["id"] as? String })
        if last["activeLeafId"] is NSNull { return nil }
        if let id = leaf(of: last), ids.contains(id) { return id }
        return entries.last { leaf(of: $0) == $0["id"] as? String }?["id"] as? String
    }

    /// A message's text blocks, joined; a plain string as it is.
    private static func text(of content: Any?, separator: String = "\n\n") -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: separator)
    }

    /// The message's own time (epoch milliseconds; a reply's when it
    /// finished, `completedAt`, as the panel saw it), else the entry's.
    private static func date(of message: [String: Any], entry: [String: Any]) -> Date? {
        if let milliseconds = message["completedAt"] as? Double ?? message["timestamp"] as? Double {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        guard let stamp = entry["timestamp"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
    }
}
