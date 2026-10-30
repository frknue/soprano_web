import AppKit
import WebKit

/// The Mini Player: one floating, non-activating panel app-wide (the
/// manager owns it) that hosts a tab's own web view while the tab is off
/// screen. The tab stays in its window's list and stays bound, so its
/// delegates, message handlers and history are the same object's; only
/// the `NSView` moves. The window controller moves it in
/// (`openMiniPlayer`) and back (`returnMiniPlayer`, `releaseMiniPlayer`).
@MainActor
final class BrowserMiniPlayer: NSObject, NSWindowDelegate {
    private(set) weak var controller: BrowserWindowController?
    private(set) weak var tab: BrowserTab?
    private(set) var panel: BrowserMiniPlayerPanel?
    /// The panel's frame is remembered (`miniPlayerFrame`); never for a
    /// private window's tab.
    private(set) var persistsFrame = true
    private let defaults: UserDefaults
    private let isOffscreen: Bool
    /// The panel is being placed by code; its move isn't the user's.
    private var isPlacing = false

    init(defaults: UserDefaults, isOffscreen: Bool) {
        self.defaults = defaults
        self.isOffscreen = isOffscreen
    }

    var isOpen: Bool {
        panel != nil && tab != nil
    }

    func hosts(_ tab: BrowserTab) -> Bool {
        isOpen && self.tab === tab
    }

    /// The remembered frame, if any.
    var rememberedFrame: NSRect? {
        BrowserMiniPlayerFrame.rect(defaults.string(forKey: BrowserMiniPlayerFrame.defaultsKey))
    }

    /// Moves `tab`'s web view into the panel and shows it. The caller has
    /// returned any other tab first.
    func show(_ tab: BrowserTab, from controller: BrowserWindowController, theme: AppTheme, persistsFrame: Bool) {
        self.controller = controller
        self.tab = tab
        self.persistsFrame = persistsFrame
        let panel = self.panel ?? BrowserMiniPlayerPanel(theme: theme)
        panel.delegate = self
        panel.allowsOffscreenFrame = isOffscreen
        panel.playerView.apply(theme: theme)
        panel.playerView.onReturn = { [weak self] in self?.returnPressed() }
        panel.playerView.onClose = { [weak self] in self?.closePressed() }
        panel.playerView.onPlayPause = { [weak self] in self?.playPausePressed() }
        self.panel = panel
        let webView = tab.webView
        webView.removeFromSuperview()
        panel.playerView.host(webView)
        update(title: tab.displayTitle, isPlaying: tab.media.info.isPlaying)
        isPlacing = true
        panel.setFrame(frame(near: controller.window), display: false)
        isPlacing = false
        if isOffscreen {
            // The harness: ordered in behind everything, off every display.
            panel.orderBack(nil)
        } else {
            panel.orderFrontRegardless()
        }
        panel.displayIfNeeded()
    }

    /// Takes the web view out of the panel and hides it; returns the tab
    /// whose web view it was (nil when none was shown).
    @discardableResult
    func takeBack() -> BrowserTab? {
        let shown = tab
        if let webView = shown?.webView, webView.superview === panel?.playerView.host {
            webView.removeFromSuperview()
        }
        panel?.playerView.clear()
        panel?.orderOut(nil)
        tab = nil
        controller = nil
        return shown
    }

    func update(title: String, isPlaying: Bool) {
        panel?.playerView.update(title: title, isPlaying: isPlaying)
    }

    /// Where the panel opens: the remembered frame when it still fits a
    /// screen, else the bottom-right corner of `window`'s screen (in the
    /// harness, whose screens are virtual: of the window itself).
    func frame(near window: NSWindow?) -> NSRect {
        let windowFrame = window?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let visible = isOffscreen
            ? windowFrame
            : window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? windowFrame
        let others = isOffscreen ? [] : NSScreen.screens.map(\.visibleFrame).filter { $0 != visible }
        return BrowserMiniPlayerFrame.frame(remembered: rememberedFrame, screens: [visible] + others, fallback: visible)
    }

    // MARK: Buttons

    func returnPressed() {
        guard let controller, let tab else { return }
        controller.returnToMiniPlayerTab(tab)
    }

    func closePressed() {
        guard let controller, let tab else { return }
        controller.closeMiniPlayer(pausing: tab)
    }

    func playPausePressed() {
        guard let controller, let tab else { return }
        controller.performMediaAction(tab.media.info.isPlaying ? .pause : .play, on: tab)
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame()
    }

    private func saveFrame() {
        guard persistsFrame, isOpen, !isPlacing, let panel else { return }
        defaults.set(BrowserMiniPlayerFrame.string(panel.frame), forKey: BrowserMiniPlayerFrame.defaultsKey)
    }
}

/// The panel: floating over every Space and full-screen app, never
/// activating the app; resizable, moved by its top bar.
@MainActor
final class BrowserMiniPlayerPanel: NSPanel {
    let playerView: BrowserMiniPlayerView

    init(theme: AppTheme) {
        playerView = BrowserMiniPlayerView(theme: theme)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: BrowserMiniPlayerFrame.defaultWidth, height: 225),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        backgroundColor = .black
        minSize = BrowserMiniPlayerFrame.minimumSize
        animationBehavior = .utilityWindow
        title = "Mini Player"
        contentView = playerView
    }

    /// The harness keeps the panel off every display, as its windows.
    var allowsOffscreenFrame = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffscreenFrame ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
