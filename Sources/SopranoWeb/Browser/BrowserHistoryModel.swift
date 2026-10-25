import Foundation
import WebKit

// MARK: - Rows

/// How a visit was reached; stored as its raw value in `visits.transition`.
enum BrowserVisitKind: Int, CaseIterable, Sendable {
    /// A link, a new tab, a link from another app or the CLI.
    case link = 0
    /// Started from the address bar.
    case typed = 1
    case reload = 2
    case backForward = 3
    case formSubmit = 4
    /// `history.pushState` or another same-document URL change that stayed.
    case sameDocument = 5

    init(_ type: WKNavigationType) {
        switch type {
        case .linkActivated: self = .link
        case .formSubmitted, .formResubmitted: self = .formSubmit
        case .backForward: self = .backForward
        case .reload: self = .reload
        case .other: self = .link
        @unknown default: self = .link
        }
    }
}

/// One page (URL) of History with its visit totals.
struct BrowserHistoryPage: Equatable, Sendable {
    var url: String
    var title: String
    var visits = 1
    var typedVisits = 0
    var lastVisit = Date()
    /// `BrowserFrecency.score` as of the last visit or daily refresh.
    var frecency: Double = 0

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url : trimmed
    }
}

/// One visit, as the History sidebar lists it.
struct BrowserHistoryVisit: Equatable, Sendable {
    var id: Int64
    var url: String
    var title: String
    var visitedAt: Date
    var kind: BrowserVisitKind

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url : trimmed
    }
}

// MARK: - Frecency

/// Frequency and recency in one number, after Firefox's frecency: each of
/// the latest `sampleSize` visits earns points by age bucket times a weight
/// for how it was reached, and the average is multiplied by the total visit
/// count. A typed visit weighs three link visits.
enum BrowserFrecency {
    static let sampleSize = 10

    /// Points for a visit `age` seconds old.
    static func recencyPoints(age: TimeInterval) -> Double {
        let days = max(0, age) / 86_400
        switch days {
        case ...4: return 100
        case ...14: return 70
        case ...31: return 50
        case ...90: return 30
        default: return 10
        }
    }

    static func weight(_ kind: BrowserVisitKind) -> Double {
        switch kind {
        case .typed: 3
        case .link, .sameDocument: 1
        case .reload, .backForward, .formSubmit: 0.5
        }
    }

    /// `samples` are the newest visits (any order; only the newest
    /// `sampleSize` count), `visitCount` all visits of the page.
    static func score(visitCount: Int, samples: [(date: Date, kind: BrowserVisitKind)], now: Date) -> Double {
        guard visitCount > 0, !samples.isEmpty else { return 0 }
        let newest = samples.sorted { $0.date > $1.date }.prefix(sampleSize)
        let points = newest.reduce(0) { sum, visit in
            sum + recencyPoints(age: now.timeIntervalSince(visit.date)) * weight(visit.kind)
        }
        return Double(visitCount) * points / Double(newest.count)
    }
}

// MARK: - Retention

/// Settings ▸ "Remove history items".
enum BrowserHistoryRetention: String, Codable, CaseIterable, Sendable {
    case oneDay
    case oneWeek
    case twoWeeks
    case oneMonth
    case oneYear
    case manually

    var name: String {
        switch self {
        case .oneDay: "After one day"
        case .oneWeek: "After one week"
        case .twoWeeks: "After two weeks"
        case .oneMonth: "After one month"
        case .oneYear: "After one year"
        case .manually: "Manually"
        }
    }

    /// Visits before this moment are removed; nil keeps everything.
    func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .oneDay: calendar.date(byAdding: .day, value: -1, to: now)
        case .oneWeek: calendar.date(byAdding: .day, value: -7, to: now)
        case .twoWeeks: calendar.date(byAdding: .day, value: -14, to: now)
        case .oneMonth: calendar.date(byAdding: .month, value: -1, to: now)
        case .oneYear: calendar.date(byAdding: .year, value: -1, to: now)
        case .manually: nil
        }
    }
}

// MARK: - Days

/// The History sidebar's day headers.
enum BrowserHistoryDays {
    enum Row: Equatable {
        case day(String)
        case visit(BrowserHistoryVisit)
    }

    /// "Today", "Yesterday", the weekday for the rest of the last week,
    /// then the date. Days are calendar days, so a 23- or 25-hour day at a
    /// daylight-saving change still counts as one.
    static func title(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2...6: return format("EEEE", date, calendar)
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return format(sameYear ? "EEEEMMMMd" : "EEEEMMMMdy", date, calendar)
        }
    }

    /// `visits` (newest first) with a header before each new day.
    static func rows(for visits: [BrowserHistoryVisit], now: Date, calendar: Calendar = .current) -> [Row] {
        var rows: [Row] = []
        var currentDay: Date?
        for visit in visits {
            let day = calendar.startOfDay(for: visit.visitedAt)
            if day != currentDay {
                currentDay = day
                rows.append(.day(title(for: visit.visitedAt, now: now, calendar: calendar)))
            }
            rows.append(.visit(visit))
        }
        return rows
    }

    private static func format(_ template: String, _ date: Date, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

// MARK: - Same-document visits

/// When a URL change without a page load (`history.pushState`, a hash
/// route) becomes a visit: after the URL has stayed for `debounce` seconds,
/// once per change, never for the URL the loaded page already recorded,
/// and not for a jump to an anchor on the same page.
struct BrowserSameDocumentVisits: Equatable {
    static let debounce: TimeInterval = 1

    /// The page's URL as last recorded (or loaded without recording).
    private(set) var recordedURL: String?
    private(set) var pendingURL: String?
    private(set) var due: Date?

    /// A page load finished at `url`; its own visit (if any) is recorded.
    mutating func pageLoaded(_ url: String?) {
        recordedURL = url
        pendingURL = nil
        due = nil
    }

    /// A main-frame load started; its finish records the visit.
    mutating func navigationStarted() {
        pendingURL = nil
        due = nil
    }

    /// The tab's URL changed. True when a visit may follow at `due`.
    mutating func urlChanged(to url: String?, isLoading: Bool, now: Date) -> Bool {
        pendingURL = nil
        due = nil
        guard !isLoading, let url, Self.isWeb(url), url != recordedURL,
              !Self.isAnchorJump(from: recordedURL, to: url)
        else { return false }
        pendingURL = url
        due = now.addingTimeInterval(Self.debounce)
        return true
    }

    /// The URL to record now, if the pending change stayed put.
    mutating func takeDueVisit(currentURL: String?, isLoading: Bool, now: Date) -> String? {
        guard let pendingURL, let due else { return nil }
        guard now >= due.addingTimeInterval(-0.05) else { return nil }
        self.pendingURL = nil
        self.due = nil
        guard !isLoading, currentURL == pendingURL, pendingURL != recordedURL else { return nil }
        recordedURL = pendingURL
        return pendingURL
    }

    private static func isWeb(_ url: String) -> Bool {
        guard let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Only the fragment changed, and it is not a hash route (`#/…`, `#!…`).
    private static func isAnchorJump(from old: String?, to new: String) -> Bool {
        guard let old,
              var before = URLComponents(string: old),
              var after = URLComponents(string: new)
        else { return false }
        let fragment = after.fragment ?? ""
        if fragment.hasPrefix("/") || fragment.hasPrefix("!") { return false }
        before.fragment = nil
        after.fragment = nil
        return before == after
    }
}
