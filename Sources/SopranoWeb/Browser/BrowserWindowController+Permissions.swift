import AppKit
import WebKit

/// Controller state for site permissions: notification prompts in flight
/// (one per host, every request from that host waits on it) and the open
/// Settings ▸ Websites sheet.
@MainActor
final class BrowserPermissionsState {
    struct NotificationWaiter {
        let tabID: UUID
        let frame: WKFrameInfo
        let id: Int
    }

    var notificationPrompts: [String: [NotificationWaiter]] = [:]
    var websitesSheet: BrowserWebsitesSheet?
}

extension BrowserWindowController {
    // MARK: - Setup

    /// Wires the permission callbacks; called once from `wireCallbacks`.
    func setUpPermissions() {
        sitePermissions.onChange = { [weak self] in self?.sitePermissionsChanged() }
        toolbar.captureIndicator.onAction = { [weak self] action in self?.performCaptureAction(action) }
        BrowserNotificationCenter.shared.onClick = { [weak self] click in self?.openNotification(click) }
    }

    /// Per-tab hooks; called from `makeTab` after the tab's observations.
    func installPermissions(on tab: BrowserTab) {
        let webView = tab.webView
        tab.observations.append(webView.observe(\.cameraCaptureState, options: [.new]) { [weak self, weak tab] _, _ in
            MainActor.assumeIsolated {
                guard let self, let tab, tab.id == self.selectedTab?.id else { return }
                self.updateCaptureIndicator()
            }
        })
        tab.observations.append(webView.observe(\.microphoneCaptureState, options: [.new]) { [weak self, weak tab] _, _ in
            MainActor.assumeIsolated {
                guard let self, let tab, tab.id == self.selectedTab?.id else { return }
                self.updateCaptureIndicator()
            }
        })
        refreshStateScripts(tab)
    }

    /// Replaces the tab's state scripts (mute flag, remembered notification
    /// decisions) so the next document starts with the current state. Every
    /// other user script stays, in order, in its own world.
    func refreshStateScripts(_ tab: BrowserTab) {
        let contentController = tab.webView.configuration.userContentController
        let kept = contentController.userScripts.filter {
            !$0.source.hasPrefix(BrowserPermissionScripts.stateMarker)
        }
        contentController.removeAllUserScripts()
        kept.forEach(contentController.addUserScript)
        BrowserPermissionScripts.stateScripts(
            muted: tab.isMuted,
            notificationStates: NotificationPermissionState.states(in: sitePermissions),
            askingAllowed: settingsStore.settings.allowsNotificationRequests
        ).forEach(contentController.addUserScript)
    }

    /// A remembered decision changed (a prompt answer or Settings ▸
    /// Websites): new documents read it from the state scripts, open pages
    /// get their `Notification.permission` updated now.
    func sitePermissionsChanged() {
        refreshPermissionStates()
        refreshPopupPermissions()
        permissionsState.websitesSheet?.reload()
    }

    /// Re-applies remembered decisions and the notification setting to every
    /// tab; also called when settings change.
    func refreshPermissionStates() {
        let asking = settingsStore.settings.allowsNotificationRequests
        for tab in tabs {
            refreshStateScripts(tab)
            guard !tab.isStartPage,
                  let host = BrowserSitePermissionStore.key(for: tab.webView.url)
            else { continue }
            let state = NotificationPermissionState(
                decision: sitePermissions.decision(.notifications, host: host),
                askingAllowed: asking
            )
            tab.webView.evaluateJavaScript(
                BrowserPermissionScripts.notificationCall("setPermission", [state.rawValue]),
                in: nil,
                in: .page
            )
        }
    }

    // MARK: - Camera and microphone

    func decideMediaCapture(
        origin: WKSecurityOrigin,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        let request = MediaCaptureRequest(type)
        let host = BrowserSitePermissionStore.key(for: origin)
        if let host, let remembered = request.rememberedDecision(in: sitePermissions, host: host) {
            return remembered == .allow ? .grant : .deny
        }
        let answer = await askPermission(
            title: origin.host.isEmpty ? "This page" : origin.host,
            message: "This page wants to use the \(request.name).",
            rememberHost: host
        )
        if let host, answer.remember {
            for permission in request.permissions {
                sitePermissions.set(permission, answer.allowed ? .allow : .deny, host: host)
            }
        }
        return answer.allowed ? .grant : .deny
    }

