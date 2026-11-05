@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserAgentPanelViewTests {
    /// A panel showing a finished run: one tool call, then the answer.
    private func panel() -> BrowserAgentPanelView {
        let view = BrowserAgentPanelView(theme: .folioPaper)
        view.pasteboard = NSPasteboard(name: NSPasteboard.Name("soprano-web-test-\(UUID().uuidString)"))
        var transcript = BrowserAgentTranscript()
        transcript.addUser("Open it", page: nil)
        transcript.apply(.toolStart(callID: "t", title: "browser click @e2", intent: "Opening the link"))
        transcript.apply(.toolEnd(callID: "t", error: nil))
        transcript.apply(.assistantEnd(messageID: "m", text: "Opened **it**.", callsTools: false))
        transcript.apply(.settled)
        view.update(transcript, model: "")
        return view
    }

    /// Clicks the chat's `action` link as the text view reports a click;
    /// returns where it is.
    @discardableResult
    private func click(_ action: String, in view: BrowserAgentPanelView) throws -> Int {
        let chat = view.renderedChat
        var found: (url: URL, index: Int)?
        chat.enumerateAttribute(.link, in: NSRange(location: 0, length: chat.length)) { value, range, stop in
            guard let url = value as? URL, url.scheme == BrowserAgentRenderer.actionScheme, url.host() == action else { return }
            found = (url, range.location)
            stop.pointee = true
        }
        let link = try #require(found)
        #expect(view.textView(view.transcriptView, clickedOnLink: link.url, at: link.index))
        return link.index
    }

    @Test func theRunRowShowsThenHidesItsSteps() throws {
        let view = panel()
        #expect(view.renderedChat.string.contains("Worked for"))
        #expect(!view.renderedChat.string.contains("browser click @e2"))
        try click("steps", in: view)
        #expect(view.renderedChat.string.contains("browser click @e2"))
        try click("steps", in: view)
        #expect(!view.renderedChat.string.contains("browser click @e2"))
    }

    @Test func copyPutsTheAnswersMarkdownOnThePasteboard() throws {
        let view = panel()
        defer { view.pasteboard.releaseGlobally() }
        let index = try click("copy", in: view)
        #expect(view.pasteboard.string(forType: .string) == "Opened **it**.")
        #expect(view.renderedChat.attribute(.toolTip, at: index, effectiveRange: nil) as? String == "Copied")
    }

    @Test func webLinksAreLeftToTheTextView() {
        let view = panel()
        let url = URL(string: "https://example.com/")!
        #expect(!view.textView(view.transcriptView, clickedOnLink: url, at: 0))
    }
}
