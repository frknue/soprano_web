import AppKit
import WebKit

/// An extension's action popup in a popover of our own, hanging from its
/// toolbar button. WebKit's `popupPopover` is not used: with it some
/// extensions' popup messages never reach their worker (Search's finding),
/// so the popup's page loads again in a web view made from the
/// extension's configuration, sized to its content (25…800 × 25…600 pt,
/// Chrome's bounds); `window.close()` closes it.
@MainActor
final class BrowserExtensionPopup: NSObject, NSPopoverDelegate, WKUIDelegate, WKNavigationDelegate {
    static let minimumSize = NSSize(width: 25, height: 25)
    static let maximumSize = NSSize(width: 800, height: 600)
    static let initialSize = NSSize(width: 320, height: 200)

    let extensionID: String
    let url: URL
    let popover = NSPopover()
    let webView: WKWebView
    var onClose: (() -> Void)?
    /// Opens a link the popup sends to a new tab (`target=_blank`).
    var onOpenTab: ((URL) -> Void)?

    init(extensionID: String, url: URL, configuration: WKWebViewConfiguration, theme: AppTheme) {
        self.extensionID = extensionID
        self.url = url
        webView = WKWebView(frame: NSRect(origin: .zero, size: Self.initialSize), configuration: configuration)
        super.init()
        webView.isInspectable = true
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = theme.colors.bgRaised
        let content = NSViewController()
        content.view = webView
        popover.contentViewController = content
        popover.contentSize = Self.initialSize
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = theme.appearance.nsAppearance
        popover.delegate = self
        webView.load(URLRequest(url: url))
    }

    func show(relativeTo view: NSView) {
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func close() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        webView.stopLoading()
        onClose?()
    }

    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            onOpenTab?(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        fitToContent()
        // Popups often build their content after load.
        for delay in [0.25, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.fitToContent()
            }
        }
    }

    /// Sizes the popover to the page's content within Chrome's bounds.
    func fitToContent() {
        let script = """
        (() => { const d = document.documentElement, b = document.body;
          return [Math.max(d.scrollWidth, b ? b.scrollWidth : 0), Math.max(d.scrollHeight, b ? b.scrollHeight : 0)]; })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let values = result as? [NSNumber], values.count == 2 else { return }
                let size = Self.fittedSize(width: CGFloat(values[0].doubleValue), height: CGFloat(values[1].doubleValue))
                if self.popover.contentSize != size {
                    self.popover.contentSize = size
                }
            }
        }
    }

    static func fittedSize(width: CGFloat, height: CGFloat) -> NSSize {
        NSSize(
            width: min(max(ceil(width), minimumSize.width), maximumSize.width),
            height: min(max(ceil(height), minimumSize.height), maximumSize.height)
        )
    }
}

extension BrowserExtensions {
    /// Shows `action`'s popup from its button in the window of the action's
    /// tab (else the key or most recent window). Nil when shown.
    func presentPopup(for action: WKWebExtension.Action, context: WKWebExtensionContext) -> Error? {
        guard let id = id(of: context) else { return Self.refusal("The extension isn't loaded.") }
        guard let url = action.popupWebView?.url, let configuration = context.webViewConfiguration else {
            action.closePopup()
            return Self.refusal("The extension has no popup.")
        }
        action.closePopup()
        closePopup()
        let window = (action.associatedTab as? BrowserExtensionTab).flatMap { manager?.tab(id: $0.tabID)?.window }
            ?? manager?.keyController
            ?? manager?.activeController
        guard let window, let anchor = window.toolbar.extensionButton(id: id) ?? Optional(window.toolbar.addressAnchorView),
              anchor.window != nil
        else { return Self.refusal("No window shows the extension's button.") }
        let popup = BrowserExtensionPopup(extensionID: id, url: url, configuration: configuration, theme: window.theme)
        popup.onClose = { [weak self, weak popup] in
            guard let self, let popup, self.popup === popup else { return }
            self.popup = nil
        }
        popup.onOpenTab = { [weak self] url in
            guard let self else { return }
            self.openExtensionPage(url, for: context)
        }
        self.popup = popup
        popup.show(relativeTo: anchor)
        return nil
    }

    func closePopup() {
        popup?.close()
        popup = nil
    }
}
