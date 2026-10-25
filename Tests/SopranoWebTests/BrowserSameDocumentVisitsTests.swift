@testable import SopranoWeb
import AppKit
import Testing

struct BrowserSameDocumentVisitsTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// The rule at `start + seconds`; a class so `#expect` can call it.
    private final class Tracker {
        var rule = BrowserSameDocumentVisits()
        let start: Date

        init(start: Date) {
            self.start = start
        }

        func pageLoaded(_ url: String?) {
            rule.pageLoaded(url)
        }

        func navigationStarted() {
            rule.navigationStarted()
        }

        func changed(_ url: String?, _ seconds: Double, loading: Bool) -> Bool {
            rule.urlChanged(to: url, isLoading: loading, now: start.addingTimeInterval(seconds))
        }

        func due(_ url: String?, _ seconds: Double, loading: Bool) -> String? {
            rule.takeDueVisit(currentURL: url, isLoading: loading, now: start.addingTimeInterval(seconds))
        }
    }

    @Test func eachPushedURLThatStaysBecomesOneVisit() {
        let visits = Tracker(start: start)
        visits.pageLoaded("https://app.example/")
        #expect(visits.changed("https://app.example/inbox", 0, loading: false))
        #expect(visits.due("https://app.example/inbox", 0.5, loading: false) == nil)
        #expect(visits.due("https://app.example/inbox", 1, loading: false) == "https://app.example/inbox")
        // Once per change.
        #expect(visits.due("https://app.example/inbox", 2, loading: false) == nil)

        #expect(visits.changed("https://app.example/settings", 3, loading: false))
        #expect(visits.due("https://app.example/settings", 4, loading: false) == "https://app.example/settings")
    }

    @Test func rapidChangesRecordOnlyWhereThePageSettles() {
        let visits = Tracker(start: start)
        visits.pageLoaded("https://app.example/")
        #expect(visits.changed("https://app.example/a", 0, loading: false))
        #expect(visits.changed("https://app.example/b", 0.3, loading: false))
        // The second starts over at /b.
        #expect(visits.due("https://app.example/b", 1, loading: false) == nil)
        #expect(visits.due("https://app.example/b", 1.3, loading: false) == "https://app.example/b")
        // Left before the second passed: nothing.
        #expect(visits.changed("https://app.example/c", 3, loading: false))
        #expect(visits.due("https://app.example/d", 4, loading: false) == nil)
    }

    @Test func theLoadedPagesOwnVisitIsNotDuplicated() {
        let visits = Tracker(start: start)
        // The URL changes while a load is in flight: the load records it.
        #expect(!visits.changed("https://app.example/", 0, loading: true))
        visits.pageLoaded("https://app.example/")
        #expect(!visits.changed("https://app.example/", 1, loading: false))
        // replaceState to the same URL, and back to it after a push.
        #expect(visits.changed("https://app.example/x", 2, loading: false))
        #expect(!visits.changed("https://app.example/", 2.2, loading: false))
        #expect(visits.due("https://app.example/", 3.2, loading: false) == nil)
    }

    @Test func aStartedNavigationCancelsThePendingVisit() {
        let visits = Tracker(start: start)
        visits.pageLoaded("https://app.example/")
        #expect(visits.changed("https://other.example/", 0, loading: false))
        visits.navigationStarted()
        #expect(visits.due("https://other.example/", 1, loading: false) == nil)
        // Still loading when the second is up: the load's finish records it.
        #expect(visits.changed("https://app.example/y", 2, loading: false))
        #expect(visits.due("https://app.example/y", 3, loading: true) == nil)
    }

    @Test func anchorJumpsAreNotVisitsButHashRoutesAre() {
        let visits = Tracker(start: start)
        visits.pageLoaded("https://docs.example/guide")
        #expect(!visits.changed("https://docs.example/guide#install", 0, loading: false))
        #expect(visits.changed("https://docs.example/guide#/settings", 1, loading: false))
        #expect(visits.changed("https://docs.example/guide#!/inbox", 2, loading: false))
        #expect(!visits.changed("about:blank", 3, loading: false))
        #expect(!visits.changed(nil, 4, loading: false))
    }
}
