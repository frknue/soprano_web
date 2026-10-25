import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Downloads

    /// The app's downloads; this window only starts them and shows the list.
    var downloadManager: BrowserDownloadManager {
        manager.downloadManager
    }

    /// Starts a download of `request` in this window.
    func startDownload(_ request: URLRequest) {
        downloadManager.start(request, in: downloadWebView(), privateContextID: dataContext.downloadContextID)
    }

    /// Takes over a download a page in this window started.
    func adoptDownload(_ download: WKDownload) {
        downloadManager.adopt(download, from: window, privateContextID: dataContext.downloadContextID)
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

    /// Downloads need a web view of this window's data store; any tab works.
    private func downloadWebView() -> WKWebView {
        if let tab = selectedTab ?? tabs.first {
            return tab.webView
        }
        return newTab(url: nil, focusAddress: false).webView
    }
}
