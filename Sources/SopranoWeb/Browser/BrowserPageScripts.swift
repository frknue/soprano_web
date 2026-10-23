import WebKit

/// A user script installed in every tab. Scripts post
/// `window.webkit.messageHandlers.sopranoWeb.postMessage({type: "<name>", …})`;
/// `BrowserWindowController.handlePageMessage` accepts each type only from
/// the world it was written for.
struct BrowserPageScript: Sendable {
    enum World: CaseIterable, Sendable {
        /// The page's own JavaScript world. Messages from it are untrusted
        /// page input; use it only to patch page globals.
        case page
        /// `BrowserPageScripts.isolatedWorld`, invisible to page scripts.
        case isolated

        @MainActor
        var contentWorld: WKContentWorld {
            switch self {
            case .page: .page
            case .isolated: BrowserPageScripts.isolatedWorld
            }
        }
    }

    let source: String
    let injectionTime: WKUserScriptInjectionTime
    let forMainFrameOnly: Bool
    let world: World
}

@MainActor
enum BrowserPageScripts {
    /// Every script `makeTab` installs, in order.
    static let all: [BrowserPageScript] = [
        BrowserPermissionScripts.mediaReporter,
        BrowserPermissionScripts.mediaMute,
        BrowserPermissionScripts.notifications,
    ]

    /// The message handler name, registered once per world.
    static let messageName = "sopranoWeb"

    static let isolatedWorld = WKContentWorld.world(name: "SopranoWeb")
}
