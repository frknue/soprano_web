import AppKit
import WebKit

/// Content blocker setup for `SopranoWeb snapshot`, read before the first
/// window opens:
///
/// - `--filter-list <url>` (repeatable): the lists the blocker downloads
///   instead of EasyList and EasyPrivacy (named after the file, e.g.
///   `easylist.txt` → `easylist`). Without it the harness has no lists and
///   never reaches the network.
struct SnapshotBlockerOptions {
    var sources: [BrowserFilterListSource] = []

    static let usage = """
                               [--filter-list <url>]... [--blocker-update] [--blocking on|off]
                               [--site-blocking on|off] [--print-blocker]
    """

    /// True when `option` is one of these flags (its value read).
    static func parse(_ option: String, value: () throws -> String, into options: inout SnapshotBlockerOptions) throws -> Bool {
        guard option == "--filter-list" else { return false }
        let raw = try value()
        guard let url = URL(string: raw), url.scheme != nil else {
            throw SnapshotCommand.OptionError.unknownOption("--filter-list \(raw)")
        }
        let name = url.deletingPathExtension().lastPathComponent
        let id = name.isEmpty ? "list\(options.sources.count + 1)" : name.lowercased()
        options.sources.append(BrowserFilterListSource(id: id, name: name, url: url))
        return true
    }
}

/// Content blocker actions, run in order with the session flags on the
/// active window:
///
/// - `--blocker-update`: Settings ▸ Update Now, waiting until the lists
///   are downloaded and compiled (launch already starts one for lists never
///   downloaded; this waits for it).
/// - `--blocking on|off`: the Settings ▸ Block ads and trackers switch.
/// - `--site-blocking on|off`: opens the connection popover on the selected
///   tab and flips its "Block ads on this site" switch (the control's own
///   press), then closes the popover.
/// - `--print-blocker`: one JSON line: the setting, status line, every
///   list (validators, check and update times, rule and filter counts,
///   skipped filters by reason, compile time, compiled list identifiers),
///   the compiled files' size, and every tab of every window (kind, pop-up,
///   address, lists attached, whether its `.ad-banner` element is hidden
///   and whether `window.adBannerLoaded` was set by an ad script).
enum SnapshotBlockerAction {
    case update
    case blocking(Bool)
    case siteBlocking(Bool)
    case report

    static let flags: Set<String> = ["--blocker-update", "--blocking", "--site-blocking", "--print-blocker"]

    /// Nil when `option` is not one of these flags.
    static func parse(_ option: String, value: () throws -> String) throws -> SnapshotBlockerAction? {
        func onOff() throws -> Bool {
            let raw = try value()
            guard raw == "on" || raw == "off" else {
                throw SnapshotCommand.OptionError.unknownOption("\(option) \(raw)")
            }
            return raw == "on"
        }
        switch option {
        case "--blocker-update": return .update
        case "--blocking": return .blocking(try onOff())
        case "--site-blocking": return .siteBlocking(try onOff())
        case "--print-blocker": return .report
        default: return nil
        }
    }

    @MainActor
    func perform(in manager: BrowserWindowManager) {
        let blocker = manager.contentBlocker
        switch self {
        case .update:
            let started = Date()
            var finished = false
            Task {
                await blocker.update()
                finished = true
            }
            Self.spin(1_800) { finished }
            print(String(format: "blocker-update: %@ (%.1fs)", blocker.statusText, Date().timeIntervalSince(started)))
        case .blocking(let on):
            manager.settingsStore.update { $0.blockAdsAndTrackers = on }
            print("blocking: \(on ? "on" : "off") (\(blocker.activeLists.count) list(s) active)")
        case .siteBlocking(let on):
            siteBlocking(on, in: manager)
        case .report:
            var finished = false
            Task {
                await blocker.waitUntilIdle()
                finished = true
            }
            Self.spin(1_800) { finished }
            Self.printBlocker(manager)
        }
    }

