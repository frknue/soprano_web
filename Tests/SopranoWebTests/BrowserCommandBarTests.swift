@testable import SopranoWeb
import AppKit
import Testing

struct BrowserCommandBarTests {
    private let wikipedia = BrowserSearchEngine(
        id: BrowserSearchEngineID(rawValue: "wiki-test"),
        name: "Wikipedia",
        keyword: "w",
        template: "https://en.wikipedia.org/w/index.php?search=%s"
    )

    private var engines: BrowserSearchEngines {
        BrowserSearchEngines(custom: [wikipedia], builtInKeywords: [:], defaultID: .duckDuckGo)
    }

    private func groups(_ input: BrowserCommandBarInput) -> [String: [BrowserCommandBarRow]] {
        Dictionary(BrowserCommandBarEngine.groups(for: input).map { ($0.title, $0.rows) }, uniquingKeysWith: { a, _ in a })
    }

    private func action(_ id: BrowserCommandID, _ title: String, _ synonyms: [String] = []) -> BrowserCommandBarInput.Action {
        .init(id: id, title: title, synonyms: synonyms, shortcut: "", symbol: "")
    }

    // MARK: What Return opens

    @Test func firstRowIsKeywordSearchAddressOrDefaultSearch() {
        let keyword = BrowserCommandBarEngine.groups(for: .init(query: "w cats", searchEngines: engines))
        #expect(keyword.first?.rows.first?.target == .search(engine: wikipedia.id, query: "cats"))
        let address = BrowserCommandBarEngine.groups(for: .init(query: "example.com/a", searchEngines: engines))
        #expect(address.first?.rows.first?.target == .url("https://example.com/a"))
        let search = BrowserCommandBarEngine.groups(for: .init(query: "cats and dogs", searchEngines: engines))
        #expect(search.first?.rows.first?.target == .search(engine: .duckDuckGo, query: "cats and dogs"))
        // "b tree": built-ins have no keyword, so it stays a default search.
        let plain = BrowserCommandBarEngine.groups(for: .init(query: "b tree", searchEngines: engines))
        #expect(plain.first?.rows.first?.target == .search(engine: .duckDuckGo, query: "b tree"))
    }

    // MARK: Site search

    @Test func tabOnAKeywordOrUniqueNameEntersSiteSearch() {
        #expect(BrowserCommandBarEngine.siteSearchEngine(for: "w", engines: engines)?.id == wikipedia.id)
        #expect(BrowserCommandBarEngine.siteSearchEngine(for: " W ", engines: engines)?.id == wikipedia.id)
        #expect(BrowserCommandBarEngine.siteSearchEngine(for: "wiki", engines: engines)?.id == wikipedia.id)
        #expect(BrowserCommandBarEngine.siteSearchEngine(for: "goo", engines: engines)?.id == .google)
        // One letter is only ever a keyword; text with a space is a query.
        #expect(BrowserCommandBarEngine.siteSearchEngine(for: "g", engines: engines) == nil)
        #expect(BrowserCommandBarEngine.siteSearchEngine(for: "w cats", engines: engines) == nil)
        #expect(BrowserCommandBarEngine.siteSearchEngine(for: "zz", engines: engines) == nil)
    }

    @Test func siteSearchShowsOnlyThatEnginesSearch() {
        var input = BrowserCommandBarInput(query: "cats", siteSearch: wikipedia.id, searchEngines: engines)
        input.tabs = [.init(id: UUID(), title: "Cats", url: "https://cats.example/")]
        let groups = BrowserCommandBarEngine.groups(for: input)
        #expect(groups.flatMap(\.rows).map(\.target) == [.search(engine: wikipedia.id, query: "cats")])
        #expect(groups.first?.rows.first?.title == "Search Wikipedia for “cats”")
        #expect(wikipedia.searchURL(for: "cats")?.absoluteString == "https://en.wikipedia.org/w/index.php?search=cats")
        input.query = ""
        #expect(BrowserCommandBarEngine.groups(for: input).isEmpty)
    }

    // MARK: Ranking

    @Test func textTiersArePrefixThenWordStartThenSubstring() {
        #expect(BrowserCommandBarEngine.textTier("arch", in: ["Archive Today Tabs"]) == .prefix)
        #expect(BrowserCommandBarEngine.textTier("arch", in: ["Show Archive"]) == .wordStart)
        #expect(BrowserCommandBarEngine.textTier("chiv", in: ["Show Archive"]) == .substring)
        #expect(BrowserCommandBarEngine.textTier("éte", in: ["Delete History"]) == .substring)
        #expect(BrowserCommandBarEngine.textTier("pin", in: ["Bookmark", "pin tab"]) == .prefix)
        #expect(BrowserCommandBarEngine.textTier("xyz", in: ["Show Archive"]) == nil)
    }

