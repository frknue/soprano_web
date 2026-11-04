import AppKit
import WebKit

/// WebKit's own Web Inspector inside the app (F12, "Inspect Element").
/// Public API only makes a page inspectable from Safari ▸ Develop
/// (`isInspectable`); showing the inspector in-app needs WebKit's private
/// `WKPreferences._developerExtrasEnabled` and `WKWebView._inspector`
/// (`_WKInspector`). Every call checks the selector first, so a macOS that
/// renames them hides the feature instead of crashing.
@MainActor
enum BrowserWebInspector {
    private static let setDeveloperExtras = NSSelectorFromString("_setDeveloperExtrasEnabled:")
    private static let inspectorSelector = NSSelectorFromString("_inspector")
    private static let isVisibleSelector = NSSelectorFromString("isVisible")
    private static let showSelector = NSSelectorFromString("show")
    private static let closeSelector = NSSelectorFromString("close")
    private static let inspectorWebViewSelector = NSSelectorFromString("inspectorWebView")
    private static let detachSelector = NSSelectorFromString("detach")
    private static let attachSelector = NSSelectorFromString("attach")

    private typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
    private typealias Action = @convention(c) (AnyObject, Selector) -> Void

    /// Adds "Inspect Element" to the page's context menu and lets the
    /// inspector open for web views made with `preferences`.
    static func enableDeveloperExtras(_ preferences: WKPreferences) {
        guard preferences.responds(to: setDeveloperExtras) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: setDeveloperExtras), to: Setter.self)(
            preferences, setDeveloperExtras, true
        )
    }

    private static func object(_ selector: Selector, of target: NSObject) -> NSObject? {
        guard target.responds(to: selector) else { return nil }
        return unsafeBitCast(target.method(for: selector), to: ObjectGetter.self)(target, selector)?
            .takeUnretainedValue() as? NSObject
    }

    /// The web view's `_WKInspector`, when this WebKit has one with the
    /// methods used here.
    private static func inspector(of webView: WKWebView) -> NSObject? {
        guard let inspector = object(inspectorSelector, of: webView),
              [isVisibleSelector, showSelector, closeSelector].allSatisfy(inspector.responds(to:))
        else { return nil }
        return inspector
    }

    static func isAvailable(for webView: WKWebView) -> Bool {
        inspector(of: webView) != nil
    }

    static func isVisible(for webView: WKWebView) -> Bool {
        guard let inspector = inspector(of: webView) else { return false }
        return unsafeBitCast(inspector.method(for: isVisibleSelector), to: BoolGetter.self)(
            inspector, isVisibleSelector
        )
    }

    /// Shows or closes `webView`'s inspector. False when WebKit has none.
    @discardableResult
    static func setVisible(_ visible: Bool, for webView: WKWebView) -> Bool {
        guard let inspector = inspector(of: webView) else { return false }
        let selector = visible ? showSelector : closeSelector
        unsafeBitCast(inspector.method(for: selector), to: Action.self)(inspector, selector)
        return true
    }

    /// Moves a docked inspector into its own window.
    static func detach(_ webView: WKWebView) {
        perform(detachSelector, on: webView)
    }

    /// Docks an inspector that has its own window beside the page.
    static func attach(_ webView: WKWebView) {
        perform(attachSelector, on: webView)
    }

    private static func perform(_ selector: Selector, on webView: WKWebView) {
        guard let inspector = inspector(of: webView), inspector.responds(to: selector) else { return }
        unsafeBitCast(inspector.method(for: selector), to: Action.self)(inspector, selector)
    }

    /// The inspector's own web view (docked or in its window); nil while
    /// it is closed.
    private static func inspectorView(of webView: WKWebView) -> NSView? {
        inspector(of: webView).flatMap { object(inspectorWebViewSelector, of: $0) } as? NSView
    }

    // MARK: Docking
    //
    // Docked, WebKit adds the inspector's web view to the page's superview
    // and sets both frames from the superview's bounds, again whenever the
    // page's frame changes (a window resize, the inspector's own divider,
    // its dock side). Auto Layout would put the page back over it, so the
    // page is laid out by frame while docked (`BrowserWebView.inspectorDidDock`).
    // WebKit always spans the whole superview: a split pane's inspector
    // gets its own window instead.

    static func host(_ host: NSView, didAdd subview: NSView) {
        guard subview is WKWebView, !(subview is BrowserWebView) else { return }
        for case let page as BrowserWebView in host.subviews where inspectorView(of: page) === subview {
            if page.pageEdgeConstraints.allSatisfy(\.isActive) {
                page.inspectorDidDock(subview)
            } else {
                // Not while WebKit is still attaching it.
                DispatchQueue.main.async { detach(page) }
            }
            return
        }
    }

    static func host(_ host: NSView, willRemove subview: NSView) {
        for case let page as BrowserWebView in host.subviews where page.dockedInspector === subview {
            page.inspectorDidUndock()
        }
    }
}

