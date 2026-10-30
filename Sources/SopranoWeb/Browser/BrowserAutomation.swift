import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Automation

    /// Commands that never read the target tab's page, so they leave a
    /// lazily restored tab unloaded.
    static let commandsWithoutPage: Set<String> = [
        "goto", "navigate", "url", "get-url", "title", "tabs", "new-tab",
        "select-tab", "close-tab", "focus-address", "media",
    ]

    /// Runs one CLI request. `--tab n` targets tab n of the current Space
    /// (as `tabs` numbers them) without selecting it.
    func performAutomation(
        _ request: BrowserCommandRequest,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let command = request.command
        let arguments = request.arguments
        let target: BrowserTab?
        if let tabIndex = request.tabIndex {
            guard tabIndex > 0, visibleTabs.indices.contains(tabIndex - 1) else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "No tab \(tabIndex). Use `tabs` to list them."
                )))
                return
            }
            target = visibleTabs[tabIndex - 1]
        } else {
            target = selectedTab
        }
        // A lazily restored tab has no page yet; commands that read or drive
        // the page load it first, without selecting it.
        if let target, !Self.commandsWithoutPage.contains(command) {
            tabWasUsed(target)
            loadRestoredTabIfNeeded(target)
        }
        let noTab = BrowserAutomationError.unavailable("No tab is open.")

        switch command {
        case "site":
            // Without `--tab`, the page the user looks at (a Peek's).
            guard let tab = request.tabIndex == nil ? pageTab : target else {
                completion(.failure(noTab))
                return
            }
            performSiteCommand(arguments, tab: tab, completion: completion)
        case "reader", "translate":
            // Without `--tab`, the page the user looks at (a Peek's).
            guard let tab = request.tabIndex == nil ? pageTab : target else {
                completion(.failure(noTab))
                return
            }
            if command == "reader" {
                performReaderCommand(arguments, tab: tab, completion: completion)
            } else {
                performTranslateCommand(arguments, tab: tab, completion: completion)
            }
        case "media":
            // Without `--tab`, the tab the media controls show.
            performMediaCommand(arguments, tab: request.tabIndex == nil ? nil : target, completion: completion)
        case "goto", "navigate":
            guard let input = arguments.first else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Usage: soprano-web browser goto <url>"
                )))
                return
            }
            guard let url = BrowserAddressResolver.resolve(
                input,
                searchEngines: settingsStore.settings.searchEngines
            ) else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Invalid browser address: \(input)"
                )))
                return
            }
            guard let tab = target else {
                completion(.failure(noTab))
                return
            }
            navigate(tab, to: url)
            completion(.success(url.absoluteString))

        case "back", "forward", "reload":
            guard let tab = target else {
                completion(.failure(noTab))
                return
            }
            switch command {
            case "back": goBack(tab)
            case "forward": goForward(tab)
            default: reload(tab)
            }
            completion(.success(tab.webView.url?.absoluteString ?? ""))

        case "url", "get-url":
            if let target, target.lifecycle.pendingRestore != nil {
                completion(.success(target.state.url ?? "about:start"))
            } else if target?.isStartPage == true {
                completion(.success("about:start"))
            } else {
                completion(.success(
                    target?.failedURL ?? target?.webView.url?.absoluteString ?? ""
                ))
            }

        case "title":
            if let target, target.lifecycle.pendingRestore != nil {
                completion(.success(target.state.title))
            } else {
                completion(.success(target?.webView.title ?? ""))
            }

        case "tabs":
            completion(.success(automationTabLines().joined(separator: "\n")))

        case "new-tab":
            let url = arguments.first
            let tab = newTab(url: url)
            revealWindowIfNeeded()
            completion(.success(tab.webView.url?.absoluteString ?? "about:start"))

        case "select-tab":
            guard let value = arguments.first, let number = Int(value), number > 0,
                  visibleTabs.indices.contains(number - 1)
            else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Usage: soprano-web browser select-tab <n>"
                )))
                return
            }
            selectTab(index: number - 1, focus: false)
            completion(.success("tab \(number)"))

        case "close-tab":
            let number = arguments.first.flatMap(Int.init) ?? request.tabIndex ?? (selectedIndex + 1)
            guard visibleTabs.indices.contains(number - 1) else {
                completion(.failure(BrowserAutomationError.invalidArguments("No tab \(number).")))
                return
            }
            closeTab(id: visibleTabs[number - 1].id, archive: true)
            completion(.success("closed tab \(number)"))

        case "vimium":
            guard let tab = target else {
                completion(.failure(noTab))
                return
            }
            guard let keys = arguments.first else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Usage: soprano-web browser vimium <keys>"
                )))
                return
            }
            tab.webView.sendKeysForTesting(keys)
            completion(.success("vimium \(keys)"))

        case "wait-for-load":
            guard let tab = target else {
                completion(.failure(noTab))
                return
            }
            waitForLoad(
                tab,
                timeout: request.timeout ?? BrowserCommandRequest.defaultWaitTimeout,
                completion: completion
            )

        case "wait-for":
            guard let tab = target else {
                completion(.failure(noTab))
                return
            }
            guard arguments.count == 2,
                  let condition = AutomationWaitCondition(kind: arguments[0], value: arguments[1])
            else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Usage: soprano-web browser wait-for <selector|url|text> <value> [--timeout s]"
                )))
                return
            }
            waitFor(
                condition,
                in: tab,
                timeout: request.timeout ?? BrowserCommandRequest.defaultWaitTimeout,
                completion: completion
            )

        case "focus-address":
            focusAddressBar()
            completion(.success("focused address bar"))

        case "snapshot":
            evaluateString(
                BrowserAutomationScripts.snapshotScript(
                    interactiveOnly: arguments.contains("--interactive")
                ),
                in: target,
                completion: completion
            )

        case "eval":
            guard !arguments.isEmpty else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Usage: soprano-web browser eval <javascript>"
                )))
                return
            }
            guard let tab = target else {
                completion(.failure(noTab))
                return
            }
            evaluateAsync(arguments.joined(separator: " "), in: tab.webView, completion: completion)

        case "click", "dblclick", "focus", "hover", "check", "uncheck", "scroll-into-view":
            guard let selector = arguments.first else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Usage: soprano-web browser \(command) <selector|@ref>"
                )))
                return
            }
            evaluateAction(
                BrowserAutomationScripts.elementActionScript(command: command, selector: selector),
                selector: selector,
                in: target,
                completion: completion
            )

        case "fill", "type":
            guard let selector = arguments.first else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Usage: soprano-web browser \(command) <selector|@ref> <text>"
                )))
                return
            }
            let text = arguments.dropFirst().joined(separator: " ")
            evaluateAction(
                BrowserAutomationScripts.textActionScript(
                    command: command,
                    selector: selector,
                    text: text
                ),
                selector: selector,
                in: target,
                completion: completion
            )

        case "press":
            guard let key = arguments.first else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Usage: soprano-web browser press <key>"
                )))
                return
            }
            evaluateAction(
                BrowserAutomationScripts.keyPressScript(key: key),
                selector: key,
                in: target,
                completion: completion
            )

        case "get":
            guard arguments.count >= 2 else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Usage: soprano-web browser get <text|html|value|attr|count> <selector> [attribute]"
                )))
                return
            }
            evaluateAction(
                BrowserAutomationScripts.getScript(
                    kind: arguments[0],
                    selector: arguments[1],
                    attribute: arguments.count > 2 ? arguments[2] : nil
                ),
                selector: arguments[1],
                in: target,
                completion: completion
            )

        case "is":
            guard arguments.count >= 2 else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Usage: soprano-web browser is <visible|enabled|checked> <selector|@ref>"
                )))
                return
            }
            evaluateAction(
                BrowserAutomationScripts.stateScript(kind: arguments[0], selector: arguments[1]),
                selector: arguments[1],
                in: target,
                completion: completion
            )

        case "screenshot":
            guard let path = arguments.last else {
                completion(.failure(BrowserAutomationError.invalidArguments(BrowserCommandRequest.screenshotUsage)))
                return
            }
            guard let tab = target else {
                completion(.failure(noTab))
                return
            }
            if arguments.first == "--full" {
                takeFullPageScreenshot(of: tab, path: path, completion: completion)
            } else {
                takeScreenshot(of: tab, path: path, completion: completion)
            }

        default:
            completion(.failure(BrowserAutomationError.invalidArguments(
                "Unsupported browser command: \(command)"
            )))
        }
    }

    /// `eval`: the source runs as an expression when it parses as one, else
    /// as an async function body. The result is awaited and returned as JSON
    /// text; a throw or rejection fails with the JavaScript message.
    private func evaluateAsync(
        _ source: String,
        in webView: WKWebView,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        webView.callAsyncJavaScript(
            BrowserAutomationEval.expressionCheck(source),
            arguments: [:],
            in: nil,
            in: .page
        ) { check in
            let isExpression: Bool
            if case .success = check { isExpression = true } else { isExpression = false }
            webView.callAsyncJavaScript(
                BrowserAutomationEval.body(source, asExpression: isExpression),
                arguments: [:],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    completion(.success(value as? String ?? "null"))
                case .failure(let error):
                    completion(.failure(BrowserAutomationError.javascript(
                        Self.javaScriptMessage(error)
                    )))
                }
            }
        }
    }

    static func javaScriptMessage(_ error: Error) -> String {
        let error = error as NSError
        return error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    }

    private func evaluateString(
        _ script: String,
        in tab: BrowserTab?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let webView = tab?.webView else {
            completion(.failure(BrowserAutomationError.unavailable("No tab is open.")))
            return
        }
        webView.evaluateJavaScript(script) { value, error in
            if let error {
                completion(.failure(BrowserAutomationError.javascript(error.localizedDescription)))
            } else {
                completion(.success(value as? String ?? ""))
            }
        }
    }

    private func evaluateAction(
        _ script: String,
        selector: String,
        in tab: BrowserTab?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let webView = tab?.webView else {
            completion(.failure(BrowserAutomationError.unavailable("No tab is open.")))
            return
        }
        webView.evaluateJavaScript(script) { value, error in
            if let error {
                completion(.failure(BrowserAutomationError.javascript(error.localizedDescription)))
                return
            }
            guard let payload = value as? [String: Any],
                  payload["ok"] as? Bool == true
            else {
                let message = (value as? [String: Any])?["error"] as? String
                completion(.failure(
                    message.map(BrowserAutomationError.javascript)
                        ?? BrowserAutomationError.elementNotFound(selector)
                ))
                return
            }
            completion(.success(payload["output"] as? String ?? "ok"))
        }
    }

    private func takeScreenshot(
        of tab: BrowserTab,
        path: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        tab.webView.takeSnapshot(with: nil) { image, error in
            if let error {
                completion(.failure(BrowserAutomationError.screenshot(error.localizedDescription)))
                return
            }
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                completion(.failure(BrowserAutomationError.screenshot(
                    "WebKit could not encode the screenshot"
                )))
                return
            }
            do {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try png.write(to: url, options: .atomic)
                completion(.success(url.path))
            } catch {
                completion(.failure(BrowserAutomationError.screenshot(error.localizedDescription)))
            }
        }
    }

    /// `screenshot --full`: the whole document (`BrowserCaptureRenderer`),
    /// at the window's scale; a page cut at the height cap says so.
    private func takeFullPageScreenshot(
        of tab: BrowserTab,
        path: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        Task { @MainActor in
            do {
                let image = try await BrowserCaptureRenderer.fullPage(
                    of: tab.webView,
                    scale: BrowserCaptureRenderer.scale(of: tab.webView)
                )
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try image.png.write(to: url, options: .atomic)
                let cut = image.isCut ? "\ncut at \(BrowserCaptureGeometry.maxPixelLength) px" : ""
                completion(.success(url.path + cut))
            } catch {
                completion(.failure(BrowserAutomationError.screenshot(error.localizedDescription)))
            }
        }
    }
}
