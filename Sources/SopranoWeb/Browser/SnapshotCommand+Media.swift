import AppKit
import WebKit

/// Snapshot flags for the Mini Player and the media controls (stage 4 P9):
/// - `--media-seed [file|url]` opens a page with a looping, muted,
///   autoplaying video in a new selected tab (without a value: a built-in
///   page with ffmpeg's test pattern as an MP4 when ffmpeg is installed,
///   else a canvas `captureStream`, which WebKit doesn't draw off screen;
///   with Media Session metadata, artwork and next/previous handlers) and
///   waits until it reports a playing, visible video. Runs before the
///   window flags, so `--cli "select-tab 1"` then leaves it.
/// - `--mini-player [return|close]` (after the window flags, repeatable):
///   presses the panel's Back to Tab or Close; without a value it prints
///   the `mini-player:` line only. The capture draws an open Mini Player
///   (with its controls) where its panel sits over the window.
/// - `--print-media`: one `media:` JSON line (every tab's media state,
///   sleep exemption and back list, the rail's and the toolbar's controls,
///   the Mini Player with its fill style and the page's own counters).
struct SnapshotMediaOptions {
    static let usage = """
                               [--media-seed [file|url]] [--mini-player [return|close]]... [--print-media]
    """
    static let flags: Set<String> = ["--media-seed", "--mini-player", "--print-media"]

    enum PanelAction: String {
        case report
        case `return`
        case close
    }

    var seed: String??
    var panelActions: [PanelAction] = []
    var printsMedia = false

    mutating func parse(_ flag: String, peek: () -> String?, skip: () -> Void) throws {
        let next = peek().flatMap { $0.hasPrefix("--") ? nil : $0 }
        switch flag {
        case "--media-seed":
            if let next { skip() }
            seed = .some(next)
        case "--mini-player":
            if let next, let action = PanelAction(rawValue: next), action != .report {
                skip()
                panelActions.append(action)
            } else {
                panelActions.append(.report)
            }
        default:
            printsMedia = true
        }
    }

