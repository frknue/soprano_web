import Foundation
import WebKit

/// Serves the app's own pages under real URLs, so they stay normal
/// back/forward entries and never record `about:blank` in history: the
/// start page (`soprano-web://start`) and Settings
/// (`soprano-web://settings`, `BrowserSettingsWebPage`). `html` gets the
/// web view asking and the address, so each tab gets its own Space's page.
@MainActor
final class BrowserStartPageSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "soprano-web"
    nonisolated static let url = URL(string: "\(scheme)://start")!

    private let html: (WKWebView, URL) -> String

    init(html: @escaping (WKWebView, URL) -> String) {
        self.html = html
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let data = Data(html(webView, url).utf8)
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
