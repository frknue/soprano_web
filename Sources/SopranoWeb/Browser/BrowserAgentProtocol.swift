import Foundation

/// What the Agent panel reads from omp's stdout, one JSONL frame each.
/// Frames the panel doesn't use (`available_commands_update`, `turn_*`,
/// user and custom messages, …) decode to nil.
enum BrowserAgentEvent: Equatable, Sendable {
    case ready
    case agentStart
    /// A delta of the assistant message's text block `index`.
    case textDelta(messageID: String, index: Int, text: String)
    /// The assistant message is thinking (a thinking block streams).
    case thinking(messageID: String)
    /// The assistant message ended: its text blocks, joined.
    case assistantEnd(messageID: String, text: String)
    case toolStart(callID: String, title: String, intent: String?)
    /// `error` is the tool's output when it failed.
    case toolEnd(callID: String, error: String?)
    /// omp asks the host to run one of its tools: `browser` with
    /// `{"args": [String]}`; `arguments` is nil when they have another shape.
    case hostToolCall(id: String, toolName: String, arguments: [String]?)
    /// `status` is `completed`, `aborted` or `error`; `settled` is false while
    /// background work can still wake the agent.
    case promptResult(status: String, error: String?, settled: Bool)
    case settled
    /// A failed command (`prompt`, `set_host_tools`, …).
    case commandFailed(command: String, error: String)
}

/// Settings ▸ Agent ▸ Thinking: omp's `--thinking` level, or none
/// (`default`: omp's own).
enum BrowserAgentThinking: String, CaseIterable, Codable, Sendable {
    case `default`, off, minimal, low, medium, high, xhigh

    var name: String {
        switch self {
        case .default: "omp’s default"
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        }
    }
}

/// How a window's omp starts: its folder, model and thinking level, read
/// from Settings ▸ Agent when a chat's first message starts omp.
struct BrowserAgentLaunch: Equatable, Sendable {
    var workingDirectory: String
    /// Empty: omp's default model.
    var model: String = ""
    var thinking: BrowserAgentThinking = .default

    init(workingDirectory: String, model: String = "", thinking: BrowserAgentThinking = .default) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.thinking = thinking
    }

    init(settings: BrowserSettings, home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        let folder = settings.agentDirectory.flatMap { $0.isEmpty ? nil : $0 }
        self.init(
            workingDirectory: folder ?? home,
            model: settings.agentModel.trimmingCharacters(in: .whitespacesAndNewlines),
            thinking: settings.agentThinking
        )
    }

    /// `omp --mode rpc --no-ui --allow-home --cwd <dir> [--model <m>]
    /// [--thinking <level>] --append-system-prompt <prompt>`. No UI
    /// requests: omp's dialogs resolve to their defaults and a tool its
    /// approval policy would prompt for fails closed.
    var arguments: [String] {
        var arguments = ["--mode", "rpc", "--no-ui", "--allow-home", "--cwd", workingDirectory]
        if !model.isEmpty { arguments += ["--model", model] }
        if thinking != .default { arguments += ["--thinking", thinking.rawValue] }
        return arguments + ["--append-system-prompt", BrowserAgentProtocol.systemPrompt]
    }
}

/// omp's `--mode rpc` JSONL protocol (omp 18.16, `omp://rpc.md`), as the
/// Agent panel speaks it: one `omp` child per window, the window's
/// `browser` host tool, prompts and aborts in, events out. Pure, so the
/// wire format is testable without a process.
enum BrowserAgentProtocol {
    static let hostToolName = "browser"

    /// The longest model name Settings ▸ Agent accepts.
    static let modelLimit = 200