    func updateCaptureIndicator() {
        let webView = selectedTab?.webView
        toolbar.captureIndicator.update(BrowserCaptureStatus(
            camera: .init(webView?.cameraCaptureState ?? .none),
            microphone: .init(webView?.microphoneCaptureState ?? .none)
        ))
    }

    func performCaptureAction(_ action: BrowserCaptureStatus.Action) {
        guard let webView = selectedTab?.webView else { return }
        switch action {
        case .stopCamera:
            webView.setCameraCaptureState(.none)
        case .muteMicrophone:
            webView.setMicrophoneCaptureState(.muted)
        case .unmuteMicrophone:
            webView.setMicrophoneCaptureState(.active)
        case .stopAll:
            webView.setCameraCaptureState(.none)
            webView.setMicrophoneCaptureState(.none)
        }
    }

    /// Allow / Don't Allow on the window, with an optional "Remember for
    /// <host>" checkbox. Without a window the answer is "deny, not
    /// remembered".
    private func askPermission(
        title: String,
        message: String,
        rememberHost: String?,
        alwaysRemember: Bool = false
    ) async -> (allowed: Bool, remember: Bool) {
        guard let window else { return (false, false) }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        if let rememberHost, !alwaysRemember {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remember for \(rememberHost)"
            alert.suppressionButton?.state = .off
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: (
                    response == .alertFirstButtonReturn,
                    alwaysRemember || alert.suppressionButton?.state == .on
                ))
            }
        }
    }

    // MARK: - Audio

    /// `mediaFrame {frame}` from the isolated media script: a document with
    /// the script started. A new main document drops every earlier frame.
    func handleMediaFrame(body: [String: Any], tab: BrowserTab, frame: WKFrameInfo) {
        guard let token = body["frame"] as? String, token.count <= 64 else { return }
        if frame.isMainFrame {
            tab.media.frames.removeAll()
            tab.media.audio.reset()
        }
        tab.media.frames[token] = frame
        if tab.isMuted {
            applyMute(tab, in: [frame])
        }
        updateAudio(tab)
    }

    /// `mediaState {frame, audible, gone}` from the isolated media script.
    func handleMediaState(body: [String: Any], tab: BrowserTab, frame: WKFrameInfo) {
        guard let token = body["frame"] as? String, token.count <= 64,
              let audible = body["audible"] as? Bool
        else { return }
        let gone = body["gone"] as? Bool ?? false
        if gone {
            tab.media.frames[token] = nil
        }
        tab.media.audio.report(frame: token, audible: audible, gone: gone)
        updateAudio(tab)
    }

    private func updateAudio(_ tab: BrowserTab) {
        let playing = tab.media.audio.isPlayingAudio
        guard tab.isPlayingAudio != playing else { return }
        tab.isPlayingAudio = playing
        metadataChanged(tab)
    }

    /// Applies `tab.isMuted` to the current page's frames and to every
    /// document the tab loads later.
    func applyMute(_ tab: BrowserTab) {
        refreshStateScripts(tab)
        var frames: [WKFrameInfo?] = Array(tab.media.frames.values)
        if !tab.media.frames.values.contains(where: \.isMainFrame) {
            frames.append(nil)
        }
        applyMute(tab, in: frames)
    }

    private func applyMute(_ tab: BrowserTab, in frames: [WKFrameInfo?]) {
        let muted = tab.isMuted
        for frame in frames {
            tab.webView.evaluateJavaScript(
                BrowserPermissionScripts.pageMuteSource(muted),
                in: frame,
                in: .page
            )
            tab.webView.evaluateJavaScript(
                BrowserPermissionScripts.isolatedMuteSource(muted),
                in: frame,
                in: BrowserPageScripts.isolatedWorld
            )
        }
    }

    // MARK: - Web notifications

    /// `notificationRequest {id}` from the page shim: answer from memory,
    /// deny when asking is off, otherwise ask once per host and remember.
    func handleNotificationRequest(body: [String: Any], tab: BrowserTab, frame: WKFrameInfo) {
        guard frame.isMainFrame, let id = body["id"] as? Int, id > 0 else { return }
        let waiter = BrowserPermissionsState.NotificationWaiter(tabID: tab.id, frame: frame, id: id)
        guard let host = BrowserSitePermissionStore.key(for: frame.securityOrigin) else {
            resolveNotificationRequests([waiter], state: .denied)
            return
        }
        let asking = settingsStore.settings.allowsNotificationRequests
        let state = NotificationPermissionState(
            decision: sitePermissions.decision(.notifications, host: host),
            askingAllowed: asking
        )
        guard state == .default else {
            resolveNotificationRequests([waiter], state: state)
            return
        }
        if permissionsState.notificationPrompts[host] != nil {
            permissionsState.notificationPrompts[host]?.append(waiter)
            return
        }
        permissionsState.notificationPrompts[host] = [waiter]
        Task { @MainActor [weak self] in
            guard let self else { return }
            let answer = await self.askPermission(
                title: host,
                message: "\(host) wants to send you notifications. They appear in Notification Center while the tab is open.",
                rememberHost: host,
                alwaysRemember: true
            )
            let waiters = self.permissionsState.notificationPrompts.removeValue(forKey: host) ?? []
            if answer.remember {
                self.sitePermissions.set(.notifications, answer.allowed ? .allow : .deny, host: host)
            }
            self.resolveNotificationRequests(waiters, state: answer.allowed ? .granted : .denied)
            if answer.allowed {
                _ = await BrowserNotificationCenter.shared.requestAuthorization()
            }
        }
    }

    private func resolveNotificationRequests(
        _ waiters: [BrowserPermissionsState.NotificationWaiter],
        state: NotificationPermissionState
    ) {
        for waiter in waiters {
            guard let tab = tabs.first(where: { $0.id == waiter.tabID }) else { continue }
            tab.webView.evaluateJavaScript(
                BrowserPermissionScripts.notificationCall("resolve", [waiter.id, state.rawValue]),
                in: waiter.frame,
                in: .page
            )
        }
    }

    /// `notificationShow {doc, id, title, body, tag, silent}`: posts to
    /// Notification Center when the host is allowed, then tells the page
    /// `show` or `error`.
    func handleNotificationShow(body: [String: Any], tab: BrowserTab, frame: WKFrameInfo) {
        guard frame.isMainFrame,
              let id = body["id"] as? Int, id > 0,
              let document = body["doc"] as? String, document.count <= 64
        else { return }
        let title = String((body["title"] as? String ?? "").prefix(512))
        let text = String((body["body"] as? String ?? "").prefix(2048))
        let tag = String((body["tag"] as? String ?? "").prefix(256))
        let silent = body["silent"] as? Bool ?? false
        let tabID = tab.id
        let acknowledge = { [weak self] (ok: Bool) in
            guard let self, let tab = self.tabs.first(where: { $0.id == tabID }) else { return }
            tab.webView.evaluateJavaScript(
                BrowserPermissionScripts.notificationCall("shown", [document, id, ok]),
                in: frame,
                in: .page
            )
        }
        guard let host = BrowserSitePermissionStore.key(for: frame.securityOrigin),
              sitePermissions.decision(.notifications, host: host) == .allow
        else {
            acknowledge(false)
            return
        }
        Task { @MainActor in
            do {
                try await BrowserNotificationCenter.shared.post(
                    tabID: tabID,
                    host: host,
                    document: document,
                    notificationID: id,
                    title: title,
                    body: text,
                    tag: tag,
                    silent: silent
                )
                acknowledge(true)
            } catch {
                acknowledge(false)
            }
        }
    }

    /// `notificationClose {doc, id, tag}`: the page closed its notification.
    func handleNotificationClose(body: [String: Any], tab: BrowserTab, frame: WKFrameInfo) {
        guard frame.isMainFrame,
              let id = body["id"] as? Int,
              let document = body["doc"] as? String
        else { return }
        BrowserNotificationCenter.shared.remove(
            tabID: tab.id,
            document: document,
            notificationID: id,
            tag: String((body["tag"] as? String ?? "").prefix(256))
        )
    }

    /// A click on a posted notification: bring the window forward, select
    /// the tab and fire the page's `click` handler.
    func openNotification(_ click: BrowserNotificationCenter.Click) {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        guard let tab = tabs.first(where: { $0.id == click.tabID }) else { return }
        selectTab(id: tab.id, focus: true)
        tab.webView.evaluateJavaScript(
            BrowserPermissionScripts.notificationCall("click", [click.document, click.notificationID]),
            in: nil,
            in: .page
        )
    }

    // MARK: - Settings ▸ Websites

    func showWebsites(on parent: NSWindow) {
        let sheet = permissionsState.websitesSheet
            ?? BrowserWebsitesSheet(store: sitePermissions, theme: theme)
        permissionsState.websitesSheet = sheet
        sheet.apply(theme: theme)
        sheet.reload()
        guard let window = sheet.window, window.sheetParent == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.permissionsState.websitesSheet = nil
        }
    }
}
