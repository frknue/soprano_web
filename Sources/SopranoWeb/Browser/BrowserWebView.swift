import AppKit
import WebKit

/// A WKWebView that lets Vimium's normal mode consume a key before the page
/// sees it. Returning false from `keyHandler` passes the event through.
final class BrowserWebView: WKWebView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    /// Feeds normal-mode keys through the real keyDown bridge for the CLI
    /// verification command. Not used by user input.
    func sendKeysForTesting(_ keys: String) {
        for character in keys {
            let value = String(character)
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: value,
                charactersIgnoringModifiers: value,
                isARepeat: false,
                keyCode: 0
            ) else { continue }
            keyDown(with: event)
        }
    }
}

/// Receives focus changes from one tab's page. The handler is retained by the
/// web view's user content controller; the controller back-reference is weak.
@MainActor
final class VimiumFocusHandler: NSObject, WKScriptMessageHandler {
    weak var controller: BrowserWindowController?
    let tabID: UUID

    init(controller: BrowserWindowController, tabID: UUID) {
        self.controller = controller
        self.tabID = tabID
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == VimiumPageScripts.focusMessageName else { return }
        let editable: Bool
        if let value = message.body as? Bool {
            editable = value
        } else if let value = message.body as? NSNumber {
            editable = value.boolValue
        } else {
            return
        }
        MainActor.assumeIsolated {
            controller?.vimiumFocusChanged(tabID: tabID, editable: editable)
        }
    }
}
