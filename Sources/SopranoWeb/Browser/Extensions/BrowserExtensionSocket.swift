import Foundation
import WebKit

/// A WebSocket an extension's worker opens, made by the app
/// (`URLSessionWebSocketTask`): WebKit's own never returns from its
/// constructor in an extension worker and freezes the extension. The shim's
/// `WebSocket` (`BrowserExtensionShimScript`, stand-in `webSocket`) talks to
/// it over a `soprano.socket` native port:
/// - worker → app: `{ open, protocols }` (repeated until any answer: a
///   worker's first posts on a new port can be lost), `{ send }`,
///   `{ sendBinary }` (base64), `{ close, reason }`;
/// - app → worker: `{ opened }` (the protocol), `{ text }`, `{ binary }`,
///   `{ failed }`, `{ closed, reason, clean }`.
///
/// Only `ws:` and `wss:` addresses open, and only where the extension's
/// `BrowserExtensionSocketPolicy` lets them; protocols must be distinct
/// RFC 6455 tokens. A refused open answers `{ failed }` and ends the socket,
/// as a failed connection does. The request carries the extension's origin
/// (`chrome-extension://<id>`) and Chrome's user agent, as Chrome's socket
/// would; redirects are refused and the only challenge answered is the
/// server's certificate (the system's checks). A socket that hears no
/// `open` within `openTimeout`, or a close before it opened, ends; messages
/// either way are at most `maxMessageSize` (a larger one to send fails the
/// socket). The extension's ports are capped at `maxPerExtension` by the
/// one creating them.
@MainActor
final class BrowserExtensionSocket: NSObject, URLSessionWebSocketDelegate {
    enum Request: Equatable {
        case open(url: URL, protocols: [String])
        case send(String)
        case sendBinary(Data)
        case close(code: Int, reason: String)
    }

    /// The most sockets one extension keeps at a time.
    static let maxPerExtension = 64
    /// How long a new port may wait for its `open`.
    static let openTimeout: TimeInterval = 10
    /// The largest message, received or sent (16 MiB).
    static let maxMessageSize = 16 << 20
    /// Chrome's user agent, as the shim's `userAgent` stand-in reports it
    /// (WebKit's macOS platform is frozen at this one).
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/\(BrowserWebStore.chromeVersion) Safari/537.36"

    /// What the worker posted, or nil for anything else (a close with a code
    /// or reason a WebSocket's `close()` would throw on included).
    nonisolated static func request(from message: Any?) -> Request? {
        guard let message = message as? [String: Any] else { return nil }
        if let address = message["open"] as? String {
            guard let url = socketURL(address) else { return nil }
            let protocols = (message["protocols"] as? [Any] ?? []).compactMap { $0 as? String }
            return .open(url: url, protocols: protocols)
        }
        if let text = message["send"] as? String { return .send(text) }
        if let encoded = message["sendBinary"] as? String {
            return Data(base64Encoded: encoded).map { .sendBinary($0) }
        }
        if let code = (message["close"] as? NSNumber)?.intValue {
            let reason = message["reason"] as? String ?? ""
            return isValidClose(code: code, reason: reason) ? .close(code: code, reason: reason) : nil
        }
        return nil
    }

    /// A `ws:`/`wss:` address with a host and no user name or password.
    nonisolated static func socketURL(_ address: String) -> URL? {
        guard let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url
        else { return nil }
        return url
    }

    /// Protocols a handshake may name: non-empty RFC 6455 tokens, none twice
    /// (what makes a WebSocket's constructor throw otherwise). The CR/LF a
    /// header could be smuggled with is no token character.
    nonisolated static func validProtocols(_ protocols: [String]) -> Bool {
        Set(protocols).count == protocols.count && protocols.allSatisfy { name in
            !name.isEmpty && name.utf8.allSatisfy(isTokenCharacter)
        }
    }

