import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Per-site zoom

    /// ⌘+ (and Vimium `zi`): the selected page's site one step larger, in
    /// every tab of that site that reads the tab's profile's site decisions.
    func zoomIn() {
        guard let tab = pageTab else { return }
        setZoom(BrowserZoom.zoomedIn(from: tab.zoom), for: tab)
    }

    /// ⌘- (and Vimium `zo`).
    func zoomOut() {
        guard let tab = pageTab else { return }
        setZoom(BrowserZoom.zoomedOut(from: tab.zoom), for: tab)
    }

    /// ⌘0, Vimium `z0` and the zoom chip: the site forgets its zoom and
    /// follows Settings ▸ Default page zoom again.
    func resetZoom() {
        guard let tab = pageTab else { return }
        if let key = BrowserSitePermissionStore.siteKey(for: tab.webView.url) {
            tab.dataContext.sitePermissions.setZoom(nil, host: key)
        }
        apply(zoom: settingsStore.settings.defaultZoom, to: tab)
    }

    /// Remembers `zoom` for the tab's site in its profile (a zoom equal to
    /// the default is forgotten) and applies it. The site decisions notify
    /// every window with tabs of the profile, whose tabs of the site follow
    /// (`applySiteZooms`); a page without a site keeps the zoom until its
    /// next page.
    private func setZoom(_ zoom: Double, for tab: BrowserTab) {
        if let key = BrowserSitePermissionStore.siteKey(for: tab.webView.url) {
            let isDefault = BrowserZoom.isSame(zoom, settingsStore.settings.defaultZoom)
            tab.dataContext.sitePermissions.setZoom(isDefault ? nil : zoom, host: key)
        }
        apply(zoom: zoom, to: tab)
    }

    /// The zoom `tab`'s page at `url` opens with: its site's remembered
    /// zoom in the tab's profile, else the default page zoom.
    func siteZoom(for url: URL?, in tab: BrowserTab) -> Double {
        BrowserSitePermissionStore.siteKey(for: url).flatMap { tab.dataContext.sitePermissions.zoom(host: $0) }
            ?? settingsStore.settings.defaultZoom
    }

    /// Every loaded page with a site (and every start page) takes its
    /// site's zoom: a remembered zoom or the default page zoom changed.
    func applySiteZooms() {
        for tab in tabsWithPeek where !tab.isRestorePending {
            let url = tab.webView.url
            guard tab.isStartPage || BrowserSitePermissionStore.siteKey(for: url) != nil else { continue }
            apply(zoom: siteZoom(for: url, in: tab), to: tab)
        }
    }

    private func apply(zoom: Double, to tab: BrowserTab) {
        tab.zoom = zoom
        if tab.webView.pageZoom != zoom {
            tab.webView.pageZoom = zoom
        }
        if tab === pageTab {
            updateZoomChip()
        }
    }

    /// The percentage chip in the address field while the page's zoom (the
    /// Peek's when one is open) differs from the default; clicking it
    /// resets that site (⌘0).
    func updateZoomChip() {
        let defaultZoom = settingsStore.settings.defaultZoom
        guard let tab = pageTab, !tab.isRestorePending, !BrowserZoom.isSame(tab.zoom, defaultZoom) else {
            zoomChip?.isHidden = true
            return
        }
        let chip: ChromeButton
        if let existing = zoomChip {
            chip = existing
        } else {
            chip = ChromeButton(
                title: BrowserZoom.percent(tab.zoom),
                theme: theme,
                kind: .standard,
                target: self,
                action: #selector(zoomChipPressed(_:))
            )
            chip.heightAnchor.constraint(equalToConstant: 20).isActive = true
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            toolbar.addressAccessories.addArrangedSubview(chip)
            zoomChip = chip
        }
        let percent = BrowserZoom.percent(tab.zoom)
        chip.apply(theme: theme)
        chip.title = percent
        chip.toolTip = "Zoom \(percent). Click to reset to \(BrowserZoom.percent(defaultZoom)) (⌘0)"
        chip.setAccessibilityLabel("Zoom \(percent), reset to default")
        chip.isHidden = false
    }

    @objc func zoomChipPressed(_ sender: NSButton) {
        resetZoom()
    }
}
