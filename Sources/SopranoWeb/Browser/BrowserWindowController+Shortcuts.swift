import AppKit
import WebKit

/// The page side of Site wins: a capture listener on `window`, installed
/// before any page script in the isolated world (so the page can neither
/// see nor forge it), reports each modified `keydown` once the event has
/// finished dispatching, with whether a page listener called
/// `preventDefault`. Every frame reports; only the selected tab counts.
enum BrowserShortcutScripts {
    static let keyReport = BrowserPageScript(
        source: """
        (() => {
          if (window.__sopranoKeyReport) return;
          window.__sopranoKeyReport = true;
          window.addEventListener('keydown', (event) => {
            if (!event.isTrusted || !(event.metaKey || event.ctrlKey || event.altKey)) return;
            setTimeout(() => {
              try {
                window.webkit.messageHandlers.sopranoWeb.postMessage({
                  type: 'keyReport', code: event.code, meta: event.metaKey, ctrl: event.ctrlKey,
                  alt: event.altKey, shift: event.shiftKey, prevented: event.defaultPrevented
                });
              } catch (_) {}
            }, 0);
          }, true);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        world: .isolated
    )
}

extension BrowserWindowController {
    // MARK: - Copy URL

    /// The selected tab's page address (none on the start page).
    var selectedPageURL: URL? {
        guard let tab = selectedTab, !tab.isStartPage else { return nil }
        return tab.webView.url ?? tab.failedURL.flatMap(URL.init(string:))
    }

    /// ⇧⌘C copies the address, ⌥⇧⌘C `[title](address)`, onto the
    /// manager's pasteboard (the general one; the harness's own).
    @discardableResult
    func copyPageAddress(markdown: Bool) -> String? {
        guard let tab = selectedTab, let url = selectedPageURL?.absoluteString else { return nil }
        let text = markdown ? Self.markdownLink(title: tab.displayTitle, url: url) : url
        let pasteboard = manager.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showVimiumToast(markdown ? "Copied URL as Markdown" : "Copied URL")
        return text
    }

    /// `[title](url)` with the title's brackets escaped.
    static func markdownLink(title: String, url: String) -> String {
        let escaped = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(escaped)](\(url))"
    }

    // MARK: - Toolbar

    /// ⇧⌘D: hides or shows the toolbar in every window.
    func toggleToolbar() {
        manager.defaults.set(!isToolbarHidden, forKey: Self.toolbarHiddenKey)
        for controller in manager.controllers {
            controller.applyTabsLayout()
        }
    }

    // MARK: - Rail walk

    /// ⌥⌘↓ / ⌥⌘↑: the next or previous rail item (favorites, the pinned
    /// outline's shown pins, Today tabs), selecting its tab or opening it.
    func walkRail(step: Int) {
        let current: BrowserRailWalk.Item? = selectedTab.map { tab in
            switch tab.origin {
            case let .favorite(id) where hasSpaces: .favorite(id)
            case let .pinned(id) where hasSpaces: .pin(id)
            default: .tab(tab.id)
            }
        }
        let items: [BrowserRailWalk.Item]
        if hasSpaces {
            // The outline's shown pins, plus the selected one where it sits
            // in the tree when its folder is collapsed, so the walk goes on
            // from it rather than jumping to an end.
            let shown = Set(railOutlineRows.compactMap { $0.node.pin?.id })
            let pins = (pinSpaceID.map { spaces.pins(inSpace: $0) } ?? [])
                .filter { shown.contains($0.id) || current == .pin($0.id) }
            items = spaces.favorites(ofProfile: profileID).map { .favorite($0.id) }
                + pins.map { .pin($0.id) }
                + todayTabs.map { .tab($0.id) }
        } else {
            items = visibleTabs.map { .tab($0.id) }
        }
        switch BrowserRailWalk.step(items, from: current, by: step) {
        case let .favorite(id)?: openFavorite(id)
        case let .pin(id)?: openPin(id)
        case let .tab(id)?: selectTab(id: id, focus: true)
        case nil: break
        }
    }

    // MARK: - Recent tabs (⌃Tab)

    /// ⌃Tab (⌃⇧Tab backward): opens the switcher on the previous tab, or
    /// moves on while it is open. Releasing ⌃ selects; a ⌃Tab already
    /// released selects at once (`commitWhenReleased`; the harness commits
    /// itself).
    func showRecentTabs(forward: Bool, commitWhenReleased: Bool) {
        if var switcher = recentTabSwitcher {
            switcher.advance(forward: forward)
            recentTabSwitcher = switcher
            recentTabsOverlay?.select(switcher.index)
            return
        }
        let items = recentTabs.recent(among: tabs.map(\.id))
        guard let switcher = BrowserRecentTabSwitcher(items: items, forward: forward) else { return }
        recentTabSwitcher = switcher
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let overlay = recentTabsOverlay ?? BrowserRecentTabsOverlay(theme: theme)
        recentTabsOverlay = overlay
        overlay.show(
            items.compactMap { byID[$0] }.map { tab in
                BrowserRecentTabsOverlay.Item(
                    title: tab.displayTitle,
                    detail: tab.isStartPage ? "Start Page" : AddressURLText.display(tab.item.url?.absoluteString ?? ""),
                    favicon: tab.favicon,
                    space: tab.spaceID != currentSpaceID
                        ? tab.spaceID.flatMap(spaces.space(id:)).map(BrowserSpacesMenu.spaceTitle)
                        : nil
                )
            },
            selected: switcher.index
        )
        rootView.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
        ])
        rootView.layoutSubtreeIfNeeded()
        guard commitWhenReleased else { return }
        guard NSEvent.modifierFlags.contains(.control) else {
            commitRecentTabs()
            return
        }
        recentTabsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.cancelRecentTabs()
                return nil
            }
            if event.type == .flagsChanged, !event.modifierFlags.contains(.control) {
                self.commitRecentTabs()
            }
            return event
        }
    }

    /// ⌃ released: the switcher's tab is selected (switching Space).
    func commitRecentTabs() {
        guard let switcher = recentTabSwitcher else { return }
        cancelRecentTabs()
        selectTab(id: switcher.selected, focus: true)
    }

    func cancelRecentTabs() {
        recentTabSwitcher = nil
        recentTabsOverlay?.removeFromSuperview()
        if let monitor = recentTabsMonitor {
            NSEvent.removeMonitor(monitor)
            recentTabsMonitor = nil
        }
    }

    // MARK: - Shortcut priority

    /// A key equivalent pressed while the page has focus. A registry
    /// shortcut runs at once under App wins; under Site wins or Press twice
    /// it goes to the page first (`BrowserShortcutGate`). WebKit hands an
    /// unhandled key back by sending the same event again, which lands here
    /// as `forwardedKey`. True when the key is consumed.
    func routePageShortcut(_ event: NSEvent, in webView: BrowserWebView) -> Bool {
        // A hand-back is recognized before the focus check: the command
        // may have moved focus since the press.
        if let consumed = consumeHandedBackKey(event) {
            return consumed
        }
        guard event.type == .keyDown, window?.firstResponder === webView else { return false }
        let now = Date()
        let keymap = settingsStore.settings.keymap
        guard let shortcut = BrowserShortcut(event: event),
              let id = keymap.command(for: shortcut),
              id.isRemappable,
              id.command.state(BrowserCommandContext(manager: manager, controller: self)).isEnabled
        else { return false }
        keyTokens += 1
        switch shortcutGate.keyPressed(id, shortcut: shortcut, priority: keymap.priority(for: id), token: keyTokens, at: now) {
        case .run:
            runShortcutCommand(id)
            return true
        case .forward:
            forwardedKeys.append((event, keyTokens))
            if forwardedKeys.count > BrowserShortcutGate.rememberedTokens { forwardedKeys.removeFirst() }
            return false
        case .swallow:
            return true
        case .pass:
            return false
        }
    }

    /// WebKit sends a key the page left unhandled through AppKit again as
    /// the same event: a press the gate forwarded is answered here (run
    /// or swallowed, never left to the menu). Nil when `event` is not one.
    func consumeHandedBackKey(_ event: NSEvent) -> Bool? {
        guard let index = forwardedKeys.firstIndex(where: { $0.event === event }) else { return nil }
        let token = forwardedKeys.remove(at: index).token
        let (decision, command) = shortcutGate.pageDidNotHandle(token: token, at: Date())
        switch decision {
        case .run:
            if let command { runShortcutCommand(command) }
            return true
        case .swallow:
            return true
        case .forward, .pass:
            return false
        }
    }

    /// The page's `keydown` report (`BrowserShortcutScripts.keyReport`):
    /// a Site wins shortcut the page did not `preventDefault` runs.
    func receiveKeyReport(_ body: [String: Any], tab: BrowserTab) {
        guard tab.id == selectedTab?.id,
              let code = body["code"] as? String,
              let shortcut = BrowserShortcut(
                  domCode: code,
                  meta: body["meta"] as? Bool ?? false,
                  ctrl: body["ctrl"] as? Bool ?? false,
                  alt: body["alt"] as? Bool ?? false,
                  shift: body["shift"] as? Bool ?? false
              ),
              let command = shortcutGate.pageReported(shortcut, prevented: body["prevented"] as? Bool ?? true, at: Date())
        else { return }
        runShortcutCommand(command)
    }

    private func runShortcutCommand(_ id: BrowserCommandID) {
        id.command.perform(in: BrowserCommandContext(manager: manager, controller: self))
    }
}
