import AppKit
import Darwin

/// Where the running app listens for `browser` CLI requests: a Unix domain
/// socket in the app's support directory that only the user can open.
enum BrowserAutomationSocket {
    struct Variant: Equatable, Sendable {
        let bundleIdentifier: String
        let applicationName: String
        let shortName: String
    }

    static let release = Variant(
        bundleIdentifier: "com.soprano.web",
        applicationName: "Soprano Web",
        shortName: "soprano-web"
    )
    static let dev = Variant(
        bundleIdentifier: "com.soprano.web.dev",
        applicationName: "Soprano Web Dev",
        shortName: "soprano-web-dev"
    )

    static var current: Variant {
        Bundle.main.bundleIdentifier == dev.bundleIdentifier ? dev : release
    }

    static let fileName = "automation.sock"

    /// `sun_path` holds 104 bytes including the terminating NUL.
    static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// The support-directory socket, or the per-user temporary directory when
    /// a long home path would overflow `sun_path`. Nil when neither fits.
    static func path(
        for variant: Variant,
        supportBase: URL = defaultSupportBase,
        temporaryDirectory: String = userTemporaryDirectory
    ) -> String? {
        let preferred = supportBase
            .appendingPathComponent(variant.applicationName, isDirectory: true)
            .appendingPathComponent(fileName)
            .path
        if preferred.utf8.count <= maxPathLength {
            return preferred
        }
        let fallback = URL(fileURLWithPath: temporaryDirectory, isDirectory: true)
            .appendingPathComponent("\(variant.shortName).sock")
            .path
        return fallback.utf8.count <= maxPathLength ? fallback : nil
    }

    /// The CLI tries its own variant first, so a CLI run from the Dev bundle
    /// drives the Dev app even when the installed release is also open.
    static func candidateVariants(ownBundleIdentifier: String?) -> [Variant] {
        ownBundleIdentifier == dev.bundleIdentifier ? [dev, release] : [release, dev]
    }

    static var defaultSupportBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
    }

    /// The per-user temporary directory from the system, not `$TMPDIR`, so the
    /// app and a shell with a different `TMPDIR` agree on the path.
    static var userTemporaryDirectory: String {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return NSTemporaryDirectory() }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else {
            return NSTemporaryDirectory()
        }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}

enum BrowserAutomationSocketError: LocalizedError, Equatable {
    case pathTooLong(String)
    case inUse(String)
    case notASocket(String)
    case notRunning
    case timedOut
    case foreignPeer
    case tooLarge
    case malformed
    case closed
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): "Socket path is too long: \(path)"
        case .inUse(let path): "Another Soprano Web instance is listening on \(path)."
        case .notASocket(let path): "A file that is not a socket is in the way: \(path)"
        case .notRunning: "Soprano Web is not running. Launch it first."
        case .timedOut: "Timed out waiting for Soprano Web automation."
        case .foreignPeer: "The automation socket belongs to another user."
        case .tooLarge: "The automation message is too large."
        case .malformed: "The automation message is not valid JSON."
        case .closed: "Soprano Web closed the connection without answering."
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Non-blocking socket I/O with absolute deadlines.
enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= BrowserAutomationSocket.maxPathLength else {
            throw BrowserAutomationSocketError.pathTooLong(path)
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func withSockaddr<T>(
        _ address: inout sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func make() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrowserAutomationSocketError.system("socket", errno) }
        configure(fd)
        return fd
    }

    /// Close-on-exec, and a write to a closed peer returns EPIPE instead of
    /// killing the process with SIGPIPE.
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    static func connect(to path: String) throws -> Int32 {
        var address = try address(path)
        let fd = try make()
        let result = withSockaddr(&address) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            let code = errno
            close(fd)
            if code == ENOENT || code == ECONNREFUSED {
                throw BrowserAutomationSocketError.notRunning
            }
            throw BrowserAutomationSocketError.system("connect", code)
        }
        return fd
    }

    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid = uid_t(0)
        var gid = gid_t(0)
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    static func wait(_ fd: Int32, for events: Int32, until deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw BrowserAutomationSocketError.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
            let milliseconds = Int32(min((remaining * 1000).rounded(.up), Double(Int32.max)))
            let result = poll(&descriptor, 1, milliseconds)
            if result > 0 { return }
            if result == 0 { throw BrowserAutomationSocketError.timedOut }
            if errno != EINTR { throw BrowserAutomationSocketError.system("poll", errno) }
        }
    }

    static func writeAll(_ data: Data, to fd: Int32, until deadline: Date) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EAGAIN || errno == EINTR {
                    try wait(fd, for: POLLOUT, until: deadline)
                } else {
                    throw BrowserAutomationSocketError.system("write", errno)
                }
            }
        }
    }

    /// Reads until the peer closes its write side.
    static func readAll(from fd: Int32, until deadline: Date, limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                guard data.count <= limit else { throw BrowserAutomationSocketError.tooLarge }
            } else if count == 0 {
                return data
            } else if errno == EAGAIN || errno == EINTR {
                try wait(fd, for: POLLIN, until: deadline)
            } else {
                throw BrowserAutomationSocketError.system("read", errno)
            }
        }
    }
}

/// CLI side: one request and one response per connection. The request ends
/// when the client closes its write side; the response when the app closes.
enum BrowserAutomationClient {
    static let maxResponseBytes = 256 * 1024 * 1024

