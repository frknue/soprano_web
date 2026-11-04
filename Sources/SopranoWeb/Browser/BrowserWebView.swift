import AppKit
import WebKit

/// A WKWebView that lets Vimium's normal mode consume a key before the page
/// sees it. Returning false from `keyHandler` passes the event through.
final class BrowserWebView: WKWebView {
    var keyHandler: ((NSEvent) -> Bool)?

    /// Set by the isolated-world `contextmenu` listener just before WebKit
    /// opens a context menu; consumed by `willOpenMenu(_:with:)`.
    var contextMenuTarget: BrowserContextMenuTarget?

    /// The content blocker's lists attached to this web view's user
    /// content controller, by identifier (WebKit has no getter).
    var contentRuleListIDs: [String] = []

    /// The extension whose configuration made this web view (it shows that
    /// extension's pages); nil for a web page's.
    var extensionID: String?

    /// Its leading and trailing constraints to the page area while it
    /// fills it (`installWebView`); a split's pane turns them off for its
    /// pane constraints (`applyPaneLayout`).
    var pageEdgeConstraints: [NSLayoutConstraint] = []

    /// The Web Inspector WebKit docked beside this page, in the same
    /// superview (`BrowserInspectorHostView`). WebKit sets both frames, so
    /// while it is docked the page is laid out by frame (resizing with the
    /// superview, which makes WebKit lay both out again) and its
    /// constraints to the superview wait in `undockedConstraints`.
    private(set) weak var dockedInspector: NSView?
    private(set) var isInspectorDocked = false
    private var undockedConstraints: [NSLayoutConstraint] = []

    func inspectorDidDock(_ inspector: NSView) {
        guard !isInspectorDocked, let superview else { return }
        undockedConstraints = superview.constraints.filter { constraint in
            constraint.isActive
                && ((constraint.firstItem === self && constraint.secondItem === superview)
                    || (constraint.firstItem === superview && constraint.secondItem === self))
        }
        NSLayoutConstraint.deactivate(undockedConstraints)
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
        // Docked beside a tab that isn't shown, it stays out of sight too.
        inspector.isHidden = isHiddenOrHasHiddenAncestor
        dockedInspector = inspector
        isInspectorDocked = true
    }

    /// Whether WebKit's inspector may dock beside this page: it spans the
    /// whole superview, so a split pane's can't.
    var canDockInspector: Bool {
        isInspectorDocked || pageEdgeConstraints.allSatisfy(\.isActive)
    }

    /// The inspector closed or moved to its own window: the page's
    /// constraints take over again. WebKit reuses the inspector's view
    /// (in its window, or docked again), so it leaves visible.
    func inspectorDidUndock() {
        guard isInspectorDocked else { return }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(undockedConstraints)
        undockedConstraints = []
        dockedInspector?.isHidden = false
        dockedInspector = nil
        isInspectorDocked = false
    }

    /// A click into a split's other pane makes its web view first
    /// responder: that pane becomes the focused (selected) one.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let controller = window?.windowController as? BrowserWindowController {
            controller.pageBecameFirstResponder(self)
        }
        return became
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let target = contextMenuTarget.flatMap { $0.isFresh(at: Date()) ? $0 : nil }
        contextMenuTarget = nil
        (uiDelegate as? BrowserWindowController)?.prepareContextMenu(menu, target: target, in: self)
    }

    /// Registry shortcuts pressed while the page has focus go through the
    /// window's priority gate first (`routePageShortcut`): App wins runs
    /// the command here; Site wins and Press twice let WebKit hand the key
    /// to the page, and WebKit sends a key the page left unhandled through
    /// here again.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let controller = window?.windowController as? BrowserWindowController,
           controller.routePageShortcut(event, in: self)
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A docked inspector follows the page: hidden with it (another tab
    /// selected), shown again with it, and closed when the page moves to
    /// another superview (another window, a Peek, the Mini Player) or
    /// closes. An inspector in its own window is left alone.
    override func viewDidHide() {
        super.viewDidHide()
        dockedInspector?.isHidden = true
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        dockedInspector?.isHidden = false
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview !== superview, isInspectorDocked {
            // Its constraints first: the new superview adds its own.
            inspectorDidUndock()
            BrowserWebInspector.setVisible(false, for: self)
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func keyDown(with event: NSEvent) {
        // ⌃ and ⌥ shortcuts (⌃Tab) and function keys (F12) may arrive as
        // plain key-downs; so may an extension's shortcut.
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            || BrowserShortcut(event: event)?.isFunctionKey == true,
           let controller = window?.windowController as? BrowserWindowController,
           controller.routePageShortcut(event, in: self)
            || controller.extensions.performCommand(for: event, in: controller)
        {
            return
        }
        if keyHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    /// Feeds normal-mode keys through the real keyDown bridge for the CLI
    /// verification command. Not used by user input.
    func sendKeysForTesting(_ keys: String) {
        for character in keys {
            let value = String(character)
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: value,
                charactersIgnoringModifiers: value,
                isARepeat: false,
                keyCode: 0
            ) else { continue }
            keyDown(with: event)
        }
    }
}

/// Receives focus changes from one tab's page. The handler is retained by the
/// web view's user content controller; the controller back-reference is weak.
@MainActor
final class VimiumFocusHandler: NSObject, WKScriptMessageHandler {
    weak var controller: BrowserWindowController?
    let tabID: UUID

    init(controller: BrowserWindowController, tabID: UUID) {
        self.controller = controller
        self.tabID = tabID
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == VimiumPageScripts.focusMessageName else { return }
        let editable: Bool
        if let value = message.body as? Bool {
            editable = value
        } else if let value = message.body as? NSNumber {
            editable = value.boolValue
        } else {
            return
        }
        MainActor.assumeIsolated {
            controller?.vimiumFocusChanged(tabID: tabID, editable: editable)
        }
    }
}
