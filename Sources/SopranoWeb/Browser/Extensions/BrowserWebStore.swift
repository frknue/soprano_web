import Foundation

/// The Chrome Web Store as an install source: what an "install" input
/// names, the update service's download and update-check URLs (protocol
/// v2, the endpoint Chrome uses), the hosts packages may come from, and
/// the update check's answer. Pure, except `fetch`.
enum BrowserWebStore {
    /// The Chrome version the update service is told; extensions with a
    /// higher `minimum_chrome_version` are refused by it.
    static let chromeVersion = "156.0.0.0"
    static let updateService = "https://clients2.google.com/service/update2/crx"
    /// Downloads and their redirects stay on these hosts (HTTPS, port 443).
    static let allowedHosts: Set<String> = ["clients2.google.com", "clients2.googleusercontent.com"]
    static let maxPackageSize = 256 << 20

    /// What `browser extension install` and Settings ▸ Extensions take.
    enum Source: Equatable, Sendable {
        case webStore(id: String)
        case folder(URL)
    }

    /// An extension id, a Chrome Web Store page
    /// (`https://chromewebstore.google.com/detail/[slug/]<id>`, or the
    /// older `https://chrome.google.com/webstore/detail/[slug/]<id>`), or a
    /// folder path (absolute, `~/…`, or relative to `workingDirectory`).
    static func source(for input: String, workingDirectory: URL? = nil) -> Source? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if BrowserExtensionID.isValid(trimmed.lowercased()), !trimmed.contains("/") {
            return .webStore(id: trimmed.lowercased())
        }
        if let id = extensionID(inStoreURL: trimmed) {
            return .webStore(id: id)
        }
        if trimmed.hasPrefix("http:") || trimmed.hasPrefix("https:") {
            return nil
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded, isDirectory: true)
            : (workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
                .appendingPathComponent(expanded, isDirectory: true)
        return .folder(url.standardizedFileURL)
    }

    /// The id in a Chrome Web Store page address; nil for anything else.
    static func extensionID(inStoreURL text: String) -> String? {
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased()
        else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        let detail: ArraySlice<String>
        switch host {
        case "chromewebstore.google.com":
            guard parts.first == "detail" else { return nil }
            detail = parts.dropFirst()
        case "chrome.google.com":
            guard parts.count >= 2, parts[0] == "webstore", parts[1] == "detail" else { return nil }
            detail = parts.dropFirst(2)
        default:
            return nil
        }
        guard (1...2).contains(detail.count), let last = detail.last, BrowserExtensionID.isValid(last) else { return nil }
        return last
    }

    /// The package of extension `id` (the service answers with a redirect
    /// to `clients2.googleusercontent.com`).
    static func downloadURL(id: String) -> URL {
        URL(string: "\(updateService)?response=redirect&prodversion=\(chromeVersion)&acceptformat=crx3"
            + "&x=id%3D\(id)%26installsource%3Dondemand%26uc")!
    }

