import AppKit

enum BrowserAutomationError: LocalizedError {
    case invalidArguments(String)
    case elementNotFound(String)
    case javascript(String)
    case screenshot(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let usage): usage
        case .elementNotFound(let selector): "Element not found: \(selector)"
        case .javascript(let message), .screenshot(let message), .unavailable(let message): message
        }
    }
}

struct BrowserCommandRequest: Codable, Equatable, Sendable {
    static let defaultWaitTimeout: TimeInterval = 10
    static let maxWaitTimeout: TimeInterval = 120
    /// How long any other command may take in the app.
    static let commandTimeout: TimeInterval = 15
    static let waitKinds = ["selector", "url", "text"]

    let command: String
    let arguments: [String]
    let tabIndex: Int?
    /// Seconds a `wait-for-load` or `wait-for` request may wait; nil otherwise.
    let timeout: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case command, arguments, timeout
        case tabIndex = "tab"
    }

    init(command: String, arguments: [String], tabIndex: Int?, timeout: TimeInterval? = nil) {
        self.command = command
        self.arguments = arguments
        self.tabIndex = tabIndex
        self.timeout = timeout
    }

    /// The app answers with a timeout error after this long; a wait gets a
    /// moment more so its own, more specific timeout message wins.
    var serverTimeout: TimeInterval {
        timeout.map { $0 + 2 } ?? Self.commandTimeout
    }

    /// The CLI gives up after this long; it follows the wait so a long
    /// `--timeout` is not cut short by the CLI.
    var clientTimeout: TimeInterval {
        (timeout ?? Self.commandTimeout) + 5
    }

    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%g", value)
    }

    static func parse(
        _ commandLine: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> BrowserCommandRequest? {
        guard commandLine.count >= 2, commandLine[1] == "browser" else { return nil }

        var tokens = Array(commandLine.dropFirst(2))
        if tokens.isEmpty || tokens == ["--help"] || tokens == ["help"] {
            return BrowserCommandRequest(command: "help", arguments: [], tabIndex: nil)
        }

        var tabIndex: Int?
        var index = 0
        while index < tokens.count {
            if tokens[index] == "--tab" {
                guard index + 1 < tokens.count else {
                    throw BrowserAutomationError.invalidArguments("--tab requires a tab number")
                }
                guard let value = Int(tokens[index + 1]), value > 0 else {
                    throw BrowserAutomationError.invalidArguments("--tab must be a positive number")
                }
                tabIndex = value
                tokens.removeSubrange(index...(index + 1))
                continue
            }
            index += 1
        }

        guard let command = tokens.first else {
            return BrowserCommandRequest(command: "help", arguments: [], tabIndex: tabIndex)
        }
        var arguments = Array(tokens.dropFirst())
        if command == "screenshot", let path = arguments.first, !path.hasPrefix("/") {
            let workingDirectory = environment["PWD"] ?? FileManager.default.currentDirectoryPath
            arguments[0] = URL(
                fileURLWithPath: workingDirectory,
                isDirectory: true
            ).appendingPathComponent(path).standardizedFileURL.path
        }

        var timeout: TimeInterval?
        if command == "wait-for-load" || command == "wait-for" {
            timeout = try extractTimeout(from: &arguments) ?? defaultWaitTimeout
        }
        if command == "wait-for" {
            let usage = "Usage: soprano-web browser wait-for <selector|url|text> <value> [--timeout s]"
            guard let kind = arguments.first, waitKinds.contains(kind) else {
                throw BrowserAutomationError.invalidArguments(usage)
            }
            let value = arguments.dropFirst().joined(separator: " ")
            guard !value.isEmpty else {
                throw BrowserAutomationError.invalidArguments(usage)
            }
            arguments = [kind, value]
        }

        return BrowserCommandRequest(
            command: command,
            arguments: arguments,
            tabIndex: tabIndex,
            timeout: timeout
        )
    }

    private static func extractTimeout(from arguments: inout [String]) throws -> TimeInterval? {
        guard let index = arguments.firstIndex(of: "--timeout") else { return nil }
        guard index + 1 < arguments.count,
              let value = TimeInterval(arguments[index + 1]),
              value.isFinite, value > 0, value <= maxWaitTimeout
        else {
            throw BrowserAutomationError.invalidArguments(
                "--timeout takes seconds, more than 0 and at most \(seconds(maxWaitTimeout))"
            )
        }
        arguments.removeSubrange(index...(index + 1))
        return value
    }
}

struct BrowserAutomationResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let output: String?
    let error: String?

    init(result: Result<String, Error>) {
        switch result {
        case .success(let output):
            ok = true
            self.output = output
            error = nil
        case .failure(let error):
            ok = false
            output = nil
            self.error = error.localizedDescription
        }
    }
}