    private nonisolated static func isTokenCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"):
            true
        default:
            "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    /// A close a worker may ask for: code 1000 or 3000–4999 and a reason of
    /// at most 123 UTF-8 bytes, as a WebSocket's `close()` allows. Another
    /// one is ignored (the shim throws before posting it).
    nonisolated static func isValidClose(code: Int, reason: String) -> Bool {
        (code == 1000 || (3000...4999).contains(code)) && reason.utf8.count <= 123
    }

    let extensionID: String
    private let port: WKWebExtension.MessagePort
    private let policy: BrowserExtensionSocketPolicy
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    /// Set by the first `open` (its address may still be being checked).
    private var opening = false
    private var openTimer: Timer?
    private var finished = false
    /// The close the worker asked for, reported back when the task ends.
    private var requestedClose: (code: Int, reason: String)?
    /// Called once the socket is done (closed, failed or the port gone).
    var onFinish: (() -> Void)?

    init(port: WKWebExtension.MessagePort, extensionID: String, policy: BrowserExtensionSocketPolicy) {
        self.port = port
        self.extensionID = extensionID
        self.policy = policy
        super.init()
        port.messageHandler = { [weak self] message, _ in
            self?.handle(message)
        }
        port.disconnectHandler = { [weak self] _ in
            self?.finish(reportingTo: false)
        }
        openTimer = Timer.scheduledTimer(withTimeInterval: Self.openTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.opening else { return }
                self.finish(reportingTo: true)
            }
        }
    }

    private func handle(_ message: Any?) {
        guard !finished, let request = Self.request(from: message) else { return }
        switch request {
        case let .open(url, protocols):
            // The worker says it again until answered; the first one opens.
            guard !opening, requestedClose == nil else { return }
            opening = true
            openTimer?.invalidate()
            openTimer = nil
            Task { [weak self] in await self?.open(url, protocols: protocols) }
        case let .send(text):
            send(.string(text), size: text.utf8.count)
        case let .sendBinary(data):
            send(.data(data), size: data.count)
        case let .close(code, reason):
            guard let task else {
                // Closed before it opened (or while its address is checked):
                // it fails, as a WebSocket closed while connecting does.
                post(["failed": true])
                finish(reportingTo: true)
                return
            }
            requestedClose = (code, reason)
            task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: Data(reason.utf8))
        }
    }

    /// Opens the socket once the protocols and the address pass.
    private func open(_ url: URL, protocols: [String]) async {
        var permitted = false
        if Self.validProtocols(protocols) { permitted = await policy.permits(url) }
        guard !finished, task == nil, requestedClose == nil else { return }
        guard permitted else {
            post(["failed": true])
            finish(reportingTo: true)
            return
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("\(BrowserExtensions.scheme)://\(extensionID)", forHTTPHeaderField: "Origin")
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if !protocols.isEmpty {
            urlRequest.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: urlRequest)
        task.maximumMessageSize = Self.maxMessageSize
        self.session = session
        self.task = task
        task.resume()
        receive()
    }

    private func send(_ message: URLSessionWebSocketTask.Message, size: Int) {
        guard let task else { return }
        guard size <= Self.maxMessageSize else {
            task.cancel(with: .messageTooBig, reason: nil)
            post(["failed": true])
            finish(reportingTo: true)
            return
        }
        task.send(message) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.finished else { return }
                    switch result {
                    case let .success(.string(text)):
                        self.post(["text": text])
                        self.receive()
                    case let .success(.data(data)):
                        self.post(["binary": data.base64EncodedString()])
                        self.receive()
                    case .success:
                        self.receive()
                    case .failure:
                        // The close callback or the task's error reports it.
                        break
                    }
                }
            }
        }
    }

    private func post(_ message: [String: Any]) {
        port.sendMessage(message, completionHandler: nil)
    }

    /// Ends the socket; `reportingTo` tells the worker it closed abnormally.
    private func finish(reportingTo worker: Bool, code: Int = 1006, reason: String = "", clean: Bool = false) {
        guard !finished else { return }
        finished = true
        openTimer?.invalidate()
        openTimer = nil
        if worker {
            post(["closed": code, "reason": reason, "clean": clean])
            port.disconnect()
        }
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        onFinish?()
        onFinish = nil
    }

    /// The app is done with the extension (unloaded).
    func close() {
        finish(reportingTo: true)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocolName: String?
    ) {
        MainActor.assumeIsolated {
            self.post(["opened": protocolName ?? ""])
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        MainActor.assumeIsolated {
            self.finish(reportingTo: true, code: closeCode.rawValue, reason: text, clean: true)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            guard !self.finished else { return }
            if let requested = self.requestedClose {
                self.finish(reportingTo: true, code: requested.code, reason: requested.reason, clean: true)
                return
            }
            if error != nil { self.post(["failed": true]) }
            self.finish(reportingTo: true)
        }
    }

    /// A redirect would take the handshake past the policy's checks.
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }

    /// The server's certificate gets the system's checks; nothing else
    /// (Negotiate, NTLM, client certificates) answers for the extension.
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? (.performDefaultHandling, nil)
            : (.cancelAuthenticationChallenge, nil)
    }
}

