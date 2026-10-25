import AppKit

/// Puts idle tabs of every window to sleep: a pass each minute against
/// Settings ▸ "Put inactive tabs to sleep", and one on every memory
/// pressure warning (tabs idle 30 minutes) or critical event (5 minutes).
/// Owned by `BrowserWindowManager`; the harness injects a clock and a short
/// threshold and calls the pressure path directly.
@MainActor
final class BrowserTabSleeper {
    /// How often the idle pass runs in the app.
    static let checkInterval: TimeInterval = 60

    /// The clock idle time is measured with.
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
            MainActor.assumeIsolated { _ = self?.sleepIdleTabs() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