    /// A model as typed into Settings ▸ Agent: trimmed; nil when it is too
    /// long or holds spaces or control characters (no model name does).
    static func validModel(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= modelLimit,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    static let systemPrompt = """
    You are the agent in Soprano Web's Agent panel: a chat beside the pages of one \
    window of Soprano Web, a macOS WebKit browser. The user writes to you from that \
    panel while looking at a page. Each user message ends with a `[Current tab: …]` \
    line naming the window's selected tab when they sent it.

    Use the `browser` tool to read and act in that window: it runs one Soprano Web \
    browser command and returns its output. Without `--window` it acts on this chat's \
    window, without `--tab` on its selected tab, the one the message names. A Peek \
    shown over that tab is not it: `peek` prints the Peek, `peek open-as-tab` makes \
    it the selected tab. Read a page with `snapshot \
    --interactive` (refs such as @e1 for click and fill) or `get text body`, act \
    with goto, click, fill, press, eval, new-tab, wait-for-load. For a picture of \
    the page, `screenshot /tmp/<name>.png`, then read that file. When the user asks \
    you to do something on a page, do it in the browser rather than describing the \
    steps.
    """

    /// The `browser` host tool: the words after `soprano-web browser`.
    static func hostToolDefinition(help: String) -> [String: Any] {
        [
            "name": hostToolName,
            "label": "Browser",
            "description": """
            Runs one Soprano Web browser command in the window this chat belongs to and \
            returns its output. `args` are the words that follow `soprano-web browser`, \
            one array item per word, e.g. ["goto", "https://example.com"], \
            ["snapshot", "--interactive"], ["click", "@e3"], ["fill", "@e5", "hello"], \
            ["eval", "document.title"]. `agent` commands are not available here.

            \(help)
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "args": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "The command and its arguments, one item per word.",
                    ],
                ],
                "required": ["args"],
                "additionalProperties": false,
            ] as [String: Any],
            "loadMode": "essential",
        ]
    }

    /// The events the panel reads, with `message_update` reduced to deltas.
    static var eventFilter: [String: Any] {
        [
            "type": "set_event_filter",
            "events": [
                "agent_start", "message_start", "message_update", "message_end",
                "tool_execution_start", "tool_execution_end",
            ],
            "messageUpdates": "delta",
        ]
    }

    /// A prompt. While a run is live `steer` delivers it into that run
    /// instead of being refused.
    static func prompt(_ message: String) -> [String: Any] {
        ["type": "prompt", "message": message, "streamingBehavior": "steer"]
    }

    static func hostToolResult(id: String, text: String, isError: Bool) -> [String: Any] {
        var frame: [String: Any] = [
            "type": "host_tool_result",
            "id": id,
            "result": ["content": [["type": "text", "text": text]]],
        ]
        if isError { frame["isError"] = true }
        return frame
    }

    /// One stdin line.
    static func encode(_ frame: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: frame, options: [.withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// The message sent for what the user typed: their text, then the tab
    /// they were looking at.
    static func message(_ text: String, page: BrowserAgentPage?) -> String {
        guard let page else { return text }
        let title = page.title.isEmpty ? page.url : page.title
        return "\(text)\n\n[Current tab: \(title) — \(page.url)]"
    }

    // MARK: - stdout

    static func decode(_ line: String) -> BrowserAgentEvent? {
        guard let data = line.data(using: .utf8),
              let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = frame["type"] as? String
        else { return nil }
        switch type {
        case "ready":
            return .ready
        case "agent_start":
            return .agentStart
        case "message_update":
            guard let messageID = frame["messageId"] as? String,
                  let event = frame["assistantMessageEvent"] as? [String: Any]
            else { return nil }
            switch event["type"] as? String {
            case "text_delta":
                guard let delta = event["delta"] as? String else { return nil }
                return .textDelta(messageID: messageID, index: event["contentIndex"] as? Int ?? 0, text: delta)
            case "thinking_start", "thinking_delta":
                return .thinking(messageID: messageID)
            default:
                return nil
            }
        case "message_end":
            guard let messageID = frame["messageId"] as? String,
                  let message = frame["message"] as? [String: Any],
                  message["role"] as? String == "assistant"
            else { return nil }
            let blocks = message["content"] as? [[String: Any]] ?? []
            let text = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n\n")
            return .assistantEnd(messageID: messageID, text: text)
        case "tool_execution_start":
            guard let callID = frame["toolCallId"] as? String,
                  let name = frame["toolName"] as? String
            else { return nil }
            let intent = (frame["intent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .toolStart(
                callID: callID,
                title: toolTitle(name: name, arguments: frame["args"] as? [String: Any] ?? [:]),
                intent: intent
            )
        case "tool_execution_end":
            guard let callID = frame["toolCallId"] as? String else { return nil }
            guard frame["isError"] as? Bool == true else { return .toolEnd(callID: callID, error: nil) }
            let result = frame["result"] as? [String: Any]
            let text = (result?["content"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            return .toolEnd(callID: callID, error: text.isEmpty ? "Failed" : text)
        case "host_tool_call":
            guard let id = frame["id"] as? String, let name = frame["toolName"] as? String else { return nil }
            let arguments = (frame["arguments"] as? [String: Any])?["args"] as? [String]
            return .hostToolCall(id: id, toolName: name, arguments: arguments)
        case "prompt_result":
            let error = (frame["error"] as? [String: Any])?["message"] as? String
            return .promptResult(
                status: frame["status"] as? String ?? "completed",
                error: error,
                settled: frame["sessionSettled"] as? Bool ?? true
            )
        case "session_settled":
            return .settled
        case "response":
            guard frame["success"] as? Bool == false else { return nil }
            return .commandFailed(
                command: frame["command"] as? String ?? "",
                error: frame["error"] as? String ?? "omp refused the command."
            )
        default:
            return nil
        }
    }

    /// One line for a tool call: its name and the argument that says what
    /// it does (`browser goto …`, `bash git status`, `read notes.md`), else
    /// its arguments as JSON. `i` (omp's intent) is shown separately.
    static func toolTitle(name: String, arguments: [String: Any]) -> String {
        let detail: String
        if name == hostToolName, let words = arguments["args"] as? [String] {
            detail = words.joined(separator: " ")
        } else if let key = ["command", "path", "url", "query", "pattern", "code"].first(where: { arguments[$0] is String }),
                  let value = arguments[key] as? String
        {
            detail = value
        } else {
            var rest = arguments
            rest.removeValue(forKey: "i")
            if rest.isEmpty {
                detail = ""
            } else if let data = try? JSONSerialization.data(
                withJSONObject: rest,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ) {
                detail = String(decoding: data, as: UTF8.self)
            } else {
                detail = ""
            }
        }
        let line = detail
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let title = line.isEmpty ? name : "\(name) \(line)"
        return title.count > 160 ? String(title.prefix(159)) + "…" : title
    }
}

/// The tab a message was sent from.
struct BrowserAgentPage: Equatable, Sendable {
    var title: String
    var url: String
}