/// Where an extension's worker may open sockets (`BrowserExtensionSocket`):
/// - only to addresses the `connect-src` of its extension pages' content
///   security policy allows (`default-src` without one; anywhere without
///   either);
/// - to a loopback, link-local, private or shared (CGNAT) address, a
///   `localhost`, `.local` or unqualified name only when the extension was
///   granted the http(s) address of the same host (`hasHostAccess`). A name
///   is resolved first and each of its addresses checked (a rebinding name
///   could still change in between; this is best effort), and a name that
///   resolves to nothing is refused, as its connection would fail.
struct BrowserExtensionSocketPolicy {
    /// What a host is before any resolving.
    enum HostKind: Equatable, Sendable {
        /// Loopback, link-local, private, `localhost`, `.local`, unqualified.
        case restricted
        /// An address on the internet.
        case global
        /// A name to resolve.
        case name
    }

    /// The source list that bounds connections, or nil when the manifest
    /// sets none.
    let connectSources: [String]?
    /// Whether the extension may reach this http(s) URL (a granted match
    /// pattern).
    let hasHostAccess: @MainActor (URL) -> Bool

    static func make(manifest: [String: Any], hasHostAccess: @escaping @MainActor (URL) -> Bool) -> Self {
        Self(connectSources: connectSources(in: manifest), hasHostAccess: hasHostAccess)
    }

    /// Whether a socket may open to `url`.
    @MainActor func permits(_ url: URL) async -> Bool {
        guard Self.allows(url, sources: connectSources),
              let host = url.host(percentEncoded: false), !host.isEmpty
        else { return false }
        if let equivalent = Self.httpEquivalent(of: url), hasHostAccess(equivalent) { return true }
        switch Self.kind(ofHost: host) {
        case .restricted:
            return false
        case .global:
            return true
        case .name:
            let addresses = await Self.resolve(Self.normalized(host: host))
            return !addresses.isEmpty && !addresses.contains(where: Self.isRestricted)
        }
    }

    // MARK: - Content security policy

    /// The policy of the extension's pages: MV3's
    /// `content_security_policy.extension_pages`, MV2's string.
    static func extensionPagesPolicy(in manifest: [String: Any]) -> String? {
        switch manifest["content_security_policy"] {
        case let text as String: text
        case let object as [String: Any]: object["extension_pages"] as? String
        default: nil
        }
    }

    /// The sources of the pages' `connect-src`, or of their `default-src`
    /// without one; nil without either.
    static func connectSources(in manifest: [String: Any]) -> [String]? {
        guard let policy = extensionPagesPolicy(in: manifest) else { return nil }
        return sources(of: "connect-src", in: policy) ?? sources(of: "default-src", in: policy)
    }

    /// The source list of `directive` in `policy` (its first occurrence, as
    /// CSP takes it); nil when the policy has no such directive.
    static func sources(of directive: String, in policy: String) -> [String]? {
        for part in policy.split(separator: ";") {
            let tokens = part.split(whereSeparator: \.isWhitespace)
            guard let name = tokens.first else { continue }
            if name.lowercased() == directive { return tokens.dropFirst().map(String.init) }
        }
        return nil
    }

