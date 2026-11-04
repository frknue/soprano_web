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

    /// The inspector's own web view while it is docked: WebKit puts it
    /// in the page's superview and shrinks the page beside it. Nil while
    /// closed or in its own window.
    static func dockedView(of webView: WKWebView) -> NSView? {
        guard let superview = webView.superview,
              let inspector = inspector(of: webView),
              let view = object(inspectorWebViewSelector, of: inspector) as? NSView,
              view.superview === superview
        else { return nil }
        return view
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

    /// `browser devtools [show|hide|toggle]`: prints `docked`, `window`
    /// (its own window) or `hidden` once WebKit reports the change (up to
    /// 3 s; it opens the inspector asynchronously), `unavailable` when
    /// WebKit has no inspector for the page.
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
        switch arguments {
        case []: target = nil
        case ["show"]: target = true
        case ["hide"]: target = false
        case ["toggle"]: target = !BrowserWebInspector.isVisible(for: webView)
        default:
            completion(.failure(BrowserAutomationError.invalidArguments(
                "Usage: soprano-web browser devtools [show|hide|toggle]"
            )))
            return
        }
        if let target { BrowserWebInspector.setVisible(target, for: webView) }
        let deadline = Date().addingTimeInterval(3)
        func report() {
            let visible = BrowserWebInspector.isVisible(for: webView)
            if let target, visible != target, Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { report() } }
                return
            }
            let state = !visible ? "hidden" : BrowserWebInspector.dockedView(of: webView) != nil ? "docked" : "window"
            completion(.success(state))
        }
        report()
    }
}
