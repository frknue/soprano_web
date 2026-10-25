import AppKit
import WebKit

extension BrowserWindowController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        createLinkWebView(
            from: webView,
            configuration: configuration,
            navigationAction: navigationAction,
            windowFeatures: BrowserPopupFeatures(windowFeatures)
        )
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        let ended = promptBegan(for: webView)
        defer { ended() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            presentDialog(
                title: frame.request.url?.host ?? "Page",
                message: message,
                confirm: nil
            ) { _ in
                continuation.resume()
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        let ended = promptBegan(for: webView)
        defer { ended() }
        return await withCheckedContinuation { continuation in
            presentDialog(
                title: frame.request.url?.host ?? "Page",
                message: message,
                confirm: "OK"
            ) { confirmed in
                continuation.resume(returning: confirmed)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        guard let window else { return nil }
        let ended = promptBegan(for: webView)
        defer { ended() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let alert = NSAlert()
            alert.messageText = frame.request.url?.host ?? "Page"
            alert.informativeText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.stringValue = defaultText ?? ""
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { response in
                continuation.resume(
                    returning: response == .alertFirstButtonReturn ? field.stringValue : nil
                )
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        guard let window else { return nil }
        let ended = promptBegan(for: webView)
        defer { ended() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[URL]?, Never>) in
            let panel = NSOpenPanel()
            panel.canChooseFiles = !parameters.allowsDirectories
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.urls : nil)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        let ended = promptBegan(for: webView)
        defer { ended() }
        return await decideMediaCapture(origin: origin, type: type)
    }

    private func presentDialog(
        title: String,
        message: String,
        confirm: String?,
        completion: @escaping (Bool) -> Void
    ) {
        guard let window else {
            completion(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm ?? "OK")
        if confirm != nil {
            alert.addButton(withTitle: "Cancel")
        }
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }
}