/// CLI entry point. A shell invokes the app binary with `browser`; the request
/// goes to the running app over its user-only Unix socket
/// (`BrowserAutomationSocket`), one JSON request and response per connection.
enum BrowserCommand {
    static let help = """
    Usage:
      soprano-web browser open [url]
      soprano-web browser [--tab n] goto <url>
      soprano-web browser [--tab n] wait-for-load [--timeout s]
      soprano-web browser [--tab n] wait-for selector <css> [--timeout s]
      soprano-web browser [--tab n] wait-for url <substring> [--timeout s]
      soprano-web browser [--tab n] wait-for text <text> [--timeout s]
      soprano-web browser [--tab n] vimium <keys>
      soprano-web browser [--tab n] back|forward|reload|url|title
      soprano-web browser [--tab n] snapshot [--interactive]
      soprano-web browser [--tab n] eval <javascript>
      soprano-web browser [--tab n] click|dblclick|focus|hover <selector|@ref>
      soprano-web browser [--tab n] fill|type <selector|@ref> <text>
      soprano-web browser [--tab n] check|uncheck|scroll-into-view <selector|@ref>
      soprano-web browser [--tab n] press <key>
      soprano-web browser [--tab n] get <text|html|value|attr|count> <selector> [attribute]
      soprano-web browser [--tab n] is <visible|enabled|checked> <selector|@ref>
      soprano-web browser [--tab n] screenshot <path.png>
      soprano-web browser tabs
      soprano-web browser new-tab [url]
      soprano-web browser select-tab <n>
      soprano-web browser [--tab n] close-tab [n]

    `--tab n` targets tab n (1-based, see `tabs`) without changing the selected
    tab; without it the selected tab is used.
    `snapshot` assigns ephemeral refs such as `e1`; pass them back as `@e1`.
    `eval` runs an expression, or an async function body that uses `return`;
    Promises are awaited and the result prints as JSON. A thrown error or a
    rejection exits 1 with its message.
    `wait-for-load` waits for the tab's navigation to finish. `wait-for`
    waits until a CSS selector matches, the URL contains a substring, or the
    page's visible text contains the text. Waits default to 10 seconds;
    `--timeout` takes up to 120. Other commands time out after 15 seconds.
    Requests go to the running app over a Unix socket only your user can open.
    """

    static func run(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32? {
        let request: BrowserCommandRequest
        do {
            guard let parsed = try BrowserCommandRequest.parse(arguments, environment: environment) else {
                return nil
            }
            request = parsed
        } catch {
            write(error.localizedDescription, to: .standardError)
            return 2
        }

        if request.command == "help" {
            write(help, to: .standardOutput)
            return 0
        }

        let variants = BrowserAutomationSocket.candidateVariants(
            ownBundleIdentifier: Bundle.main.bundleIdentifier
        )
        for variant in variants {
            guard let path = BrowserAutomationSocket.path(for: variant) else { continue }
            let response: BrowserAutomationResponse
            do {
                response = try BrowserAutomationClient.send(
                    request,
                    to: path,
                    timeout: request.clientTimeout
                )
            } catch BrowserAutomationSocketError.notRunning {
                continue
            } catch {
                write(error.localizedDescription, to: .standardError)
                return 1
            }
            if response.ok {
                write(response.output ?? "", to: .standardOutput)
                return 0
            }
            write(response.error ?? "", to: .standardError)
            return 1
        }
        write(BrowserAutomationSocketError.notRunning.localizedDescription, to: .standardError)
        return 2
    }

    private static func write(_ value: String, to handle: FileHandle) {
        let terminated = value.hasSuffix("\n") ? value : "\(value)\n"
        if let data = terminated.data(using: .utf8) {
            handle.write(data)
        }
    }
}

/// App-side receiver: owns the automation socket for this app variant and
/// routes each request to the window controller.
@MainActor
final class BrowserAutomationController {
    private let windowController: () -> BrowserWindowController?
    private var server: BrowserAutomationServer?
    private var terminationObserver: NSObjectProtocol?

    init(
        windowController: @escaping () -> BrowserWindowController?,
        socketPath: String? = BrowserAutomationSocket.path(for: BrowserAutomationSocket.current)
    ) {
        self.windowController = windowController
        guard let socketPath else {
            FileHandle.standardError.write(Data(
                "Soprano Web automation is off: no socket path fits sun_path.\n".utf8
            ))
            return
        }
        do {
            server = try BrowserAutomationServer(path: socketPath) { [weak self] request, reply in
                guard let self else {
                    reply(BrowserAutomationResponse(result: .failure(
                        BrowserAutomationError.unavailable("Soprano Web is not ready.")
                    )))
                    return
                }
                self.handle(request, reply: reply)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "Soprano Web automation is off: \(error.localizedDescription)\n".utf8
            ))
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.server?.stop()
            }
        }
    }

    private func handle(
        _ request: BrowserCommandRequest,
        reply: @escaping BrowserAutomationServer.Reply
    ) {
        guard let controller = windowController() else {
            reply(BrowserAutomationResponse(result: .failure(
                BrowserAutomationError.unavailable("Soprano Web is not ready.")
            )))
            return
        }

        if request.command == "open" || request.command == "new-tab" {
            let url = request.arguments.first
            let tab = controller.newTab(url: url)
            controller.revealWindowIfNeeded()
            reply(BrowserAutomationResponse(result: .success(url ?? tab.state.url ?? "about:start")))
            return
        }

        controller.performAutomation(request) { result in
            reply(BrowserAutomationResponse(result: result))
        }
    }
}