    @MainActor
    private func siteBlocking(_ on: Bool, in manager: BrowserWindowManager) {
        guard let controller = manager.activeController, let window = controller.window else { return }
        controller.showConnectionInfo()
        Self.spin(0.3)
        guard let sheet = window.attachedSheet else {
            print("site-blocking: no connection popover")
            return
        }
        var queue = sheet.contentView.map { [$0] } ?? []
        var accessory: BrowserSiteBlockingAccessory?
        while !queue.isEmpty, accessory == nil {
            let view = queue.removeFirst()
            accessory = view as? BrowserSiteBlockingAccessory
            queue += view.subviews
        }
        if let accessory {
            if accessory.toggle.isOn != on {
                _ = accessory.toggle.accessibilityPerformPress()
            }
            print("site-blocking: \(accessory.host) switch \(accessory.toggle.isOn ? "on" : "off")")
        } else {
            print("site-blocking: the popover has no switch")
        }
        window.endSheet(sheet)
    }

    // MARK: - Reporting

    @MainActor
    private static func printBlocker(_ manager: BrowserWindowManager) {
        let blocker = manager.contentBlocker
        let iso = ISO8601DateFormatter()
        let sources: [[String: Any]] = blocker.sources.map { source in
            let entry = blocker.state.sources[source.id]
            return [
                "id": source.id,
                "url": source.url.absoluteString,
                "etag": entry?.etag ?? NSNull(),
                "lastModified": entry?.lastModified ?? NSNull(),
                "checkedAt": entry?.checkedAt.map(iso.string(from:)) ?? NSNull(),
                "updatedAt": entry?.updatedAt.map(iso.string(from:)) ?? NSNull(),
                "filters": entry?.filterCount ?? 0,
                "rules": entry?.ruleCount ?? 0,
                "skipped": entry?.skipped ?? [:],
                "compileSeconds": entry?.compileSeconds ?? NSNull(),
                "lists": entry?.lists ?? [],
                "lastError": entry?.lastError ?? NSNull(),
                "cachedTextBytes": fileSize(blocker.textURL(for: source)),
            ]
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: blocker.directory.path)) ?? []
        let compiledFiles = files.filter { $0.hasPrefix("ContentRuleList") }.sorted()
        let compiledBytes = compiledFiles.reduce(0) { $0 + fileSize(blocker.directory.appendingPathComponent($1)) }

        var tabs: [[String: Any]] = []
        var pending = 0
        for (windowIndex, controller) in manager.controllers.enumerated() {
            for tab in controller.tabs {
                let index = tabs.count
                tabs.append([
                    "window": windowIndex + 1,
                    "kind": controller.kind.isPrivate ? "private" : "normal",
                    "popup": controller.isPopup,
                    "url": tab.webView.url?.absoluteString ?? NSNull(),
                    "lists": tab.webView.contentRuleListIDs.count,
                ])
                guard tab.webView.url?.scheme?.hasPrefix("http") == true else { continue }
                pending += 1
                tab.webView.evaluateJavaScript(pageProbe) { result, _ in
                    MainActor.assumeIsolated {
                        if let json = (result as? String)?.data(using: .utf8),
                           let page = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
                        {
                            tabs[index]["adBannerDisplay"] = page["banner"] ?? NSNull()
                            tabs[index]["adScriptRan"] = page["adScript"] ?? false
                        }
                        pending -= 1
                    }
                }
            }
        }
        spin(5) { pending == 0 }

        let report: [String: Any] = [
            "printedAt": iso.string(from: Date()),
            "enabled": blocker.isEnabled,
            "updating": blocker.isUpdating,
            "status": blocker.statusText,
            "rules": blocker.ruleCount,
            "activeLists": blocker.activeLists.compactMap { $0.identifier },
            "compiledFiles": compiledFiles.count,
            "compiledBytes": compiledBytes,
            "sources": sources,
            "tabs": tabs,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8)
        {
            print("blocker: \(line)")
        }
    }

    private static let pageProbe = """
    (() => {
        const banner = document.querySelector('.ad-banner');
        return JSON.stringify({
            banner: banner ? getComputedStyle(banner).display : null,
            adScript: !!window.adBannerLoaded,
        });
    })()
    """

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    @MainActor
    private static func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            autoreleasepool {
                _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
            }
        }
    }
}
