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
    /// The tab sleeps: its page was released and reloads when selected.
    var isAsleep = false
    /// The live tab of a pin or favorite: the strip shows it compact (its
    /// icon only), before the Today tabs.
    var isLinked = false
    /// A linked tab whose page left its pin's address: the "/" mark.
    var isAway = false

    static func == (lhs: BrowserTabItem, rhs: BrowserTabItem) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.url == rhs.url
            && lhs.favicon === rhs.favicon
            && lhs.isLoading == rhs.isLoading
            && lhs.isPlayingAudio == rhs.isPlayingAudio
            && lhs.isMuted == rhs.isMuted
            && lhs.isAsleep == rhs.isAsleep
            && lhs.isLinked == rhs.isLinked
            && lhs.isAway == rhs.isAway
    }
}

/// Where a live tab comes from: a Today tab (opened from a link, ⌘T, a
/// moved tab), or the live tab of a pin of its Space or a favorite of its
/// profile. The session saves it as `pinID` / `favoriteID`.
enum BrowserTabOrigin: Equatable, Sendable {
    case today
    case pinned(UUID)
    case favorite(UUID)

    var pinID: UUID? {
        if case let .pinned(id) = self { return id }
        return nil
    }

    var favoriteID: UUID? {
        if case let .favorite(id) = self { return id }
        return nil
    }
}

@MainActor
final class BrowserTab {
    let id: UUID
    /// What the tab reads and writes for its whole life: its Space's
    /// profile (a private or pop-up window's tab: the window's context).
    /// Its web views are made from it, and every WebKit callback and
    /// per-tab operation (History, site decisions, favicons, connection
    /// security, downloads) uses it, never the window's current Space's.
    let dataContext: BrowserDataContext
    /// The Space the tab belongs to in its window; nil in a private or
    /// pop-up window. Only the window holding the tab changes it (before
    /// `attachTab`), since its `visibleTabs` follow it.
    var spaceID: UUID?
    var origin: BrowserTabOrigin
    /// Where the last load of its pin (or favorite) started by the window
    /// landed after redirects; the tab is not "away" there.
    var linkLanding: String?
    /// That load is under way: its first main-frame commit sets
    /// `linkLanding`.
    var awaitsLinkLanding = false
    /// The tab's page. Sleeping replaces it with a fresh, empty one
    /// (`BrowserWindowController.replaceWebView`); everything that binds a
    /// web view to a window follows the swap.
    private(set) var webView: BrowserWebView
    var title: String
    /// The zoom applied to the current page: its site's zoom, or the default
    /// page zoom (a page without a site keeps ⌘+/⌘- until the next page).
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
    /// How the main-frame load in flight was started (its policy decision).
    var pendingVisitKind: BrowserVisitKind?
    /// URL changes without a page load that may become History visits.
    var sameDocumentVisits = BrowserSameDocumentVisits()
    var sameDocumentTimer: Timer?
    /// `wait-for-load` requests on this tab; they follow it between windows.
    var loadWaiters: [UUID: BrowserLoadWaiter] = [:]

    init(
        id: UUID = UUID(),
        webView: BrowserWebView,
        dataContext: BrowserDataContext,
        spaceID: UUID? = nil,
        origin: BrowserTabOrigin = .today,
        title: String = "New Tab",
        zoom: Double = 1,
        isStartPage: Bool = true,
        suppressNextHistoryRecord: Bool = false
    ) {
        self.id = id
        self.webView = webView
        self.dataContext = dataContext
        self.spaceID = spaceID
        self.origin = origin
        self.title = title
        self.zoom = zoom
        self.isStartPage = isStartPage
        self.suppressNextHistoryRecord = suppressNextHistoryRecord
    }

    /// A tab that is not loaded: restored and never selected, or asleep.
    /// Its web view is empty and `lifecycle.pendingRestore` holds the saved
    /// address and history.
    var isRestorePending: Bool {
        lifecycle.pendingRestore != nil
    }

    var isAsleep: Bool {
        lifecycle.sleep != nil
    }

    /// Swaps in `webView` for the current one; the caller unbinds the old
    /// one first and binds the new one after.
    func replaceWebView(with webView: BrowserWebView) {
        self.webView = webView
    }

    var state: BrowserTabState {
        var state = BrowserTabState.snapshot(
            pending: lifecycle.pendingRestore,
            isStartPage: isStartPage,
            failedURL: failedURL,
            currentURL: webView.url?.absoluteString,
            title: title,
            interactionState: { webView.interactionState as? Data }
        )
        state.spaceID = spaceID
        state.origin = origin
        state.linkLanding = origin == .today ? nil : linkLanding
        return state
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
            isMuted: isMuted,
            isAsleep: isAsleep
        )
    }

    func invalidateObservations() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        sameDocumentTimer?.invalidate()
        sameDocumentTimer = nil
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
