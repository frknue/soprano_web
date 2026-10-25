import Foundation
import WebKit

/// The time range offered by Clear Browsing Data.
enum BrowserClearRange: String, CaseIterable, Sendable {
    case lastHour
    case today
    case todayAndYesterday
    case allTime

    var title: String {
        switch self {
        case .lastHour: "Last Hour"
        case .today: "Today"
        case .todayAndYesterday: "Today and Yesterday"
        case .allTime: "All Time"
        }
    }

    /// The earliest moment whose data the range removes; everything at or
    /// after it goes. Days follow `calendar`'s midnight, not 24-hour spans.
    func startDate(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .lastHour:
            return now.addingTimeInterval(-3_600)
        case .today:
            return calendar.startOfDay(for: now)
        case .todayAndYesterday:
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -1, to: today) ?? today
        case .allTime:
            return .distantPast
        }
    }
}

/// What the Clear Browsing Data sheet removes.
struct BrowserClearOptions: Equatable, Sendable {
    var range: BrowserClearRange = .lastHour
    /// History list entries and the closed-tab stack.
    var history = true
    /// Cookies and every non-cache website data type.
    var cookiesAndSiteData = true
    var cachedFiles = true
    /// Finished entries of the download list (the files stay).
    var downloadList = false

    static let cacheTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeFetchCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
    ]

    var isEmpty: Bool {
        !history && !cookiesAndSiteData && !cachedFiles && !downloadList
    }

    /// The `WKWebsiteDataStore` types to remove, out of `available`
    /// (`WKWebsiteDataStore.allWebsiteDataTypes()` at runtime).
    func websiteDataTypes(available: Set<String>) -> Set<String> {
        var types: Set<String> = []
        if cookiesAndSiteData {
            types.formUnion(available.subtracting(Self.cacheTypes))
        }
        if cachedFiles {
            types.formUnion(available.intersection(Self.cacheTypes))
        }
        return types
    }
}

/// User-facing names for website data types, for the Website Data list.
enum BrowserWebsiteDataKinds {
    /// Distinct labels in a stable order; unknown types are skipped.
    static func labels(for types: Set<String>) -> [String] {
        var labels: [String] = []
        for (label, members) in groups where !types.isDisjoint(with: members) {
            labels.append(label)
        }
        return labels
    }

    private static let groups: [(String, Set<String>)] = [
        ("Cookies", [WKWebsiteDataTypeCookies]),
        ("Local storage", [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage]),
        ("Databases", [WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases]),
        ("Service workers", [WKWebsiteDataTypeServiceWorkerRegistrations]),
        ("File system", [WKWebsiteDataTypeFileSystem]),
        ("Cache", BrowserClearOptions.cacheTypes),
        ("Media keys", [WKWebsiteDataTypeMediaKeys, WKWebsiteDataTypeHashSalt]),
        ("Recent searches", [WKWebsiteDataTypeSearchFieldRecentSearches]),
    ]
}

/// Parses the disposition type of a `Content-Disposition` header
/// (RFC 6266): `attachment` means download instead of display.
enum BrowserContentDisposition {
    static func isAttachment(_ header: String?) -> Bool {
        dispositionType(header) == "attachment"
    }

    /// The lowercased type token before the first parameter, or nil for an
    /// empty or malformed header.
    static func dispositionType(_ header: String?) -> String? {
        guard let header else { return nil }
        let token = header
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard !token.isEmpty,
              token.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) })
        else { return nil }
        return token
    }

    /// RFC 7230 `tchar`.
    private static let tokenCharacters = CharacterSet.alphanumerics
        .intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        .union(CharacterSet(charactersIn: "!#$%&'*+-.^_`|~"))
}
