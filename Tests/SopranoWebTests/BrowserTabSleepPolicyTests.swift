@testable import SopranoWeb
import AppKit
import Testing

struct BrowserTabSleepPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let minute: TimeInterval = 60

    private func idle(_ seconds: TimeInterval) -> BrowserTabSleepCandidate {
        BrowserTabSleepCandidate(lastActive: now.addingTimeInterval(-seconds))
    }

    @Test func anIdleBackgroundTabSleepsAtTheThreshold() {
        #expect(BrowserTabSleepPolicy.exemption(for: idle(0)) == nil)
        #expect(!BrowserTabSleepPolicy.shouldSleep(idle(3_599), now: now, idleThreshold: 3_600))
        #expect(BrowserTabSleepPolicy.shouldSleep(idle(3_600), now: now, idleThreshold: 3_600))
        #expect(BrowserTabSleepPolicy.shouldSleep(idle(10_000), now: now, idleThreshold: 3_600))
    }

    @Test func everyExemptionKeepsALongIdleTabAwake() {
        let cases: [(BrowserTabSleepExemption, (inout BrowserTabSleepCandidate) -> Void)] = [
            (.selected, { $0.isSelected = true }),
            (.notLoaded, { $0.isLoaded = false }),
            (.playingAudio, { $0.isPlayingAudio = true }),
            (.capturing, { $0.isCapturing = true }),
            (.loading, { $0.isLoading = true }),
            (.prompt, { $0.hasOpenPrompt = true }),
            (.unsavedInput, { $0.hasUnsavedInput = true }),
            (.popup, { $0.isPopup = true }),
            (.keptAwake, { $0.isKeptAwake = true }),
        ]
        for (expected, change) in cases {
            var candidate = idle(24 * 3_600)
            change(&candidate)
            #expect(BrowserTabSleepPolicy.exemption(for: candidate) == expected, "\(expected)")
            #expect(!BrowserTabSleepPolicy.shouldSleep(candidate, now: now, idleThreshold: 60), "\(expected)")
        }
    }

    @Test func theSelectedTabOfAWindowNeverSleepsEvenUnderCriticalPressure() {
        var selected = idle(24 * 3_600)
        selected.isSelected = true
        let threshold = BrowserTabSleepPolicy.idleThreshold(setting: .fifteenMinutes, pressure: .critical)
        #expect(threshold == 5 * minute)
        #expect(!BrowserTabSleepPolicy.shouldSleep(selected, now: now, idleThreshold: threshold ?? 0))
    }

    @Test func settingThresholds() {
        #expect(BrowserSettings.default.tabSleep == .oneHour)
        #expect(BrowserTabSleepAfter.never.interval == nil)
        #expect(BrowserTabSleepAfter.fifteenMinutes.interval == 15 * minute)
        #expect(BrowserTabSleepAfter.oneHour.interval == 60 * minute)
        #expect(BrowserTabSleepAfter.fourHours.interval == 4 * 60 * minute)
        #expect(BrowserTabSleepPolicy.idleThreshold(setting: .fourHours) == 4 * 60 * minute)
        #expect(BrowserTabSleepPolicy.idleThreshold(setting: .never) == nil)
    }

    @Test func memoryPressureShortensTheThreshold() {
        #expect(BrowserMemoryPressure.warning.idleThreshold == 30 * 60)
        #expect(BrowserMemoryPressure.critical.idleThreshold == 5 * 60)
        #expect(BrowserTabSleepPolicy.idleThreshold(setting: .fourHours, pressure: .warning) == 30 * minute)
        #expect(BrowserTabSleepPolicy.idleThreshold(setting: .oneHour, pressure: .critical) == 5 * minute)
        // The setting is already shorter than the warning level.
        #expect(BrowserTabSleepPolicy.idleThreshold(setting: .fifteenMinutes, pressure: .warning) == 15 * minute)

        // Under a warning a tab idle 20 minutes stays; one idle 40 sleeps.
        let warning = BrowserTabSleepPolicy.idleThreshold(setting: .fourHours, pressure: .warning) ?? 0
        #expect(!BrowserTabSleepPolicy.shouldSleep(idle(20 * 60), now: now, idleThreshold: warning))
        #expect(BrowserTabSleepPolicy.shouldSleep(idle(40 * 60), now: now, idleThreshold: warning))
        let critical = BrowserTabSleepPolicy.idleThreshold(setting: .fourHours, pressure: .critical) ?? 0
        #expect(BrowserTabSleepPolicy.shouldSleep(idle(6 * 60), now: now, idleThreshold: critical))
        #expect(!BrowserTabSleepPolicy.shouldSleep(idle(4 * 60), now: now, idleThreshold: critical))
    }

    @Test func neverMeansNeverEvenUnderPressure() {
        #expect(BrowserTabSleepPolicy.idleThreshold(setting: .never, pressure: .critical) == nil)
    }

    @Test func theHarnessOverrideReplacesTheSetting() {
        #expect(BrowserTabSleepPolicy.idleThreshold(setting: .oneHour, override: 2) == 2)
        #expect(BrowserTabSleepPolicy.idleThreshold(setting: .never, override: 2) == 2)
        #expect(BrowserTabSleepPolicy.idleThreshold(setting: .oneHour, override: 600, pressure: .critical) == 5 * minute)
    }

    @Test func theSettingDecodesKeyByKey() throws {
        let json = Data(#"{ "tabSleep": "fourHours", "searchEngine": "google" }"#.utf8)
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: json)
        #expect(settings.tabSleep == .fourHours)
        let unknown = Data(#"{ "tabSleep": "sometimes", "searchEngine": "google" }"#.utf8)
        let fallback = try JSONDecoder().decode(BrowserSettings.self, from: unknown)
        #expect(fallback.tabSleep == .oneHour)
        #expect(fallback.searchEngine == .google)
    }
}
