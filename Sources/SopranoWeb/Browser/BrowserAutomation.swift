import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Zoom and palette

    var canReopenClosedTab: Bool {
        !closedTabs.isEmpty
    }

    func zoomIn() {
        setZoom((selectedTab?.zoom ?? 1) + 0.1)
    }

    func zoomOut() {
        setZoom((selectedTab?.zoom ?? 1) - 0.1)
    }

    func resetZoom() {
        setZoom(1)
    }

    private func setZoom(_ value: Double) {
        guard let tab = selectedTab else { return }
        let rounded = (min(2.5, max(0.5, value)) * 10).rounded() / 10
        tab.zoom = rounded
        tab.webView.pageZoom = rounded
        saveSession()
    }

    func showCommandPalette() {
        guard let window else { return }
        let commands: [CommandItem] = [
            CommandItem(
                id: "new-tab",
                icon: "plus",
                label: "New Tab",
                description: "Open the start page in a new tab",
                shortcut: ["⌘T"]
            ) { [weak self] in
                self?.newTab(focusAddress: true)
            },
            CommandItem(
                id: "close-tab",
                icon: "xmark",
                label: "Close Tab",
                description: "Close the selected tab",
                shortcut: ["⌘W"]
            ) { [weak self] in
                self?.closeSelectedTab()
            },
            CommandItem(
                id: "reopen-tab",
                icon: "arrow.uturn.backward",
                label: "Reopen Closed Tab",
                description: "Bring back the last closed tab",
                shortcut: ["⇧⌘T"]
            ) { [weak self] in
                self?.reopenClosedTab()
            },
            CommandItem(
                id: "focus-address",
                icon: "character.cursor.ibeam",
                label: "Focus Address Bar",
                description: "Type a URL or search",
                shortcut: ["⌘L"]
            ) { [weak self] in
                self?.focusAddressBar()
            },
            CommandItem(
                id: "reload",
                icon: "arrow.clockwise",
                label: "Reload Page",
                description: "Reload the selected page",
                shortcut: ["⌘R"]
            ) { [weak self] in
                self?.reload()
            },
            CommandItem(
                id: "find",
                icon: "magnifyingglass",
                label: "Find in Page",
                description: "Search the current page",
                shortcut: ["⌘F"]
            ) { [weak self] in
                self?.showFindBar()
            },
            CommandItem(
                id: "bookmark",
                icon: "star",
                label: "Bookmark This Page",
                description: "Add or remove the page from bookmarks",
                shortcut: ["⌘D"]
            ) { [weak self] in
                self?.toggleBookmark()
            },
            CommandItem(
                id: "history",
                icon: "clock",
                label: "Show History",
                description: "Browse and search visited pages",
                shortcut: ["⌘Y"]
            ) { [weak self] in
                self?.showSidebar(section: .history)
            },
            CommandItem(
                id: "bookmarks",
                icon: "bookmark",
                label: "Show Bookmarks",
                description: "Open the bookmark list",
                shortcut: ["⌥⌘B"]
            ) { [weak self] in
                self?.showSidebar(section: .bookmarks)
            },
            CommandItem(
                id: "downloads",
                icon: "arrow.down.circle",
                label: "Show Downloads",
                description: "Open the download list",
                shortcut: ["⌥⌘L"]
            ) { [weak self] in
                self?.showSidebar(section: .downloads)
            },
            CommandItem(
                id: "settings",
                icon: "gearshape",
                label: "Settings…",
                description: "Search engine, homepage, theme",
                shortcut: ["⌘,"]
            ) { [weak self] in
                self?.showSettings()
            },
        ]
        palette.show(
            relativeTo: window,
            commands: commands,
            placeholder: "Search commands…",
            searchShortcut: ["⇧⌘P"]
        )
    }

    // MARK: - Automation

    func performAutomation(
        command: String,
        arguments: [String],
        tabIndex: Int?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        if let tabIndex {
            guard tabIndex > 0, tabs.indices.contains(tabIndex - 1) else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "No tab \(tabIndex). Use `tabs` to list them."
                )))
                return
            }
            selectTab(index: tabIndex - 1, focus: false)
        }

        switch command {
        case "goto", "navigate":
            guard let input = arguments.first else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Usage: soprano-web browser goto <url>"
                )))
                return
            }
            guard let url = BrowserAddressResolver.resolve(
                input,
                searchEngine: settingsStore.settings.searchEngine
            ) else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Invalid browser address: \(input)"
                )))
                return
            }
            guard let tab = selectedTab else {
                completion(.failure(BrowserAutomationError.unavailable("No tab is open.")))
                return
            }
            navigate(tab, to: url)
            completion(.success(url.absoluteString))

        case "back":
            goBack()
            completion(.success(selectedTab?.webView.url?.absoluteString ?? ""))

        case "forward":
            goForward()
            completion(.success(selectedTab?.webView.url?.absoluteString ?? ""))

        case "reload":
            reload()
            completion(.success(selectedTab?.webView.url?.absoluteString ?? ""))

        case "url", "get-url":
            if selectedTab?.isStartPage == true {
                completion(.success("about:start"))
            } else {
                completion(.success(
                    selectedTab?.failedURL ?? selectedTab?.webView.url?.absoluteString ?? ""
                ))
            }

        case "title":
            completion(.success(selectedTab?.webView.title ?? ""))

        case "tabs":
            let lines = tabs.enumerated().map { index, tab in
                let selected = tab.id == selectedTab?.id ? "*" : " "
                return "\(selected) \(index + 1)\t\(tab.displayTitle)\t\(tab.state.url ?? "about:start")"
            }
            completion(.success(lines.joined(separator: "\n")))

        case "new-tab":
            let url = arguments.first
            let tab = newTab(url: url)
            revealWindowIfNeeded()
            completion(.success(tab.webView.url?.absoluteString ?? "about:start"))

        case "select-tab":
            guard let value = arguments.first, let number = Int(value), number > 0,
                  tabs.indices.contains(number - 1)
            else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Usage: soprano-web browser select-tab <n>"
                )))
                return
            }
            selectTab(index: number - 1, focus: false)
            completion(.success("tab \(number)"))

        case "close-tab":
            let number = arguments.first.flatMap(Int.init) ?? (selectedIndex + 1)
            guard tabs.indices.contains(number - 1) else {
                completion(.failure(BrowserAutomationError.invalidArguments("No tab \(number).")))
                return
            }
            closeTab(id: tabs[number - 1].id)
            completion(.success("closed tab \(number)"))

        case "vimium":
            guard let tab = selectedTab else {
                completion(.failure(BrowserAutomationError.unavailable("No tab is open.")))
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
            guard let tab = selectedTab else {
                completion(.failure(BrowserAutomationError.unavailable("No tab is open.")))
                return
            }
            waitForLoad(tab, completion: completion)

        case "focus-address":
            focusAddressBar()
            completion(.success("focused address bar"))

        case "snapshot":
            evaluateString(
                BrowserAutomationScripts.snapshotScript(
                    interactiveOnly: arguments.contains("--interactive")
                ),
                completion: completion
            )

        case "eval":
            guard !arguments.isEmpty else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Usage: soprano-web browser eval <javascript>"
                )))
                return
            }
            evaluateJavaScript(arguments.joined(separator: " "), completion: completion)

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
                completion: completion
            )

        case "screenshot":
            guard let path = arguments.first else {
                completion(.failure(BrowserAutomationError.invalidArguments(
                    "Usage: soprano-web browser screenshot <path.png>"
                )))
                return
            }
            takeScreenshot(path: path, completion: completion)

        default:
            completion(.failure(BrowserAutomationError.invalidArguments(
                "Unsupported browser command: \(command)"
            )))
        }
    }

    private func evaluateJavaScript(
        _ script: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let webView = selectedTab?.webView else {
            completion(.failure(BrowserAutomationError.unavailable("No tab is open.")))
            return
        }
        webView.evaluateJavaScript(script) { value, error in
            if let error {
                completion(.failure(BrowserAutomationError.javascript(error.localizedDescription)))
                return
            }
            completion(.success(BrowserAutomationScripts.printableJavaScriptValue(value)))
        }
    }

    private func evaluateString(
        _ script: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let webView = selectedTab?.webView else {
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
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let webView = selectedTab?.webView else {
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
        path: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let webView = selectedTab?.webView else {
            completion(.failure(BrowserAutomationError.unavailable("No tab is open.")))
            return
        }
        webView.takeSnapshot(with: nil) { image, error in
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
}
