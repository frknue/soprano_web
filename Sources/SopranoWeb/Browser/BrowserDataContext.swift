import AppKit
import WebKit

/// Whether a window's browsing is kept (normal) or lives only as long as the
/// window (private). Each property is one place the two differ; everything
/// a private window would write to disk asks here first.
enum BrowserWindowKind: String, Sendable {
    case normal
    case `private`

    var isPrivate: Bool { self == .private }

    /// Visits (and their typed flags) go into History.
    var recordsHistory: Bool { !isPrivate }
    /// The window is saved in `session.json` and restored at launch.
    var savesSession: Bool { !isPrivate }
    /// Closed tabs and the closed window go onto the app-wide Recently
    /// Closed stack (saved with the session). A private window keeps its
    /// closed tabs on its own in-memory stack, and closing it is final.
    var usesAppRecentlyClosed: Bool { !isPrivate }
    /// New site decisions (camera, microphone, notifications, pop-ups,
    /// external apps) are saved; a private window keeps them in memory.
    var savesSiteDecisions: Bool { !isPrivate }
    /// Favicons are cached as files; a private window keeps them in memory.
    var writesFavicons: Bool { !isPrivate }
    /// Download records (and resume data) are saved; a private window's are
    /// listed while it is open and kept in memory.
    var savesDownloadRecords: Bool { !isPrivate }
    /// Address-bar suggestions and the start page read History.
    var suggestsHistory: Bool { !isPrivate }
    /// The `browser` CLI lists and targets the window, and links from other
    /// apps may open in it.
    var acceptsOutsideRequests: Bool { !isPrivate }

    /// The window title for a page titled `title`.
    func windowTitle(_ title: String) -> String {
        isPrivate ? "Private — \(title)" : title
    }
}

/// The data one window's tabs read and write: the WebKit data store, site
/// decisions, favicons and connection decisions (certificate exceptions,
/// client certificates). Windows share a context exactly when tabs may move
/// between them: every normal window uses the manager's `defaultContext`; a
/// private window has its own, shared with its pop-up windows and the windows
/// its tabs moved into, and released with the last of them. App-wide stores
/// (history, bookmarks, downloads, settings) stay on the manager and consult
/// `kind` before writing.
///
/// The profiles slice adds one normal context per profile here (its own
/// `WKWebsiteDataStore(forIdentifier:)`, site decisions and history).
@MainActor
final class BrowserDataContext {
    let id = UUID()
    let kind: BrowserWindowKind
    let websiteDataStore: WKWebsiteDataStore
    let sitePermissions: BrowserSitePermissionStore
    let faviconStore: BrowserFaviconStore
    let connectionSecurity: BrowserConnectionSecurity

    init(
        kind: BrowserWindowKind,
        websiteDataStore: WKWebsiteDataStore,
        sitePermissions: BrowserSitePermissionStore,
        faviconStore: BrowserFaviconStore,
        connectionSecurity: BrowserConnectionSecurity
    ) {
        self.kind = kind
        self.websiteDataStore = websiteDataStore
        self.sitePermissions = sitePermissions
        self.faviconStore = faviconStore
        self.connectionSecurity = connectionSecurity
    }

    /// A private window's context: a fresh non-persistent data store, site
    /// decisions and favicons that read `base`'s saved ones and keep new ones
    /// in memory, and its own certificate exceptions and client-certificate
    /// choices.
    static func makePrivate(over base: BrowserDataContext) -> BrowserDataContext {
        BrowserDataContext(
            kind: .private,
            websiteDataStore: .nonPersistent(),
            sitePermissions: BrowserSitePermissionStore(overlaying: base.sitePermissions),
            faviconStore: BrowserFaviconStore(inMemoryOver: base.faviconStore),
            connectionSecurity: BrowserConnectionSecurity()
        )
    }

    /// The id a private context tags its download records with; nil for a
    /// normal context, whose records are saved.
    var downloadContextID: UUID? {
        kind.savesDownloadRecords ? nil : id
    }
}
