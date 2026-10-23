import Foundation

/// Fetches search-engine suggestions for the address bar. Requests wait a
/// short debounce, a new request cancels the previous one, and the session is
/// ephemeral and never sends or stores cookies.
@MainActor
final class BrowserSearchSuggestionFetcher {
    private let session: URLSession
    private let debounce: Duration
    private var task: Task<Void, Never>?

    init(debounce: Duration = .milliseconds(150)) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 4
        self.session = URLSession(configuration: configuration)
        self.debounce = debounce
    }

    /// Calls `completion` with the phrases for `query`, unless another
    /// request or `cancel()` comes first. Failures deliver nothing.
    func request(
        _ query: String,
        engine: SearchEngine,
        completion: @escaping @MainActor ([String]) -> Void
    ) {
        task?.cancel()
        guard let url = engine.suggestionURL(for: query) else { return }
        let session = session
        let debounce = debounce
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: debounce)
                var request = URLRequest(url: url)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                guard !Task.isCancelled,
                      (response as? HTTPURLResponse)?.statusCode == 200
                else { return }
                completion(SearchSuggestionParser.parse(data))
            } catch {
                // Cancelled or offline: the dropdown keeps its local rows.
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
