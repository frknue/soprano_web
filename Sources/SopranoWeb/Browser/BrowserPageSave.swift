import AppKit
import UniformTypeIdentifiers
import WebKit

/// File ▸ Save As… formats.
enum BrowserPageSaveFormat: Int, CaseIterable {
    /// `createWebArchiveData`: the page with its subresources, opens in Safari.
    case webArchive
    /// The document's original bytes as the server sent them.
    case pageSource

    var title: String {
        switch self {
        case .webArchive: "Web Archive"
        case .pageSource: "Page Source"
        }
    }

    var contentType: UTType {
        switch self {
        case .webArchive: .webArchive
        case .pageSource: .html
        }
    }

    /// Page Source refetches the document, so it needs a URL scheme that can
    /// be fetched again outside the web view.
    static func available(for url: URL?) -> [BrowserPageSaveFormat] {
        guard let url else { return [] }
        return BrowserPageSource.canFetch(url) ? allCases : [.webArchive]
    }

    /// A file name from the page title, falling back to the host; path
    /// separators and colons become dashes.
    static func suggestedName(title: String?, url: URL?) -> String {
        let base = [title, url?.host]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Untitled"
        let cleaned = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return String(cleaned.prefix(200))
    }
}

/// Fetches a page's original document again with the tab's cookies, outside
/// WebKit's download path.
@MainActor
enum BrowserPageSource {
    enum FetchError: LocalizedError {
        case unsupportedScheme
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedScheme: "This page has no source that can be saved."
            case let .http(status): "The server answered with status \(status)."
            }
        }
    }

    nonisolated static func canFetch(_ url: URL) -> Bool {
        ["http", "https", "file", "data"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Calls `completion` on the main actor with the document bytes.
    static func fetch(
        _ url: URL,
        from webView: WKWebView,
        completion: @escaping @MainActor (Result<Data, Error>) -> Void
    ) {
        guard canFetch(url) else {
            completion(.failure(FetchError.unsupportedScheme))
            return
        }
        if url.isFileURL {
            completion(Result { try Data(contentsOf: url) })
            return
        }
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        webView.evaluateJavaScript("navigator.userAgent") { value, _ in
            let userAgent = value as? String
            cookieStore.getAllCookies { cookies in
                load(url, cookies: cookies, userAgent: userAgent, completion: completion)
            }
        }
    }

    private static func load(
        _ url: URL,
        cookies: [HTTPCookie],
        userAgent: String?,
        completion: @escaping @MainActor (Result<Data, Error>) -> Void
    ) {
        // An ephemeral session has its own in-memory cookie jar; filling it
        // with the tab's cookies lets URLSession pick the ones that match the
        // URL (domain, path, Secure, expiry).
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        for cookie in cookies {
            configuration.httpCookieStorage?.setCookie(cookie)
        }
        var request = URLRequest(url: url)
        request.mainDocumentURL = url
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { data, response, error in
            session.finishTasksAndInvalidate()
            let result: Result<Data, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(FetchError.http(http.statusCode))
            } else {
                result = .success(data ?? Data())
            }
            Task { @MainActor in completion(result) }
        }.resume()
    }
}
