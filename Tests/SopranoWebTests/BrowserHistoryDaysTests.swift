@testable import SopranoWeb
import AppKit
import Testing

struct BrowserHistoryDaysTests {
    private func berlin() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func visit(_ id: Int64, _ text: String) -> BrowserHistoryVisit {
        BrowserHistoryVisit(id: id, url: "https://\(id).example/", title: "\(id)", visitedAt: date(text), kind: .link)
    }

    @Test func titlesNameTodayYesterdayWeekdaysThenDates() {
        // Wednesday 2026-10-28, 09:30 CET.
        let now = date("2026-10-28T08:30:00Z")
        let calendar = berlin()
        func title(_ text: String) -> String {
            BrowserHistoryDays.title(for: date(text), now: now, calendar: calendar)
        }
        #expect(title("2026-10-27T23:00:00Z") == "Today") // 00:00 local
        #expect(title("2026-10-27T22:59:00Z") == "Yesterday") // 23:59 local
        #expect(title("2026-10-26T12:00:00Z") == "Monday")
        #expect(title("2026-10-22T12:00:00Z") == "Thursday")
        #expect(title("2026-10-21T12:00:00Z") == "Wednesday, October 21")
        #expect(title("2025-12-31T12:00:00Z") == "Wednesday, December 31, 2025")
    }

    @Test func daysStayCalendarDaysAcrossTheAutumnClockChange() {
        // Sunday 2026-10-25 lasts 25 hours in Berlin (CEST → CET at 03:00).
        let calendar = berlin()
        let now = date("2026-10-25T22:30:00Z") // 23:30 CET, Sunday
        func title(_ text: String) -> String {
            BrowserHistoryDays.title(for: date(text), now: now, calendar: calendar)
        }
        #expect(title("2026-10-24T22:00:00Z") == "Today") // 00:00 CEST Sunday, 24.5 h earlier
        #expect(title("2026-10-24T21:59:00Z") == "Yesterday") // 23:59 CEST Saturday
        #expect(title("2026-10-23T22:30:00Z") == "Yesterday") // 00:30 CEST Saturday
        #expect(title("2026-10-23T21:30:00Z") == "Friday")
        // The morning after: Sunday is yesterday although 25 hours long.
        let monday = date("2026-10-26T00:30:00Z") // 01:30 CET Monday
        #expect(BrowserHistoryDays.title(for: date("2026-10-25T00:30:00Z"), now: monday, calendar: calendar) == "Yesterday")
        #expect(BrowserHistoryDays.title(for: date("2026-10-25T23:00:00Z"), now: monday, calendar: calendar) == "Today")
    }

    @Test func rowsGetOneHeaderPerDayInTheSpringToo() {
        // Sunday 2026-03-29 lasts 23 hours (CET → CEST at 02:00).
        let calendar = berlin()
        let now = date("2026-03-30T10:00:00Z") // Monday 12:00 CEST
        let visits = [
            visit(5, "2026-03-30T06:00:00Z"), // Monday 08:00
            visit(4, "2026-03-29T21:59:00Z"), // Sunday 23:59 CEST
            visit(3, "2026-03-29T00:30:00Z"), // Sunday 01:30 CET
            visit(2, "2026-03-28T22:59:00Z"), // Saturday 23:59 CET
            visit(1, "2026-03-20T12:00:00Z"),
        ]
        let rows = BrowserHistoryDays.rows(for: visits, now: now, calendar: calendar)
        #expect(rows == [
            .day("Today"), .visit(visits[0]),
            .day("Yesterday"), .visit(visits[1]), .visit(visits[2]),
            .day("Saturday"), .visit(visits[3]),
            .day("Friday, March 20"), .visit(visits[4]),
        ])
        #expect(BrowserHistoryDays.rows(for: [], now: now, calendar: calendar).isEmpty)
    }
}
