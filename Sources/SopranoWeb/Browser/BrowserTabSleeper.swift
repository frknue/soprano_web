import AppKit

/// The idle pass over every window, each minute: idle Today tabs archive
/// themselves (`BrowserWindowManager.archiveIdleTabs`, each profile's
/// `archiveAfter`), then idle tabs go to sleep (Settings ▸ "Put inactive
/// tabs to sleep"); every memory pressure warning (tabs idle 30 minutes)
/// or critical event (5 minutes) puts tabs to sleep too. Owned by
/// `BrowserWindowManager`; the harness injects a clock and a short sleep
/// threshold and calls the pressure path directly.
@MainActor
final class BrowserTabSleeper {
    /// How often the idle pass runs in the app.
    static let checkInterval: TimeInterval = 60

    /// The clock idle time (sleep and archive) is measured with.
    var now: () -> Date = { Date() }
    /// Used instead of the setting (the harness's short threshold); the pass
    /// then runs four times per threshold.
    var thresholdOverride: TimeInterval? {
        didSet { scheduleTimer() }
    }
    weak var manager: BrowserWindowManager?

    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?

    func start(manager: BrowserWindowManager) {
        self.manager = manager
        scheduleTimer()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            MainActor.assumeIsolated {
                self?.memoryPressure(event.contains(.critical) ? .critical : .warning)
            }
        }
        source.activate()
        pressureSource = source
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
    }

    /// The system asks for memory back: tabs idle past the level's
    /// threshold sleep now.
    func memoryPressure(_ level: BrowserMemoryPressure) {
        sleepIdleTabs(pressure: level)
    }

    /// What the timer runs: archives every idle Today tab, then starts
    /// every idle tab falling asleep. Returns both.
    @discardableResult
    func idlePass() -> (archived: [BrowserArchiveEntry], falling: [BrowserTab]) {
        let archived = manager?.archiveIdleTabs(now: now()) ?? []
        return (archived, sleepIdleTabs())
    }

    /// Starts every eligible tab of every window falling asleep (each takes
    /// a snapshot first) and returns them.
    @discardableResult
    func sleepIdleTabs(pressure: BrowserMemoryPressure? = nil) -> [BrowserTab] {
        guard let manager,
              let threshold = BrowserTabSleepPolicy.idleThreshold(
                  setting: manager.settingsStore.settings.tabSleep,
                  override: thresholdOverride,
                  pressure: pressure
              )
        else { return [] }
        let now = now()
        var falling: [BrowserTab] = []
        for controller in manager.controllers {
            // A selected tab is in use; its idle time starts when it is left.
            controller.selectedTab?.lifecycle.lastActiveAt = now
            for tab in controller.tabs where tab.lifecycle.sleepAttempt == nil {
                guard BrowserTabSleepPolicy.shouldSleep(
                    controller.sleepCandidate(tab),
                    now: now,
                    idleThreshold: threshold
                ) else { continue }
                controller.sleepTab(tab)
                falling.append(tab)
            }
        }
        return falling
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = thresholdOverride.map { max(0.25, $0 / 4) } ?? Self.checkInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.idlePass() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