    /// One request asking for updates of every `(id, installed version)`.
    static func updateCheckURL(_ installed: [(id: String, version: String)]) -> URL {
        var text = "\(updateService)?response=updatecheck&prodversion=\(chromeVersion)&acceptformat=crx3"
        for (id, version) in installed {
            let encoded = version.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "."))) ?? version
            text += "&x=id%3D\(id)%26v%3D\(encoded)%26uc"
        }
        return URL(string: text)!
    }

    static func isAllowedDownload(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased()
        else { return false }
        return allowedHosts.contains(host)
    }

    // MARK: Update check

    struct Update: Equatable, Sendable {
        var version: String
        var codebase: URL
        /// Hex SHA-256 of the package, when the service gives one.
        var sha256: String?
    }

    /// The `<gupdate>` answer: for each app id with `updatecheck
    /// status="ok"`, the new version and where to get it.
    static func parseUpdateCheck(_ data: Data) -> [String: Update] {
        let parser = XMLParser(data: data)
        let collector = UpdateCheckCollector()
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return [:] }
        return collector.updates
    }

    private final class UpdateCheckCollector: NSObject, XMLParserDelegate {
        var updates: [String: Update] = [:]
        private var app: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            switch elementName {
            case "app":
                app = attributes["appid"]
            case "updatecheck":
                guard let app, attributes["status"] == "ok",
                      let version = attributes["version"],
                      let codebase = attributes["codebase"].flatMap(URL.init(string:))
                else { return }
                updates[app] = Update(version: version, codebase: codebase, sha256: attributes["hash_sha256"])
            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if elementName == "app" { app = nil }
        }
    }

    /// Whether dotted version `candidate` is newer than `installed`
    /// (missing parts count as 0; non-numbers as 0).
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Network

    enum FetchError: Error, CustomStringConvertible {
        case refusedHost(String)
        case status(Int)
        case tooLarge
        case empty

        var description: String {
            switch self {
            case let .refusedHost(host): "the download went to \(host), which is not the Chrome Web Store"
            case let .status(code): "the Chrome Web Store answered HTTP \(code)"
            case .tooLarge: "the package is too large"
            case .empty: "the Chrome Web Store sent nothing (is the extension available?)"
            }
        }
    }

    /// GETs `url` without cookies or cache; `url`, every redirect and the
    /// final address stay on `allowedHosts` (a refused redirect ends the
    /// request with its 3xx status). The body streams in and the request
    /// is cancelled as soon as it (or its declared length) passes `limit`.
    static func fetch(_ url: URL, limit: Int = maxPackageSize) async throws -> Data {
        guard isAllowedDownload(url) else { throw FetchError.refusedHost(url.host ?? url.absoluteString) }
        let collector = CappedCollector(limit: limit)
        let session = URLSession(configuration: .ephemeral, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.start(session.dataTask(with: request), continuation: continuation)
            }
        } onCancel: {
            collector.cancel()
        }
        if let final = response.url, !isAllowedDownload(final) {
            throw FetchError.refusedHost(final.host ?? final.absoluteString)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FetchError.status(status) }
        guard !data.isEmpty else { throw FetchError.empty }
        return data
    }

    /// One download's delegate: refuses redirects off `allowedHosts`,
    /// collects the body and stops it past `limit`. URLSession calls it on
    /// its serial delegate queue; the lock covers `cancel` from elsewhere.
    final class CappedCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let limit: Int
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var data = Data()
        private var response: URLResponse?
        private var failure: Error?
        private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

        init(limit: Int) {
            self.limit = limit
        }

        func start(_ task: URLSessionTask, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
            lock.withLock {
                self.task = task
                self.continuation = continuation
            }
            task.resume()
        }

        func cancel() {
            lock.withLock { task }?.cancel()
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(BrowserWebStore.isAllowedDownload(request.url) ? request : nil)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            let tooLarge = response.expectedContentLength > Int64(limit)
            lock.withLock {
                self.response = response
                if tooLarge { failure = FetchError.tooLarge }
            }
            completionHandler(tooLarge ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let over = lock.withLock {
                guard failure == nil else { return true }
                guard self.data.count + data.count <= limit else {
                    failure = FetchError.tooLarge
                    self.data = Data()
                    return true
                }
                self.data.append(data)
                return false
            }
            if over { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (continuation, result): (CheckedContinuation<(Data, URLResponse), Error>?, Result<(Data, URLResponse), Error>) = lock.withLock {
                let continuation = self.continuation
                self.continuation = nil
                if let failure { return (continuation, .failure(failure)) }
                if let error { return (continuation, .failure(error)) }
                guard let response = self.response ?? task.response else {
                    return (continuation, .failure(URLError(.badServerResponse)))
                }
                return (continuation, .success((self.data, response)))
            }
            continuation?.resume(with: result)
        }
    }
}

extension BrowserWebStore.FetchError: LocalizedError {
    var errorDescription: String? { description }
}
