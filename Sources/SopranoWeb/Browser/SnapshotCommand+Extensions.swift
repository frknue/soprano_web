import AppKit
import WebKit

/// Extension flags for `SopranoWeb snapshot`. The harness's controller is
/// non-persistent and never checks for updates; `--support-dir` loads the
/// extensions installed there (`extensions.json`, `Extensions/<id>/`).
///
/// - `--extension <folder|id|store url>` (repeatable): installs it through
///   Settings ▸ Extensions' path (a store install downloads and verifies)
///   after the first window opens, and waits until it runs; prints
///   `extension: installed …` or `extension: failed …`.
/// - `--extension-private <id>`: "Allow in private windows" on.
/// - `--extension-site-access <id>=all|click|<host>`: site access ("On all
///   sites", "When you click", or "On specific sites" with the host added).
/// - `--extension-action <id>`: clicks the extension's toolbar button in
///   the captured window (its action, or its popup: prints
///   `extension-popup:` with its address and size, and the capture draws
///   the popup under the button).
/// - `--extensions-sheet`: captures Settings ▸ Extensions and prints each
///   row (`extensions-sheet:`).
/// - `--print-extensions`: one `extensions:` JSON line: each extension's
///   record (state, private access, site access, version, source), its
///   errors, commands and granted match patterns, and the captured
///   window's toolbar buttons (id, label, badge, icon).
struct SnapshotExtensionOptions {
    var installs: [String] = []
    var allowPrivate: [String] = []
    var siteAccess: [(id: String, value: String)] = []
    var actions: [String] = []
    var showsSheet = false
    var prints = false

    static let usage = """
                               [--extension <folder|id|store url>]... [--extension-private <id>]
                               [--extension-site-access <id>=all|click|<host>] [--extension-action <id>]
                               [--extensions-sheet] [--print-extensions]
    """

