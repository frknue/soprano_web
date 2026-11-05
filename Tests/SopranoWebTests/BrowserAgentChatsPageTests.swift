@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserAgentChatsPageTests {
    @Test func theChatsPageIsAnAppPageNotTheStartPage() throws {
        let id = UUID()
        let page = BrowserAgentChatsPage.url(for: id)
        #expect(page.absoluteString == "soprano-web://chats#\(id.uuidString)")
        #expect(BrowserAgentChatsPage.isChats(page))
        #expect(BrowserAgentChatsPage.chatID(in: page) == id)
        #expect(BrowserAgentChatsPage.chatID(in: BrowserAgentChatsPage.url) == nil)
        #expect(BrowserAgentChatsPage.chatID(in: URL(string: "soprano-web://chats#nope")) == nil)
        #expect(BrowserAgentChatsPage.chatID(in: URL(string: "https://chats#\(id.uuidString)")) == nil)
        #expect(!BrowserAddressResolver.isStartPage(page))
        #expect(!BrowserWindowController.showsStartPage(page))
        #expect(BrowserAddressResolver.isStartPage(URL(string: "soprano-web://start")))
    }

    @Test func messagesAreCheckedBeforeTheyAct() {
        let id = UUID()
        #expect(BrowserAgentChatsPage.Message(["action": "send", "text": "Hi"]) == .send(chat: nil, text: "Hi"))
        #expect(BrowserAgentChatsPage.Message(["action": "send", "id": id.uuidString, "text": "Hi"]) == .send(chat: id, text: "Hi"))
        #expect(BrowserAgentChatsPage.Message(["action": "send", "text": "  \n"]) == nil)
        #expect(BrowserAgentChatsPage.Message([
            "action": "send", "text": String(repeating: "a", count: BrowserAgentChatsPage.Message.textLimit + 1),
        ]) == nil)
        #expect(BrowserAgentChatsPage.Message(["action": "delete"]) == nil)
        #expect(BrowserAgentChatsPage.Message(["action": "delete", "id": "not-a-uuid"]) == nil)
        #expect(BrowserAgentChatsPage.Message(["action": "pin", "id": id.uuidString, "pinned": true]) == .pin(id, true))
        #expect(BrowserAgentChatsPage.Message(["action": "copy", "id": id.uuidString, "run": 3]) == .copy(chat: id, run: 3))
        #expect(BrowserAgentChatsPage.Message(["action": "ready"]) == .ready(nil))
        #expect(BrowserAgentChatsPage.Message(["action": "launch"]) == nil)
    }

    @Test func answersRenderEscapedWithOnlyWebLinks() {
        let html = BrowserAgentChatsPage.markdownHTML("""
        # Title <b>
        Use `a<b>` and **bold** [site](https://example.com/?a=1&b=2) [bad](javascript:alert(1))

        - one
          - <img src=x onerror=alert(1)>
        ```
        <script>alert(1)</script>
        ```
        """)
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<img"))
        #expect(!html.contains("javascript:"))
        #expect(html.contains("<h3>Title &lt;b&gt;</h3>"))
        #expect(html.contains("<code>a&lt;b&gt;</code>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains(#"<a href="https://example.com/?a=1&amp;b=2" target="_blank" rel="noopener">site</a>"#))
        #expect(html.contains(#"style="--depth: 1""#))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    @Test func aChatRendersAsThePanelLaysItOut() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var transcript = BrowserAgentTranscript()
        transcript.addUser("Open <it>", page: BrowserAgentPage(title: "Example", url: "https://example.com/"), at: start)
        transcript.apply(.toolStart(callID: "t", title: "browser click @e2", intent: "Opening"), at: start + 1)
        transcript.apply(.toolEnd(callID: "t", error: "gone\nat x"), at: start + 2)
        transcript.apply(.assistantEnd(messageID: "m", text: "Done.", answers: true), at: start + 16)
        let html = BrowserAgentChatsPage.transcriptHTML(transcript)
        #expect(html.contains("<div class=\"bubble\">Open &lt;it&gt;</div>"))
        #expect(html.contains("<span class=\"card-host\">example.com</span>"))
        #expect(html.contains("Worked for 16s"))
        #expect(html.contains("class=\"tool failed\""))
        #expect(html.contains("<pre class=\"failure\">gone\nat x</pre>"))
        let run = try #require(transcript.blocks.compactMap { block -> Int? in
            if case let .run(run) = block { run.id } else { nil }
        }.first)
        #expect(html.contains("data-copy=\"\(run)\""))
        #expect(BrowserAgentChatsPage.answer(of: run, in: transcript) == "Done.")
        #expect(BrowserAgentChatsPage.answer(of: run + 100, in: transcript) == nil)

        // While it works: the running label, no Copy yet.
        var working = BrowserAgentTranscript()
        working.addUser("Go", page: nil, at: start)
        let live = BrowserAgentChatsPage.transcriptHTML(working)
        #expect(live.contains("runlabel live"))
        #expect(!live.contains("data-copy"))
    }
}
