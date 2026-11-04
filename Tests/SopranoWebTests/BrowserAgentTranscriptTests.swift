@testable import SopranoWeb
import AppKit
import Testing

struct BrowserAgentTranscriptTests {
    private func sent(_ text: String = "Go") -> BrowserAgentTranscript {
        var transcript = BrowserAgentTranscript()
        transcript.addUser(text, page: BrowserAgentPage(title: "Example", url: "https://example.com/"))
        return transcript
    }

    @Test func sendingStartsWork() {
        let transcript = sent()
        #expect(transcript.isWorking)
        #expect(transcript.entries.map(\.kind) == [.user])
        #expect(transcript.entries.first?.detail == "Example")
    }

    @Test func deltasOfSeveralBlocksJoinAndTheEndIsAuthoritative() {
        var transcript = sent()
        transcript.apply(.textDelta(messageID: "m", index: 1, text: "World"))
        transcript.apply(.textDelta(messageID: "m", index: 0, text: "Hello"))
        #expect(transcript.entries.last?.text == "Hello\n\nWorld")
        transcript.apply(.assistantEnd(messageID: "m", text: "Hello, world."))
        #expect(transcript.entries.map(\.kind) == [.user, .assistant])
        #expect(transcript.entries.last?.text == "Hello, world.")
    }

    @Test func messagesOfToolCallsOnlyLeaveNoEntry() {
        var transcript = sent()
        transcript.apply(.thinking(messageID: "m"))
        transcript.apply(.assistantEnd(messageID: "m", text: "  "))
        #expect(transcript.entries.map(\.kind) == [.user])
        #expect(transcript.activity == "Thinking")
    }

    @Test func eachMessageGetsItsOwnEntry() {
        var transcript = sent()
        transcript.apply(.textDelta(messageID: "a", index: 0, text: "First"))
        transcript.apply(.assistantEnd(messageID: "a", text: "First"))
        transcript.apply(.textDelta(messageID: "b", index: 0, text: "Second"))
        #expect(transcript.entries.filter { $0.kind == .assistant }.map(\.text) == ["First", "Second"])
    }

    @Test func toolCallsRunAndFail() {
        var transcript = sent()
        transcript.apply(.toolStart(callID: "t", title: "browser click @e9", intent: "Opening the link"))
        #expect(transcript.activity == "Running browser")
        #expect(transcript.entries.last?.toolState == .running)
        transcript.apply(.toolEnd(callID: "t", error: "Element not found: @e9\n\n  at x\nline 3\nline 4"))
        let tool = transcript.entries.last
        #expect(tool?.toolState == .failed)
        #expect(tool?.detail == "Opening the link")
        #expect(tool?.failure == "Element not found: @e9\n  at x\nline 3")
    }

    @Test func revisionsGrowOnlyWithChanges() {
        var transcript = sent()
        transcript.apply(.textDelta(messageID: "m", index: 0, text: "Hi"))
        let first = transcript.entries.last?.revision
        transcript.apply(.assistantEnd(messageID: "m", text: "Hi"))
        #expect(transcript.entries.last?.revision == first)
        transcript.apply(.textDelta(messageID: "m", index: 0, text: "!"))
        #expect((transcript.entries.last?.revision ?? 0) > (first ?? 0))
    }

    @Test func workEndsWhenTheSessionSettles() {
        var transcript = sent()
        transcript.apply(.promptResult(status: "completed", error: nil, settled: false))
        #expect(transcript.isWorking)
        transcript.apply(.settled)
        #expect(!transcript.isWorking)
        #expect(transcript.activity == nil)
    }

    @Test func errorsAndStopsBecomeNotes() {
        var transcript = sent()
        transcript.apply(.promptResult(status: "error", error: "429 rate limited", settled: true))
        #expect(transcript.entries.last?.kind == .note)
        #expect(transcript.entries.last?.text == "429 rate limited")
        #expect(!transcript.isWorking)

        var stopped = sent()
        stopped.apply(.toolStart(callID: "t", title: "browser wait-for-load", intent: nil))
        stopped.apply(.promptResult(status: "aborted", error: nil, settled: true))
        #expect(stopped.entries.map(\.kind) == [.user, .tool, .note])
        #expect(stopped.entries[1].toolState == .failed)
    }

    @Test func aRefusedPromptEndsWorkButSetupRefusalsDoNot() {
        var transcript = sent()
        transcript.apply(.commandFailed(command: "set_event_filter", error: "nope"))
        #expect(transcript.isWorking)
        #expect(transcript.entries.count == 1)
        transcript.apply(.commandFailed(command: "prompt", error: "No model available"))
        #expect(!transcript.isWorking)
        #expect(transcript.entries.last?.text == "No model available")
    }

    @Test func plainTextListsTheChat() {
        var transcript = sent("Open it")
        transcript.apply(.toolStart(callID: "t", title: "browser click @e2", intent: "Opening"))
        transcript.apply(.toolEnd(callID: "t", error: "gone"))
        transcript.apply(.assistantEnd(messageID: "m", text: "Done."))
        #expect(transcript.plainText == """
        you: Open it
        tool failed: browser click @e2 (Opening): gone
        agent: Done.
        """)
    }
}
