import AppKit
import WebKit

/// What the tab strip and the vertical rail render for one tab. Change the
/// tab, then call `metadataChanged(_:)` so the views get a fresh item.
struct BrowserTabItem: Equatable {
    let id: UUID
    var title: String
    /// Nil on the start page.
    var url: URL?
    var favicon: NSImage?
    var isLoading: Bool
    var isPlayingAudio: Bool
    var isMuted: Bool

    static func == (lhs: BrowserTabItem, rhs: BrowserTabItem) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.url == rhs.url
            && lhs.favicon === rhs.favicon
            && lhs.isLoading == rhs.isLoading
            && lhs.isPlayingAudio == rhs.isPlayingAudio
            && lhs.isMuted == rhs.isMuted
    }
}

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
    /// Set while the tab shows the certificate interstitial.
    var certificateInterstitial: BrowserCertificateInterstitial?
    var favicon: NSImage?
    var isPlayingAudio = false
    var isMuted = false
    /// Audio reports and media frames; see `BrowserTabMedia`.
    let media = BrowserTabMedia()
    var vimium: VimiumController?
    var lifecycle = BrowserTabLifecycle()
    var observations: [NSKeyValueObservation] = []
    var links = BrowserTabLinks()
    /// The next load to finish started from the address bar (a typed visit).
    var typedNavigationPending = false
    /// `wait-for-load` requests on this tab; they follow it between windows.
    var loadWaiters: [UUID: BrowserLoadWaiter] = [:]

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

    /// A restored tab that has not loaded yet: its web view is empty and
    /// `lifecycle.pendingRestore` holds the saved address and history.
    var isRestorePending: Bool {
        lifecycle.pendingRestore != nil
    }

    var state: BrowserTabState {
        BrowserTabState.snapshot(
            pending: lifecycle.pendingRestore,
            isStartPage: isStartPage,
            failedURL: failedURL,
            currentURL: webView.url?.absoluteString,
            title: title,
            zoom: zoom,
            interactionState: { webView.interactionState as? Data }
        )
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if let host = (webView.url ?? lifecycle.pendingRestore?.url.flatMap(URL.init(string:)))?.host,
           !host.isEmpty
        {
            return host
        }
        return isStartPage ? "New Tab" : "Untitled"
    }

    var item: BrowserTabItem {
        BrowserTabItem(
            id: id,
            title: displayTitle,
            url: isStartPage
                ? nil
                : (failedURL.flatMap(URL.init(string:))
                    ?? webView.url
                    ?? lifecycle.pendingRestore?.url.flatMap(URL.init(string:))),
            favicon: favicon,
            isLoading: webView.isLoading,
            isPlayingAudio: isPlayingAudio,
            isMuted: isMuted
        )
    }

    func invalidateObservations() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
    }
}

/// One `wait-for-load` request: its timeout and who to answer.
struct BrowserLoadWaiter {
    let timer: Timer
    let completion: (Result<String, Error>) -> Void
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
