@testable import SopranoWeb
import AppKit
import Testing

struct BrowserCrashPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func firstCrashOfTheVisibleTabReloads() {
        #expect(BrowserCrashPolicy.action(isSelected: true, previousCrash: nil, now: now) == .reload)
    }

    @Test func secondCrashSoonAfterShowsTheCrashPage() {
        let previous = now.addingTimeInterval(-3)
        #expect(BrowserCrashPolicy.action(isSelected: true, previousCrash: previous, now: now) == .showCrashPage)
    }

    @Test func crashLongAfterTheLastOneReloadsAgain() {
        let atBoundary = now.addingTimeInterval(-BrowserCrashPolicy.loopInterval)
        let longAgo = now.addingTimeInterval(-600)
        #expect(BrowserCrashPolicy.action(isSelected: true, previousCrash: atBoundary, now: now) == .reload)
        #expect(BrowserCrashPolicy.action(isSelected: true, previousCrash: longAgo, now: now) == .reload)
    }

    @Test func backgroundTabWaitsForSelection() {
        #expect(BrowserCrashPolicy.action(isSelected: false, previousCrash: nil, now: now) == .reloadWhenSelected)
        #expect(
            BrowserCrashPolicy.action(isSelected: false, previousCrash: now.addingTimeInterval(-1), now: now)
                == .reloadWhenSelected
        )
    }
}
