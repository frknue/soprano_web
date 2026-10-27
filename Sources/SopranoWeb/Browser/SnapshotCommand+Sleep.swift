import AppKit
import WebKit

/// Tab sleep and per-site zoom setup for `SopranoWeb snapshot`, read
/// before the first window opens:
///
/// - `--sleep-after <seconds>`: the idle threshold instead of Settings ▸ Put
///   inactive tabs to sleep (the idle pass then runs four times per
///   threshold, on the real timer).
/// - `--tab-sleep never|fifteenMinutes|oneHour|fourHours`: the setting.
/// - `--default-zoom <percent>`: Settings ▸ Default page zoom.
/// - `--support-dir <dir>`: use (and keep) this support folder instead of a
///   temporary one, so a second run sees what the first saved.
struct SnapshotSleepOptions {
    var sleepAfter: TimeInterval?
    var tabSleep: BrowserTabSleepAfter?
    var defaultZoom: Double?
    var supportDirectory: URL?

    static let usage = """
                               [--sleep-after <seconds>] [--tab-sleep <setting>] [--default-zoom <percent>]
                               [--support-dir <dir>] [--advance-clock <seconds>] [--sleep-pass]
                               [--memory-pressure warning|critical] [--zoom-in] [--zoom-out] [--zoom-reset]
                               [--keep-awake <tab>]
    """

    /// True when `option` is one of these flags (its value read).
    static func parse(_ option: String, value: () throws -> String, into options: inout SnapshotSleepOptions) throws -> Bool {
        switch option {
        case "--sleep-after":
            let raw = try value()
            guard let seconds = TimeInterval(raw), seconds > 0 else {
                throw SnapshotCommand.OptionError.unknownOption("--sleep-after \(raw)")
            }
            options.sleepAfter = seconds
        case "--tab-sleep":
            let raw = try value()
            guard let setting = BrowserTabSleepAfter(rawValue: raw) else {
                throw SnapshotCommand.OptionError.unknownOption("--tab-sleep \(raw)")
            }
            options.tabSleep = setting
        case "--default-zoom":
            let raw = try value()
            guard let percent = Double(raw.replacingOccurrences(of: "%", with: "")),
                  let zoom = BrowserZoom.validated(percent / 100)
            else {
                throw SnapshotCommand.OptionError.unknownOption("--default-zoom \(raw)")
            }
            options.defaultZoom = BrowserZoom.nearestStep(zoom)
        case "--support-dir":
            options.supportDirectory = URL(fileURLWithPath: try value(), isDirectory: true)
        default:
            return false
        }
        return true
    }

    /// Settings the flags change, before any window reads them.
    @MainActor
    func apply(to settings: BrowserSettingsStore) {
        if let tabSleep {
            settings.update { $0.tabSleep = tabSleep }
        }
        if let defaultZoom {
            settings.update { $0.defaultZoom = defaultZoom }
        }
    }

    /// The test threshold and the harness clock (`--advance-clock`).
    @MainActor
    func apply(to manager: BrowserWindowManager) {
        manager.tabSleeper.now = { Date().addingTimeInterval(SnapshotSleepAction.clockOffset) }
        if let sleepAfter {
            manager.tabSleeper.thresholdOverride = sleepAfter
        }
    }
}

/// Tab sleep and zoom actions, run in order with the session flags on the
/// active window:
///
/// - `--advance-clock <seconds>`: moves the idle clock forward, then runs
///   the idle pass the timer runs (archive, then sleep); prints the tabs
///   archived (with their archive times) and falling asleep.
/// - `--sleep-pass`: runs the idle pass now.
/// - `--memory-pressure warning|critical`: what the memory pressure source
///   runs for that event.
/// - `--zoom-in`, `--zoom-out`, `--zoom-reset`: ⌘+, ⌘-, ⌘0.
/// - `--keep-awake <n>`: tab menu ▸ Keep This Site Awake on tab n.
///
/// `--print-windows` shows each tab's `asleep`, `awakeBecause` (the
/// exemption, or `idle`), `snapshotBytes`, `siteZoom` and its web content
/// process, and `webViews`: every web view a tab ever had, how many
/// replaced ones are still alive and whether their processes still run.
enum SnapshotSleepAction {
    case advanceClock(TimeInterval)
    case sleepPass
    case memoryPressure(BrowserMemoryPressure)
    case zoomIn
    case zoomOut
    case zoomReset
    case keepAwake(Int)

    static let flags: Set<String> = [
        "--advance-clock", "--sleep-pass", "--memory-pressure", "--zoom-in", "--zoom-out", "--zoom-reset",
        "--keep-awake",
    ]

    /// Nil when `option` is not one of these flags.
    static func parse(_ option: String, value: () throws -> String) throws -> SnapshotSleepAction? {
        switch option {
        case "--advance-clock":
            let raw = try value()
            guard let seconds = TimeInterval(raw), seconds >= 0 else {
                throw SnapshotCommand.OptionError.unknownOption("--advance-clock \(raw)")
            }
            return .advanceClock(seconds)
        case "--sleep-pass": return .sleepPass
        case "--memory-pressure":
            let raw = try value()
            guard let level = BrowserMemoryPressure(rawValue: raw) else {
                throw SnapshotCommand.OptionError.unknownOption("--memory-pressure \(raw)")
            }
            return .memoryPressure(level)
        case "--zoom-in": return .zoomIn
        case "--zoom-out": return .zoomOut
        case "--zoom-reset": return .zoomReset
        case "--keep-awake":
            let raw = try value()
            guard let number = Int(raw), number > 0 else {
                throw SnapshotCommand.OptionError.unknownOption("--keep-awake \(raw)")
            }
            return .keepAwake(number)
        default: return nil
        }
    }

