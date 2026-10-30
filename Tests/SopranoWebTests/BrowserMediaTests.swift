@testable import SopranoWeb
import AppKit
import Testing

/// The Mini Player's and the media controls' pure parts: report parsing,
/// the per-tab reducer, the trigger rule, the panel frame, which tab the
/// controls show, the sleep/archive exemptions and the CLI's parsing.
@MainActor
struct BrowserMediaTests {
    @Test func aReportReadsTheSessionAndCapsWhatThePageSent() throws {
        let report = try #require(BrowserMediaReport(body: [
            "frame": "abc123", "playing": true, "video": true, "audible": false, "media": true,
            "title": "  Song\nTitle  ", "artist": "Artist", "album": String(repeating: "a", count: 400),
            "artwork": "https://cdn.example/art.png", "state": "playing",
        ]))
        #expect(report.frame == "abc123")
        #expect(report.isPlaying && report.hasVisibleVideo && !report.isAudible && report.hasMedia)
        #expect(report.title == "Song Title")
        #expect(report.album.count == BrowserMediaReport.maxText)
        #expect(report.artwork == "https://cdn.example/art.png")
        #expect(report.sessionState == .playing)
        #expect(report.hasSessionMetadata)
    }

    @Test func aReportRefusesBadFramesAndUnsafeArtwork() throws {
        #expect(BrowserMediaReport(body: ["playing": true]) == nil)
        #expect(BrowserMediaReport(body: ["frame": ""]) == nil)
        #expect(BrowserMediaReport(body: ["frame": String(repeating: "f", count: 65)]) == nil)
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,<b>", "https://", "blob:https://a/b", 42] as [Any] {
            let report = try #require(BrowserMediaReport(body: ["frame": "f", "artwork": bad]))
            #expect(report.artwork.isEmpty)
        }
        let data = try #require(BrowserMediaReport(body: ["frame": "f", "artwork": "data:image/png;base64,AAAA"]))
        #expect(data.artwork == "data:image/png;base64,AAAA")
        let huge = "data:image/png;base64," + String(repeating: "A", count: BrowserMediaReport.maxArtworkLength)
        #expect(try #require(BrowserMediaReport(body: ["frame": "f", "artwork": huge])).artwork.isEmpty)
        // A video or audio that isn't playing is neither; an unknown state is none.
        let paused = try #require(BrowserMediaReport(body: ["frame": "f", "playing": false, "video": true, "audible": true, "state": "loud"]))
        #expect(!paused.hasVisibleVideo && !paused.isAudible && !paused.hasMedia)
        #expect(paused.sessionState == .none)
        // Gone drops what it had.
        let gone = try #require(BrowserMediaReport(body: ["frame": "f", "gone": true, "media": true]))
        #expect(gone.isGone && !gone.hasMedia)
    }

    private func report(_ frame: String, playing: Bool = false, video: Bool = false, media: Bool = false, title: String = "") -> BrowserMediaReport {
        var report = BrowserMediaReport(frame: frame)
        report.isPlaying = playing
        report.hasVisibleVideo = playing && video
        report.hasMedia = media || playing
        report.title = title
        return report
    }

    @Test func theMainFrameWinsAndAnEmbeddedPlayerIsTheFallback() {
        var info = BrowserTabMediaInfo()
        info.update(report("main"), isMainFrame: true)
        info.update(report("embed", playing: true, video: true, title: "Embedded"), isMainFrame: false)
        // The main frame has nothing: the frame that plays shows.
        #expect(info.current?.frame == "embed")
        #expect(info.isPlaying && info.hasMedia)
        // Only the main frame's video fills a Mini Player.
        #expect(!info.hasVisibleVideo)
        info.update(report("main", playing: true, video: true, title: "Main"), isMainFrame: true)
        #expect(info.current?.title == "Main")
        #expect(info.hasVisibleVideo)
        // The embed's document goes: its report goes with it.
        var gone = BrowserMediaReport(frame: "embed")
        gone.isGone = true
        info.update(gone, isMainFrame: false)
        #expect(info.reports["embed"] == nil)
        // A new main document replaces the old one's report.
        info.update(report("main2"), isMainFrame: true)
        #expect(info.reports["main"] == nil)
        #expect(info.mainFrame == "main2")
        #expect(!info.isPlaying)
        info.reset()
        #expect(info == BrowserTabMediaInfo())
    }

    @Test func theRuleMovesOnlyAPlayingVisibleVideoThatLeavesTheScreen() {
        let playing = BrowserMiniPlayerCandidate(isEnabled: true, hasVisibleVideo: true, isPlaying: true)
        #expect(BrowserMiniPlayerRule.decide(playing) == .open)
        var candidate = playing
        candidate.isEnabled = false
        #expect(BrowserMiniPlayerRule.decide(candidate) == .disabled)
        candidate = playing
        candidate.hasVisibleVideo = false
        // Audio only: the controls show it, no panel.
        #expect(BrowserMiniPlayerRule.decide(candidate) == .noVideo)
        candidate = playing
        candidate.isPlaying = false
        #expect(BrowserMiniPlayerRule.decide(candidate) == .noVideo)
        candidate = playing
        candidate.isPeek = true
        #expect(BrowserMiniPlayerRule.decide(candidate) == .peek)
        candidate = playing
        candidate.staysVisible = true
        #expect(BrowserMiniPlayerRule.decide(candidate) == .visible)
        candidate = playing
        candidate.isPopup = true
        #expect(BrowserMiniPlayerRule.decide(candidate) == .popup)
    }

    @Test func thePanelOpensBottomRightOrWhereItWasLeft() {
        let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let frame = BrowserMiniPlayerFrame.defaultFrame(in: screen)
        #expect(frame == NSRect(x: 1440 - 20 - 400, y: 45, width: 400, height: 225))
        // A short screen keeps the panel at most half its height.
        let short = BrowserMiniPlayerFrame.defaultFrame(in: NSRect(x: 0, y: 0, width: 1000, height: 300))
        #expect(short.height <= 150 && short.height >= BrowserMiniPlayerFrame.minimumSize.height)
        // A remembered frame on a screen wins; one off every screen or too small doesn't.
        let moved = NSRect(x: 100, y: 500, width: 480, height: 270)
        #expect(BrowserMiniPlayerFrame.frame(remembered: moved, screens: [screen], fallback: screen) == moved)
        let gone = NSRect(x: 5000, y: 500, width: 480, height: 270)
        #expect(BrowserMiniPlayerFrame.frame(remembered: gone, screens: [screen], fallback: screen) == frame)
        let tiny = NSRect(x: 100, y: 500, width: 100, height: 50)
        #expect(BrowserMiniPlayerFrame.frame(remembered: tiny, screens: [screen], fallback: screen) == frame)
        #expect(BrowserMiniPlayerFrame.rect(BrowserMiniPlayerFrame.string(moved)) == moved)
        #expect(BrowserMiniPlayerFrame.rect("") == nil)
        #expect(BrowserMiniPlayerFrame.rect("nonsense") == nil)
    }

    @Test func theControlsShowAnOffScreenTabPlayingFirst() {
        let now = Date()
        let a = UUID(), b = UUID(), c = UUID()
        typealias Entry = BrowserMediaTabChoice.Entry
        // The shown tab never; a playing one before a paused newer one.
        #expect(BrowserMediaTabChoice.pick([
            Entry(id: a, isShown: true, isPlaying: true, hasMedia: true, changedAt: now),
            Entry(id: b, isShown: false, isPlaying: false, hasMedia: true, changedAt: now),
            Entry(id: c, isShown: false, isPlaying: true, hasMedia: true, changedAt: now.addingTimeInterval(-60)),
        ]) == c)
        // Among paused ones the most recent; nothing without media.
        #expect(BrowserMediaTabChoice.pick([
            Entry(id: a, isShown: false, isPlaying: false, hasMedia: true, changedAt: now.addingTimeInterval(-5)),
            Entry(id: b, isShown: false, isPlaying: false, hasMedia: true, changedAt: now),
            Entry(id: c, isShown: false, isPlaying: false, hasMedia: false, changedAt: now.addingTimeInterval(5)),
        ]) == b)
        #expect(BrowserMediaTabChoice.pick([Entry(id: a, isShown: true, isPlaying: true, hasMedia: true, changedAt: now)]) == nil)
    }

    @Test func aMiniPlayerTabNeitherSleepsNorArchives() {
        let candidate = BrowserTabSleepCandidate(isInMiniPlayer: true, lastActive: .distantPast)
        #expect(BrowserTabSleepPolicy.exemption(for: candidate) == .miniPlayer)
        #expect(!BrowserTabSleepPolicy.shouldSleep(candidate, now: Date(), idleThreshold: 1))
        let archive = BrowserArchiveCandidate(activity: candidate)
        #expect(BrowserArchivePolicy.exemption(for: archive) == .miniPlayer)
    }

    @Test func theCLIParsesMediaWords() throws {
        func parse(_ words: [String]) throws -> BrowserCommandRequest? {
            try BrowserCommandRequest.parse(["soprano-web", "browser"] + words, environment: [:])
        }
        #expect(try parse(["media"])?.command == "media")
        for word in ["info", "play", "pause", "next", "previous", "mute"] {
            #expect(try parse(["media", word])?.arguments == [word])
        }
        #expect(try parse(["--tab", "2", "media", "pause"])?.tabIndex == 2)
        #expect(throws: BrowserAutomationError.self) { try parse(["media", "skip"]) }
        #expect(throws: BrowserAutomationError.self) { try parse(["media", "play", "now"]) }
        #expect(BrowserMediaAction(word: "next") == .next)
        #expect(BrowserMediaAction.next.rawValue == "nexttrack")
        #expect(BrowserMediaAction(word: "nexttrack") == nil)
        #expect(BrowserCommand.help.contains("media [info|play|pause|next|previous|mute]"))
    }

    @Test func theSettingIsOnByDefaultAndDecodesKeyByKey() throws {
        #expect(BrowserSettings.default.miniPlayer)
        let off = try JSONDecoder().decode(BrowserSettings.self, from: Data(#"{"miniPlayer": false}"#.utf8))
        #expect(!off.miniPlayer)
        let bad = try JSONDecoder().decode(BrowserSettings.self, from: Data(#"{"miniPlayer": "no", "homepage": "x"}"#.utf8))
        #expect(bad.miniPlayer && bad.homepage == "x")
    }
}
