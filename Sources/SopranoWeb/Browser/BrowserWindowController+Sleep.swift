import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Tab sleep

    /// What `BrowserTabSleepPolicy` reads from `tab` in this window.
    func sleepCandidate(_ tab: BrowserTab) -> BrowserTabSleepCandidate {
        let webView = tab.webView
        return BrowserTabSleepCandidate(
            isSelected: tab.id == selectedTab?.id,
            isLoaded: !tab.isRestorePending && webView.url != nil,
            isPlayingAudio: tab.isPlayingAudio,
            isCapturing: webView.cameraCaptureState != .none
                || webView.microphoneCaptureState != .none
                || !tab.lifecycle.capturingFrames.isEmpty,
            isLoading: webView.isLoading,
            hasOpenPrompt: hasOpenPrompt(tab),
            hasUnsavedInput: !tab.lifecycle.unsavedFrames.isEmpty,
            isPopup: isPopup || manager.hasPopupWindow(openedBy: tab),
            isKeptAwake: keepAwakeKey(for: tab).map(tab.dataContext.sitePermissions.keepsAwake(host:)) ?? false,
            lastActive: tab.lifecycle.lastActiveAt
        )
    }

    /// Why `tab` stays awake now, whatever its idle time; nil when it may
    /// sleep.
    func sleepExemption(_ tab: BrowserTab) -> BrowserTabSleepExemption? {
        BrowserTabSleepPolicy.exemption(for: sleepCandidate(tab))
    }

    private func hasOpenPrompt(_ tab: BrowserTab) -> Bool {
        tab.lifecycle.openPrompts > 0
            || tab.links.isPromptingExternalApp
            || permissionsState.notificationPrompts.values.contains { $0.contains { $0.tabID == tab.id } }
    }

    /// The site Keep This Site Awake applies to: the page's (a sleeping
    /// tab's saved) site.
    func keepAwakeKey(for tab: BrowserTab) -> String? {
        BrowserSitePermissionStore.siteKey(for: tab.isStartPage ? nil : tab.item.url)
    }

    /// `tab` was just used (selected, targeted by a CLI command): its idle
    /// time starts over and a snapshot in flight no longer puts it to sleep.
    func tabWasUsed(_ tab: BrowserTab) {
        tab.lifecycle.lastActiveAt = manager.tabSleeper.now()
        tab.lifecycle.sleepAttempt = nil
    }

    /// Puts `tab` to sleep: takes a snapshot of its page, then releases the
    /// page (`finishSleeping`) if the tab may still sleep by then. Its
    /// title, address, favicon and back/forward list stay; selecting it, a
    /// CLI command or moving it to another window wakes it.
    func sleepTab(_ tab: BrowserTab) {
        guard tab.lifecycle.sleepAttempt == nil, sleepExemption(tab) == nil else { return }
        let attempt = UUID()
        tab.lifecycle.sleepAttempt = attempt
        let tabID = tab.id
        let finish: @MainActor (Data?) -> Void = { [weak manager] snapshot in
            guard let found = manager?.tab(id: tabID),
                  found.tab.lifecycle.sleepAttempt == attempt
            else { return }
            found.tab.lifecycle.sleepAttempt = nil
            // The tab may have been selected, moved or started playing since.
            found.window.finishSleeping(found.tab, snapshot: snapshot)
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        tab.webView.takeSnapshot(with: configuration) { image, _ in
            MainActor.assumeIsolated {
                finish(image.flatMap(Self.snapshotData))
            }
        }
        // A hidden page may never answer; it sleeps without a snapshot.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated { finish(nil) }
        }
    }

    /// Releases `tab`'s page if it may still sleep: saves what brings it
    /// back (`lifecycle.pendingRestore`, the lazy-restore path) and swaps in
    /// an empty web view, so the old one and its web content process go
    /// away.
    func finishSleeping(_ tab: BrowserTab, snapshot: Data?) {
        guard tabs.contains(where: { $0 === tab }), sleepExemption(tab) == nil else { return }
        let state = tab.state
        removeWakeSnapshot(tab)
        removeCrashPage(tab)
        tab.lifecycle.crashedURL = nil
        tab.lifecycle.reloadsWhenSelected = false
        tab.lifecycle.unsavedFrames.removeAll()
        tab.lifecycle.capturingFrames.removeAll()
        tab.links.blockedPopups.removeAll()
        tab.certificateInterstitial = nil
        tab.errorMessage = nil
        tab.failedURL = nil
        tab.isShowingErrorPage = false
        tab.pendingURL = nil
        tab.lifecycle.pendingRestore = state
        tab.lifecycle.sleep = BrowserTabSleepState(sleptAt: manager.tabSleeper.now(), snapshot: snapshot)
        replaceWebView(of: tab)
        metadataChanged(tab)
    }

    /// A JPEG of the page at one pixel per point (about 100–200 KB), kept
    /// in memory while the tab sleeps.
    nonisolated static func snapshotData(_ image: NSImage) -> Data? {
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: width,
                  pixelsHigh: height,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }

    // MARK: - Waking

    /// Covers the waking page with the snapshot it had when it fell asleep;
    /// it goes once the page is back (`wakeSnapshotPageCommitted`, finish,
    /// failure) and after five seconds at the most.
    func showWakeSnapshot(_ data: Data?, for tab: BrowserTab) {
        removeWakeSnapshot(tab)
        guard let data, let image = NSImage(data: data), tabs.contains(where: { $0 === tab }) else { return }
        let view = BrowserWakeSnapshotView(image: image)
        webArea.addSubview(view, positioned: .above, relativeTo: tab.webView)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: tab.webView.topAnchor),
            view.leadingAnchor.constraint(equalTo: tab.webView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: tab.webView.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: tab.webView.bottomAnchor),
        ])
        tab.lifecycle.wakeSnapshotView = view
        removeWakeSnapshot(view, of: tab, after: 5)
    }

    /// The woken page committed; it paints shortly after.
    func wakeSnapshotPageCommitted(_ tab: BrowserTab) {
        guard let view = tab.lifecycle.wakeSnapshotView else { return }
        removeWakeSnapshot(view, of: tab, after: 0.5)
    }

    func removeWakeSnapshot(_ tab: BrowserTab) {
        tab.lifecycle.wakeSnapshotView?.removeFromSuperview()
        tab.lifecycle.wakeSnapshotView = nil
    }

    private func removeWakeSnapshot(_ view: NSView, of tab: BrowserTab, after delay: TimeInterval) {
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self, weak tab, weak view] _ in
            MainActor.assumeIsolated {
                guard let self, let tab, let view, tab.lifecycle.wakeSnapshotView === view else { return }
                self.removeWakeSnapshot(tab)
            }
        }
    }

    // MARK: - What keeps a tab awake

    /// `sleepGuard {frame, unsaved, capturing}` from the page script.
    func receiveSleepGuard(_ body: [String: Any], tab: BrowserTab) {
        guard let frame = body["frame"] as? String, frame.count <= 64 else { return }
        if body["unsaved"] as? Bool == true {
            tab.lifecycle.unsavedFrames.insert(frame)
        } else {
            tab.lifecycle.unsavedFrames.remove(frame)
        }
        if body["capturing"] as? Bool == true {
            tab.lifecycle.capturingFrames.insert(frame)
        } else {
            tab.lifecycle.capturingFrames.remove(frame)
        }
    }

    /// Counts a dialog, sheet or prompt `webView`'s page waits on; the tab
    /// stays awake until the returned call ends it.
    func promptBegan(for webView: WKWebView) -> @MainActor @Sendable () -> Void {
        guard let tab = tab(for: webView) else { return {} }
        tab.lifecycle.openPrompts += 1
        return { [weak tab] in
            guard let tab else { return }
            tab.lifecycle.openPrompts = max(0, tab.lifecycle.openPrompts - 1)
        }
    }

    // MARK: - Keep This Site Awake

    @objc func toggleKeepAwakeFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let tab = tabs.first(where: { $0.id == id }),
              let host = keepAwakeKey(for: tab)
        else { return }
        let sitePermissions = tab.dataContext.sitePermissions
        sitePermissions.setKeepsAwake(!sitePermissions.keepsAwake(host: host), host: host)
    }
}

/// The snapshot over a waking tab's page. Clicks reach the page beneath.
final class BrowserWakeSnapshotView: NSImageView {
    convenience init(image: NSImage) {
        self.init(frame: .zero)
        self.image = image
        imageScaling = .scaleAxesIndependently
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
