@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserSessionRestoreTests {
    private let history = Data("archived back/forward list".utf8)

    private func temporaryStore() -> (BrowserSessionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebRestore-\(UUID().uuidString)", isDirectory: true)
        return (BrowserSessionStore(url: directory.appendingPathComponent("session.json")), directory)
    }

    @Test func interactionStateRoundTrips() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = BrowserSession(
            tabs: [
                BrowserTabState(url: "https://example.com/b", title: "B", zoom: 1.1, interactionState: history),
                BrowserTabState(url: nil, title: "New Tab", zoom: 1),
            ],
            selectedIndex: 0,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.save(session)
        let loaded = store.load()
        #expect(loaded == session)
        #expect(loaded?.tabs.first?.interactionState == history)
    }

    @Test func notYetLoadedTabKeepsAddressAndHistoryThroughASave() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = BrowserTabState(url: "https://example.com/b", title: "B", zoom: 1.25, interactionState: history)
        // A lazy tab's empty web view has no URL and no history of its own.
        let state = BrowserTabState.snapshot(
            pending: saved,
            isStartPage: false,
            failedURL: nil,
            currentURL: nil,
            title: "B",
            zoom: 1.25,
            interactionState: {
                Issue.record("A lazy tab must not read its empty web view's history")
                return nil
            }
        )
        store.save(BrowserSession(tabs: [state], selectedIndex: 0, savedAt: Date()))
        #expect(store.load()?.tabs == [saved])
    }

    @Test func loadedTabSavesItsLiveAddressAndHistory() {
        let state = BrowserTabState.snapshot(
            pending: nil,
            isStartPage: false,
            failedURL: nil,
            currentURL: "https://example.com/c",
            title: "C",
            zoom: 1,
            interactionState: { history }
        )
        #expect(state == BrowserTabState(url: "https://example.com/c", title: "C", zoom: 1, interactionState: history))
    }

    @Test func legacySessionWithoutInteractionStateOrClosedTabsLoads() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        {
          "version": 1,
          "tabs": [
            { "url": "https://example.com", "title": "Example", "zoom": 1 },
            { "url": "https://webkit.org", "title": "WebKit", "interactionState": 42 }
          ],
          "selectedIndex": 1,
          "savedAt": "2023-11-14T22:13:20Z"
        }
        """.utf8).write(to: store.url)

        let loaded = try #require(store.load())
        #expect(loaded.tabs == [
            BrowserTabState(url: "https://example.com", title: "Example", zoom: 1),
            BrowserTabState(url: "https://webkit.org", title: "WebKit", zoom: 1),
        ])
        #expect(loaded.closedTabs.isEmpty)
    }

    @Test func closedTabsPersistWithTheirHistory() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var closed = BrowserClosedTabStack()
        closed.push(BrowserTabState(url: "https://example.com/a", title: "A"))
        closed.push(BrowserTabState(url: "https://example.com/b", title: "B", interactionState: history))
        store.save(BrowserSession(tabs: [], selectedIndex: 0, savedAt: Date(), closedTabs: closed.entries))

        var reloaded = BrowserClosedTabStack(store.load()?.closedTabs ?? [])
        #expect(reloaded.pop() == BrowserTabState(url: "https://example.com/b", title: "B", interactionState: history))
        #expect(reloaded.pop()?.url == "https://example.com/a")
        #expect(reloaded.pop() == nil)
    }

    @Test func closedTabStackKeepsTheTwentyMostRecent() {
        var stack = BrowserClosedTabStack()
        for number in 1...25 {
            stack.push(BrowserTabState(url: "https://example.com/\(number)"))
        }
        #expect(stack.count == BrowserClosedTabStack.capacity)
        #expect(stack.entries.first?.url == "https://example.com/6")
        #expect(stack.pop()?.url == "https://example.com/25")

        let oversized = (1...30).map { BrowserTabState(url: "https://example.com/\($0)") }
        let loaded = BrowserClosedTabStack(oversized)
        #expect(loaded.count == 20)
        #expect(loaded.entries.first?.url == "https://example.com/11")
    }
}
