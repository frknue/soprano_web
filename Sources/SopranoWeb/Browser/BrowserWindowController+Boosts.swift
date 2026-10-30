import AppKit
import WebKit

/// Boosts in this window: user scripts on every tab (`refreshStateScripts`
/// swaps them), live CSS and Zap changes, the editor sheet and Zap mode.
extension BrowserWindowController {
    /// A Boost changed: new documents get the new scripts; open pages get
    /// the new CSS and hidden elements now (JavaScript waits for the next
    /// load).
    func boostsChanged() {
        for tab in tabsWithPeek {
            refreshStateScripts(tab)
            applyBoostStyle(to: tab)
        }
        // Only a change to the zaps the editor loaded replaces its list,
        // so unsaved zap edits survive another Boost's change.
        if let editor = boostEditor, let boost = manager.boosts.boost(host: editor.host), boost.zaps != editor.loadedZaps {
            editor.refreshZaps(boost.zaps)
        }
        updateSiteControlPanel()
    }

    /// Sets the open page's Boost sheet to its enabled Boost's CSS and
    /// zaps, or takes it out.
    func applyBoostStyle(to tab: BrowserTab) {
        guard let host = BrowserBoost.key(for: tab.webView.url) else { return }
        let boost = manager.boosts.boost(host: host).flatMap { $0.isEnabled ? $0 : nil }
        tab.webView.evaluateJavaScript(
            BrowserBoostScripts.styleSource(host: host, css: boost?.css ?? "", zaps: boost?.zaps ?? []),
            in: nil,
            in: BrowserBoostScripts.world
        )
    }

    // MARK: Editor

    /// The Boost host of the page the user looks at; nil when it is not an
    /// http(s) page.
    var boostHost: String? {
        pageTab.flatMap { BrowserBoost.key(for: $0.webView.url ?? $0.state.url.flatMap(URL.init(string:))) }
    }

    /// Opens the Boost editor for the page's site (`/boost`, the Site
    /// Control Center's Boost row).
    func showBoostEditor() {
        guard let window, window.attachedSheet == nil, let host = boostHost else {
            NSSound.beep()
            return
        }
        siteControlPanel.close()
        let store = manager.boosts
        let editor = BrowserBoostEditor(boost: store.boost(host: host) ?? BrowserBoost(host: host), theme: theme)
        editor.onSave = { [weak self] boost in
            self?.manager.boosts.update(host: boost.host) { $0 = boost }
        }
        editor.onDelete = { [weak self] host in
            self?.manager.boosts.remove(host: host)
        }
        editor.onZap = { [weak self] in
            self?.startZap()
        }
        editor.onClose = { [weak self] in
            self?.boostEditor = nil
        }
        boostEditor = editor
        editor.present(on: window)
    }

    // MARK: Zap mode

    /// Hover outlines elements of the page, a click hides one and records
    /// its selector in the site's Boost, Esc ends.
    func startZap() {
        guard let tab = pageTab, let host = BrowserBoost.key(for: tab.webView.url) else {
            NSSound.beep()
            return
        }
        stopZap()
        zapSession = (tab.id, host)
        window?.makeFirstResponder(tab.webView)
        tab.webView.evaluateJavaScript(BrowserBoostScripts.zapStart, in: nil, in: BrowserPageScripts.isolatedWorld)
    }

    func stopZap() {
        guard let session = zapSession else { return }
        zapSession = nil
        tabsWithPeek.first { $0.id == session.tabID }?.webView.evaluateJavaScript(
            BrowserBoostScripts.zapStop,
            in: nil,
            in: BrowserPageScripts.isolatedWorld
        )
    }

    /// Esc in the tab in Zap mode ends it before Vimium sees the key.
    func endsZap(on event: NSEvent, in tab: BrowserTab) -> Bool {
        guard zapSession?.tabID == tab.id, event.keyCode == 53 else { return false }
        stopZap()
        return true
    }

    /// A new document in the Zap tab: its page script is gone, so is the
    /// session (Esc goes back to Vimium, the Peek and the page).
    func zapPageCommitted(_ tab: BrowserTab) {
        if zapSession?.tabID == tab.id {
            zapSession = nil
        }
    }

    /// Zap mode belongs to the page the user looks at: another tab, pane,
    /// Space or a Peek ends it.
    func updateZapSession() {
        if let session = zapSession, session.tabID != pageTab?.id {
            stopZap()
        }
    }

    /// `zapPick` from the isolated world: the clicked element's path.
    func receiveZapPick(_ body: [String: Any], tab: BrowserTab, frame: WKFrameInfo) {
        guard frame.isMainFrame else { return }
        recordZap(body, tab: tab)
    }

    /// Adds the selector of a `zapPick` path to the tab's site's Boost
    /// while the tab is in Zap mode.
    func recordZap(_ body: [String: Any], tab: BrowserTab) {
        guard let session = zapSession, session.tabID == tab.id,
              let host = BrowserBoost.key(for: tab.webView.url), host == session.host,
              let raw = body["path"] as? [[String: Any]]
        else { return }
        let path = raw.compactMap(BrowserZapSelector.Node.init)
        guard path.count == raw.count, let selector = BrowserZapSelector.selector(for: path) else { return }
        manager.boosts.zap(selector, host: host)
    }

    func receiveZapEnd(tab: BrowserTab) {
        if zapSession?.tabID == tab.id {
            zapSession = nil
        }
    }
}
