import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Downloads

    /// The app's downloads; this window only starts them and shows the list.
    var downloadManager: BrowserDownloadManager {
        manager.downloadManager
    }

    /// Starts a download of `request` in the selected tab's data store.
    func startDownload(_ request: URLRequest) {
        let webView = downloadWebView()
        let context = tab(for: webView)?.dataContext ?? dataContext
        downloadManager.start(request, in: webView, privateContextID: context.downloadContextID)
    }

    /// Takes over a download a page in this window started (its tab's
    /// context decides whether the record is kept).
    func adoptDownload(_ download: WKDownload) {
        let context = download.webView.flatMap(tab(for:))?.dataContext ?? dataContext
        downloadManager.adopt(download, from: window, privateContextID: context.downloadContextID)
    }

    func cancelDownload(id: UUID) {
        downloadManager.cancel(id: id)
    }

    func resumeDownload(id: UUID) {
        downloadManager.resume(id: id, in: downloadWebView())
    }

    func retryDownload(id: UUID) {
        downloadManager.retry(id: id, in: downloadWebView())
    }

    /// Downloads need a web view of the current Space's data store; any of
    /// its tabs works.
    private func downloadWebView() -> WKWebView {
        if let tab = selectedTab ?? visibleTabs.first {
            return tab.webView
        }
        return newTab(url: nil, focusAddress: false).webView
    }
}
