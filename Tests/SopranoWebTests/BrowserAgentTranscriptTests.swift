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
        #expect(transcript.entries.first?.page?.title == "Example")
    }

    @Test func deltasOfSeveralBlocksJoinAndTheEndIsAuthoritative() {
        var transcript = sent()
        transcript.apply(.textDelta(messageID: "m", index: 1, text: "World"))
        transcript.apply(.textDelta(messageID: "m", index: 0, text: "Hello"))
        #expect(transcript.entries.last?.text == "Hello\n\nWorld")
        transcript.apply(.assistantEnd(messageID: "m", text: "Hello, world.", answers: true))
        #expect(transcript.entries.map(\.kind) == [.user, .assistant])
        #expect(transcript.entries.last?.text == "Hello, world.")
    }

    @Test func messagesOfToolCallsOnlyLeaveNoEntry() {
        var transcript = sent()
        transcript.apply(.thinking(messageID: "m"))
        transcript.apply(.assistantEnd(messageID: "m", text: "  ", answers: false))
        #expect(transcript.entries.map(\.kind) == [.user])
        #expect(transcript.isWorking)
        #expect(transcript.activity == "Thinking")
    }

    @Test func eachMessageGetsItsOwnEntry() {
        var transcript = sent()
        transcript.apply(.textDelta(messageID: "a", index: 0, text: "First"))
        transcript.apply(.assistantEnd(messageID: "a", text: "First", answers: true))
        transcript.apply(.textDelta(messageID: "b", index: 0, text: "Second"))
        #expect(transcript.entries.filter { $0.kind == .assistant }.map(\.text) == ["First", "Second"])
    }

    @Test func theAnswerEndsWorkWhileOmpStillReviewsTheTurn() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var transcript = BrowserAgentTranscript()
        transcript.addUser("test", page: nil, at: start)
        transcript.apply(.agentStart, at: start + 1)
        transcript.apply(.textDelta(messageID: "m", index: 0, text: "Connected."), at: start + 2)
        #expect(transcript.activity == "Writing")
        transcript.apply(.assistantEnd(messageID: "m", text: "Connected.", answers: true), at: start + 3)
        // omp's advisor reviews the turn before omp yields: no more "Writing…".
        #expect(!transcript.isWorking)
        #expect(transcript.activity == nil)
        transcript.apply(.promptResult(status: "completed", error: nil, settled: true), at: start + 10)
        #expect(!transcript.isWorking)
        #expect(transcript.entries.first?.duration == 3)
        #expect(transcript.entries.first?.runEnd == start + 3)
    }

    @Test func workResumesWhenOmpActsAfterTheAnswer() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var transcript = BrowserAgentTranscript()
        transcript.addUser("Open it", page: nil, at: start)
        transcript.apply(.assistantEnd(messageID: "m1", text: "Opened.", answers: true), at: start + 2)
        #expect(!transcript.isWorking)
        // The advisor's note sends the agent back to work.
        transcript.apply(.thinking(messageID: "m2"), at: start + 5)
        #expect(transcript.isWorking)
        #expect(transcript.activity == "Thinking")
        transcript.apply(.toolStart(callID: "t", title: "browser reload", intent: nil), at: start + 6)
        transcript.apply(.toolEnd(callID: "t", error: nil), at: start + 7)
        transcript.apply(.assistantEnd(messageID: "m3", text: "Reloaded too.", answers: true), at: start + 8)
        #expect(!transcript.isWorking)
        #expect(transcript.entries.first?.duration == 8)
    }

    @Test func aFailedReplyKeepsWorkingWhileOmpRetries() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var transcript = BrowserAgentTranscript()
        transcript.addUser("test", page: nil, at: start)
        transcript.apply(.agentStart, at: start + 1)
        transcript.apply(.assistantEnd(messageID: "m1", text: "", answers: false), at: start + 2)
        // omp backs off and retries: Stop stays.
        #expect(transcript.isWorking)
        transcript.apply(.textDelta(messageID: "m2", index: 0, text: "Hi."), at: start + 9)
        transcript.apply(.assistantEnd(messageID: "m2", text: "Hi.", answers: true), at: start + 10)
        #expect(!transcript.isWorking)
        #expect(transcript.entries.first?.duration == 10)
    }

    @Test func aRestartedOmpReusingMessageIDsAddsNewEntries() {
        var transcript = sent("Count")
        transcript.apply(.textDelta(messageID: "msg-2", index: 0, text: "1 2 3"))
        transcript.addNote("omp exited (status 143).")
        transcript.processEnded()
        transcript.addUser("Again", page: nil)
        // The next omp process numbers its messages from msg-1 again.
        transcript.apply(.textDelta(messageID: "msg-2", index: 0, text: "back"))
        transcript.apply(.assistantEnd(messageID: "msg-2", text: "back", answers: true))
        #expect(transcript.entries.map(\.kind) == [.user, .assistant, .note, .user, .assistant])
        #expect(transcript.entries.filter { $0.kind == .assistant }.map(\.text) == ["1 2 3", "back"])
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
        transcript.apply(.assistantEnd(messageID: "m", text: "Hi", answers: true))
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
        transcript.apply(.assistantEnd(messageID: "m", text: "Done.", answers: true))
        #expect(transcript.plainText == """
        you: Open it
        tool failed: browser click @e2 (Opening): gone
        agent: Done.
        """)
    }

    @Test func aRunShowsItsAnswerAfterTheLastToolAndHowLongItTookToAnswer() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var transcript = BrowserAgentTranscript()
        transcript.addUser("Open it", page: nil, at: start)
        transcript.apply(.textDelta(messageID: "m1", index: 0, text: "Looking."), at: start + 1)
        transcript.apply(.toolStart(callID: "t", title: "browser click @e2", intent: "Opening"), at: start + 2)
        // A steer while the run works: the run's time still counts from the first message.
        transcript.addUser("Faster", page: nil, at: start + 3)
        transcript.apply(.toolEnd(callID: "t", error: nil), at: start + 4)
        transcript.apply(.textDelta(messageID: "m2", index: 0, text: "Opened."), at: start + 5)
        transcript.apply(.assistantEnd(messageID: "m2", text: "Opened.", answers: true), at: start + 5)
        transcript.apply(.textDelta(messageID: "m3", index: 0, text: "It's IANA."), at: start + 6)
        transcript.apply(.assistantEnd(messageID: "m3", text: "It's IANA.", answers: true), at: start + 6)
        transcript.apply(.settled, at: start + 16)

        let runs = transcript.blocks.compactMap { block -> BrowserAgentTranscript.Run? in
            if case let .run(run) = block { run } else { nil }
        }
        #expect(runs.count == 2)
        #expect(runs[0].steps.map(\.text) == ["Looking.", "browser click @e2"])
        #expect(runs[0].answer.isEmpty)
        #expect(runs[0].duration == nil)
        #expect(runs[1].steps.isEmpty)
        #expect(runs[1].answer.map(\.text) == ["Opened.", "It's IANA."])
        #expect(runs[1].duration == 6)
        #expect(runs[1].end == start + 6)
    }
}