    /// The built-in page: a canvas animation streamed into a muted,
    /// looping `<video>`, Media Session metadata with a `data:` artwork,
    /// and next/previous handlers that count in `window.__next` /
    /// `window.__previous`.
    static let seedPage = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Mini Player test</title>
        <style>body{margin:0;font:15px -apple-system;background:#f4efe6;color:#222}
        main{padding:24px}video{width:640px;height:360px;background:#000;display:block;border-radius:8px}</style>
        </head><body><main><h1>Mini Player test</h1>
        <video id="clip" muted autoplay loop playsinline></video>
        <p>A canvas streams into the video above.</p></main>
        <script>
        const canvas = document.createElement('canvas');
        canvas.width = 640; canvas.height = 360;
        const context = canvas.getContext('2d');
        let frame = 0;
        const draw = () => {
          frame += 1;
          const hue = (frame * 2) % 360;
          context.fillStyle = `hsl(${hue}, 60%, 45%)`;
          context.fillRect(0, 0, 640, 360);
          context.fillStyle = '#fff';
          context.font = 'bold 48px -apple-system';
          context.fillText('Soprano clip ' + frame, 40, 190);
          requestAnimationFrame(draw);
        };
        draw();
        const art = document.createElement('canvas');
        art.width = 96; art.height = 96;
        const artContext = art.getContext('2d');
        artContext.fillStyle = '#b5532c'; artContext.fillRect(0, 0, 96, 96);
        artContext.fillStyle = '#fff'; artContext.font = 'bold 56px -apple-system'; artContext.fillText('S', 30, 68);
        const video = document.getElementById('clip');
        if (!video.getAttribute('src')) {
          video.srcObject = canvas.captureStream(30);
          video.play().catch(() => {});
        }
        window.__next = 0; window.__previous = 0;
        navigator.mediaSession.metadata = new MediaMetadata({
          title: 'Soprano Test Clip', artist: 'Soprano Web', album: 'Mini Player',
          artwork: [{ src: art.toDataURL('image/png'), sizes: '96x96', type: 'image/png' }],
        });
        navigator.mediaSession.setActionHandler('nexttrack', () => { window.__next += 1; });
        navigator.mediaSession.setActionHandler('previoustrack', () => { window.__previous += 1; });
        </script></body></html>
        """

    /// `--media-seed`: the page in a new selected tab, waited on.
    @MainActor
    func runSeed(controller: BrowserWindowController, directory: URL, wait: (TimeInterval) -> Void) {
        guard let seed else { return }
        let url: URL
        if let value = seed {
            let file = URL(fileURLWithPath: value)
            if FileManager.default.fileExists(atPath: file.path) {
                url = file
            } else if let resolved = BrowserAddressResolver.resolve(
                value,
                searchEngines: controller.settingsStore.settings.searchEngines
            ) {
                url = resolved
            } else {
                print("media-seed: bad address \(value)")
                return
            }
        } else {
            url = directory.appendingPathComponent("media-seed.html")
            // A real MP4 (ffmpeg's test pattern) when ffmpeg is installed:
            // WebKit draws no canvas `captureStream` frames off screen.
            let clip = directory.appendingPathComponent("media-seed.mp4")
            let page = Self.makeClip(at: clip)
                ? Self.seedPage.replacingOccurrences(
                    of: "<video id=\"clip\" muted",
                    with: "<video id=\"clip\" src=\"media-seed.mp4\" muted"
                )
                : Self.seedPage
            try? Data(page.utf8).write(to: url, options: .atomic)
        }
        let tab = controller.newTab(url: url.absoluteString)
        let start = Date()
        let deadline = start.addingTimeInterval(15)
        while !tab.media.info.hasVisibleVideo, Date() < deadline {
            wait(0.1)
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
        print(tab.media.info.hasVisibleVideo
            ? "media-seed: \(url.lastPathComponent) plays a visible video after \(seconds)s"
            : "media-seed: \(url.lastPathComponent) no visible video after \(seconds)s (playing \(tab.media.info.isPlaying))")
    }

    /// A 4 s, 640×360 H.264 test pattern through ffmpeg; false without it.
    static func makeClip(at url: URL) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map { "\($0)/ffmpeg" } + ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        guard let ffmpeg = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30:duration=4",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-an", url.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
    }

    /// `--mini-player` actions and `--print-media`, on the captured window.
    @MainActor
    func run(controller: BrowserWindowController, wait: (TimeInterval) -> Void) {
        let player = controller.manager.miniPlayer
        for action in panelActions {
            switch action {
            case .report: break
            case .return: player.panel?.playerView.returnPressed()
            case .close: player.panel?.playerView.closePressed()
            }
            wait(0.8)
            print("mini-player: \(action.rawValue) -> \(Self.panelLine(controller))")
        }
        if printsMedia {
            print("media: \(Self.mediaJSON(controller, wait: wait))")
        }
    }

    @MainActor
    static func panelLine(_ controller: BrowserWindowController) -> String {
        let player = controller.manager.miniPlayer
        guard player.isOpen, let tab = player.tab, let panel = player.panel else { return "closed" }
        let offset = controller.manager.placement.offset
        let frame = panel.frame.offsetBy(dx: -offset.x, dy: -offset.y)
        return "open \(tab.displayTitle) \(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY))"
    }
}

extension SnapshotMediaOptions {
    /// Runs `source` in `tab`'s page (`world`) and waits for the answer.
    @MainActor
    static func evaluate(_ source: String, in tab: BrowserTab, world: WKContentWorld, wait: (TimeInterval) -> Void) -> Any? {
        var answer: Any?
        var finished = false
        tab.webView.evaluateJavaScript(source, in: nil, in: world) { result in
            answer = try? result.get()
            finished = true
        }
        let deadline = Date().addingTimeInterval(3)
        while !finished, Date() < deadline {
            wait(0.05)
        }
        return answer
    }

    @MainActor
    static func mediaJSON(_ controller: BrowserWindowController, wait: (TimeInterval) -> Void) -> String {
        let player = controller.manager.miniPlayer
        let tabs = controller.tabs.enumerated().map { index, tab -> [String: Any] in
            let info = tab.media.info
            let current = info.current
            var entry: [String: Any] = [
                "n": index + 1,
                "title": tab.displayTitle,
                "playing": info.isPlaying,
                "hasMedia": info.hasMedia,
                "video": info.hasVisibleVideo,
                "audible": current?.isAudible ?? false,
                "muted": tab.isMuted,
                "selected": tab.id == controller.selectedTab?.id,
                "hidden": tab.webView.isHidden,
                "inMiniPlayer": player.hosts(tab),
                "inPageArea": tab.webView.superview === controller.webArea,
                "backCount": tab.webView.backForwardList.backList.count,
                "awake": controller.sleepExemption(tab)?.rawValue ?? "idle",
                "archive": controller.archiveExemption(tab)?.rawValue ?? "none",
                "miniPlayerRule": controller.miniPlayerDecision(tab, shown: []).rawValue,
            ]
            if let current {
                entry["session"] = [
                    "title": current.title, "artist": current.artist, "album": current.album,
                    "state": current.sessionState.rawValue,
                    "artwork": String(current.artwork.prefix(40)),
                    "artworkLoaded": tab.media.artwork != nil,
                ] as [String: Any]
            }
            if info.hasMedia || info.isPlaying {
                let page = evaluate(
                    "JSON.stringify({next: window.__next ?? null, previous: window.__previous ?? null, paused: Array.from(document.querySelectorAll('video, audio')).map((e) => e.paused)})",
                    in: tab, world: .page, wait: wait
                ) as? String
                entry["page"] = page ?? ""
                entry["fill"] = evaluate(BrowserMediaScripts.fillStateSource, in: tab, world: BrowserPageScripts.isolatedWorld, wait: wait) as? String ?? ""
            }
            return entry
        }
        func controls(_ view: BrowserMediaControlsView) -> Any {
            guard let item = view.item, !view.isHidden else { return NSNull() }
            return [
                "title": item.title, "subtitle": item.subtitle, "playing": item.isPlaying,
                "muted": item.isMuted, "canSkip": item.canSkip, "inMiniPlayer": item.inMiniPlayer,
                "artwork": item.image != nil,
            ] as [String: Any]
        }
        var mini: [String: Any] = ["state": panelLine(controller)]
        if let tab = player.tab, player.isOpen {
            mini["webViewInPanel"] = tab.webView.window === player.panel
            mini["navigationDelegate"] = tab.webView.navigationDelegate === controller
            mini["uiDelegate"] = tab.webView.uiDelegate === controller
        }
        mini["remembered"] = player.rememberedFrame.map(NSStringFromRect) ?? NSNull()
        let object: [String: Any] = [
            "tabs": tabs,
            "rail": controls(controller.verticalTabsView.mediaControls),
            "toolbar": controls(controller.toolbar.mediaControls),
            "miniPlayer": mini,
            "setting": controller.settingsStore.settings.miniPlayer,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// An open Mini Player as the capture draws it: the page's snapshot,
    /// its controls and where the panel sits over the window (its
    /// bottom-right corner when it lies elsewhere).
    struct MiniPlayerImage {
        let page: NSImage?
        let controls: NSImage?
        let rect: NSRect
    }

    /// Taken before the capture draws (it waits on WebKit).
    @MainActor
    static func miniPlayerImage(
        _ controller: BrowserWindowController,
        window: NSWindow,
        in content: NSView,
        wait: (TimeInterval) -> Void
    ) -> MiniPlayerImage? {
        let player = controller.manager.miniPlayer
        guard player.isOpen, let tab = player.tab, let panel = player.panel else { return nil }
        let view = panel.playerView
        view.pinsControls = true
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        var page: NSImage?
        var finished = false
        tab.webView.takeSnapshot(with: nil) { image, _ in
            page = image
            finished = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !finished, Date() < deadline {
            wait(0.05)
        }
        var controls: NSImage?
        if let rep = view.controls.bitmapImageRepForCachingDisplay(in: view.controls.bounds) {
            view.controls.cacheDisplay(in: view.controls.bounds, to: rep)
            let image = NSImage(size: view.controls.bounds.size)
            image.addRepresentation(rep)
            controls = image
        }
        var rect = panel.frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        if !content.bounds.contains(rect) {
            rect = BrowserMiniPlayerFrame.defaultFrame(in: content.bounds)
        }
        return MiniPlayerImage(page: page, controls: controls, rect: rect)
    }

    /// Draws `image` into the focused capture.
    @MainActor
    static func draw(_ image: MiniPlayerImage) {
        let rect = image.rect
        let path = NSBezierPath(roundedRect: rect, xRadius: Chrome.Radius.panel, yRadius: Chrome.Radius.panel)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.black.setFill()
        rect.fill()
        image.page?.draw(in: rect)
        image.controls?.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        path.stroke()
    }
}
