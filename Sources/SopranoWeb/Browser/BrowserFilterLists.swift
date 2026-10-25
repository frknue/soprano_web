import CryptoKit
import Foundation

/// A filter list the content blocker downloads.
struct BrowserFilterListSource: Hashable, Sendable {
    /// File and rule-list names: `easylist.txt`, `easylist-…`.
    let id: String
    let name: String
    let url: URL

    static let easyList = BrowserFilterListSource(
        id: "easylist",
        name: "EasyList",
        url: URL(string: "https://easylist.to/easylist/easylist.txt")!
    )
    static let easyPrivacy = BrowserFilterListSource(
        id: "easyprivacy",
        name: "EasyPrivacy",
        url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!
    )
    /// Settings ▸ Block ads and trackers.
    static let defaults = [easyList, easyPrivacy]
}

enum BrowserFilterListResponse: Equatable, Sendable {
    /// 304: the cached copy is current.
    case notModified
    case fetched(text: String, etag: String?, lastModified: String?)
}

/// Downloads a filter list, conditionally on what the cached copy came
/// with.
protocol BrowserFilterListFetching: Sendable {
    func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> BrowserFilterListResponse
}

enum BrowserFilterListError: LocalizedError, Equatable {
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .status(let code): "The server answered \(code)."
        }
    }
}

/// `If-None-Match` / `If-Modified-Since` GETs without cookies or a URL
/// cache (the text is cached next to the compiled lists).
struct BrowserFilterListFetcher: BrowserFilterListFetching {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> BrowserFilterListResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 200 {
        case 304:
            return .notModified
        case 200:
            return .fetched(
                text: String(decoding: data, as: UTF8.self),
                etag: http?.value(forHTTPHeaderField: "ETag"),
                lastModified: http?.value(forHTTPHeaderField: "Last-Modified")
            )
        case let code:
            throw BrowserFilterListError.status(code)
        }
    }
}

/// What the content blocker remembers about each list:
/// `ContentBlocking/content-blocking.json`, `{ "version": 1, "sources": {
/// id: … } }`. A source entry that doesn't decode is dropped, not the file.
struct BrowserContentBlockingState: Codable, Equatable {
    static let currentVersion = 1

    struct Source: Codable, Equatable {
        /// The address it was downloaded from; another address starts over.
        var url: String
        var etag: String?
        var lastModified: String?
        /// The last download that answered (200 or 304).
        var checkedAt: Date?
        /// When the compiled lists last changed.
        var updatedAt: Date?
        /// SHA-256 of the text the lists were compiled from.
        var textHash: String?
        var converterVersion: Int?
        /// Compiled `WKContentRuleList` identifiers, in order.
        var lists: [String] = []
        var ruleCount = 0
        var filterCount = 0
        /// `BrowserFilterSkipReason` raw value → filters skipped.
        var skipped: [String: Int] = [:]
        var compileSeconds: Double?
        var lastError: String?

        init(url: String) {
            self.url = url
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            etag = try? c.decodeIfPresent(String.self, forKey: .etag)
            lastModified = try? c.decodeIfPresent(String.self, forKey: .lastModified)
            checkedAt = try? c.decodeIfPresent(Date.self, forKey: .checkedAt)
            updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
            textHash = try? c.decodeIfPresent(String.self, forKey: .textHash)
            converterVersion = try? c.decodeIfPresent(Int.self, forKey: .converterVersion)
            lists = (try? c.decodeIfPresent([String].self, forKey: .lists)) ?? []
            ruleCount = (try? c.decodeIfPresent(Int.self, forKey: .ruleCount)) ?? 0
            filterCount = (try? c.decodeIfPresent(Int.self, forKey: .filterCount)) ?? 0
            skipped = (try? c.decodeIfPresent([String: Int].self, forKey: .skipped)) ?? [:]
            compileSeconds = try? c.decodeIfPresent(Double.self, forKey: .compileSeconds)
            lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
        }
    }

    var version = currentVersion
    var sources: [String: Source] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        let raw = (try? c.decodeIfPresent([String: Lossy].self, forKey: .sources)) ?? [:]
        sources = raw.compactMapValues(\.value)
    }

    private struct Lossy: Decodable {
        let value: Source?

        init(from decoder: Decoder) throws {
            value = try? Source(from: decoder)
        }
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
