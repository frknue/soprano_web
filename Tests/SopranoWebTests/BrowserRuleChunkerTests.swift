@testable import SopranoWeb
import AppKit
import Testing

/// Splitting rules into lists WebKit compiles (at most 150,000 rules
/// each), with the exceptions copied into every list.
struct BrowserRuleChunkerTests {
    private func rules(_ prefix: String, _ count: Int) -> [BrowserContentRule] {
        (1...max(1, count)).prefix(count).map { BrowserContentRule(urlFilter: "\(prefix)\($0)", action: .block) }
    }

    @Test func splitRulesSpreadOverListsAndRepeatedRulesGoInEach() {
        let blocks = rules("b", 5)
        let exceptions = rules("e", 2)
        let late = rules("l", 2)
        let result = BrowserRuleChunker.chunk([
            .split(blocks),
            .repeated(exceptions),
            .split(late),
        ], capacity: 5)
        #expect(result.dropped == 0)
        // Room for 3 split rules per list: b1-b3 | b4 b5 l1 | l2.
        #expect(result.lists.map { $0.map(\.urlFilter) } == [
            ["b1", "b2", "b3", "e1", "e2"],
            ["b4", "b5", "e1", "e2", "l1"],
            ["e1", "e2", "l2"],
        ])
        #expect(result.lists.allSatisfy { $0.count <= 5 })
    }

    @Test func oneListWhenEverythingFits() {
        let result = BrowserRuleChunker.chunk([.split(rules("b", 3)), .repeated(rules("e", 1))], capacity: 150_000)
        #expect(result.lists.count == 1)
        #expect(result.lists[0].map(\.urlFilter) == ["b1", "b2", "b3", "e1"])
    }

    @Test func noSplitRulesMeansNoList() {
        let result = BrowserRuleChunker.chunk([.split([]), .repeated(rules("e", 3))], capacity: 10)
        #expect(result.lists.isEmpty)
        #expect(result.dropped == 0)
    }

    @Test func repeatedRulesThatFillAListLeaveNoRoom() {
        let result = BrowserRuleChunker.chunk([.split(rules("b", 4)), .repeated(rules("e", 3))], capacity: 3)
        #expect(result.lists.isEmpty)
        #expect(result.dropped == 4)
    }
}
