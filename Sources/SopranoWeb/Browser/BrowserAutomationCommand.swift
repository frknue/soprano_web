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

struct BrowserCommandRequest: Equatable {
    let command: String
    let arguments: [String]
    let tabIndex: Int?

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

        return BrowserCommandRequest(command: command, arguments: arguments, tabIndex: tabIndex)
    }
}

/// CLI entry point. A shell invokes the app binary with `browser`; the request
/// is routed to the running app and answered through a request-scoped
/// distributed notification.
enum BrowserCommand {
    private static let requestPrefix = "com.soprano.web.browser-request"
    private static let responsePrefix = "com.soprano.web.browser-response"
    private static let bundleIdentifiers = ["com.soprano.web", "com.soprano.web.dev"]
    private static let timeout: TimeInterval = 15

    static let help = """
    Usage:
      soprano-web browser open [url]
      soprano-web browser [--tab n] goto <url>
      soprano-web browser [--tab n] wait-for-load
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
      soprano-web browser close-tab [n]

    `snapshot` assigns ephemeral refs such as `e1`; pass them back as `@e1`.
    `--tab` targets a tab by its 1-based number; without it the selected tab is used.
    """

    static func requestName(appProcessId: String) -> Notification.Name {
        Notification.Name("\(requestPrefix).\(appProcessId)")
    }

    static func responseName(requestId: String) -> Notification.Name {
        Notification.Name("\(responsePrefix).\(requestId)")
    }

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

        guard let app = runningApp() else {
            write("Soprano Web is not running. Launch it first.", to: .standardError)
            return 2
        }

        let appProcessId = String(app.processIdentifier)
        let requestId = UUID().uuidString
        let responseNotification = responseName(requestId: requestId)
        let center = DistributedNotificationCenter.default()
        let responseBox = BrowserCommandResponseBox()
        let observer = center.addObserver(
            forName: responseNotification,
            object: nil,
            queue: nil
        ) { notification in
            let response = notification.userInfo?.reduce(into: [String: String]()) {
                guard let key = $1.key as? String, let value = $1.value as? String else { return }
                $0[key] = value
            }
            responseBox.set(response)
        }
        defer { center.removeObserver(observer) }

        let argumentData = (try? JSONEncoder().encode(request.arguments)) ?? Data("[]".utf8)
        var userInfo: [String: String] = [
            "requestId": requestId,
            "command": request.command,
            "arguments": String(data: argumentData, encoding: .utf8) ?? "[]",
        ]
        if let tabIndex = request.tabIndex {
            userInfo["tab"] = String(tabIndex)
        }

        center.postNotificationName(
            requestName(appProcessId: appProcessId),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )

        let deadline = Date().addingTimeInterval(timeout)
        while responseBox.value == nil, Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.05))
            )
        }

        guard let response = responseBox.value else {
            write("Timed out waiting for Soprano Web automation.", to: .standardError)
            return 1
        }
        let succeeded = response["ok"] == "1"
        let output = response[succeeded ? "output" : "error"] ?? ""
        write(output, to: succeeded ? .standardOutput : .standardError)
        return succeeded ? 0 : 1
    }

    private static func runningApp() -> NSRunningApplication? {
        // A CLI run from the Dev bundle must drive the Dev app, even when the
        // installed release is also open with the user's real logins.
        var identifiers: [String] = []
        if let own = Bundle.main.bundleIdentifier, bundleIdentifiers.contains(own) {
            identifiers.append(own)
        }
        for identifier in bundleIdentifiers where !identifiers.contains(identifier) {
            identifiers.append(identifier)
        }
        for identifier in identifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first(where: { !$0.isTerminated })
            {
                return app
            }
        }
        return nil
    }

    private static func write(_ value: String, to handle: FileHandle) {
        let terminated = value.hasSuffix("\n") ? value : "\(value)\n"
        if let data = terminated.data(using: .utf8) {
            handle.write(data)
        }
    }
}

final class BrowserCommandResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: [String: String]?

    var value: [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: [String: String]?) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

struct BrowserAutomationNotificationPayload: Sendable {
    let requestId: String
    let command: String
    let arguments: [String]
    let tabIndex: Int?

    init?(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let requestId = userInfo["requestId"] as? String,
              let command = userInfo["command"] as? String,
              let encodedArguments = userInfo["arguments"] as? String,
              let data = encodedArguments.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String].self, from: data)
        else {
            return nil
        }
        self.requestId = requestId
        self.command = command
        self.arguments = arguments
        self.tabIndex = (userInfo["tab"] as? String).flatMap(Int.init)
    }
}

/// App-side receiver. It only routes requests addressed to this process, so a
/// second instance never answers another instance's CLI call.
@MainActor
final class BrowserAutomationController: @unchecked Sendable {
    private let windowController: () -> BrowserWindowController?
    private var observer: NSObjectProtocol?

    init(windowController: @escaping () -> BrowserWindowController?) {
        self.windowController = windowController
        let processId = String(ProcessInfo.processInfo.processIdentifier)
        observer = DistributedNotificationCenter.default().addObserver(
            forName: BrowserCommand.requestName(appProcessId: processId),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let payload = BrowserAutomationNotificationPayload(notification) else { return }
            MainActor.assumeIsolated {
                self?.handle(payload)
            }
        }
    }

    private func handle(_ payload: BrowserAutomationNotificationPayload) {
        guard let controller = windowController() else {
            respond(
                requestId: payload.requestId,
                result: .failure(BrowserAutomationError.unavailable("Soprano Web is not ready."))
            )
            return
        }

        if payload.command == "open" || payload.command == "new-tab" {
            let url = payload.arguments.first
            let tab = controller.newTab(url: url)
            controller.revealWindowIfNeeded()
            respond(
                requestId: payload.requestId,
                result: .success(url ?? tab.state.url ?? "about:start")
            )
            return
        }

        controller.performAutomation(
            command: payload.command,
            arguments: payload.arguments,
            tabIndex: payload.tabIndex
        ) { [weak self] result in
            self?.respond(requestId: payload.requestId, result: result)
        }
    }

    private func respond(requestId: String, result: Result<String, Error>) {
        let userInfo: [String: String]
        switch result {
        case .success(let output):
            userInfo = ["ok": "1", "output": output]
        case .failure(let error):
            userInfo = ["ok": "0", "error": error.localizedDescription]
        }
        DistributedNotificationCenter.default().postNotificationName(
            BrowserCommand.responseName(requestId: requestId),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }
}
