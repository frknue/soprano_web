import AppKit
import WebKit

/// Media controls and the Mini Player (stage 4 P9). Each frame's isolated
/// `BrowserMediaScripts.reporter` posts `mediaInfo`; the rail's bottom (or
/// the toolbar without a rail) shows the off-screen tab that plays, and
/// leaving a tab with a playing, visible video moves its web view into
/// the manager's `BrowserMiniPlayer` until the tab comes back on screen.
extension BrowserWindowController {
    // MARK: - Reports

    /// `mediaInfo` from the isolated media script.
    func handleMediaInfo(body: [String: Any], tab: BrowserTab, frame: WKFrameInfo) {
        guard let report = BrowserMediaReport(body: body) else { return }
        let before = tab.media.info
        tab.media.info.update(report, isMainFrame: frame.isMainFrame)
        guard tab.media.info != before else { return }
        tab.media.changedAt = Date()
        // A new document in the Mini Player fills it too.
        if manager.miniPlayer.hosts(tab), frame.isMainFrame, report.isPlaying,
           tab.media.filledFrame != report.frame
        {
            tab.media.filledFrame = report.frame
            setMiniPlayerFill(true, in: tab)
        }
        mediaChanged(tab)
    }

    /// A new main document: its media starts over.
    func resetMediaInfo(_ tab: BrowserTab) {
        guard tab.media.info != BrowserTabMediaInfo() else { return }
        tab.media.info.reset()
        tab.media.changedAt = Date()
        mediaChanged(tab)
    }

    /// The tab's media changed: artwork, the controls and the panel.
    func mediaChanged(_ tab: BrowserTab) {
        loadMediaArtwork(tab)
        if manager.miniPlayer.hosts(tab) {
            manager.miniPlayer.update(title: mediaTitle(of: tab), isPlaying: tab.media.info.isPlaying)
        }
        updateMediaControls()
    }

