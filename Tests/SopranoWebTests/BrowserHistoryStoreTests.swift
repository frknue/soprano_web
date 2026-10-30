@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserHistoryStoreTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func visitsPersistAndARepeatWithinFiveMinutesMerges() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(directory: directory)
        let date = Date().addingTimeInterval(-3_600)

        store.record(url: "https://example.com/", title: "Example", at: date, kind: .typed)
        // A reload within five minutes merges into the typed visit.
        store.record(url: "https://example.com/", title: "Example again", at: date.addingTimeInterval(30), kind: .reload)
        store.record(url: "https://example.com/a", title: "A", at: date.addingTimeInterval(60))
        store.record(url: "https://example.com/", title: "Example", at: date.addingTimeInterval(120))

        let reloaded = BrowserHistoryStore(directory: directory)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("History.sqlite").path))
        let visits = reloaded.visits(limit: 10)
        #expect(visits.map(\.url) == ["https://example.com/", "https://example.com/a", "https://example.com/"])
        #expect(visits.map(\.kind) == [.link, .link, .typed])
        #expect(visits[2].visitedAt.timeIntervalSince1970 == date.addingTimeInterval(30).timeIntervalSince1970)
        let page = reloaded.recentPages(limit: 5).first { $0.url == "https://example.com/" }
        #expect(page?.visits == 2)
        #expect(page?.typedVisits == 1)
        #expect(page?.title == "Example")
        #expect(reloaded.recentPages(limit: 5).map(\.url) == ["https://example.com/", "https://example.com/a"])
    }

    @Test func aTitleSetAfterTheLoadRenamesTheRecentRow() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(directory: directory)
        let now = Date()
        // Recorded at the load's end, before the page set `document.title`.
        store.record(url: "https://late.example/", title: "late.example", at: now.addingTimeInterval(-1))
        store.record(url: "https://old.example/", title: "Old", at: now.addingTimeInterval(-600))
        var changes = 0
        let observation = store.changes.observe { changes += 1 }
        defer { observation.cancel() }

        store.updateTitle(url: "https://late.example/", title: "Late Title", at: now)
        store.updateTitle(url: "https://late.example/", title: "Late Title", at: now)
        store.updateTitle(url: "https://late.example/", title: "", at: now)
        // A visit older than the merge window keeps its title.
        store.updateTitle(url: "https://old.example/", title: "Changed", at: now)

        let reloaded = BrowserHistoryStore(directory: directory)
        let visits = reloaded.visits(limit: 10)
        #expect(visits.map(\.title) == ["Late Title", "Old"])
        #expect(reloaded.visitCount() == 2)
        #expect(changes == 1)
        // The search index follows the new title.
        #expect(reloaded.visits(matching: "Late Title", limit: 10).map(\.url) == ["https://late.example/"])
        #expect(reloaded.visits(matching: "Changed", limit: 10).isEmpty)
    }

    @Test func onlyWebAndFileAddressesAreRecorded() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(directory: directory)
        store.record(url: "about:blank", title: "Blank")
        store.record(url: "soprano-web://start", title: "Start")
        store.record(url: "file:///tmp/a.html", title: "File")
        #expect(store.visits(limit: 10).map(\.url) == ["file:///tmp/a.html"])
    }

    @Test func suggestionCandidatesComeFromIndexedMatches() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(directory: directory)
        let now = Date()
        store.importVisits([
            BrowserHistoryImport(url: "https://www.github.com/frknue", title: "frknue", visitedAt: now, kind: .typed),
            BrowserHistoryImport(url: "https://news.example/", title: "The Gitlab Weekly", visitedAt: now, kind: .link),
            BrowserHistoryImport(url: "https://legit.example/", title: "Shop", visitedAt: now, kind: .link),
            BrowserHistoryImport(url: "https://other.example/", title: "Nothing here", visitedAt: now, kind: .link),
        ], now: now)

        func urls(_ query: String) -> Set<String> {
            Set(store.suggestionCandidates(for: query).map(\.url))
        }
        // Host prefix (after www.), title word start, and substring.
        #expect(urls("git") == [
            "https://www.github.com/frknue",
            "https://news.example/",
            "https://legit.example/",
        ])
        // Under three characters the substring pass scans by frecency.
        #expect(urls("gi").contains("https://legit.example/"))
        // One character: prefixes and word starts only.
        #expect(urls("g") == ["https://www.github.com/frknue", "https://news.example/"])
        #expect(urls("weekly git") == ["https://news.example/"])
        #expect(urls("frk") == ["https://www.github.com/frknue"])
        #expect(urls("zzz").isEmpty)
        #expect(urls("%_\"").isEmpty)
        #expect(store.suggestionCandidates(for: "git").first { $0.url.contains("github") }?.typedVisits == 1)
    }

    @Test func databaseCandidatesKeepStageOneRanking() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(directory: directory)
        let now = Date()
        func visits(_ url: String, _ title: String, count: Int, typed: Bool = false, hoursAgo: Double = 1) -> [BrowserHistoryImport] {
            (0..<count).map {
                BrowserHistoryImport(
                    url: url,
                    title: title,
                    visitedAt: now.addingTimeInterval(-hoursAgo * 3_600 - Double($0) * 600),
                    kind: typed ? .typed : .link
                )
            }
        }
        store.importVisits(
            visits("https://myforum.example/", "Board", count: 3, typed: true)
                + visits("https://news.example/", "The Forum Times", count: 2)
                + visits("https://www.forum.example/", "Home", count: 1, hoursAgo: 400),
            now: now
        )
        let result = AddressSuggestionEngine.suggestions(for: AddressSuggestionInput(
            query: "forum",
            history: store.suggestionCandidates(for: "forum"),
            allowsInlineCompletion: false
        ))
        let urls = result.rows.compactMap { row -> String? in
            if case .url(let url) = row.target, row.kind == .history { return url }
            return nil
        }
        #expect(urls == ["https://www.forum.example/", "https://news.example/", "https://myforum.example/"])
    }

    @Test func removingAPageRemovesAllItsVisits() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(directory: directory)
        let start = Date().addingTimeInterval(-7_200)
        store.record(url: "https://a.example/", title: "A", at: start)
        store.record(url: "https://b.example/", title: "B", at: start.addingTimeInterval(600))
        store.record(url: "https://a.example/", title: "A", at: start.addingTimeInterval(1_200))
        var notified = 0
        let token = store.changes.observe { notified += 1 }
        store.removePage(url: "https://a.example/")
        #expect(store.visits(limit: 10).map(\.url) == ["https://b.example/"])
        #expect(store.pageCount() == 1)
        #expect(store.suggestionCandidates(for: "a.ex").isEmpty)
        #expect(notified == 1)
        token.cancel()
    }

    @Test func visitPagesFollowTheCursorAndTheSearch() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(directory: directory)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // Two visits share a timestamp; the cursor still splits them.
        let imports = (0..<25).map { (index: Int) -> BrowserHistoryImport in
            let minute = Double(index == 24 ? 23 : index)
            let title = index % 2 == 0 ? "Even \(index)" : "Odd \(index)"
            return BrowserHistoryImport(
                url: "https://site\(index % 5).example/page\(index)",
                title: title,
                visitedAt: start.addingTimeInterval(minute * 60),
                kind: .link
            )
        }
        store.importVisits(imports, now: start)

        var seen: [Int64] = []
        var cursor: BrowserHistoryVisit?
        repeat {
            let page = store.visits(before: cursor, limit: 10)
            seen += page.map(\.id)
            cursor = page.count == 10 ? page.last : nil
        } while cursor != nil
        #expect(seen.count == 25)
        #expect(Set(seen).count == 25)

        #expect(store.visitCount() == 25)
        #expect(store.visitCount(matching: "odd") == 12)
        #expect(store.visitCount(matching: "SITE3 even") == 2)
        #expect(store.visitCount(matching: "e") == 25)
        let odd = store.visits(matching: "Odd", limit: 5)
        #expect(odd.count == 5)
        #expect(odd.allSatisfy { $0.title.hasPrefix("Odd") })
        let older = store.visits(matching: "Odd", before: odd.last, limit: 50)
        #expect(older.count == 7)
        #expect(older.allSatisfy { $0.visitedAt <= odd.last!.visitedAt })
    }

    @Test func aDamagedDatabaseIsKeptAsideAndHistoryStartsOver() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("History.sqlite")
        try Data(repeating: 0x41, count: 8_192).write(to: file)

        let store = BrowserHistoryStore(directory: directory)
        #expect(store.isPersistent)
        store.record(url: "https://example.com/", title: "Example")
        #expect(BrowserHistoryStore(directory: directory).visitCount() == 1)
        #expect(FileManager.default.fileExists(atPath: file.path + ".corrupt"))
    }
}
