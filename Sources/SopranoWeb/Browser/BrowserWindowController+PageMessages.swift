import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Page messages

    func receivePageMessage(_ message: WKScriptMessage, world: BrowserPageScript.World) {
        guard let webView = message.webView,
              let tab = tab(for: webView),
              let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else { return }
        handlePageMessage(type: type, body: body, tab: tab, frame: message.frameInfo, world: world)
    }

    /// Routes one `sopranoWeb` message. Each case names the type and the one
    /// world it is accepted from, so the same type from another world (page
    /// input pretending to be ours) falls through and is dropped.
    func handlePageMessage(
        type: String,
        body: [String: Any],
        tab: BrowserTab,
        frame: WKFrameInfo,
        world: BrowserPageScript.World
    ) {
        switch (type, world) {
        case ("popupBlocked", .page):
            receivePopupBlocked(body: body, tab: tab)
        case (BrowserCertificateInterstitialPage.messageType, .page):
            handleCertificateInterstitialMessage(body: body, tab: tab, frame: frame)
        case ("favicons", .isolated):
            receiveFavicons(body, tab: tab, frame: frame)
        case ("linkHover", .isolated):
            receiveLinkHover(body, tab: tab, frame: frame)
        default:
            return
        }
    }
}

/// Receives `sopranoWeb` messages from one content world. The user content
/// controller retains the handler; the controller back-reference is weak.
@MainActor
final class BrowserPageMessageHandler: NSObject, WKScriptMessageHandler {
    weak var controller: BrowserWindowController?
    let world: BrowserPageScript.World

    init(controller: BrowserWindowController, world: BrowserPageScript.World) {
        self.controller = controller
        self.world = world
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == BrowserPageScripts.messageName else { return }
        MainActor.assumeIsolated {
            controller?.receivePageMessage(message, world: world)
        }
    }
}
