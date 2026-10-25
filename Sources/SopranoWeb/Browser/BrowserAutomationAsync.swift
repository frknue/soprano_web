import AppKit
import WebKit

/// The JavaScript behind `browser eval`. Run through `callAsyncJavaScript`,
/// so the code may `await` and a returned Promise is awaited.
enum BrowserAutomationEval {
    /// Parses the source as an expression without running it: the arrow
    /// function is never called. Success means `body(asExpression: true)`.
    static func expressionCheck(_ source: String) -> String {
        "return;\n(async () => (\n\(expression(source))\n));"
    }

    /// An expression needs no `return` (`document.title`); anything else runs
    /// as an async function body. The result comes back as JSON text.
    static func body(_ source: String, asExpression: Bool) -> String {
        let function = asExpression
            ? "async () => (\n\(expression(source))\n)"
            : "async () => {\n\(source)\n}"
        return """
        const __sopranoEvalResult = await (\(function))();
        return __sopranoEvalResult === undefined
          ? "null"
          : (JSON.stringify(__sopranoEvalResult, null, 2) ?? "null");
        """
    }

    /// A trailing `;` is fine on the command line but not inside `( … )`.
    static func expression(_ source: String) -> String {
        var trimmed = Substring(source)
        while let last = trimmed.last, last == ";" || last.isWhitespace {
            trimmed.removeLast()
        }
        return String(trimmed)
    }
}

/// What `browser wait-for` waits for.
enum AutomationWaitCondition: Equatable {
    case selector(String)
    case url(String)
    case text(String)

    init?(kind: String, value: String) {
        switch kind {
        case "selector": self = .selector(value)
        case "url": self = .url(value)
        case "text": self = .text(value)
        default: return nil
        }
    }

    var summary: String {
        switch self {
        case .selector(let value): "selector \(value)"
        case .url(let value): "URL containing \(value)"
        case .text(let value): "text \(value)"
        }
    }

    /// The page check; nil for conditions checked natively. Runs in the
    /// client world, so page scripts cannot fake the answer. 1 met, 0 not yet,
    /// -1 invalid selector.
    var script: String? {
        switch self {
        case .selector(let value):
            """
            (() => {
              try { return document.querySelector(\(BrowserAutomationScripts.literal(value))) ? 1 : 0; }
              catch (_) { return -1; }
            })()
            """
        case .text(let value):
            """
            (() => {
              const body = document.body;
              return body && body.innerText.includes(\(BrowserAutomationScripts.literal(value))) ? 1 : 0;
            })()
            """
        case .url:
            nil
        }
    }
}

extension BrowserWindowController {
    // MARK: - Automation waits

    private enum WaitCheck {
        case met
        case pending
        case failed(String)
    }

    private static let waitPollInterval: UInt64 = 100_000_000

    /// Polls from the app rather than the page, so the wait survives
    /// navigations and works in background tabs. Succeeds with the tab's URL.
    func waitFor(
        _ condition: AutomationWaitCondition,
        in tab: BrowserTab,
        timeout: TimeInterval,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        Task { @MainActor [weak self] in
            while true {
                guard let self, self.tabs.contains(where: { $0.id == tab.id }) else {
                    completion(.failure(BrowserAutomationError.unavailable("The tab was closed.")))
                    return
                }
                switch await self.check(condition, in: tab) {
                case .met:
                    completion(.success(tab.webView.url?.absoluteString ?? ""))
                    return
                case .failed(let message):
                    completion(.failure(BrowserAutomationError.invalidArguments(message)))
                    return
                case .pending:
                    break
                }
                guard Date() < deadline else {
                    completion(.failure(BrowserAutomationError.unavailable(
                        "Timed out after \(BrowserCommandRequest.seconds(timeout)) s waiting for \(condition.summary)."
                    )))
                    return
                }
                try? await Task.sleep(nanoseconds: Self.waitPollInterval)
            }
        }
    }

    private func check(_ condition: AutomationWaitCondition, in tab: BrowserTab) async -> WaitCheck {
        if case .url(let substring) = condition {
            return tab.webView.url?.absoluteString.contains(substring) == true ? .met : .pending
        }
        guard let script = condition.script else { return .pending }
        let webView = tab.webView
        let value: Int = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                // A page between navigations has no document to ask yet.
                let value = (try? result.get()) as? NSNumber
                continuation.resume(returning: value?.intValue ?? 0)
            }
        }
        switch (value, condition) {
        case (1, _): return .met
        case (-1, .selector(let selector)): return .failed("Invalid CSS selector: \(selector)")
        default: return .pending
        }
    }
}
