import Foundation
import WebKit

/// A WebSocket an extension's worker opens, made by the app
/// (`URLSessionWebSocketTask`): WebKit's own never returns from its
/// constructor in an extension worker and freezes the extension. The shim's
/// `WebSocket` (`BrowserExtensionShimScript`, stand-in `webSocket`) talks to
/// it over a `soprano.socket` native port:
/// - worker → app: `{ open, protocols, userAgent }` (repeated until any
///   answer: a worker's first posts on a new port can be lost),
///   `{ send }`, `{ sendBinary }` (base64), `{ close, reason }`;
/// - app → worker: `{ opened }` (the protocol), `{ text }`, `{ binary }`,
///   `{ failed }`, `{ closed, reason, clean }`.
/// Only `ws:` and `wss:` addresses open. The request carries the
/// extension's origin (`chrome-extension://<id>`) and its user agent, as
/// Chrome's socket would.
@MainActor
final class BrowserExtensionSocket: NSObject, URLSessionWebSocketDelegate {
    enum Request: Equatable {
        case open(url: URL, protocols: [String], userAgent: String?)
        case send(String)
        case sendBinary(Data)
        case close(code: Int, reason: String)
    }

    /// What the worker posted, or nil for anything else.
    nonisolated static func request(from message: Any?) -> Request? {
        guard let message = message as? [String: Any] else { return nil }
        if let address = message["open"] as? String {
            guard let url = socketURL(address) else { return nil }
            let protocols = (message["protocols"] as? [Any] ?? []).compactMap { $0 as? String }
            return .open(url: url, protocols: protocols, userAgent: message["userAgent"] as? String)
        }
        if let text = message["send"] as? String { return .send(text) }
        if let encoded = message["sendBinary"] as? String {
            return Data(base64Encoded: encoded).map { .sendBinary($0) }
        }
        if let code = (message["close"] as? NSNumber)?.intValue {
            return .close(code: code, reason: message["reason"] as? String ?? "")
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

    let extensionID: String
    private let port: WKWebExtension.MessagePort
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var finished = false
    /// The close the worker asked for, reported back when the task ends.
    private var requestedClose: (code: Int, reason: String)?
    /// Called once the socket is done (closed, failed or the port gone).
    var onFinish: (() -> Void)?

    init(port: WKWebExtension.MessagePort, extensionID: String) {
        self.port = port
        self.extensionID = extensionID
        super.init()
        port.messageHandler = { [weak self] message, _ in
            self?.handle(message)
        }
        port.disconnectHandler = { [weak self] _ in
            self?.finish(reportingTo: false)
        }
    }

    private func handle(_ message: Any?) {
        guard !finished, let request = Self.request(from: message) else { return }
        switch request {
        case let .open(url, protocols, userAgent):
            // The worker says it again until answered; the first one opens.
            guard task == nil else { return }
            var urlRequest = URLRequest(url: url)
            urlRequest.setValue("\(BrowserExtensions.scheme)://\(extensionID)", forHTTPHeaderField: "Origin")
            if let userAgent, !userAgent.isEmpty {
                urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
            if !protocols.isEmpty {
                urlRequest.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
            }
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
            let task = session.webSocketTask(with: urlRequest)
            self.session = session
            self.task = task
            task.resume()
            receive()
        case let .send(text):
            task?.send(.string(text)) { _ in }
        case let .sendBinary(data):
            task?.send(.data(data)) { _ in }
        case let .close(code, reason):
            requestedClose = (code, reason)
            task?.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: Data(reason.utf8))
        }
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
}