/// A view that holds pages (the page area, the Peek's panel): it tells
/// `BrowserWebInspector` when WebKit docks an inspector in it or takes it out.
@MainActor
class BrowserInspectorHostView: NSView {
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        BrowserWebInspector.host(self, didAdd: subview)
    }

    override func willRemoveSubview(_ subview: NSView) {
        BrowserWebInspector.host(self, willRemove: subview)
        super.willRemoveSubview(subview)
    }
}

extension BrowserWindowController {
    /// The page F12 inspects: the one the user looks at (a Peek's).
    var inspectableWebView: WKWebView? {
        guard let tab = pageTab, !tab.isAsleep, BrowserWebInspector.isAvailable(for: tab.webView) else { return nil }
        return tab.webView
    }

    var isWebInspectorVisible: Bool {
        inspectableWebView.map(BrowserWebInspector.isVisible(for:)) ?? false
    }

    /// F12: opens the page's Web Inspector, or closes it.
    func toggleWebInspector() {
        guard let webView = inspectableWebView else { return }
        BrowserWebInspector.setVisible(!BrowserWebInspector.isVisible(for: webView), for: webView)
    }

    /// `browser devtools [show|hide|toggle|dock|window]`: prints `docked`,
    /// `window` (its own window) or `hidden` once WebKit reports the change
    /// (up to 3 s; it opens the inspector asynchronously), `unavailable`
    /// when WebKit has no inspector for the page. `dock` and `window` show
    /// it there, as its dock buttons do (a split pane's stays a window).
    func performDevToolsCommand(
        _ arguments: [String],
        tab: BrowserTab,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let webView = tab.webView
        guard !tab.isAsleep, BrowserWebInspector.isAvailable(for: webView) else {
            completion(.success("unavailable"))
            return
        }
        let target: Bool?
        let docked: Bool?
        switch arguments {
        case []: (target, docked) = (nil, nil)
        case ["show"]: (target, docked) = (true, nil)
        case ["hide"]: (target, docked) = (false, nil)
        case ["toggle"]: (target, docked) = (!BrowserWebInspector.isVisible(for: webView), nil)
        case ["dock"], ["window"]:
            (target, docked) = (true, arguments == ["dock"])
        default:
            completion(.failure(BrowserAutomationError.invalidArguments(
                "Usage: soprano-web browser devtools [show|hide|toggle|dock|window]"
            )))
            return
        }
        if let target { BrowserWebInspector.setVisible(target, for: webView) }
        let deadline = Date().addingTimeInterval(3)
        var moved = false
        func report() {
            let visible = BrowserWebInspector.isVisible(for: webView)
            if visible, let docked, !moved {
                // Once it shows: WebKit moves it, the page area takes it in
                // (a split pane's stays in its window).
                moved = true
                if docked { BrowserWebInspector.attach(webView) } else { BrowserWebInspector.detach(webView) }
            }
            let waiting = target.map { visible != $0 } ?? false
                || (visible && docked.map { webView.isInspectorDocked != $0 } ?? false)
            if waiting, Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { report() } }
                return
            }
            let state = !visible ? "hidden" : webView.isInspectorDocked ? "docked" : "window"
            completion(.success(state))
        }
        report()
    }
}
