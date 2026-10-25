@testable import SopranoWeb
import AppKit
import Testing

struct AddressSuggestionEngineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func visit(
        _ url: String,
        _ title: String,
        hoursAgo: Double = 1,
        typed: Bool = false
    ) -> BrowserHistoryEntry {
        BrowserHistoryEntry(
            url: url,
            title: title,
            visitedAt: now.addingTimeInterval(-hoursAgo * 3_600),
            typed: typed ? true : nil
        )
    }

    private func suggest(
        _ query: String,
        history: [BrowserHistoryEntry] = [],
        bookmarks: [BrowserBookmark] = [],
        tabs: [AddressSuggestionTab] = [],
        remote: [String] = [],
        completes: Bool = true
    ) -> AddressSuggestionResult {
        AddressSuggestionEngine.suggestions(for: AddressSuggestionInput(
            query: query,
            history: history,
            bookmarks: bookmarks,
            tabs: tabs,
            searchEngine: .duckDuckGo,
            remoteSuggestions: remote,
            allowsInlineCompletion: completes,
            now: now
        ))
    }

    // MARK: Ranking

    @Test func hostPrefixBeatsTitleWordStartBeatsSubstring() {
        let history = [
            // Substring only ("forum" inside the host), visited most.
            visit("https://myforum.example/", "Board", typed: true),
            visit("https://myforum.example/", "Board", typed: true),
            visit("https://myforum.example/", "Board", typed: true),
            // Title word start.
            visit("https://news.example/", "The Forum Times"),
            visit("https://news.example/", "The Forum Times"),
            // Host prefix (after www.), visited once.
            visit("https://www.forum.example/", "Home", hoursAgo: 400),
        ]
        let urls = suggest("forum", history: history, completes: false).rows.compactMap { row -> String? in
            if case .url(let url) = row.target, row.kind != .url { return url }
            return nil
        }
        #expect(urls == [
            "https://www.forum.example/",
            "https://news.example/",
            "https://myforum.example/",
        ])
    }

    @Test func typedVisitsCountsAndRecencyBoostWithinATier() {
        let history = [
            visit("https://alpha.example/", "Alpha", hoursAgo: 2),
            visit("https://alpine.example/", "Alpine", hoursAgo: 2, typed: true),
            visit("https://alps.example/", "Alps", hoursAgo: 2),
            visit("https://alps.example/", "Alps", hoursAgo: 3),
            visit("https://alpaca.example/", "Alpaca", hoursAgo: 24 * 60),
        ]
        let titles = suggest("al", history: history, completes: false).rows
            .filter { $0.kind == .history }
            .map(\.title)
        // Typed weighs more than a second visit; a two-month-old visit last.
        #expect(titles == ["Alpine", "Alps", "Alpha", "Alpaca"])
        #expect(
            AddressSuggestionEngine.boost(visits: 1, typedVisits: 0, isBookmarked: false, lastVisit: now, now: now)
                > AddressSuggestionEngine.boost(
                    visits: 1, typedVisits: 0, isBookmarked: false,
                    lastVisit: now.addingTimeInterval(-30 * 86_400), now: now
                )
        )
    }

    @Test func visitStatsAggregateCountsTypedAndLastVisit() {
        let history = [
            visit("https://a.example/", "A new", hoursAgo: 1, typed: true),
            visit("https://b.example/", "B", hoursAgo: 2),
            visit("https://a.example/", "A old", hoursAgo: 5),
            visit("https://a.example/", "", hoursAgo: 9, typed: true),
        ]
        let stats = AddressSuggestionEngine.visitStats(history)
        #expect(stats.count == 2)
        let a = stats[0]
        #expect(a.url == "https://a.example/")
        #expect(a.visits == 3)
        #expect(a.typedVisits == 2)
        #expect(a.title == "A new")
        #expect(a.lastVisit == now.addingTimeInterval(-3_600))
        #expect(stats[1].visits == 1)
        #expect(stats[1].typedVisits == 0)
    }

    // MARK: Dedupe

    @Test func samePageAppearsOnceAcrossTabsBookmarksAndHistory() {
        let tabID = UUID()
        let result = suggest(
            "swift",
            history: [
                visit("https://www.swift.org/documentation/", "Swift Docs"),
                visit("http://swift.org/documentation/#intro", "Swift Docs"),
                visit("https://swift.org/blog/", "Swift Blog"),
            ],
            bookmarks: [
                BrowserBookmark(url: "https://swift.org/blog", title: "Blog (bookmark)"),
            ],
            tabs: [
                AddressSuggestionTab(id: tabID, title: "Docs tab", url: "https://swift.org/documentation/"),
            ],
            completes: false
        )
        let local = result.rows.filter { [.switchToTab, .history, .bookmark].contains($0.kind) }
        #expect(local.count == 2)
        #expect(local.contains { $0.kind == .switchToTab && $0.target == .tab(tabID) })
        #expect(local.contains { $0.kind == .bookmark && $0.title == "Blog (bookmark)" })
        #expect(!local.contains { $0.kind == .history })
    }

    @Test func rowsStayWithinTheLimitAndKeepTheSearchRow() {
        let history = (0..<20).map { visit("https://site\($0).example/", "Rust page \($0)") }
        let result = suggest(
            "rust",
            history: history,
            remote: ["rust book", "rust lang", "rust", "Rust Book", "rust analyzer", "rustup"]
        )
        #expect(result.rows.count == 8)
        #expect(result.rows.first?.kind == .search)
        let suggestions = result.rows.filter { $0.kind == .searchSuggestion }.map(\.title)
        // The query itself and case duplicates drop; three slots are kept.
        #expect(suggestions == ["rust book", "rust lang", "rust analyzer"])
    }

    @Test func nonAddressInputOffersSearchAddressInputDoesNot() {
        let search = suggest("how to bake bread")
        #expect(search.rows.first == AddressSuggestion(
            kind: .search,
            title: "Search “how to bake bread”",
            detail: "DuckDuckGo",
            target: .search("how to bake bread"),
            fillText: "how to bake bread"
        ))

        let address = suggest("example.com/path")
        #expect(address.rows.first?.kind == .url)
        #expect(address.rows.first?.target == .url("https://example.com/path"))
        #expect(!address.rows.contains { $0.kind == .search })
        #expect(suggest("   ").rows.isEmpty)
    }

    @Test func typedAddressKeepsItsSchemeWhenHistoryHasAnother() {
        let result = suggest(
            "http://neverssl.com",
            history: [visit("https://neverssl.com/", "NeverSSL")],
            completes: false
        )
        #expect(result.rows.first?.target == .url("http://neverssl.com"))
        #expect(result.rows.first?.title == "NeverSSL")
    }

    // MARK: Inline completion

    @Test func completesTheHostOfTheStrongestSite() {
        let history = [
            visit("https://github.com/frknue/soprano_web", "Soprano Web", typed: true),
            visit("https://github.com/frknue/soprano_web", "Soprano Web"),
            visit("https://gist.github.com/", "Gists", hoursAgo: 300),
        ]
        let result = suggest("gi", history: history)
        #expect(result.inlineCompletion == "github.com")
        #expect(result.rows.first?.target == .url("https://github.com/"))
        #expect(result.rows.first?.fillText == "github.com")
        #expect(result.rows.contains { $0.kind == .search && $0.target == .search("gi") })
    }

    @Test func completionKeepsTypedCaseSchemeAndWww() {
        let history = [visit("https://www.webkit.org/blog/", "Blog")]
        #expect(suggest("WEB", history: history).inlineCompletion == "WEBkit.org")
        #expect(suggest("www.we", history: history).inlineCompletion == "www.webkit.org")
        #expect(suggest("https://web", history: history).inlineCompletion == "https://webkit.org")
        #expect(suggest("localhost:8", history: [visit("http://localhost:8000/app", "App")])
            .inlineCompletion == "localhost:8000")
    }

    @Test func completionStopsAtTheHostAndAfterDeletion() {
        let history = [visit("https://github.com/frknue/soprano_web", "Soprano Web")]
        #expect(suggest("github.com", history: history).inlineCompletion == nil)
        #expect(suggest("github.com/fr", history: history).inlineCompletion == nil)
        #expect(suggest("git hub", history: history).inlineCompletion == nil)
        #expect(suggest("soprano", history: history).inlineCompletion == nil)
        #expect(suggest("git", history: history, completes: false).inlineCompletion == nil)
    }

    @Test func completionOfAnOpenTabSwitchesToIt() {
        let tabID = UUID()
        let result = suggest(
            "exa",
            tabs: [AddressSuggestionTab(id: tabID, title: "Example", url: "https://example.com/")]
        )
        #expect(result.inlineCompletion == "example.com")
        #expect(result.rows.first?.kind == .switchToTab)
        #expect(result.rows.first?.target == .tab(tabID))
        #expect(result.rows.filter { $0.target == .tab(tabID) }.count == 1)
    }

    @Test func completionFollowsTypingForwardOnly() {
        #expect(AddressInlineCompletion.isAllowed(lastEditWasDeletion: false, caretAtEnd: true, hasMarkedText: false))
        #expect(!AddressInlineCompletion.isAllowed(lastEditWasDeletion: true, caretAtEnd: true, hasMarkedText: false))
        #expect(!AddressInlineCompletion.isAllowed(lastEditWasDeletion: false, caretAtEnd: false, hasMarkedText: false))
        #expect(!AddressInlineCompletion.isAllowed(lastEditWasDeletion: false, caretAtEnd: true, hasMarkedText: true))

        #expect(AddressInlineCompletion.suffix(typed: "Gi", completion: "Github.com") == "thub.com")
        #expect(AddressInlineCompletion.suffix(typed: "github.com", completion: "github.com") == nil)
        #expect(AddressInlineCompletion.suffix(typed: "gx", completion: "github.com") == nil)
        #expect(AddressInlineCompletion.suffix(typed: "gi", completion: nil) == nil)
    }

    // MARK: URL text

    @Test func displayAndKeyIgnoreSchemeWwwAndBareSlash() {
        #expect(AddressURLText.display("https://www.example.com/") == "example.com")
        #expect(AddressURLText.display("http://example.com/a/") == "example.com/a/")
        #expect(AddressURLText.key("https://www.Example.com/#top") == AddressURLText.key("http://example.com"))
        #expect(AddressURLText.key("https://example.com/a?b=1") != AddressURLText.key("https://example.com/a"))
        #expect(AddressURLText.key("https://example.com:8443/") != AddressURLText.key("https://example.com/"))
    }
}