    /// Whether a source list lets a socket connect to `url` (nil: no list,
    /// anything goes; an empty list is `'none'`).
    static func allows(_ url: URL, sources: [String]?) -> Bool {
        guard let sources else { return true }
        return sources.contains { matches(url, source: $0) }
    }

    /// Whether a source list could let a socket connect to some `ws:` or
    /// `wss:` address (what the WebSocket stand-in is for): no list, `*`,
    /// a scheme source `http:`, `https:`, `ws:` or `wss:` (each covers a
    /// socket scheme, `schemeMatches`), or a host source with one of those
    /// schemes or none. Keywords and other schemes never do.
    static func mayConnectToSockets(sources: [String]?) -> Bool {
        guard let sources else { return true }
        let socketSchemes: Set<String> = ["http", "https", "ws", "wss"]
        return sources.contains { source in
            if source == "*" { return true }
            if source.hasPrefix("'") { return false }
            if let scheme = schemeSource(source) { return socketSchemes.contains(scheme) }
            if let separator = source.range(of: "://") {
                return socketSchemes.contains(source[..<separator.lowerBound].lowercased())
            }
            return true
        }
    }

    /// CSP source-expression matching for a `ws:`/`wss:` URL:
    /// - `*` matches it;
    /// - keywords (`'self'`, the extension's own non-socket origin; `'none'`;
    ///   nonces and hashes) never do;
    /// - a scheme source matches its scheme and what it upgrades to (below);
    /// - a host source `[scheme://]host[:port][/path]`: the scheme as a
    ///   scheme source (either socket scheme without one), the host exactly
    ///   or `*.` for any subdomain, the port exactly, `*` for any, the
    ///   scheme's default without one, and the path exactly or, ending in
    ///   `/`, as a prefix.
    static func matches(_ url: URL, source: String) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host(percentEncoded: false).map({ normalized(host: $0) }), !host.isEmpty
        else { return false }
        if source == "*" { return true }
        if source.hasPrefix("'") { return false }
        if let sourceScheme = schemeSource(source) { return schemeMatches(sourceScheme, scheme) }

