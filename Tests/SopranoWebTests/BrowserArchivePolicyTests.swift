@testable import SopranoWeb
import AppKit
import Testing

struct BrowserArchivePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3_600

    private func idle(_ seconds: TimeInterval) -> BrowserArchiveCandidate {
        BrowserArchiveCandidate(activity: BrowserTabSleepCandidate(lastActive: now.addingTimeInterval(-seconds)))
    }

    @Test func anIdleTodayTabArchivesAtItsProfilesThreshold() {
        #expect(BrowserArchivePolicy.exemption(for: idle(0)) == nil)
        #expect(!BrowserArchivePolicy.shouldArchive(idle(12 * hour - 1), now: now, archiveAfter: .hours12))
        #expect(BrowserArchivePolicy.shouldArchive(idle(12 * hour), now: now, archiveAfter: .hours12))
        #expect(BrowserArchivePolicy.shouldArchive(idle(13 * hour), now: now, archiveAfter: .hours12))
        #expect(!BrowserArchivePolicy.shouldArchive(idle(13 * hour), now: now, archiveAfter: .hours24))
        #expect(BrowserArchivePolicy.shouldArchive(idle(hour), now: now, archiveAfter: .hour1))
    }

    @Test func idleThresholdPerSetting() {
        let expected: [(BrowserArchiveAfter, TimeInterval?)] = [
            (.never, nil),
            (.days30, 30 * 24 * hour),
            (.days7, 7 * 24 * hour),
            (.hours24, 24 * hour),
            (.hours12, 12 * hour),
            (.hours6, 6 * hour),
            (.hour1, hour),
        ]
        #expect(expected.map(\.0) == BrowserArchiveAfter.allCases)
        for (setting, interval) in expected {
            #expect(BrowserArchivePolicy.idleThreshold(setting) == interval, "\(setting)")
            if let interval {
                #expect(!BrowserArchivePolicy.shouldArchive(idle(interval - 1), now: now, archiveAfter: setting), "\(setting)")
                #expect(BrowserArchivePolicy.shouldArchive(idle(interval), now: now, archiveAfter: setting), "\(setting)")
            }
        }
        #expect(BrowserArchiveAfter.default == .hours12)
    }

    @Test func neverKeepsEvenAYearOldTab() {
        #expect(!BrowserArchivePolicy.shouldArchive(idle(365 * 24 * hour), now: now, archiveAfter: .never))
    }

    @Test func everyExemptionKeepsALongIdleTab() {
        let cases: [(BrowserArchiveExemption, (inout BrowserArchiveCandidate) -> Void)] = [
            (.noSpace, { $0.inSpace = false }),
            (.linked, { $0.isToday = false }),
            (.startPage, { $0.isStartPage = true }),
            (.selected, { $0.activity.isSelected = true }),
            (.popup, { $0.activity.isPopup = true }),
            (.playingAudio, { $0.activity.isPlayingAudio = true }),
            (.capturing, { $0.activity.isCapturing = true }),
            (.prompt, { $0.activity.hasOpenPrompt = true }),
        ]
        for (expected, change) in cases {
            var candidate = idle(40 * 24 * hour)
            change(&candidate)
            #expect(BrowserArchivePolicy.exemption(for: candidate) == expected, "\(expected)")
            #expect(!BrowserArchivePolicy.shouldArchive(candidate, now: now, archiveAfter: .hour1), "\(expected)")
        }
    }

    @Test func privateAndPopupWindowsNeverArchiveWhateverElseHolds() {
        // A private window's selected, linked start page: the window rule
        // comes first.
        var candidate = idle(40 * 24 * hour)
        candidate.inSpace = false
        candidate.isToday = false
        candidate.isStartPage = true
        candidate.activity.isSelected = true
        #expect(BrowserArchivePolicy.exemption(for: candidate) == .noSpace)
    }

    @Test func sleepOnlyStatesDoNotKeepATabOutOfTheArchive() {
        // Asleep or never loaded, loading, unsaved input, Keep This Site
        // Awake: the tab still archives.
        let changes: [(inout BrowserArchiveCandidate) -> Void] = [
            { $0.activity.isLoaded = false },
            { $0.activity.isLoading = true },
            { $0.activity.hasUnsavedInput = true },
            { $0.activity.isKeptAwake = true },
        ]
        for change in changes {
            var candidate = idle(12 * hour)
            change(&candidate)
            #expect(BrowserArchivePolicy.exemption(for: candidate) == nil)
            #expect(BrowserArchivePolicy.shouldArchive(candidate, now: now, archiveAfter: .hours12))
        }
    }

    @Test func onlyWebAndFileAddressesAreArchivable() {
        #expect(BrowserArchiveEntry.isArchivable(URL(string: "https://example.com/")))
        #expect(BrowserArchiveEntry.isArchivable(URL(string: "http://127.0.0.1:8000/a.html")))
        #expect(BrowserArchiveEntry.isArchivable(URL(string: "file:///tmp/a.html")))
        #expect(!BrowserArchiveEntry.isArchivable(URL(string: "soprano://start")))
        #expect(!BrowserArchiveEntry.isArchivable(URL(string: "about:blank")))
        #expect(!BrowserArchiveEntry.isArchivable(nil))
    }
}
