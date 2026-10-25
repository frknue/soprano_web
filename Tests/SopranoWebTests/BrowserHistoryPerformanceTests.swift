@testable import SopranoWeb
import AppKit
import Testing

/// 100,000 visits over 30,000 pages: address-bar queries and History pages
/// stay interactive. The bounds are generous (debug build, background
/// priority, a busy Mac); the printed numbers are the measurement. It works
/// on `BrowserHistoryDatabase` (what `BrowserHistoryStore` forwards to) off
/// the main actor, so building the data does not stall other suites.
struct BrowserHistoryPerformanceTests {
    private static let words = [
        "github", "news", "weather", "swift", "webkit", "recipe", "invoice", "travel", "music", "video",
        "docs", "guide", "release", "notes", "forum", "market", "health", "garden", "design", "photo",
        "school", "bank", "map", "train", "hotel", "football", "science", "history", "kitchen", "router",
    ]

    /// A deterministic pseudo-random sequence.
    private struct Generator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private func synthesize(now: Date) -> [BrowserHistoryImport] {
        var random = Generator()
        let hosts = (0..<3_000).map { index -> String in
            let a = Self.words[index % Self.words.count]
            let b = Self.words[(index / Self.words.count) % Self.words.count]
            return "\(a)\(b)\(index).example"
        }
        let pages = (0..<30_000).map { index -> (String, String) in
            let host = hosts[random.next(hosts.count)]
            let word = Self.words[random.next(Self.words.count)]
            let other = Self.words[random.next(Self.words.count)]
            return ("https://\(host)/\(word)/\(index)", "\(word.capitalized) \(other) page \(index)")
        }
        var visits: [BrowserHistoryImport] = []
        visits.reserveCapacity(100_000)
        for index in 0..<100_000 {
            // Every page once, then a skew towards the first pages.
            let page = index < pages.count ? pages[index] : pages[random.next(random.next(pages.count) + 1)]
            let age = Double(random.next(365 * 86_400))
            visits.append(BrowserHistoryImport(
                url: page.0,
                title: page.1,
                visitedAt: now.addingTimeInterval(-age),
                kind: random.next(5) == 0 ? .typed : .link
            ))
        }
        return visits
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let duration = clock.measure(body)
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    @Test func suggestionsAndHistoryPagesStayFastAtOneHundredThousandVisits() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(BrowserHistoryStore.databaseName).path
        let seeded = try BrowserHistoryDatabase(path: path)
        let visits = synthesize(now: now)
        let build = milliseconds { try? seeded.importVisits(visits, now: now) }
        var opened: BrowserHistoryDatabase?
        let open = milliseconds { opened = try? BrowserHistoryDatabase(path: path) }
        let store = try #require(opened)
        #expect(try store.visitCount(matching: "") == 100_000)
        #expect(try store.pageCount() == 30_000)

        var report = ["build \(Int(build)) ms", String(format: "open %.2f ms", open)]
        var worstSuggestion = 0.0
        for query in ["g", "gi", "git", "github", "news", "wea", "swift guide", "page 12", "docs.example", "zzzq"] {
            var times: [Double] = []
            var queryTimes: [Double] = []
            for _ in 0..<5 {
                var candidates: [BrowserHistoryPage] = []
                queryTimes.append(milliseconds { candidates = (try? store.suggestionCandidates(for: query)) ?? [] })
                times.append(queryTimes.last! + milliseconds {
                    let input = AddressSuggestionInput(query: query, history: candidates, allowsInlineCompletion: true)
                    _ = AddressSuggestionEngine.suggestions(for: input)
                })
            }
            let median = times.sorted()[times.count / 2]
            worstSuggestion = max(worstSuggestion, median)
            report.append(String(
                format: "suggest %@ %.2f ms (max %.2f; database %.2f)",
                "“\(query)”", median, times.max() ?? 0, queryTimes.sorted()[queryTimes.count / 2]
            ))
        }
        #expect(try !store.suggestionCandidates(for: "github").isEmpty)

        var worstPage = 0.0
        func page(_ label: String, _ body: () -> Void) {
            let times = (0..<5).map { _ in milliseconds(body) }
            let median = times.sorted()[times.count / 2]
            worstPage = max(worstPage, median)
            report.append(String(format: "page %@ %.2f ms (max %.2f)", label, median, times.max() ?? 0))
        }
        func listPage(_ query: String, before cursor: BrowserHistoryVisit? = nil) -> [BrowserHistoryVisit] {
            (try? store.visits(matching: query, before: cursor, limit: 100)) ?? []
        }
        page("first") { #expect(listPage("").count == 100) }
        let deep = (0..<50).reduce(nil as BrowserHistoryVisit?) { cursor, _ in listPage("", before: cursor).last }
        page("after 5,000") { #expect(listPage("", before: deep).count == 100) }
        page("search “news”") { #expect(listPage("news").count == 100) }
        page("search “ne”") { #expect(listPage("ne").count == 100) }
        page("search “zzzq”") { #expect(listPage("zzzq").isEmpty) }
        page("count") { #expect((try? store.visitCount(matching: "")) == 100_000) }
        page("count “news”") { #expect(((try? store.visitCount(matching: "news")) ?? 0) > 0) }
        page("recent") { #expect((try? store.recentPages(limit: 6))?.count == 6) }

        print("History performance (100,000 visits, 30,000 pages):\n  " + report.joined(separator: "\n  "))
        #expect(worstSuggestion < 150)
        #expect(worstPage < 200)
    }
}