    /// The artwork of the current report, fetched once per address
    /// (ephemeral session, no cookies, at most 2 MB); `data:` decodes here.
    private func loadMediaArtwork(_ tab: BrowserTab) {
        let address = tab.media.info.current?.artwork ?? ""
        guard !address.isEmpty else {
            tab.media.artwork = nil
            return
        }
        guard tab.media.artwork?.url != address, let url = URL(string: address) else { return }
        if url.scheme?.lowercased() == "data" {
            tab.media.artwork = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:)).map { (address, $0) }
            return
        }
        BrowserMediaArtwork.fetch(url) { [weak self, weak tab] image in
            guard let self, let tab, let image, tab.media.info.current?.artwork == address else { return }
            tab.media.artwork = (address, image)
            self.mediaChanged(tab)
        }
    }

    // MARK: - Controls

    /// The tab the media controls show: off screen (or in the Mini
    /// Player) with media, playing first.
    var mediaControlTab: BrowserTab? {
        let shown = shownTabs
        let entries = tabs.map { tab in
            BrowserMediaTabChoice.Entry(
                id: tab.id,
                isShown: shown.contains { $0 === tab } && !manager.miniPlayer.hosts(tab),
                isPlaying: tab.media.info.isPlaying,
                hasMedia: tab.media.info.hasMedia,
                changedAt: tab.media.changedAt
            )
        }
        return BrowserMediaTabChoice.pick(entries).flatMap { id in tabs.first { $0.id == id } }
    }

    func mediaTitle(of tab: BrowserTab) -> String {
        let session = tab.media.info.current?.title ?? ""
        return session.isEmpty ? tab.displayTitle : session
    }

    func mediaControlItem(for tab: BrowserTab) -> BrowserMediaControlItem {
        let current = tab.media.info.current
        let artist = [current?.artist, current?.album].compactMap { $0 }.first { !$0.isEmpty }
        let host = tab.item.url?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        return BrowserMediaControlItem(
            tabID: tab.id,
            title: mediaTitle(of: tab),
            subtitle: artist ?? (current?.title.isEmpty == false ? tab.displayTitle : host ?? ""),
            isPlaying: tab.media.info.isPlaying,
            isMuted: tab.isMuted,
            canSkip: current?.hasSessionMetadata ?? false,
            inMiniPlayer: manager.miniPlayer.hosts(tab),
            image: tab.media.artwork?.image ?? tab.favicon
        )
    }

    /// The rail's bar with a rail on screen, else the toolbar's chip.
    func updateMediaControls() {
        let item = mediaControlTab.map(mediaControlItem(for:))
        let railShown = !verticalTabsView.isHidden
        verticalTabsView.setMedia(railShown ? item : nil)
        toolbar.setMedia(railShown ? nil : item)
    }

    func wireMediaControls() {
        for controls in [verticalTabsView.mediaControls, toolbar.mediaControls] {
            controls.onSelect = { [weak self] id in self?.selectTab(id: id, focus: true) }
            controls.onPlayPause = { [weak self] id in
                guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }
                self.performMediaAction(tab.media.info.isPlaying ? .pause : .play, on: tab)
            }
            controls.onNext = { [weak self] id in
                guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }
                self.performMediaAction(.next, on: tab)
            }
            controls.onMute = { [weak self] id in
                guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }
                self.toggleMute(tab)
            }
        }
    }

    /// Runs `action` in every frame of the tab's page that runs the media
    /// script; `completion` gets whether the main frame took it.
    func performMediaAction(_ action: BrowserMediaAction, on tab: BrowserTab, completion: ((Bool) -> Void)? = nil) {
        tabWasUsed(tab)
        let source = BrowserMediaScripts.controlSource(action)
        let subframes = tab.media.frames.values.filter { !$0.isMainFrame }
        for frame in subframes {
            tab.webView.evaluateJavaScript(source, in: frame, in: BrowserPageScripts.isolatedWorld)
        }
        tab.webView.evaluateJavaScript(source, in: nil, in: BrowserPageScripts.isolatedWorld) { result in
            MainActor.assumeIsolated {
                completion?((try? result.get()) as? Bool ?? false)
            }
        }
    }

    // MARK: - Mini Player

    /// What the Mini Player rule decides for `tab` leaving the screen
    /// while `shown` comes on.
    func miniPlayerDecision(_ tab: BrowserTab, shown: [BrowserTab]) -> BrowserMiniPlayerDecision {
        BrowserMiniPlayerRule.decide(BrowserMiniPlayerCandidate(
            isEnabled: settingsStore.settings.miniPlayer,
            hasVisibleVideo: tab.media.info.hasVisibleVideo,
            isPlaying: tab.media.info.isPlaying,
            isPeek: tab === peek?.tab,
            staysVisible: shown.contains { $0 === tab },
            isPopup: role == .popup
        ))
    }

    /// `leaving` (the page of `previous`) leaves the screen while `shown`
    /// comes on: the first of them (`previous` first) whose playing video
    /// the rule moves goes into the Mini Player.
    func miniPlayerLeaving(_ leaving: [BrowserTab], previous: BrowserTab, shown: [BrowserTab]) {
        let ordered = [previous] + leaving.filter { $0 !== previous }
        for tab in ordered where tabs.contains(where: { $0 === tab }) && !manager.miniPlayer.hosts(tab) {
            if miniPlayerDecision(tab, shown: shown) == .open {
                openMiniPlayer(for: tab)
                return
            }
        }
    }

    /// Moves `tab`'s web view into the Mini Player (another tab there
    /// goes back to its window first) and fills the panel with its video.
    func openMiniPlayer(for tab: BrowserTab) {
        let player = manager.miniPlayer
        if player.isOpen {
            player.controller?.returnMiniPlayer()
        }
        player.show(tab, from: self, theme: theme, persistsFrame: !kind.isPrivate)
        tab.media.filledFrame = tab.media.info.mainFrame
        setMiniPlayerFill(true, in: tab)
        updateMediaControls()
    }

    func setMiniPlayerFill(_ on: Bool, in tab: BrowserTab) {
        tab.webView.evaluateJavaScript(
            BrowserMediaScripts.fillSource(on),
            in: nil,
            in: BrowserPageScripts.isolatedWorld
        )
    }

    /// Puts this window's Mini Player tab back in the page area (hidden
    /// until it is shown), without its fill style.
    func returnMiniPlayer() {
        let player = manager.miniPlayer
        guard player.controller === self, let tab = player.takeBack() else { return }
        tab.media.filledFrame = nil
        setMiniPlayerFill(false, in: tab)
        if tabs.contains(where: { $0 === tab }) {
            installWebView(tab.webView)
            applyPaneLayout()
        }
        updateMediaControls()
    }

    /// The Mini Player's tab is among `tabs` coming on screen: it returns.
    func returnMiniPlayerIfShown(_ tabs: [BrowserTab]) {
        let player = manager.miniPlayer
        guard player.controller === self, let tab = player.tab, tabs.contains(where: { $0 === tab }) else { return }
        returnMiniPlayer()
    }

    /// `tab` leaves the window (unbound): out of the Mini Player, not
    /// back into the page area.
    func releaseMiniPlayer(of tab: BrowserTab) {
        let player = manager.miniPlayer
        guard player.hosts(tab) else { return }
        player.takeBack()
        tab.media.filledFrame = nil
        setMiniPlayerFill(false, in: tab)
    }

    /// The panel's "Back to Tab": the window comes forward on the tab.
    func returnToMiniPlayerTab(_ tab: BrowserTab) {
        if !manager.placement.isOffscreen {
            NSApp.activate()
        }
        manager.present(self)
        selectTab(id: tab.id, focus: true)
        if manager.miniPlayer.hosts(tab) {
            returnMiniPlayer()
        }
    }

    /// The panel's Close: pauses the page and puts it back in its window.
    func closeMiniPlayer(pausing tab: BrowserTab) {
        performMediaAction(.pause, on: tab)
        tab.webView.pauseAllMediaPlayback {}
        returnMiniPlayer()
    }

    // MARK: - CLI

    /// `browser media [info|play|pause|next|previous|mute]` on `tab`
    /// (`--tab n`), else the tab the controls show, else the selected tab
    /// when it has media.
    func performMediaCommand(
        _ arguments: [String],
        tab requested: BrowserTab?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let selected = selectedTab.flatMap { $0.media.info.hasMedia || $0.media.info.isPlaying ? $0 : nil }
        guard let tab = requested ?? mediaControlTab ?? selected else {
            completion(.failure(BrowserAutomationError.unavailable("No tab plays media.")))
            return
        }
        let word = arguments.first ?? "info"
        switch word {
        case "info":
            completion(.success(mediaInfoLines(for: tab).joined(separator: "\n")))
        case "mute":
            toggleMute(tab)
            completion(.success(tab.isMuted ? "muted" : "unmuted"))
        default:
            guard let action = BrowserMediaAction(word: word) else {
                completion(.failure(BrowserAutomationError.invalidArguments(BrowserCommandRequest.mediaUsage)))
                return
            }
            performMediaAction(action, on: tab) { [weak self, weak tab] taken in
                // The page's state settles (its events are debounced).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    MainActor.assumeIsolated {
                        guard let self, let tab else { return }
                        let lines = ["\(word): \(taken ? "sent" : "nothing took it")"] + self.mediaInfoLines(for: tab)
                        completion(.success(lines.joined(separator: "\n")))
                    }
                }
            }
        }
    }

    /// `media info`: the tab, its state, the Media Session and the Mini
    /// Player.
    func mediaInfoLines(for tab: BrowserTab) -> [String] {
        let info = tab.media.info
        let current = info.current
        let number = visibleTabs.firstIndex { $0 === tab }.map { "tab \($0 + 1)" }
            ?? tab.spaceID.flatMap(spaces.space(id:)).map { "Space \($0.displayName)" } ?? "tab"
        let state = info.isPlaying ? "playing" : info.hasMedia ? "paused" : "none"
        var lines = [
            "\(number): \(tab.displayTitle)",
            "url: \(tab.item.url?.absoluteString ?? "")",
            "state: \(state)\(current.map { " (session \($0.sessionState.rawValue))" } ?? "")",
            "video: \(info.hasVisibleVideo ? "visible" : "none")",
            "audible: \(current?.isAudible == true ? "yes" : "no"), muted: \(tab.isMuted ? "yes" : "no")",
        ]
        if let current, current.hasSessionMetadata || !current.artwork.isEmpty {
            lines.append("session: \([current.title, current.artist, current.album].filter { !$0.isEmpty }.joined(separator: " — "))")
            if !current.artwork.isEmpty {
                lines.append("artwork: \(current.artwork.prefix(120))\(tab.media.artwork == nil ? "" : " (loaded)")")
            }
        }
        let player = manager.miniPlayer
        if player.hosts(tab), let frame = player.panel?.frame {
            let origin = manager.placement.isOffscreen
                ? NSPoint(x: frame.minX - manager.placement.offset.x, y: frame.minY - manager.placement.offset.y)
                : frame.origin
            lines.append("mini-player: open \(Int(frame.width))x\(Int(frame.height)) at \(Int(origin.x)),\(Int(origin.y))")
        } else {
            lines.append("mini-player: \(player.isOpen ? "open (another tab)" : "closed")")
        }
        let exemption = sleepExemption(tab)
        lines.append("awake: \(exemption?.rawValue ?? "idle")")
        return lines
    }
}

/// Fetches Media Session artwork for the controls: an ephemeral session
/// (no cookies or cache on disk), images up to 2 MB, a small memory cache.
@MainActor
enum BrowserMediaArtwork {
    nonisolated static let maxBytes = 2 * 1024 * 1024
    private static let session = URLSession(configuration: .ephemeral)
    private static var cache: [URL: NSImage] = [:]

    static func fetch(_ url: URL, completion: @escaping @MainActor (NSImage?) -> Void) {
        if let image = cache[url] {
            completion(image)
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        session.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let bytes = ok && (data?.count ?? 0) <= maxBytes ? data : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let image = bytes.flatMap(NSImage.init(data:))
                    if let image {
                        if cache.count > 32 { cache.removeAll() }
                        cache[url] = image
                    }
                    completion(image)
                }
            }
        }.resume()
    }
}