    @Test func slashListsActionsBestMatchFirst() {
        var input = BrowserCommandBarInput(query: "/arch")
        input.actions = [
            // Its synonym starts with the term too; the title match wins.
            action(.showArchive, "Show Archive", ["archived tabs"]),
            action(.archiveToday, "Archive Today Tabs"),
            action(.reload, "Reload", ["refresh"]),
        ]
        let rows = BrowserCommandBarEngine.groups(for: input).flatMap(\.rows)
        #expect(rows.map(\.target) == [.command(.archiveToday), .command(.showArchive)])
        input.query = "/"
        #expect(BrowserCommandBarEngine.groups(for: input).first?.rows.count == 3)
        input.query = "/refr"
        #expect(BrowserCommandBarEngine.groups(for: input).first?.rows.map(\.target) == [.command(.reload)])
        // Without "/", only a strong match shows, after the pages.
        input.query = "chiv"
        #expect(groups(input)["Actions"] == nil)
    }

    @Test func groupsTabsPinsHistorySpacesAndSettings() {
        let tabID = UUID(), spaceID = UUID()
        let pin = BrowserPin(url: "https://swift.org/documentation/", title: "Swift Docs")
        let favorite = BrowserPin(url: "https://swiftpackageindex.com/", title: "Swift Packages")
        var input = BrowserCommandBarInput(query: "swift", searchEngines: engines)
        input.tabs = [.init(id: tabID, title: "Swift Forums", url: "https://forums.swift.org/", otherSpace: "Work")]
        input.pins = [pin]
        input.favorites = [favorite]
        input.history = [
            BrowserHistoryPage(url: "https://swift.org/blog/", title: "Swift Blog", visits: 9, frecency: 900),
            BrowserHistoryPage(url: "https://swift.org/documentation/", title: "Docs", visits: 1, frecency: 10),
            // An open tab's page is the tab, not a history row.
            BrowserHistoryPage(url: "https://forums.swift.org/", title: "Swift Forums", visits: 3, frecency: 300),
        ]
        input.spaces = [.init(id: spaceID, name: "Swift Work", isCurrent: false)]
        input.settingsPages = BrowserSettingsPage.allCases
        let found = groups(input)
        #expect(found["Open Tabs"]?.map(\.target) == [.tab(tabID)])
        #expect(found["Open Tabs"]?.first?.detail == "Work")
        #expect(Set(found["Pinned and Favorites"]?.map(\.target) ?? []) == [.pin(pin.id), .favorite(favorite.id)])
        #expect(found["Pinned and Favorites"]?.first { $0.target == .pin(pin.id) }?.title == "Swift Docs")
        #expect(found["History"]?.map(\.target) == [.url("https://swift.org/blog/")])
        #expect(found["Spaces"]?.map(\.target) == [.space(spaceID)])
        #expect(found["Settings"] == nil)
        let order = BrowserCommandBarEngine.groups(for: input).map(\.title)
        #expect(order == ["", "Open Tabs", "Pinned and Favorites", "History", "Spaces"])

        input.query = "keyboard"
        #expect(groups(input)["Settings"]?.map(\.target) == [.settings(.shortcuts)])
    }

    @Test func historyRanksByMatchThenFrecency() {
        var input = BrowserCommandBarInput(query: "web")
        input.history = [
            BrowserHistoryPage(url: "https://example.com/webkit-notes", title: "Notes", visits: 50, frecency: 5_000),
            BrowserHistoryPage(url: "https://webkit.org/", title: "WebKit", visits: 1, frecency: 100),
            BrowserHistoryPage(url: "https://webkit.org/blog/", title: "WebKit Blog", visits: 4, frecency: 400),
        ]
        let rows = groups(input)["History"]?.map(\.target)
        // Host prefix first (by frecency), then the title word start, then
        // the substring.
        #expect(rows == [.url("https://webkit.org/blog/"), .url("https://webkit.org/"), .url("https://example.com/webkit-notes")])
    }

    @Test func emptyQueryListsRecentTabs() {
        let ids = (0..<8).map { _ in UUID() }
        var input = BrowserCommandBarInput(query: "")
        input.tabs = ids.map { .init(id: $0, title: "T", url: "https://\($0.uuidString).example/") }
        let groups = BrowserCommandBarEngine.groups(for: input)
        #expect(groups.map(\.title) == ["Recent Tabs"])
        #expect(groups.first?.rows.map(\.target) == ids.prefix(6).map { .tab($0) })
    }

    @MainActor
    @Test func markdownLinksEscapeTheTitle() {
        #expect(BrowserWindowController.markdownLink(title: "Example Domain", url: "https://example.com/")
            == "[Example Domain](https://example.com/)")
        #expect(BrowserWindowController.markdownLink(title: "a [b] c", url: "https://x.example/")
            == #"[a \[b\] c](https://x.example/)"#)
    }
}
