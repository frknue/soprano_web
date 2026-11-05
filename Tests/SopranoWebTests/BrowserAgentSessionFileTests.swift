@testable import SopranoWeb
import AppKit
import Testing

struct BrowserAgentSessionFileTests {
    private static let start = 1_793_867_060_000.0

    /// One entry line of omp's session file, at `seconds` after `start`;
    /// `PARENT` is the entry before it unless `parent` names another.
    private func message(_ id: String, _ seconds: Double, parent: String? = nil, _ body: String) -> String {
        let parentField = parent.map { "\"\($0)\"" } ?? "PARENT"
        return """
        {"type":"message","id":"\(id)","parentId":\(parentField),"timestamp":"2026-11-05T08:24:20.000Z","message":\(body.replacingOccurrences(of: "TIME", with: String(Int(Self.start + seconds * 1000))))}
        """
    }

    /// A file as omp writes it: a title slot, a header, then entries each
    /// pointing at the one before (`PARENT`).
    private func file(_ lines: [String]) -> Data {
        var previous = "577d3c6b"
        var chained: [String] = []
        for line in lines {
            chained.append(line.replacingOccurrences(of: "PARENT", with: "\"\(previous)\""))
            if let match = line.firstMatch(of: #/"id":"([^"]+)"/#) {
                previous = String(match.1)
            }
        }
        return Data(([
            #"{"type":"title","v":1,"title":"","updatedAt":"2026-11-05T08:24:19.374Z","pad":"   "}"#,
            #"{"type":"session","version":3,"id":"01a1aacf-10ae-7432-97bd-dc5daf98b44c","timestamp":"2026-11-05T08:24:19.374Z","cwd":"/Users/me"}"#,
            #"{"type":"model_change","id":"577d3c6b","parentId":null,"model":"anthropic/claude"}"#,
        ] + chained).joined(separator: "\n").utf8)
    }

    @Test func onlyTheActiveBranchShowsAndRetriedRepliesStayOut() {
        let data = file([
            message("u1", 0, #"{"role":"user","content":"First","timestamp":TIME}"#),
            message("e1", 1, #"{"role":"assistant","content":[],"stopReason":"error","errorMessage":"overloaded","retryRecovery":true,"timestamp":TIME}"#),
            message("a1", 3, #"{"role":"assistant","content":[{"type":"text","text":"One."}],"stopReason":"stop","timestamp":TIME,"completedAt":\#(Int(Self.start + 9000))}"#),
            // A turn omp later moved off the branch.
            message("u2", 20, #"{"role":"user","content":"Abandoned","timestamp":TIME}"#),
            message("a2", 21, #"{"role":"assistant","content":[{"type":"text","text":"Gone."}],"stopReason":"stop","timestamp":TIME}"#),
            message("u3", 30, parent: "a1", #"{"role":"user","content":"Second","timestamp":TIME}"#),
            message("a3", 31, #"{"role":"assistant","content":[{"type":"text","text":"Two."}],"stopReason":"stop","timestamp":TIME}"#),
        ])
        let transcript = BrowserAgentSessionFile.transcript(data: data)
        #expect(transcript.plainText == """
        you: First
        agent: One.
        you: Second
        agent: Two.
        """)
        // The run took until the reply finished (`completedAt`), not until it began.
        #expect(transcript.entries.first?.duration == 9)
    }

    @Test func aSavedChatReadsBackAsItRanLive() throws {
        let data = file([
            message("u1", 0, #"{"role":"user","content":[{"type":"text","text":"Open its link\n\n[Current tab: Example Domain — https://example.com/]"}],"attribution":"user","timestamp":TIME}"#),
            #"{"type":"custom","customType":"tool_execution_start","data":{"toolCallId":"t1"},"id":"c1","parentId":PARENT}"#,
            message("a1", 2, #"{"role":"assistant","content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"Looking."},{"type":"toolCall","id":"t1","name":"browser","arguments":{"args":["click","@e9"],"i":"Opening the link"}}],"stopReason":"toolUse","timestamp":TIME}"#),
            message("r1", 3, #"{"role":"toolResult","toolCallId":"t1","toolName":"browser","content":[{"type":"text","text":"Element not found: @e9"}],"isError":true,"timestamp":TIME}"#),
            message("a2", 4, #"{"role":"assistant","content":[{"type":"toolCall","id":"t2","name":"browser","arguments":{"args":["click","@e2"]},"intent":"Retrying"}],"stopReason":"toolUse","timestamp":TIME}"#),
            message("r2", 5, #"{"role":"toolResult","toolCallId":"t2","toolName":"browser","content":[{"type":"text","text":"clicked"}],"isError":false,"timestamp":TIME}"#),
            message("a3", 9, #"{"role":"assistant","content":[{"type":"text","text":"Opened **IANA**."}],"stopReason":"stop","timestamp":TIME}"#),
            // An advisor's card is not the user's message.
            message("x1", 10, #"{"role":"user","content":"Consider checking the title.","attribution":"agent","timestamp":TIME}"#),
            "not json",
        ])
        let transcript = BrowserAgentSessionFile.transcript(data: data)
        #expect(!transcript.isWorking)
        #expect(transcript.plainText == """
        you: Open its link
        agent: Looking.
        tool failed: browser click @e9 (Opening the link): Element not found: @e9
        tool done: browser click @e2 (Retrying)
        agent: Opened **IANA**.
        """)
        let user = try #require(transcript.entries.first)
        #expect(user.page == BrowserAgentPage(title: "Example Domain", url: "https://example.com/"))
        #expect(user.date == Date(timeIntervalSince1970: Self.start / 1000))
        // The run took until its answer, as "Worked for 9s".
        let runs = transcript.blocks.compactMap { block -> BrowserAgentTranscript.Run? in
            if case let .run(run) = block { run } else { nil }
        }
        #expect(runs.count == 1)
        #expect(runs[0].duration == 9)
        #expect(runs[0].answer.map(\.text) == ["Opened **IANA**."])
    }

    @Test func failedAndStoppedRepliesBecomeNotesAndAnUnfinishedRunEnds() {
        let data = file([
            message("u1", 0, #"{"role":"user","content":[{"type":"text","text":"First"}],"timestamp":TIME}"#),
            message("a1", 1, #"{"role":"assistant","content":[],"stopReason":"error","errorMessage":"429 rate limited","timestamp":TIME}"#),
            message("u2", 60, #"{"role":"user","content":[{"type":"text","text":"Second"}],"timestamp":TIME}"#),
            message("a2", 61, #"{"role":"assistant","content":[{"type":"toolCall","id":"t9","name":"browser","arguments":{"args":["wait-for-load"]}}],"stopReason":"toolUse","timestamp":TIME}"#),
            // omp was stopped while the tool ran: the file ends here.
        ])
        let transcript = BrowserAgentSessionFile.transcript(data: data)
        #expect(!transcript.isWorking)
        #expect(transcript.plainText == """
        you: First
        note: 429 rate limited
        you: Second
        tool failed: browser wait-for-load
        """)
    }

    @Test func theNewestSessionFileOfAFolderIsTheChats() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SopranoWebSessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(BrowserAgentSessionFile.latest(in: folder) == nil)
        for name in [
            "2026-11-04T10-00-00-000Z_a.jsonl",
            "2026-11-05T08-45-32-604Z_b.jsonl",
            ".2026-11-06T00-00-00-000Z_c.jsonl.lock.os",
            "2026-11-07T00-00-00-000Z_d.txt",
        ] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        #expect(BrowserAgentSessionFile.latest(in: folder)?.lastPathComponent == "2026-11-05T08-45-32-604Z_b.jsonl")
    }
}
