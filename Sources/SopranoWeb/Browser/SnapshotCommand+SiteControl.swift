import AppKit

/// Snapshot flags for the lock's Site Control Center, built offscreen and
/// never shown as a panel:
/// - `--site-control`: the popover for the page the user looks at, put
///   into the window under the lock and captured; its state prints as
///   `site-control:` lines.
/// - `--security-info`: the popover's Connection row pressed: the
///   connection details sheet (`--sheet` prints it).
/// - `--site-blocking on|off` (`SnapshotBlockerAction`): the popover's "Block
///   ads on this site" switch.
extension SnapshotCommand {
    static func makeSiteControlPopover(controller: BrowserWindowController) -> NSView? {
        guard let tab = controller.siteControlTab, let view = controller.makeSiteControlView(for: tab) else {
            print("site-control: the page has no site")
            return nil
        }
        let root = controller.rootView
        view.translatesAutoresizingMaskIntoConstraints = true
        view.layoutSubtreeIfNeeded()
        let anchor = controller.toolbar.securityAnchor
        let anchorRect = anchor.convert(anchor.bounds, to: root)
        view.frame = BrowserSiteControlView.frame(size: view.fittingSize, below: anchorRect, within: root.bounds)
        root.addSubview(view, positioned: .above, relativeTo: nil)
        view.layoutSubtreeIfNeeded()
        for line in view.state.lines {
            print("site-control: \(line)")
        }
        return view
    }

    /// Presses the Connection row of a popover built for the page.
    static func openConnectionDetails(controller: BrowserWindowController) {
        guard let tab = controller.siteControlTab,
              let button = controller.makeSiteControlView(for: tab)?.connectionButton
        else {
            print("security-info: the page has no site")
            return
        }
        _ = button.accessibilityPerformPress()
    }
}

extension SnapshotBlockerAction {
    /// The popover's "Block ads on this site" switch, pressed by its own
    /// control.
    @MainActor
    static func pressSiteBlocking(_ on: Bool, in manager: BrowserWindowManager) {
        guard let controller = manager.activeController,
              let tab = controller.siteControlTab,
              let view = controller.makeSiteControlView(for: tab)
        else {
            print("site-blocking: no site control popover")
            return
        }
        guard let accessory = view.blockingAccessory else {
            print("site-blocking: the popover has no switch")
            return
        }
        if accessory.toggle.isOn != on {
            _ = accessory.toggle.accessibilityPerformPress()
        }
        print("site-blocking: \(accessory.host) switch \(accessory.toggle.isOn ? "on" : "off")")
    }
}
