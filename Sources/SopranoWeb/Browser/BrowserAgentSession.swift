import Foundation

enum BrowserAgentError: LocalizedError, Equatable {
    case ompMissing
    case folderMissing(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .ompMissing:
            "omp isn't installed. Install oh-my-pi (`bun install -g @oh-my-pi/pi-coding-agent`) and log in with `omp login`."
        case let .folderMissing(path):
            "The agent's working folder \(path) doesn't exist. Choose another in Settings ▸ Agent."
        case let .launchFailed(message):
            "omp didn't start: \(message)"
        }
    }
}

/// One `omp --mode rpc` child for a window's Agent panel. Started on the
/// first message, it lives until the window closes or the process ends;
/// the next message after an exit starts a new one. Frames go in on
/// stdin, events come back on stdout (`BrowserAgentProtocol`), both on
/// the main actor in order.
@MainActor
final class BrowserAgentSession {
    /// Every decoded stdout frame, in order.
    var onEvent: ((BrowserAgentEvent) -> Void)?
    /// The process ended without `stop()`: why, from its stderr.
    var onExit: ((String) -> Void)?

    /// How the next process starts (Settings ▸ Agent); a running one keeps
    /// what it started with.
    var launch: BrowserAgentLaunch
    /// The folder the running (or next) omp works in.
    private(set) var workingDirectory: String
    private let hostTool: [String: Any]
    private var process: Process?
    private var input: FileHandle?
    private var pending = Data()
    private var errorTail = Data()
    private static let errorTailLimit = 4096

    var isRunning: Bool { process != nil }
    /// Grows with every process started, so an answer meant for an ended
    /// process never reaches the next one.
    private(set) var generation = 0

    init(launch: BrowserAgentLaunch, hostTool: [String: Any]) {
        self.launch = launch
        self.workingDirectory = launch.workingDirectory
        self.hostTool = hostTool
    }

    /// Starts omp when it isn't running and registers the event filter and
    /// the `browser` host tool; omp reads them after its `ready` frame,
    /// before any prompt sent after them.
    func startIfNeeded() throws {
        guard process == nil else { return }
        guard let omp = Self.resolve() else { throw BrowserAgentError.ompMissing }
        let launch = self.launch
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: launch.workingDirectory, isDirectory: &isFolder), isFolder.boolValue else {
            throw BrowserAgentError.folderMissing(launch.workingDirectory)
        }
        let process = Process()
        process.executableURL = omp
        process.arguments = launch.arguments
        process.environment = Self.environment()
        process.currentDirectoryURL = URL(fileURLWithPath: launch.workingDirectory, isDirectory: true)
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // A write after omp exits returns EPIPE instead of killing the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.received(data, from: process) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receivedError(data, from: process) }
            }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.exited(process, status: status) }
            }
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw BrowserAgentError.launchFailed(error.localizedDescription)
        }
        self.process = process
        workingDirectory = launch.workingDirectory
        generation += 1
        input = stdin.fileHandleForWriting
        pending = Data()
        errorTail = Data()
        send(BrowserAgentProtocol.eventFilter)
        send(["type": "set_host_tools", "tools": [hostTool]])
    }

    func send(_ frame: [String: Any]) {
        guard let input else { return }
        try? input.write(contentsOf: BrowserAgentProtocol.encode(frame))
    }

    /// Aborts the run and ends the process: stdin closes (omp exits on
    /// EOF), then SIGTERM after 3 s and SIGKILL 2 s later if it lingers.
    func stop() {
        guard let process else { return }
        send(["type": "abort"])
        try? input?.close()
        input = nil
        self.process = nil
        let pid = process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    private func received(_ data: Data, from source: Process) {
        guard source === process else { return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            if let event = BrowserAgentProtocol.decode(line) {
                onEvent?(event)
            }
        }
    }

    private func receivedError(_ data: Data, from source: Process) {
        guard source === process else { return }
        errorTail.append(data)
        if errorTail.count > Self.errorTailLimit {
            errorTail = errorTail.suffix(Self.errorTailLimit)
        }
    }

    private func exited(_ source: Process, status: Int32) {
        // A stopped process (or one already replaced) ends quietly.
        guard source === process else { return }
        process = nil
        try? input?.close()
        input = nil
        let lines = String(decoding: errorTail, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(3)
            .joined(separator: "\n")
        onExit?(lines.isEmpty ? "omp exited (status \(status))." : "omp exited (status \(status)): \(lines)")
    }

    // MARK: - Finding omp

    /// A GUI app gets launchd's short `PATH`: omp (and the `bun` it runs
    /// on) are looked up in the user and Homebrew tool folders first.
    nonisolated static func toolDirectories(home: String) -> [String] {
        [
            "\(home)/.bun/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.cargo/bin", "\(home)/bin",
        ]
    }

    nonisolated static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in toolDirectories(home: home) + inherited where !directory.isEmpty {
            let path = (directory as NSString).appendingPathComponent("omp")
            if isExecutable(path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    nonisolated static func environment(
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String: String] {
        var environment = inherited
        var seen = Set<String>()
        let path = (toolDirectories(home: home) + (inherited["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        environment["PATH"] = path.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        return environment
    }
}
