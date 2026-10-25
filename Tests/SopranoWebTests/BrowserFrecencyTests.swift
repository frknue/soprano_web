@testable import SopranoWeb
import AppKit
import Testing

struct BrowserFrecencyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    private func score(_ visits: [(Double, BrowserVisitKind)], count: Int? = nil) -> Double {
        BrowserFrecency.score(
            visitCount: count ?? visits.count,
            samples: visits.map { (daysAgo($0.0), $0.1) },
            now: now
        )
    }

    @Test func recencyBucketsStepDown() {
        let ages: [Double] = [0, 4, 4.1, 14, 15, 31, 32, 90, 91, 400]
        let points = ages.map { BrowserFrecency.recencyPoints(age: $0 * 86_400) }
        #expect(points == [100, 100, 70, 70, 50, 50, 30, 30, 10, 10])
    }

    @Test func typedVisitsWeighThreeLinkVisits() {
        #expect(score([(1, .typed)]) == 300)
        #expect(score([(1, .link)]) == 100)
        #expect(score([(1, .typed)]) > score([(1, .link), (1, .link)]))
        #expect(score([(1, .link)]) > score([(1, .reload)]))
        #expect(score([(1, .sameDocument)]) == score([(1, .link)]))
    }

    @Test func ordersPagesTypedFrequentAndRecentFirst() {
        let pages: [(String, Double)] = [
            ("typed today", score([(0, .typed)])),
            ("four this week", score([(1, .link), (2, .link), (3, .link), (3, .reload)])),
            ("one today", score([(0, .link)])),
            ("one last month", score([(20, .link)])),
            ("many long ago", score([(200, .link), (210, .link)])),
            ("never", score([])),
        ]
        let ordered = pages.sorted { $0.1 > $1.1 }.map(\.0)
        #expect(ordered == ["four this week", "typed today", "one today", "one last month", "many long ago", "never"])
    }

    @Test func onlyTheNewestTenVisitsAreSampledButAllAreCounted() {
        // Ten recent visits and twenty old ones: the sample is the recent ten,
        // the multiplier all thirty.
        let recent = (0..<10).map { (Double($0) * 0.1, BrowserVisitKind.link) }
        let old = (0..<20).map { (300 + Double($0), BrowserVisitKind.link) }
        #expect(score(recent + old) == 30 * 100)
        #expect(score(old + recent) == 30 * 100)
        // The visit count multiplies the average of the sampled points.
        #expect(score([(0, .link)], count: 4) == 400)
    }
}
