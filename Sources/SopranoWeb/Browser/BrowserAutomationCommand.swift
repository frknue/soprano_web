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
    /// `--window n` (1-based, see `windows`); nil is the key window, else
    /// the most recently active one.
    let windowIndex: Int?
    /// Seconds a `wait-for-load` or `wait-for` request may wait; nil otherwise.
    let timeout: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case command, arguments, timeout
        case tabIndex = "tab"
        case windowIndex = "window"
    }

    init(
        command: String,
        arguments: [String],
        tabIndex: Int?,
        windowIndex: Int? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.tabIndex = tabIndex
        self.windowIndex = windowIndex
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
        var windowIndex: Int?
        var index = 0
        while index < tokens.count {
            let flag = tokens[index]
            if flag == "--tab" || flag == "--window" {
                let noun = flag == "--tab" ? "tab" : "window"
                guard index + 1 < tokens.count else {
                    throw BrowserAutomationError.invalidArguments("\(flag) requires a \(noun) number")
                }
                guard let value = Int(tokens[index + 1]), value > 0 else {
                    throw BrowserAutomationError.invalidArguments("\(flag) must be a positive number")
                }
                if flag == "--tab" {
                    tabIndex = value
                } else {
                    windowIndex = value
                }
                tokens.removeSubrange(index...(index + 1))
                continue
            }
            index += 1
        }

        guard let command = tokens.first else {
            return BrowserCommandRequest(command: "help", arguments: [], tabIndex: tabIndex, windowIndex: windowIndex)
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
        if command == "move-to-window" {
            guard arguments.count == 1,
                  let destination = arguments.first,
                  destination == "new" || (Int(destination) ?? 0) > 0
            else {
                throw BrowserAutomationError.invalidArguments(moveToWindowUsage)
            }
        }

        return BrowserCommandRequest(
            command: command,
            arguments: arguments,
            tabIndex: tabIndex,
            windowIndex: windowIndex,
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

    static let moveToWindowUsage = "Usage: soprano-web browser [--window n] [--tab m] move-to-window <k|new>"
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
      soprano-web browser [--window n] open [url]
      soprano-web browser [--window n] [--tab n] goto <url>
      soprano-web browser [--window n] [--tab n] wait-for-load [--timeout s]
      soprano-web browser [--window n] [--tab n] wait-for selector <css> [--timeout s]
      soprano-web browser [--window n] [--tab n] wait-for url <substring> [--timeout s]
      soprano-web browser [--window n] [--tab n] wait-for text <text> [--timeout s]
      soprano-web browser [--window n] [--tab n] vimium <keys>
      soprano-web browser [--window n] [--tab n] back|forward|reload|url|title
      soprano-web browser [--window n] [--tab n] snapshot [--interactive]
      soprano-web browser [--window n] [--tab n] eval <javascript>
      soprano-web browser [--window n] [--tab n] click|dblclick|focus|hover <selector|@ref>
      soprano-web browser [--window n] [--tab n] fill|type <selector|@ref> <text>
      soprano-web browser [--window n] [--tab n] check|uncheck|scroll-into-view <selector|@ref>
      soprano-web browser [--window n] [--tab n] press <key>
      soprano-web browser [--window n] [--tab n] get <text|html|value|attr|count> <selector> [attribute]
      soprano-web browser [--window n] [--tab n] is <visible|enabled|checked> <selector|@ref>
      soprano-web browser [--window n] [--tab n] screenshot <path.png>
      soprano-web browser [--window n] tabs
      soprano-web browser [--window n] new-tab [url]
      soprano-web browser [--window n] select-tab <n>
      soprano-web browser [--window n] [--tab n] close-tab [n]
      soprano-web browser windows
      soprano-web browser new-window [url]
      soprano-web browser [--window n] close-window [n]
      soprano-web browser [--window n] [--tab m] move-to-window <k|new>

    `windows` lists the open windows (1-based) with their tab count and the
    selected tab's title; `*` marks the window commands use by default: the
    key window, else the most recently active one. `--window n` targets
    window n and `--tab n` tab n of that window (1-based, see `windows` and
    `tabs`); neither selects a tab or brings a window forward.
    `close-window` puts the window on History ▸ Recently Closed, like ⇧⌘W.
    `move-to-window` moves the selected tab (or tab m) of the window into
    window k, after its tabs, or into a new window (`new`); the tab keeps
    its page and history. It selects nothing and brings no window forward;
    a window left without tabs closes.
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

/// App-side receiver: owns the automation socket for this app variant,
/// picks the window (`--window n`, else the key or most recently active
/// one) and routes each request to it.
@MainActor
final class BrowserAutomationController {
    private let windowManager: () -> BrowserWindowManager?
    private var server: BrowserAutomationServer?
    private var terminationObserver: NSObjectProtocol?

    init(
        windowManager: @escaping () -> BrowserWindowManager?,
        socketPath: String? = BrowserAutomationSocket.path(for: BrowserAutomationSocket.current)
    ) {
        self.windowManager = windowManager
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
        guard let manager = windowManager() else {
            reply(BrowserAutomationResponse(result: .failure(
                BrowserAutomationError.unavailable("Soprano Web is not ready.")
            )))
            return
        }
        BrowserAutomationRouter.perform(request, in: manager) { result in
            reply(BrowserAutomationResponse(result: result))
        }
    }
}

/// Window-level CLI commands and the window a request goes to.
@MainActor
enum BrowserAutomationRouter {
    static func perform(
        _ request: BrowserCommandRequest,
        in manager: BrowserWindowManager,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let url = request.arguments.first
        switch request.command {
        case "windows":
            completion(.success(windowList(manager)))
            return
        case "new-window":
            let controller = manager.newWindow(url: url)
            completion(.success("window \(manager.number(of: controller) ?? manager.controllers.count)"))
            return
        default:
            break
        }

        let target: BrowserWindowController
        if let number = request.windowIndex {
            guard manager.controllers.indices.contains(number - 1) else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "No window \(number). Use `windows` to list them."
                )))
                return
            }
            target = manager.controllers[number - 1]
        } else if let active = manager.activeController {
            target = active
        } else if request.command == "open" || request.command == "new-tab" {
            let controller = manager.newWindow(url: url)
            completion(.success(url ?? controller.selectedTab?.state.url ?? "about:start"))
            return
        } else {
            completion(.failure(BrowserAutomationError.unavailable(
                "No window is open. Use `new-window` to open one."
            )))
            return
        }

        switch request.command {
        case "close-window":
            var closing = target
            if let value = request.arguments.first {
                guard let number = Int(value), manager.controllers.indices.contains(number - 1) else {
                    completion(.failure(BrowserAutomationError.invalidArguments("No window \(value).")))
                    return
                }
                closing = manager.controllers[number - 1]
            }
            let number = manager.number(of: closing) ?? 0
            manager.closeWindow(closing)
            completion(.success("closed window \(number)"))
        case "open":
            let tab = target.newTab(url: url)
            target.revealWindowIfNeeded()
            completion(.success(url ?? tab.state.url ?? "about:start"))
        case "move-to-window":
            completion(moveToWindow(request, from: target, in: manager))
        default:
            target.performAutomation(request, completion: completion)
        }
    }

    /// `move-to-window <k|new>`: the selected tab or `--tab m` of `source`
    /// moves to the end of window k, or alone into a new window behind
    /// `source`. Nothing is selected or brought forward.
    static func moveToWindow(
        _ request: BrowserCommandRequest,
        from source: BrowserWindowController,
        in manager: BrowserWindowManager
    ) -> Result<String, Error> {
        let tab: BrowserTab
        if let number = request.tabIndex {
            guard source.tabs.indices.contains(number - 1) else {
                return .failure(BrowserAutomationError.invalidArguments("No tab \(number). Use `tabs` to list them."))
            }
            tab = source.tabs[number - 1]
        } else if let selected = source.selectedTab {
            tab = selected
        } else {
            return .failure(BrowserAutomationError.unavailable("No tab is open."))
        }
        guard let destination = request.arguments.first else {
            return .failure(BrowserAutomationError.invalidArguments(BrowserCommandRequest.moveToWindowUsage))
        }
        let target: BrowserWindowController
        if destination == "new" {
            guard let created = manager.moveTabToNewWindow(tab, from: source, raise: false) else {
                return .failure(BrowserAutomationError.unavailable("The tab could not move."))
            }
            target = created
        } else {
            guard let number = Int(destination), manager.controllers.indices.contains(number - 1) else {
                return .failure(BrowserAutomationError.invalidArguments(
                    "No window \(destination). Use `windows` to list them."
                ))
            }
            target = manager.controllers[number - 1]
            guard target !== source else {
                return .failure(BrowserAutomationError.invalidArguments("The tab is already in window \(number)."))
            }
            guard manager.canMoveTab(from: source, to: target) else {
                return .failure(BrowserAutomationError.invalidArguments("Window \(number) can't take tabs."))
            }
            manager.moveTab(tab, from: source, to: target, at: nil, select: false)
        }
        let window = manager.number(of: target) ?? 0
        let index = (target.tabs.firstIndex { $0 === tab } ?? 0) + 1
        return .success("window \(window) tab \(index)")
    }

    /// `* 1\t3 tabs\tExample Domain`, one line per window.
    static func windowList(_ manager: BrowserWindowManager) -> String {
        let active = manager.activeController
        return manager.controllers.enumerated().map { index, controller in
            let mark = controller === active ? "*" : " "
            let count = controller.tabs.count
            let title = controller.selectedTab?.displayTitle ?? "New Tab"
            return "\(mark) \(index + 1)\t\(count) \(count == 1 ? "tab" : "tabs")\t\(title)"
        }.joined(separator: "\n")
    }
}