    /// How far `--advance-clock` moved the sleep clock.
    @MainActor static var clockOffset: TimeInterval = 0

    @MainActor
    func perform(in manager: BrowserWindowManager) {
        switch self {
        case .advanceClock(let seconds):
            Self.clockOffset += seconds
            let pass = manager.tabSleeper.idlePass()
            print("archive: clock +\(Int(Self.clockOffset))s, \(pass.archived.count) tab(s) archived: \(SnapshotArchiveAction.describe(pass.archived))")
            print("sleep: clock +\(Int(Self.clockOffset))s, \(pass.falling.count) tab(s) falling asleep: \(pass.falling.map(\.displayTitle))")
        case .sleepPass:
            let pass = manager.tabSleeper.idlePass()
            print("archive: pass, \(pass.archived.count) tab(s) archived: \(SnapshotArchiveAction.describe(pass.archived))")
            print("sleep: pass, \(pass.falling.count) tab(s) falling asleep: \(pass.falling.map(\.displayTitle))")
        case .memoryPressure(let level):
            Self.trackWebViews(in: manager)
            let before = Set(manager.controllers.flatMap(\.tabs).filter(\.isAsleep).map(\.id))
            manager.tabSleeper.memoryPressure(level)
            let falling = manager.controllers.flatMap(\.tabs).filter {
                $0.lifecycle.sleepAttempt != nil && !before.contains($0.id)
            }
            print("memory-pressure \(level.rawValue): \(falling.count) tab(s) falling asleep: \(falling.map(\.displayTitle))")
        case .zoomIn, .zoomOut, .zoomReset:
            guard let controller = manager.activeController else { return }
            switch self {
            case .zoomIn: controller.zoomIn()
            case .zoomOut: controller.zoomOut()
            default: controller.resetZoom()
            }
            let tab = controller.selectedTab
            print("zoom: \(tab.map { BrowserZoom.percent($0.zoom) } ?? "-") on \(tab?.webView.url?.host ?? "-")")
        case .keepAwake(let number):
            guard let controller = manager.activeController, controller.visibleTabs.indices.contains(number - 1) else {
                print("snapshot: no tab \(number)")
                return
            }
            let tab = controller.visibleTabs[number - 1]
            guard let menu = controller.tabContextMenu(for: tab.id, closeAfterTitle: "Close Tabs Below"),
                  let item = menu.items.first(where: { $0.title == "Keep This Site Awake" }),
                  item.isEnabled
            else {
                print("snapshot: Keep This Site Awake is not available for tab \(number)")
                return
            }
            controller.toggleKeepAwakeFromMenu(item)
            let host = controller.keepAwakeKey(for: tab) ?? "-"
            print("keep-awake: \(host) \(tab.dataContext.sitePermissions.keepsAwake(host: host) ? "on" : "off")")
        }
    }

    // MARK: - Reporting

    private struct TrackedWebView {
        weak var webView: WKWebView?
        var pid: pid_t
    }

    @MainActor private static var tracked: [TrackedWebView] = []

    /// Remembers every tab's web view (weakly) and its content process, so
    /// a replaced one can be checked after the tab sleeps.
    @MainActor
    static func trackWebViews(in manager: BrowserWindowManager) {
        for tab in manager.controllers.flatMap(\.tabs) {
            let pid = processIdentifier(of: tab.webView)
            if let index = tracked.firstIndex(where: { $0.webView === tab.webView }) {
                if pid > 0 {
                    tracked[index].pid = pid
                }
            } else {
                tracked.append(TrackedWebView(webView: tab.webView, pid: pid))
            }
        }
    }

    @MainActor
    static func webViewReport(in manager: BrowserWindowManager) -> [String: Any] {
        let open = manager.controllers.flatMap(\.tabs).map(\.webView)
        let replaced = tracked.filter { entry in
            guard let webView = entry.webView else { return true }
            return !open.contains { $0 === webView }
        }
        let processes = replaced.map(\.pid).filter { $0 > 0 }
        return [
            "tracked": tracked.count,
            "inTabs": open.count,
            "replaced": replaced.count,
            "replacedStillAlive": replaced.filter { $0.webView != nil }.count,
            "replacedProcesses": processes.map(Int.init),
            "replacedProcessesRunning": processes.filter { kill($0, 0) == 0 }.map(Int.init),
            "replacedStillAliveURLs": replaced.compactMap { $0.webView.map { $0.url?.absoluteString ?? "(empty)" } },
        ]
    }

    @MainActor
    static func tabInfo(_ tab: BrowserTab, in controller: BrowserWindowController) -> [String: Any] {
        let host = BrowserSitePermissionStore.siteKey(for: tab.webView.url)
        return [
            "asleep": tab.isAsleep,
            "awakeBecause": tab.isAsleep ? NSNull() : (controller.sleepExemption(tab)?.rawValue ?? "idle") as Any,
            "snapshotBytes": tab.lifecycle.sleep?.snapshot?.count ?? 0,
            "webContentPID": Int(processIdentifier(of: tab.webView)),
            "siteZoom": host.flatMap { tab.dataContext.sitePermissions.zoom(host: $0) } ?? NSNull(),
            "keptAwake": controller.keepAwakeKey(for: tab).map(tab.dataContext.sitePermissions.keepsAwake(host:)) ?? false,
            "playingAudio": tab.isPlayingAudio,
        ]
    }

    /// The web view's content process (WebKit SPI, harness only); 0 when it
    /// has none.
    @MainActor
    private static func processIdentifier(of webView: WKWebView) -> pid_t {
        (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
    }
}