        var rest = Substring(source)
        if let separator = rest.range(of: "://") {
            guard schemeMatches(rest[..<separator.lowerBound].lowercased(), scheme) else { return false }
            rest = rest[separator.upperBound...]
        }
        let hostEnd = rest.firstIndex(where: { $0 == ":" || $0 == "/" }) ?? rest.endIndex
        let sourceHost = rest[..<hostEnd].lowercased()
        rest = rest[hostEnd...]
        var sourcePort: Substring?
        if rest.first == ":" {
            let portEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            sourcePort = rest[rest.index(after: rest.startIndex)..<portEnd]
            rest = rest[portEnd...]
        }
        return hostMatches(sourceHost, host)
            && portMatches(sourcePort, url: url, scheme: scheme)
            && pathMatches(String(rest), url: url)
    }

    /// The scheme of a scheme source (`wss:`), or nil for another source.
    private static func schemeSource(_ source: String) -> String? {
        guard source.hasSuffix(":"), let first = source.unicodeScalars.first, first.isASCII,
              CharacterSet.letters.contains(first)
        else { return nil }
        let scheme = source.dropLast().lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+-.")
        return scheme.unicodeScalars.allSatisfy(allowed.contains) ? scheme : nil
    }

    /// Whether a source's scheme covers a URL's: the same one, or one it
    /// upgrades to or stands for (CSP3, as Chrome matches it): `http`
    /// covers `https`, `ws` and `wss`, `https` covers `wss`, `ws` covers
    /// `wss`.
    static func schemeMatches(_ sourceScheme: String, _ scheme: String) -> Bool {
        if sourceScheme == scheme { return true }
        switch (sourceScheme, scheme) {
        case ("http", "https"), ("http", "ws"), ("http", "wss"), ("https", "wss"), ("ws", "wss"): return true
        default: return false
        }
    }

    private static func hostMatches(_ sourceHost: String, _ host: String) -> Bool {
        if sourceHost == "*" { return true }
        if sourceHost.hasPrefix("*.") { return host.hasSuffix(sourceHost.dropFirst()) }
        return !sourceHost.isEmpty && normalized(host: sourceHost) == host
    }

    private static func portMatches(_ sourcePort: Substring?, url: URL, scheme: String) -> Bool {
        let defaultPort = scheme == "wss" ? 443 : 80
        let port = url.port ?? defaultPort
        guard let sourcePort else { return port == defaultPort }
        if sourcePort == "*" { return true }
        return Int(sourcePort) == port
    }

    private static func pathMatches(_ sourcePath: String, url: URL) -> Bool {
        if sourcePath.isEmpty || sourcePath == "/" { return true }
        let source = sourcePath.removingPercentEncoding ?? sourcePath
        let path = url.path(percentEncoded: false)
        let urlPath = path.isEmpty ? "/" : path
        return source.hasSuffix("/") ? urlPath.hasPrefix(source) : urlPath == source
    }

    // MARK: - Hosts

    /// The http(s) address a `ws:`/`wss:` one stands for (host access is
    /// granted for those).
    static func httpEquivalent(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased() == "wss" ? "https" : "http"
        return components.url
    }

    /// A host as compared: lowercased, without IPv6 brackets, zone or a
    /// trailing dot.
    static func normalized(host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// What `host` is before resolving: an IP literal by its address, a
    /// `localhost`, `*.localhost`, `.local` or dotless name restricted,
    /// another name to resolve (a numeric form `inet_pton` rejects, like
    /// `127.1`, resolves to its address).
    static func kind(ofHost host: String) -> HostKind {
        let host = normalized(host: host)
        if host.isEmpty { return .restricted }
        if let address = address(host) { return isRestricted(address) ? .restricted : .global }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || !host.contains(".") {
            return .restricted
        }
        return .name
    }

    /// The bytes of an IPv4 (4) or IPv6 (16) literal.
    static func address(_ text: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
        return nil
    }

    /// Whether an address is one the extension needs host access for:
    /// IPv4 0/8, 10/8, 100.64/10 (CGNAT), 127/8, 169.254/16, 172.16/12,
    /// 192.168/16; IPv6 `::`, `::1`, fc00::/7, fe80::/10 (and the old
    /// site-local fec0::/10), and an IPv4-mapped or -compatible address by
    /// its IPv4 one. Anything not 4 or 16 bytes long is.
    static func isRestricted(_ address: [UInt8]) -> Bool {
        switch address.count {
        case 4:
            let (a, b) = (address[0], address[1])
            return a == 0 || a == 10 || a == 127
                || (a == 100 && b & 0xC0 == 0x40)
                || (a == 169 && b == 254)
                || (a == 172 && b & 0xF0 == 0x10)
                || (a == 192 && b == 168)
        case 16:
            if address[0..<10].allSatisfy({ $0 == 0 }),
               (address[10] == 0xFF && address[11] == 0xFF) || (address[10] == 0 && address[11] == 0) {
                return isRestricted(Array(address[12...]))
            }
            return address[0] & 0xFE == 0xFC || (address[0] == 0xFE && address[1] >= 0x80)
        default:
            return true
        }
    }

    /// Every address `host` resolves to, looked up off the main actor.
    static func resolve(_ host: String) async -> [[UInt8]] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: addresses(of: host))
            }
        }
    }

    private static func addresses(of host: String) -> [[UInt8]] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var result: [[UInt8]] = []
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let socketAddress = entry.pointee.ai_addr else { continue }
            switch entry.pointee.ai_family {
            case AF_INET:
                result.append(socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
                })
            case AF_INET6:
                result.append(socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                })
            default:
                break
            }
        }
        return result
    }
}
