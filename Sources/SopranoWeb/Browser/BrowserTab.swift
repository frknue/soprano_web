import AppKit
import WebKit

@MainActor
final class BrowserTab {
    let id: UUID
    let webView: BrowserWebView
    var title: String
    var zoom: Double
    var isStartPage: Bool
    /// Restored tabs load without adding a fresh history visit.
    var suppressNextHistoryRecord: Bool
    var errorMessage: String?
    var failedURL: String?
    var pendingURL: String?
    var isShowingErrorPage = false
    var vimium: VimiumController?
    var observations: [NSKeyValueObservation] = []

    init(
        id: UUID = UUID(),
        webView: BrowserWebView,
        title: String = "New Tab",
        zoom: Double = 1,
        isStartPage: Bool = true,
        suppressNextHistoryRecord: Bool = false
    ) {
        self.id = id
        self.webView = webView
        self.title = title
        self.zoom = zoom
        self.isStartPage = isStartPage
        self.suppressNextHistoryRecord = suppressNextHistoryRecord
    }

    var state: BrowserTabState {
        BrowserTabState(
            url: isStartPage ? nil : (failedURL ?? webView.url?.absoluteString),
            title: title,
            zoom: zoom
        )
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if let host = webView.url?.host, !host.isEmpty {
            return host
        }
        return isStartPage ? "New Tab" : "Untitled"
    }

    func invalidateObservations() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
    }
}

/// The main window lets the snapshot harness keep it off-screen without AppKit
/// pulling it back onto a display.
final class BrowserWindow: NSWindow {
    var allowsOffscreenFrame = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffscreenFrame ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}