    static func send(
        _ request: BrowserCommandRequest,
        to path: String,
        timeout: TimeInterval
    ) throws -> BrowserAutomationResponse {
        let fd = try UnixSocket.connect(to: path)
        defer { close(fd) }
        guard UnixSocket.peerUID(fd) == getuid() else {
            throw BrowserAutomationSocketError.foreignPeer
        }
        UnixSocket.setNonBlocking(fd)
        let deadline = Date().addingTimeInterval(timeout)
        try UnixSocket.writeAll(JSONEncoder().encode(request), to: fd, until: deadline)
        shutdown(fd, SHUT_WR)
        let data = try UnixSocket.readAll(from: fd, until: deadline, limit: maxResponseBytes)
        guard !data.isEmpty else { throw BrowserAutomationSocketError.closed }
        guard let response = try? JSONDecoder().decode(BrowserAutomationResponse.self, from: data) else {
            throw BrowserAutomationSocketError.malformed
        }
        return response
    }
}

/// App side. Accepts connections only from processes of the same user,
/// answers each request once, and answers with a timeout error when the
/// command does not finish in time.
final class BrowserAutomationServer: @unchecked Sendable {
    typealias Reply = @Sendable (BrowserAutomationResponse) -> Void
    typealias Handler = @MainActor @Sendable (BrowserCommandRequest, @escaping Reply) -> Void

    static let maxRequestBytes = 16 * 1024 * 1024
    static let requestReadTimeout: TimeInterval = 5
    static let responseWriteTimeout: TimeInterval = 10

    let path: String
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "com.soprano.web.automation.accept")
    private let connectionQueue = DispatchQueue(
        label: "com.soprano.web.automation.connections",
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var inode: ino_t = 0

    /// Binds and starts listening. A stale socket left by a crashed run is
    /// removed; a socket another live instance answers on is left alone.
    init(path: String, handler: @escaping Handler) throws {
        self.path = path
        self.handler = handler

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.removeStaleSocket(at: path)

        var address = try UnixSocket.address(path)
        let fd = try UnixSocket.make()
        guard UnixSocket.withSockaddr(&address, { bind(fd, $0, $1) }) == 0 else {
            let code = errno
            close(fd)
            throw BrowserAutomationSocketError.system("bind", code)
        }
        guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw BrowserAutomationSocketError.system("listen", code)
        }
        var info = stat()
        if lstat(path, &info) == 0 {
            inode = info.st_ino
        }
        UnixSocket.setNonBlocking(fd)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPending(on: fd)
        }
        source.setCancelHandler {
            close(fd)
        }
        self.source = source
        source.resume()
    }

    deinit {
        stop()
    }

    /// Stops listening and removes the socket file if it is still ours.
    func stop() {
        lock.lock()
        let source = self.source
        self.source = nil
        lock.unlock()
        guard let source else { return }
        source.cancel()
        var info = stat()
        if lstat(path, &info) == 0, info.st_ino == inode {
            unlink(path)
        }
    }

    static func removeStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK else {
            throw BrowserAutomationSocketError.notASocket(path)
        }
        if let fd = try? UnixSocket.connect(to: path) {
            close(fd)
            throw BrowserAutomationSocketError.inUse(path)
        }
        unlink(path)
    }

    private func acceptPending(on listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            UnixSocket.configure(client)
            guard UnixSocket.peerUID(client) == getuid() else {
                close(client)
                continue
            }
            UnixSocket.setNonBlocking(client)
            let handler = handler
            let connectionQueue = connectionQueue
            connectionQueue.async {
                Self.serve(client, handler: handler, queue: connectionQueue)
            }
        }
    }

    private static func serve(_ client: Int32, handler: @escaping Handler, queue: DispatchQueue) {
        let reply = BrowserAutomationReplyOnce { response in
            queue.async {
                if let data = try? JSONEncoder().encode(response) {
                    try? UnixSocket.writeAll(
                        data,
                        to: client,
                        until: Date().addingTimeInterval(responseWriteTimeout)
                    )
                }
                close(client)
            }
        }

        let request: BrowserCommandRequest
        do {
            let data = try UnixSocket.readAll(
                from: client,
                until: Date().addingTimeInterval(requestReadTimeout),
                limit: maxRequestBytes
            )
            request = try JSONDecoder().decode(BrowserCommandRequest.self, from: data)
        } catch {
            reply.send(BrowserAutomationResponse(
                result: .failure(BrowserAutomationSocketError.malformed)
            ))
            return
        }

        let timeout = request.serverTimeout
        queue.asyncAfter(deadline: .now() + timeout) {
            reply.send(BrowserAutomationResponse(result: .failure(
                BrowserAutomationError.unavailable(
                    "Timed out after \(BrowserCommandRequest.seconds(timeout)) s waiting for `\(request.command)`."
                )
            )))
        }
        Task { @MainActor in
            handler(request) { reply.send($0) }
        }
    }
}

/// Delivers the first response for a connection and drops later ones, so a
/// command that finishes after its timeout cannot write twice.
final class BrowserAutomationReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@Sendable (BrowserAutomationResponse) -> Void)?

    init(_ deliver: @escaping @Sendable (BrowserAutomationResponse) -> Void) {
        self.deliver = deliver
    }

    func send(_ response: BrowserAutomationResponse) {
        lock.lock()
        let deliver = self.deliver
        self.deliver = nil
        lock.unlock()
        deliver?(response)
    }
}