    static func parse(_ option: String, value: () throws -> String, into options: inout SnapshotExtensionOptions) throws -> Bool {
        switch option {
        case "--extension":
            options.installs.append(try value())
        case "--extension-private":
            options.allowPrivate.append(try value())
        case "--extension-site-access":
            let raw = try value()
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw SnapshotCommand.OptionError.unknownOption("--extension-site-access \(raw)") }
            options.siteAccess.append((parts[0], parts[1]))
        case "--extension-action":
            options.actions.append(try value())
        case "--extensions-sheet":
            options.showsSheet = true
        case "--print-extensions":
            options.prints = true
        default:
            return false
        }
        return true
    }

    /// Installs, then waits for every enabled extension to run (or fail),
    /// then applies the settings flags.
    @MainActor
    func prepare(_ manager: BrowserWindowManager, wait: (Double) -> Void) {
        let extensions = manager.extensions
        for input in installs {
            var finished = false
            Task { @MainActor in
                do {
                    let record = try await extensions.install(input)
                    print("extension: installed \(BrowserExtensionCommands.line(for: record, in: extensions))")
                } catch {
                    print("extension: failed \(input): \(error.localizedDescription)")
                }
                finished = true
            }
            let deadline = Date().addingTimeInterval(120)
            while !finished, Date() < deadline { wait(0.05) }
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, extensions.records.contains(where: { record in
            record.isEnabled && extensions.context(id: record.id) == nil && extensions.loadErrors[record.id] == nil
        }) {
            wait(0.05)
        }
        for id in allowPrivate {
            do {
                try extensions.setAllowsPrivate(id, true)
            } catch {
                print("extension: private \(id) refused: \(error.localizedDescription)")
            }
        }
        for (id, value) in siteAccess {
            do {
                switch value {
                case "all": try extensions.setSiteAccess(id, .allSites)
                case "click": try extensions.setSiteAccess(id, .onClick)
                default: try extensions.setSite(id, host: value, allowed: true)
                }
            } catch {
                print("extension: site access \(id) refused: \(error.localizedDescription)")
            }
        }
        if !installs.isEmpty || !allowPrivate.isEmpty || !siteAccess.isEmpty {
            // Background pages start and register their rules.
            wait(1.5)
        }
    }

    /// Clicks each `--extension-action` button in `controller`; returns
    /// the popup still open with a snapshot of its page.
    @MainActor
    func performActions(in controller: BrowserWindowController, wait: (Double) -> Void) -> SnapshotExtensionPopup? {
        let extensions = controller.extensions
        for id in actions {
            guard extensions.context(id: id) != nil else {
                print("extension-action: \(id) is not running")
                continue
            }
            controller.performExtensionAction(id)
            wait(1.5)
            if let popup = extensions.popup, popup.extensionID == id {
                let size = popup.popover.contentSize
                print("extension-popup: \(id) \(popup.url.absoluteString) \(Int(size.width))x\(Int(size.height)) shown \(popup.popover.isShown)")
            } else {
                print("extension-action: \(id) ran (no popup)")
            }
        }
        guard let popup = extensions.popup else { return nil }
        var image: NSImage?
        var finished = false
        popup.webView.takeSnapshot(with: nil) { snapshot, _ in
            image = snapshot
            finished = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !finished, Date() < deadline { wait(0.05) }
        return SnapshotExtensionPopup(extensionID: popup.extensionID, size: popup.popover.contentSize, image: image)
    }

    @MainActor
    func report(_ manager: BrowserWindowManager, controller: BrowserWindowController) {
        guard prints else { return }
        let extensions = manager.extensions
        let rows: [[String: Any]] = extensions.records.map { record in
            let context = extensions.context(id: record.id)
            var row: [String: Any] = [
                "id": record.id,
                "name": record.name,
                "version": record.version,
                "state": BrowserExtensionCommands.state(of: record, in: extensions),
                "private": record.allowsPrivate,
                "privateAccess": context?.hasAccessToPrivateData ?? false,
                "siteAccess": record.siteAccess.rawValue,
                "allowedSites": record.allowedSites,
                "errors": BrowserExtensionCommands.errors(of: record.id, in: extensions),
                // What an update newly asked for, waiting for the user.
                "pending": extensions.pendingAdditions[record.id].map { $0.permissions + $0.matchPatterns } ?? [],
                "standIns": record.standIns,
            ]
            if let context {
                row["baseURL"] = context.baseURL.absoluteString
                row["commands"] = context.commands.map { "\($0.id)=\(BrowserExtensions.shortcutText($0))" }
                row["grantedMatchPatterns"] = context.grantedPermissionMatchPatterns.keys.map(\.string).sorted()
                row["hasBackground"] = context.webExtension.hasBackgroundContent
                row["contentRules"] = context.hasContentModificationRules
                // What WebKit tracks for the extension: the windows and tabs
                // the adapters announced or it asked for.
                row["openWindows"] = context.openWindows.count
                row["openTabs"] = context.openTabs.count
                row["focusedWindow"] = context.focusedWindow != nil
                row["permissions"] = context.currentPermissions.map(\.rawValue).sorted()
                row["accessToAllURLs"] = context.hasAccessToAllURLs
            }
            return row
        }
        let toolbar: [[String: Any]] = controller.toolbar.extensionToolbarItems.map { item in
            ["id": item.id, "label": item.label, "badge": item.badge, "icon": item.icon != nil, "enabled": item.isEnabled]
        }
        let report: [String: Any] = [
            "extensions": rows,
            "toolbar": toolbar,
            "windowKind": controller.kind.isPrivate ? "private" : "normal",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8)
        {
            print("extensions: \(line)")
        }
    }
}

/// An open extension popup as the capture draws it.
struct SnapshotExtensionPopup {
    var extensionID: String
    var size: NSSize
    var image: NSImage?
}

extension SnapshotCommand {
    /// Draws the popup's page in a popover frame hanging under `anchor`
    /// (call inside `lockFocus`).
    static func drawPopup(_ popup: SnapshotExtensionPopup, under anchor: NSView, in content: NSView) {
        let button = anchor.convert(anchor.bounds, to: content)
        let frame = NSRect(
            x: min(max(8, button.midX - popup.size.width / 2), content.bounds.width - popup.size.width - 8),
            y: content.isFlipped ? button.maxY + 6 : button.minY - 6 - popup.size.height,
            width: popup.size.width,
            height: popup.size.height
        )
        let shape = NSBezierPath(roundedRect: frame, xRadius: Chrome.Radius.popover, yRadius: Chrome.Radius.popover)
        NSColor.white.setFill()
        shape.fill()
        if let image = popup.image {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            image.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.black.withAlphaComponent(0.25).setStroke()
        shape.lineWidth = Chrome.hairline
        shape.stroke()
    }
}
