@testable import SopranoWeb
import AppKit
import Testing

/// The frames below are omp 18.16's own (`--mode rpc`, delta updates).
struct BrowserAgentProtocolTests {
    @Test func hostToolCallCarriesTheCommandWords() {
        let event = BrowserAgentProtocol.decode(#"""
        {"type":"host_tool_call","id":"15c1","toolCallId":"toolu_01","toolName":"browser","arguments":{"args":["goto","https://example.com"]}}
        """#)
        #expect(event == .hostToolCall(id: "15c1", toolName: "browser", arguments: ["goto", "https://example.com"]))
    }

    @Test func hostToolCallWithOtherArgumentsHasNone() {
        let event = BrowserAgentProtocol.decode(#"""
        {"type":"host_tool_call","id":"h2","toolName":"browser","arguments":{"args":"goto https://example.com"}}
        """#)
        #expect(event == .hostToolCall(id: "h2", toolName: "browser", arguments: nil))
    }

    @Test func toolStartNamesTheCommandAndKeepsTheIntent() {
        let event = BrowserAgentProtocol.decode(#"""
        {"type":"tool_execution_start","toolCallId":"toolu_01","toolName":"browser","args":{"args":["title"]},"intent":"Getting current page title"}
        """#)
        #expect(event == .toolStart(callID: "toolu_01", title: "browser title", intent: "Getting current page title"))
    }

    @Test func toolTitlesPickTheTellingArgument() {
        #expect(BrowserAgentProtocol.toolTitle(name: "bash", arguments: ["command": "git status\n", "i": "x"]) == "bash git status")
        #expect(BrowserAgentProtocol.toolTitle(name: "read", arguments: ["path": "notes.md"]) == "read notes.md")
        #expect(BrowserAgentProtocol.toolTitle(name: "todo", arguments: ["op": "view", "i": "Viewing"]) == #"todo {"op":"view"}"#)
        #expect(BrowserAgentProtocol.toolTitle(name: "wait", arguments: ["i": "Waiting"]) == "wait")
        let long = BrowserAgentProtocol.toolTitle(name: "bash", arguments: ["command": String(repeating: "a", count: 400)])
        #expect(long.count == 160)
        #expect(long.hasSuffix("…"))
    }

    @Test func toolEndReportsOnlyFailures() {
        #expect(BrowserAgentProtocol.decode(#"""
        {"type":"tool_execution_end","toolCallId":"t1","toolName":"browser","result":{"content":[{"type":"text","text":"Example Domain"}]},"isError":false}
        """#) == .toolEnd(callID: "t1", error: nil))
        #expect(BrowserAgentProtocol.decode(#"""
        {"type":"tool_execution_end","toolCallId":"t2","toolName":"browser","result":{"content":[{"type":"text","text":"Element not found: @e9"}]},"isError":true}
        """#) == .toolEnd(callID: "t2", error: "Element not found: @e9"))
    }

    @Test func textDeltaKeepsItsBlock() {
        let event = BrowserAgentProtocol.decode(#"""
        {"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"The title is"},"message":{"role":"assistant"},"messageId":"msg-6"}
        """#)
        #expect(event == .textDelta(messageID: "msg-6", index: 1, text: "The title is"))
    }

    @Test func assistantEndJoinsOnlyTextBlocks() {
        let event = BrowserAgentProtocol.decode(#"""
        {"type":"message_end","messageId":"msg-6","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"One."},{"type":"toolCall","id":"t","name":"browser","arguments":{}},{"type":"text","text":"Two."}]}}
        """#)
        #expect(event == .assistantEnd(messageID: "msg-6", text: "One.\n\nTwo."))
    }

    @Test func userAndCustomMessagesAreIgnored() {
        #expect(BrowserAgentProtocol.decode(#"""
        {"type":"message_end","messageId":"msg-1","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
        """#) == nil)
        #expect(BrowserAgentProtocol.decode(#"{"type":"available_commands_update","commands":[]}"#) == nil)
        #expect(BrowserAgentProtocol.decode("not json") == nil)
    }

    @Test func promptResultCarriesTheProviderError() {
        let event = BrowserAgentProtocol.decode(#"""
        {"type":"prompt_result","id":"p","agentInvoked":true,"status":"error","error":{"message":"429 rate limited","retryable":true},"sessionSettled":false}
        """#)
        #expect(event == .promptResult(status: "error", error: "429 rate limited", settled: false))
    }

    @Test func onlyFailedResponsesSurface() {
        #expect(BrowserAgentProtocol.decode(#"{"id":"p","type":"response","command":"prompt","success":true}"#) == nil)
        #expect(BrowserAgentProtocol.decode(#"""
        {"type":"response","command":"prompt","success":false,"error":"No model available"}
        """#) == .commandFailed(command: "prompt", error: "No model available"))
    }

    @Test func messageNamesTheTabItWasSentFrom() {
        let page = BrowserAgentPage(title: "Example Domain", url: "https://example.com/")
        #expect(BrowserAgentProtocol.message("Summarize", page: page)
            == "Summarize\n\n[Current tab: Example Domain — https://example.com/]")
        #expect(BrowserAgentProtocol.message("Summarize", page: BrowserAgentPage(title: "", url: "https://a.test/"))
            == "Summarize\n\n[Current tab: https://a.test/ — https://a.test/]")
        #expect(BrowserAgentProtocol.message("Summarize", page: nil) == "Summarize")
    }

    @Test func hostToolResultMarksFailures() throws {
        let data = BrowserAgentProtocol.encode(BrowserAgentProtocol.hostToolResult(id: "h1", text: "No tab", isError: true))
        #expect(data.last == 0x0A)
        let frame = try #require(try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        #expect(frame["type"] as? String == "host_tool_result")
        #expect(frame["isError"] as? Bool == true)
        let ok = BrowserAgentProtocol.encode(BrowserAgentProtocol.hostToolResult(id: "h1", text: "Done.", isError: false))
        let okFrame = try #require(try JSONSerialization.jsonObject(with: ok.dropLast()) as? [String: Any])
        #expect(okFrame["isError"] == nil)
    }

    @Test func ompIsFoundInTheUserToolFoldersFirst() {
        let found = BrowserAgentSession.resolve(
            environment: ["PATH": "/usr/bin:/elsewhere"],
            home: "/Users/me",
            isExecutable: { $0 == "/Users/me/.bun/bin/omp" || $0 == "/elsewhere/omp" }
        )
        #expect(found?.path == "/Users/me/.bun/bin/omp")
        #expect(BrowserAgentSession.resolve(environment: ["PATH": "/usr/bin"], home: "/Users/me", isExecutable: { _ in false }) == nil)
    }

    @Test func childPathAddsToolFoldersOnce() {
        let environment = BrowserAgentSession.environment(
            inherited: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": "/Users/me"],
            home: "/Users/me"
        )
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(path.first == "/Users/me/.bun/bin")
        #expect(path.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(path.suffix(2) == ["/usr/bin", "/bin"])
        #expect(environment["HOME"] == "/Users/me")
    }

    @Test func agentCommandParses() throws {
        let send = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "agent", "send", "open", "the", "docs"])
        #expect(send?.command == "agent")
        #expect(send?.arguments == ["send", "open the docs"])
        #expect(try BrowserCommandRequest.parse(["SopranoWeb", "browser", "agent"])?.arguments == [])
        #expect(throws: BrowserAutomationError.self) {
            try BrowserCommandRequest.parse(["SopranoWeb", "browser", "agent", "send"])
        }
        #expect(throws: BrowserAutomationError.self) {
            try BrowserCommandRequest.parse(["SopranoWeb", "browser", "agent", "dance"])
        }
    }

    @Test func toolCallsThatReadStandardInputAreRefusedWhereverFlagsSit() {
        for words in [
            ["boost", "css", "example.com", "-"],
            ["--window", "1", "boost", "css", "example.com", "-"],
            ["boost", "--window", "1", "js", "example.com", "-"],
            ["boost", "css", "example.com", "--tab", "2", "-"],
        ] {
            #expect(throws: BrowserAutomationError.self, "\(words)") {
                try BrowserAgentChat.toolRequest(words, workingDirectory: "/Users/me")
            }
        }
    }

    @Test func toolCallsParseAsTheCLIWouldFromOmpsFolder() throws {
        let shot = try BrowserAgentChat.toolRequest(["--window", "2", "screenshot", "page.png"], workingDirectory: "/Users/me")
        #expect(shot.command == "screenshot")
        #expect(shot.windowIndex == 2)
        #expect(shot.arguments == ["/Users/me/page.png"])
        #expect(try BrowserAgentChat.toolRequest(["boost", "zap", "example.com", ".ad"], workingDirectory: "/").command == "boost")
    }

    @Test func launchFollowsSettingsAgent() throws {
        let plain = BrowserAgentLaunch(settings: .default, home: "/Users/me")
        #expect(plain.workingDirectory == "/Users/me")
        #expect(Array(plain.arguments.prefix(6)) == ["--mode", "rpc", "--no-ui", "--allow-home", "--cwd", "/Users/me"])
        #expect(!plain.arguments.contains("--model"))
        #expect(!plain.arguments.contains("--thinking"))
        #expect(plain.arguments.suffix(2).first == "--append-system-prompt")

        var settings = BrowserSettings.default
        settings.agentModel = "opus"
        settings.agentThinking = .low
        settings.agentDirectory = "/Users/me/work"
        let chosen = BrowserAgentLaunch(settings: settings, home: "/Users/me")
        #expect(chosen.workingDirectory == "/Users/me/work")
        let arguments = chosen.arguments
        let model = try #require(arguments.firstIndex(of: "--model"))
        #expect(arguments[model + 1] == "opus")
        let thinking = try #require(arguments.firstIndex(of: "--thinking"))
        #expect(arguments[thinking + 1] == "low")
    }

    @Test func agentSettingsDecodeTolerantly() throws {
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: Data(#"""
        {"agentThinking": "maximum", "agentModel": "opus", "agentIncludesPage": "no", "homepage": "x"}
        """#.utf8))
        #expect(settings.agentThinking == .default)
        #expect(settings.agentModel == "opus")
        #expect(settings.agentIncludesPage)
        #expect(settings.agentDirectory == nil)
        #expect(settings.homepage == "x")
    }
}
