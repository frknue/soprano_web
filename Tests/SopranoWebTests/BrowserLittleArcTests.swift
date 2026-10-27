@testable import SopranoWeb
import AppKit
import Testing

/// Little Arc's rules: where links from other apps go, where its tab lands
/// (⌘O and its new tabs), its frame and when the idle pass closes it.
struct BrowserLittleArcTests {
    private let meet = BrowserLinkRoutingRule(match: .contains, value: "meet.example", destination: .mostRecentSpace)

    // MARK: Links from other apps

    @Test func aMatchingRuleWinsOverTheSetting() {
        for setting in BrowserOutsideLinkDestination.allCases {
            #expect(BrowserLinkRouting.route(for: "https://meet.example/abc", rules: [meet], otherLinks: setting) == .rule(meet))
        }
    }

    @Test func otherLinksFollowTheSetting() {
        #expect(BrowserLinkRouting.route(for: "https://news.example/", rules: [meet], otherLinks: .littleArc) == .littleArc)
        #expect(BrowserLinkRouting.route(for: "https://news.example/", rules: [meet], otherLinks: .mostRecentWindow)
            == .mostRecentWindow)
        #expect(BrowserLinkRouting.route(for: "https://news.example/", rules: [], otherLinks: .littleArc) == .littleArc)
    }

    @Test func theRoutingFileKeepsTheChoiceAndDefaultsToLittleArc() throws {
        let file = BrowserLinkRoutingFile(rules: [meet], otherLinks: .mostRecentWindow)
        let data = try JSONEncoder().encode(file)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["otherLinks"] as? String == "mostRecentWindow")
        #expect(try JSONDecoder().decode(BrowserLinkRoutingFile.self, from: data) == file)
        // A file from before the choice, or with an unknown value: Little Arc.
        let old = try JSONDecoder().decode(BrowserLinkRoutingFile.self, from: Data(#"{"version": 1, "rules": []}"#.utf8))
        #expect(old.otherLinks == .littleArc)
        let odd = try JSONDecoder().decode(
            BrowserLinkRoutingFile.self,
            from: Data(#"{"version": 1, "otherLinks": "teleport", "rules": []}"#.utf8)
        )
        #expect(odd.otherLinks == .littleArc)
    }

    @MainActor
    @Test func theStoreSavesTheChoice() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebRouting-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BrowserLinkRoutingStore(url: url)
        #expect(store.otherLinks == .littleArc)
        var changes = 0
        let observation = store.changes.observe { changes += 1 }
        store.setOtherLinks(.mostRecentWindow)
        store.setOtherLinks(.mostRecentWindow)
        #expect(changes == 1)
        #expect(BrowserLinkRoutingStore(url: url).otherLinks == .mostRecentWindow)
        withExtendedLifetime(observation) {}
    }

    // MARK: Landing (⌘O, new tabs)

    private let work = UUID()
    private let home = UUID()

    @Test func aWindowShowingTheSpaceWinsEvenWhenNotMostRecent() {
        let recent = BrowserLittleArcLanding.Window(id: UUID(), takesTabs: true, currentSpaceID: home)
        let showing = BrowserLittleArcLanding.Window(id: UUID(), takesTabs: true, currentSpaceID: work)
        #expect(BrowserLittleArcLanding.target(space: work, windows: [recent, showing]) == .showing(showing.id))
    }

    @Test func otherwiseTheMostRecentNormalWindowSwitches() {
        let little = BrowserLittleArcLanding.Window(id: UUID(), takesTabs: false, currentSpaceID: nil)
        let privateOnWork = BrowserLittleArcLanding.Window(id: UUID(), takesTabs: false, currentSpaceID: nil)
        let recent = BrowserLittleArcLanding.Window(id: UUID(), takesTabs: true, currentSpaceID: home)
        let older = BrowserLittleArcLanding.Window(id: UUID(), takesTabs: true, currentSpaceID: home)
        #expect(BrowserLittleArcLanding.target(space: work, windows: [little, privateOnWork, recent, older])
            == .switching(recent.id))
    }

    @Test func withoutANormalWindowANewOneOpens() {
        let little = BrowserLittleArcLanding.Window(id: UUID(), takesTabs: false, currentSpaceID: nil)
        #expect(BrowserLittleArcLanding.target(space: work, windows: [little]) == .newWindow)
        #expect(BrowserLittleArcLanding.target(space: work, windows: []) == .newWindow)
    }

    // MARK: Frame

    @Test func littleArcsCascadeFromTheScreensTopRight() {
        let screen = NSRect(x: 0, y: 25, width: 1512, height: 920)
        let first = BrowserLittleArcFrame.frame(screens: [screen], open: 0)
        #expect(first.size == BrowserLittleArcFrame.size)
        #expect(first.maxX == screen.maxX - BrowserLittleArcFrame.inset)
        #expect(first.maxY == screen.maxY - BrowserLittleArcFrame.inset)
        let second = BrowserLittleArcFrame.frame(screens: [screen], open: 1)
        #expect(second.origin == NSPoint(x: first.minX - BrowserWindowFrames.cascadeOffset, y: first.minY - BrowserWindowFrames.cascadeOffset))
        // Every frame stays on the screen; the cascade starts over.
        for open in 0..<40 {
            let frame = BrowserLittleArcFrame.frame(screens: [screen], open: open)
            #expect(screen.contains(frame))
        }
        // A screen smaller than the window: it fits.
        let small = NSRect(x: 0, y: 0, width: 500, height: 400)
        #expect(BrowserLittleArcFrame.frame(screens: [small], open: 0).width <= small.width)
    }

    // MARK: Idle

    private func candidate(lastActive: Date, start: Bool = false, audio: Bool = false) -> BrowserArchiveCandidate {
        var activity = BrowserTabSleepCandidate(lastActive: lastActive)
        activity.isSelected = true
        activity.isPlayingAudio = audio
        return BrowserArchiveCandidate(inSpace: true, isToday: true, isStartPage: start, activity: activity)
    }

    @Test func aLittleArcClosesAfterSixHoursThoughItsTabIsSelected() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let now = start.addingTimeInterval(BrowserLittleArcIdle.closeAfter)
        #expect(BrowserLittleArcIdle.closes(candidate(lastActive: start), now: now))
        #expect(!BrowserLittleArcIdle.closes(candidate(lastActive: start), now: now.addingTimeInterval(-1)))
        // A start page closes too (nothing to archive); audio keeps it.
        #expect(BrowserLittleArcIdle.closes(candidate(lastActive: start, start: true), now: now))
        #expect(!BrowserLittleArcIdle.closes(candidate(lastActive: start, audio: true), now: now))
        // The normal policy would never archive a selected tab.
        #expect(BrowserArchivePolicy.exemption(for: candidate(lastActive: start)) == .selected)
    }
}
