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
    /// `new-window --space <n|name>`: the Space the window opens on.
    let space: String?

    enum CodingKeys: String, CodingKey {
        case command, arguments, timeout, space
        case tabIndex = "tab"
        case windowIndex = "window"
    }

    init(
        command: String,
        arguments: [String],
        tabIndex: Int?,
        windowIndex: Int? = nil,
        timeout: TimeInterval? = nil,
        space: String? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.tabIndex = tabIndex
        self.windowIndex = windowIndex
        self.timeout = timeout
        self.space = space
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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        standardInput: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }
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
        if command == "space", arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces).isEmpty {
            throw BrowserAutomationError.invalidArguments(spaceUsage)
        }
        if command == "extension" {
            try parseExtension(&arguments, environment: environment)
            if ["install", "update"].contains(arguments.first) {
                // A download, its check and WebKit's load of the package.
                timeout = maxWaitTimeout
            }
        }
        var space: String?
        if command == "new-window" || command == "little" {
            space = try extractSpace(from: &arguments)
            guard arguments.count <= 1 else {
                throw BrowserAutomationError.invalidArguments(command == "little" ? littleUsage : newWindowUsage)
            }
        }
        if command == "peek", arguments.count > 1 {
            throw BrowserAutomationError.invalidArguments(peekUsage)
        }
        if command == "split" {
            let valid: Bool
            switch arguments.first {
            case nil: valid = true
            case "close": valid = arguments.count == 1
            case "focus": valid = arguments.count == 2 && (Int(arguments[1]) ?? 0) > 0
            default: valid = arguments.count == 1
            }
            guard valid else { throw BrowserAutomationError.invalidArguments(splitUsage) }
        }
        if command == "boost" {
            try parseBoost(&arguments, environment: environment, standardInput: standardInput)
        }
        if command == "site" {
            let valid: Bool
            switch arguments.first {
            case nil, "info", "clear": valid = arguments.count <= 1
            case "permission":
                valid = arguments.count == 3
                    && BrowserSiteControlState.permissionRows.contains { $0.0.rawValue == arguments[1] }
                    && BrowserSiteChoice(rawValue: arguments[2]) != nil
            default: valid = false
            }
            guard valid else { throw BrowserAutomationError.invalidArguments(siteUsage) }
        }

        return BrowserCommandRequest(
            command: command,
            arguments: arguments,
            tabIndex: tabIndex,
            windowIndex: windowIndex,
            timeout: timeout,
            space: space
        )
    }

    /// `--space <n|name>` (a name may contain spaces when quoted).
    private static func extractSpace(from arguments: inout [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: "--space") else { return nil }
        guard index + 1 < arguments.count else {
            throw BrowserAutomationError.invalidArguments("--space requires a Space number or name")
        }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw BrowserAutomationError.invalidArguments("--space requires a Space number or name")
        }
        arguments.removeSubrange(index...(index + 1))
        return value
    }

    /// `extension install <store url|id|folder>` (a relative folder is
    /// resolved against the shell's directory here),
    /// `extension enable|disable|remove|errors <id>`, `extension update`.
    private static func parseExtension(_ arguments: inout [String], environment: [String: String]) throws {
        guard let action = arguments.first else {
            throw BrowserAutomationError.invalidArguments(extensionUsage)
        }
        switch action {
        case "install":
            let input = arguments.dropFirst().joined(separator: " ")
            let directory = URL(
                fileURLWithPath: environment["PWD"] ?? FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
            switch BrowserWebStore.source(for: input, workingDirectory: directory) {
            case let .webStore(id)?:
                arguments = ["install", id]
            case let .folder(url)?:
                arguments = ["install", url.path]
            case nil:
                throw BrowserAutomationError.invalidArguments(extensionUsage)
            }
        case "enable", "disable", "remove", "errors":
            guard arguments.count == 2, BrowserExtensionID.isValid(arguments[1]) else {
                throw BrowserAutomationError.invalidArguments(extensionUsage)
            }
        case "update":
            guard arguments.count == 1 else { throw BrowserAutomationError.invalidArguments(extensionUsage) }
        case "action":
            guard arguments.count == 2 || arguments.count == 3, BrowserExtensionID.isValid(arguments[1]) else {
                throw BrowserAutomationError.invalidArguments(extensionUsage)
            }
            if arguments.count == 3, !arguments[2].hasPrefix("/") {
                let directory = environment["PWD"] ?? FileManager.default.currentDirectoryPath
                arguments[2] = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent(arguments[2]).standardizedFileURL.path
            }
        default:
            throw BrowserAutomationError.invalidArguments(extensionUsage)
        }
    }

    /// `boost list|show <host>|css <host> <file|->|js <host> <file|->|zap
    /// <host> <selector>|enable|disable|remove <host>`. The CLI reads the
    /// file (relative to `PWD`) or its own stdin for `-` and sends the
    /// text, since the app can't read either.
    static func parseBoost(
        _ arguments: inout [String],
        environment: [String: String],
        standardInput: () -> Data
    ) throws {
        let usage = BrowserAutomationError.invalidArguments(boostUsage)
        if arguments.isEmpty {
            arguments = ["list"]
        }
        let action = arguments[0]
        if action == "list" {
            guard arguments.count == 1 else { throw usage }
            return
        }
        guard arguments.count >= 2, isBoostHost(arguments[1]) else { throw usage }
        switch action {
        case "show", "enable", "disable", "remove":
            guard arguments.count == 2 else { throw usage }
        case "css", "js":
            guard arguments.count == 3 else { throw usage }
            let source = arguments[2]
            let data: Data
            if source == "-" {
                data = standardInput()
            } else {
                let directory = environment["PWD"] ?? FileManager.default.currentDirectoryPath
                let url = source.hasPrefix("/")
                    ? URL(fileURLWithPath: source)
                    : URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(source)
                guard let contents = try? Data(contentsOf: url.standardizedFileURL) else {
                    throw BrowserAutomationError.invalidArguments("Can't read \(url.standardizedFileURL.path)")
                }
                data = contents
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw BrowserAutomationError.invalidArguments("The \(action.uppercased()) is not UTF-8 text")
            }
            arguments[2] = text
        case "zap":
            let selector = arguments.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selector.isEmpty else { throw usage }
            arguments = ["zap", arguments[1], selector]
        default:
            throw usage
        }
    }

    /// A host name, not an address: no scheme, path, port or spaces.
    static func isBoostHost(_ value: String) -> Bool {
        BrowserBoost.key(value) != nil
            && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
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
    static let newWindowUsage = "Usage: soprano-web browser new-window [url] [--space <n|name>]"
    static let littleUsage = "Usage: soprano-web browser little [url] [--space <n|name>] | [--window n] little to-window"
    static let spaceUsage = "Usage: soprano-web browser [--window n] space <n|name>"
    static let peekUsage = "Usage: soprano-web browser [--window n] peek [<url>|close|open-as-tab]"
    static let splitUsage = "Usage: soprano-web browser [--window n] split [<url>|close|focus <n>]"
    static let siteUsage = """
    Usage: soprano-web browser [--window n] [--tab n] site [info|clear|permission <camera|microphone|notifications|popups> allow|deny|ask]
    """
    static let boostUsage = """
    Usage: soprano-web browser boost [list]
           soprano-web browser boost show|enable|disable|remove <host>
           soprano-web browser boost css|js <host> <file|->
           soprano-web browser boost zap <host> <selector>
    """
    static let extensionUsage = """
    Usage: soprano-web browser extension install <chrome web store url|id|folder>
           soprano-web browser extension enable|disable|remove|errors <id>
           soprano-web browser extension action <id> [<popup.png>]
           soprano-web browser extension update
    """
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
      soprano-web browser new-window [url] [--space <n|name>]
      soprano-web browser little [url] [--space <n|name>]
      soprano-web browser [--window n] little to-window
      soprano-web browser [--window n] close-window [n]
      soprano-web browser [--window n] [--tab m] move-to-window <k|new>
      soprano-web browser [--window n] peek [<url>|close|open-as-tab]
      soprano-web browser [--window n] split [<url>|close|focus <n>]
      soprano-web browser [--window n] [--tab n] site [info|clear|permission <name> allow|deny|ask]
      soprano-web browser boost [list]
      soprano-web browser boost show|enable|disable|remove <host>
      soprano-web browser boost css|js <host> <file|->
      soprano-web browser boost zap <host> <selector>
      soprano-web browser [--window n] spaces
      soprano-web browser [--window n] space <n|name>
      soprano-web browser extensions
      soprano-web browser extension install <chrome web store url|id|folder>
      soprano-web browser extension enable|disable|remove|errors <id>
      soprano-web browser extension action <id> [<popup.png>]
      soprano-web browser extension update

    `windows` lists the open windows (1-based) with their kind (`normal`,
    `little` for a Little Arc or `popup`), current Space (a Little Arc's own),
    its tab count, the selected tab's title and every Space's tab count;
    `*` marks the window commands use by default: the key
    window, else the most recently active one. `--window n` targets window n
    and `--tab n` tab n of its current Space (1-based, see `windows` and
    `tabs`); neither selects a tab or brings a window forward. Tab commands
    work on the window's current Space. Private windows are never listed,
    numbered or targeted.
    `spaces` lists every Space (1-based, as ⌃1…⌃9 count them) with the
    window's tab count in it; `*` marks the window's current Space.
    `space` switches the window to Space n or the Space named (any case).
    Every Space keeps its own cookies, History and Archive.
    `extensions` lists the installed Chrome extensions: id, name, version,
    state (on, off, not running, installing), private windows, site access,
    source and how many errors WebKit reported. `extension install` takes a
    Chrome Web Store link or id (downloaded, its signatures checked as
    Chrome checks a store install) or an unpacked folder (copied), and
    waits until it runs; `errors` prints what WebKit reported (the
    background's uncaught errors and console errors included); `action`
    clicks the extension's toolbar button in the window commands use and,
    when its popup opens, prints the popup's address, size and text (and
    saves its capture to the PNG); `update`
    checks the Web Store extensions for updates now.
    `new-window` opens on Space n or the Space named by `--space` (any
    case), else on the current Space of the window commands use by
    default (the Default Space when none is open); an unknown Space is an
    error.
    `little` opens a Little Arc (one tab, compact toolbar) with `url` or the
    start page, on the Space named by `--space`, else the Space of the
    window commands use by default; `little to-window` moves a Little
    Arc's tab into its Space's window (⌘O: a window showing the Space,
    else the most recent normal window switched to it) and closes it.
    `close-window` puts the window on History ▸ Recently Closed, like ⇧⌘W.
    `move-to-window` moves the selected tab (or tab m) of the window into
    window k, after the tabs of its current Space, when that is the tab's
    Space, or into a new window on the tab's Space (`new`); the tab
    keeps its page and history. It selects nothing and brings no window
    forward; a window left without tabs closes.
    `peek <url>` opens a Peek over the selected tab (its data context; one
    per window, a second replaces it), as ⇧-click does; `peek` prints the
    open Peek (address, title, back and forward counts, the tab it is
    over); `peek close` closes it (Esc, ⌘W); `peek open-as-tab` makes it a
    selected Today tab after that tab, history kept (⌘O). Page commands
    keep working on the selected tab.
    `split <url>` opens `url` (the start page without one) in a new pane
    right of the focused one: a split view of 2–4 tabs side by side, as
    ⌃⇧= and ⌥-click do; `split close` closes the focused pane (⌃⇧-, its
    tab as ⌘W closes it); `split focus n` focuses pane n, left to right
    (⌃⇧1…4). The focused pane is the selected tab every tab command uses;
    `tabs` marks each pane with `split s, pane p of k`.
    `site` acts on the page the user looks at (the Peek's, the focused
    pane's; `--tab n` another) like the lock's Site Control Center: `site`
    or `site info` prints its site, connection, permissions, zoom, ad
    blocking and extensions' access; `site permission <camera|microphone|
    notifications|popups> allow|deny|ask` sets a decision in the tab's
    profile (a private window's own layer); `site clear` removes the
    site's website data (its registrable domain's: WebKit keeps no finer
    grain) and the host's cookies without asking, then reloads the page.
    `boost` edits Boosts, the user's per-site CSS, JavaScript and hidden
    elements (app-wide, every Space). A host matches itself and its `www.`
    form, not other subdomains. `css`/`js` replace the Boost's code with a
    file or `-` (stdin), making the Boost when there is none; `zap` adds a
    selector to hide. CSS and zaps apply to open pages at once, JavaScript
    from the next load.
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

/// Window-level CLI commands and the window a request goes to. The CLI
/// sees only normal windows: private windows are never listed, numbered or
/// targeted.
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
        case "extensions":
            completion(.success(BrowserExtensionCommands.list(manager.extensions)))
            return
        case "extension":
            BrowserExtensionCommands.perform(request.arguments, in: manager.extensions, completion: completion)
            return
        case "boost":
            completion(BrowserBoostCommands.perform(request.arguments, in: manager.boosts))
            return
        case "little":
            completion(littleArc(request, in: manager))
            return
        case "new-window":
            let controller: BrowserWindowController
            if let value = request.space {
                switch resolveSpace(value, in: manager) {
                case .success(let index):
                    controller = manager.newWindow(url: url, spaceID: manager.spaces.spaces[index].id)
                case .failure(let error):
                    completion(.failure(error))
                    return
                }
            } else {
                let active = manager.automationActiveController.flatMap(manager.space(of:))
                controller = manager.newWindow(url: url, spaceID: active?.id)
            }
            completion(.success("window \(manager.number(of: controller) ?? manager.automationControllers.count)"))
            return
        default:
            break
        }

        let windows = manager.automationControllers
        let target: BrowserWindowController
        if let number = request.windowIndex {
            guard windows.indices.contains(number - 1) else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "No window \(number). Use `windows` to list them."
                )))
                return
            }
            target = windows[number - 1]
        } else if let active = manager.automationActiveController {
            target = active
        } else if request.command == "open" || request.command == "new-tab" {
            let controller = manager.newWindow(url: url, spaceID: manager.spaces.defaultSpace?.id)
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
                guard let number = Int(value), windows.indices.contains(number - 1) else {
                    completion(.failure(BrowserAutomationError.invalidArguments("No window \(value).")))
                    return
                }
                closing = windows[number - 1]
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
        case "spaces":
            completion(.success(spaceList(for: target, in: manager)))
        case "space":
            completion(switchSpace(request, in: target, manager: manager))
        case "peek":
            completion(peek(request, in: target))
        case "split":
            completion(target.performSplitCommand(request.arguments))
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
            guard source.visibleTabs.indices.contains(number - 1) else {
                return .failure(BrowserAutomationError.invalidArguments("No tab \(number). Use `tabs` to list them."))
            }
            tab = source.visibleTabs[number - 1]
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
            let windows = manager.automationControllers
            guard let number = Int(destination), windows.indices.contains(number - 1) else {
                return .failure(BrowserAutomationError.invalidArguments(
                    "No window \(destination). Use `windows` to list them."
                ))
            }
            target = windows[number - 1]
            guard target !== source else {
                return .failure(BrowserAutomationError.invalidArguments("The tab is already in window \(number)."))
            }
            guard manager.canMoveTab(tab, from: source, to: target) else {
                guard target.dataContext.profileID == tab.dataContext.profileID else {
                    let space = target.currentSpaceID.flatMap(manager.spaces.space(id:))?.displayName ?? "another Space"
                    return .failure(BrowserAutomationError.invalidArguments(
                        "Window \(number) shows \(space); a tab moves only into a window showing its own Space."
                    ))
                }
                return .failure(BrowserAutomationError.invalidArguments("Window \(number) can't take tabs."))
            }
            manager.moveTab(tab, from: source, to: target, at: nil, select: false)
        }
        let window = manager.number(of: target) ?? 0
        let index = (target.visibleTabs.firstIndex { $0 === tab } ?? 0) + 1
        return .success("window \(window) tab \(index)")
    }

    /// `peek [<url>|close|open-as-tab]` on `window` (see the help).
    static func peek(_ request: BrowserCommandRequest, in window: BrowserWindowController) -> Result<String, Error> {
        switch request.arguments.first {
        case nil:
            guard let peek = window.peek else { return .success("no peek") }
            return .success(peekLine(peek, in: window))
        case "close":
            guard window.peek != nil else {
                return .failure(BrowserAutomationError.unavailable("No Peek is open."))
            }
            window.closePeek()
            return .success("closed peek")
        case "open-as-tab":
            guard let tab = window.openPeekAsTab() else {
                return .failure(BrowserAutomationError.unavailable("No Peek is open."))
            }
            let index = (window.visibleTabs.firstIndex { $0 === tab } ?? 0) + 1
            return .success("tab \(index)\t\(tab.webView.url?.absoluteString ?? "")\tback \(tab.webView.backForwardList.backList.count)")
        case let input?:
            guard let opener = window.selectedTab else {
                return .failure(BrowserAutomationError.unavailable("No tab is open."))
            }
            guard let url = BrowserAddressResolver.resolve(input, searchEngines: window.settingsStore.settings.searchEngines),
                  BrowserWebSchemes.isWeb(url)
            else {
                return .failure(BrowserAutomationError.invalidArguments("Invalid browser address: \(input)"))
            }
            window.openPeek(url, from: opener)
            let index = (window.visibleTabs.firstIndex { $0 === opener } ?? 0) + 1
            return .success("peek \(url.absoluteString) over tab \(index)")
        }
    }

    /// `<address>\t<title>\tback n, forward m\tover tab k`.
    static func peekLine(_ peek: BrowserPeek, in window: BrowserWindowController) -> String {
        let list = peek.tab.webView.backForwardList
        let address = peek.tab.webView.url?.absoluteString ?? peek.tab.pendingURL ?? ""
        let over = (window.visibleTabs.firstIndex { $0.id == peek.openerID } ?? 0) + 1
        return "\(address)\t\(peek.tab.displayTitle)\tback \(list.backList.count), forward \(list.forwardList.count)\tover tab \(over)"
    }

    /// `little [url] [--space]` opens a Little Arc; `little to-window` (on
    /// `--window n`, else the most recent Little Arc) is ⌘O.
    static func littleArc(_ request: BrowserCommandRequest, in manager: BrowserWindowManager) -> Result<String, Error> {
        if request.arguments == ["to-window"] {
            let little: BrowserWindowController?
            if let number = request.windowIndex {
                let windows = manager.automationControllers
                little = windows.indices.contains(number - 1) ? windows[number - 1] : nil
            } else {
                little = manager.mostRecentlyActive { $0.role == .little }
            }
            guard let little, little.role == .little else {
                return .failure(BrowserAutomationError.invalidArguments("No Little Arc. Use `windows` to list them."))
            }
            guard let target = manager.moveLittleArcToSpaceWindow(little) else {
                return .failure(BrowserAutomationError.unavailable("The Little Arc has no tab to move."))
            }
            let space = manager.space(of: target)?.displayName ?? "-"
            let index = (target.visibleTabs.firstIndex { $0.id == target.selectedTab?.id } ?? 0) + 1
            return .success("window \(manager.number(of: target) ?? 0) tab \(index) (\(space))")
        }
        var spaceID: UUID?
        if let value = request.space {
            switch resolveSpace(value, in: manager) {
            case .success(let index): spaceID = manager.spaces.spaces[index].id
            case .failure(let error): return .failure(error)
            }
        } else {
            spaceID = manager.automationActiveController.flatMap(manager.space(of:))?.id
        }
        let little = manager.newLittleArc(url: request.arguments.first, spaceID: spaceID)
        let space = manager.space(of: little)?.displayName ?? "-"
        return .success("window \(manager.number(of: little) ?? 0) little (\(space))")
    }

    /// `* 1\tnormal\tWork\t2 tabs\tExample Domain\tDefault 3, Work 2`, one
    /// line per window the CLI sees: its kind (`normal`, `little`, `popup`),
    /// its current Space (a Little Arc's own; `-` for a pop-up), that
    /// Space's tab count, the selected tab's title and every Space's tab
    /// count in the window.
    static func windowList(_ manager: BrowserWindowManager) -> String {
        let active = manager.automationActiveController
        return manager.automationControllers.enumerated().map { index, controller in
            let mark = controller === active ? "*" : " "
            let count = controller.visibleTabs.count
            let title = controller.selectedTab?.displayTitle ?? "New Tab"
            let space = (controller.currentSpaceID ?? controller.littleSpaceID)
                .flatMap(manager.spaces.space(id:))?.displayName ?? "-"
            let perSpace = manager.spaces.spaces.compactMap { space -> String? in
                let inSpace = controller.tabs.filter { $0.spaceID == space.id }.count
                return inSpace == 0 ? nil : "\(space.displayName) \(inSpace)"
            }.joined(separator: ", ")
            let kind = controller.role.rawValue
            return "\(mark) \(index + 1)\t\(kind)\t\(space)\t\(count) \(count == 1 ? "tab" : "tabs")\t\(title)\t\(perSpace)"
        }.joined(separator: "\n")
    }

    /// `* 1\tDefault\t3 tabs`, one line per Space: its number, name and how
    /// many of `window`'s tabs are in it; `*` marks the window's current
    /// Space.
    static func spaceList(for window: BrowserWindowController, in manager: BrowserWindowManager) -> String {
        manager.spaces.spaces.enumerated().map { index, space in
            let mark = space.id == window.currentSpaceID ? "*" : " "
            let count = window.tabs.filter { $0.spaceID == space.id }.count
            return "\(mark) \(index + 1)\t\(space.displayName)\t\(count) \(count == 1 ? "tab" : "tabs")"
        }.joined(separator: "\n")
    }

    /// Space n (1-based) or the Space named (any case, surrounding spaces
    /// ignored), as its index in display order.
    static func resolveSpace(_ value: String, in manager: BrowserWindowManager) -> Result<Int, Error> {
        let all = manager.spaces.spaces
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let wanted = trimmed.lowercased()
        guard let index = Int(trimmed).map({ $0 - 1 }).flatMap({ all.indices.contains($0) ? $0 : nil })
            ?? all.firstIndex(where: { $0.displayName.lowercased() == wanted })
        else {
            let known = all.map(\.displayName).joined(separator: ", ")
            return .failure(BrowserAutomationError.invalidArguments("No Space \(value). Spaces: \(known)."))
        }
        return .success(index)
    }

    /// `space <n|name>`: switches `window` to Space n (1-based) or the Space
    /// named (any case, surrounding spaces ignored).
    static func switchSpace(
        _ request: BrowserCommandRequest,
        in window: BrowserWindowController,
        manager: BrowserWindowManager
    ) -> Result<String, Error> {
        let value = request.arguments.joined(separator: " ")
        guard !value.isEmpty else {
            return .failure(BrowserAutomationError.invalidArguments(BrowserCommandRequest.spaceUsage))
        }
        guard window.hasSpaces else {
            return .failure(BrowserAutomationError.invalidArguments("This window has no Spaces."))
        }
        switch resolveSpace(value, in: manager) {
        case .success(let index):
            let space = manager.spaces.spaces[index]
            window.switchToSpace(space.id, focus: false)
            return .success("space \(index + 1) \(space.displayName)")
        case .failure(let error):
            return .failure(error)
        }
    }
}
