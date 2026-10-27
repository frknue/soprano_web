import Foundation
import WebKit

/// Serves the generated start page under a real URL so it stays a normal
/// back/forward entry and never records `about:blank` in history. `html`
/// gets the web view asking, so each tab gets its own Space's page.
@MainActor
final class BrowserStartPageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "soprano-web"
    static let url = URL(string: "\(scheme)://start")!

    private let html: (WKWebView) -> String

    init(html: @escaping (WKWebView) -> String) {
        self.html = html
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let data = Data(html(webView).utf8)
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
