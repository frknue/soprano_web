import AppKit
import WebKit

/// Settings in a tab (`BrowserSettingsWebPage`): opening it, its messages,
/// the state every open Settings page shows, the native sheets it opens on
/// its window and the New Little Arc shortcut recorder.
extension BrowserWindowManager {
    func showSettings() {
        showSettings(page: .general)
    }

    /// Selects the Settings tab of the current Space of the most recently
    /// active normal window (never a private one), else opens one there or
    /// in a new window; `page` other than General opens its sheet over it
    /// (Help ▸ Keyboard Shortcuts, the Command Bar's settings rows, Manage
    /// Extensions…).
    func showSettings(page: BrowserSettingsPage) {
        let controller: BrowserWindowController
        if let target = outsideTabbedController {
            controller = target
            if let tab = target.visibleTabs.first(where: Self.isSettingsTab) {
                target.selectTab(id: tab.id, focus: true)
            } else {
                target.newTab(url: BrowserSettingsWebPage.url.absoluteString)
            }
            present(target)
        } else {
            controller = newWindow(url: BrowserSettingsWebPage.url.absoluteString)
        }
        let sheet: BrowserSettingsWebPage.Sheet? = switch page {
        case .general: nil
        case .searchEngines: .searchEngines
        case .shortcuts: .shortcuts
        case .websites: .websites
        case .websiteData: .websiteData
        case .extensions: .extensions
        }
        if let sheet {
            openSettingsSheet(sheet, on: controller)
        }
    }

    /// A tab showing Settings, loaded or still to load.
    static func isSettingsTab(_ tab: BrowserTab) -> Bool {
        let address = tab.webView.url?.absoluteString ?? tab.pendingURL ?? tab.lifecycle.pendingRestore?.url
        return BrowserSettingsWebPage.isSettings(address.flatMap(URL.init(string:)))
    }

    // MARK: Messages

    /// One message from a Settings page; anything not from its own main
    /// frame is dropped. The page gets the whole state back, so a refused
    /// value puts its control back.
    func handleSettingsMessage(
        _ body: [String: Any],
        tab: BrowserTab,
        frame: WKFrameInfo,
        in controller: BrowserWindowController
    ) {
        // The frame's document, not only its address, must be Settings'.
        guard BrowserSettingsWebPage.acceptsMessage(frameURL: frame.request.url, isMainFrame: frame.isMainFrame),
              frame.securityOrigin.protocol.lowercased() == BrowserStartPageSchemeHandler.scheme,
              frame.securityOrigin.host.lowercased() == BrowserSettingsWebPage.host,
              BrowserSettingsWebPage.isSettings(tab.webView.url),
              let message = BrowserSettingsWebPage.Message(body)
        else { return }
        switch message {
        case .ready:
            break
        case let .set(key, value):
            settingsStore.update { BrowserSettingsWebPage.apply(key: key, value: value, to: &$0) }
        case let .open(sheet):
            openSettingsSheet(sheet, on: controller)
        case .updateLists:
            let blocker = contentBlocker
            Task { await blocker.update() }
        case .makeDefault:
            // The system's prompt; the harness shows nothing.
            guard !placement.isOffscreen else { break }
            BrowserDefaultBrowser.makeDefault { [weak self] _ in self?.refreshSettingsPages() }
        case .chooseDownloads:
            chooseDownloadFolder(on: controller)
        case .recordShortcut:
            recordGlobalShortcut(in: controller, tab: tab)
        case let .allowTranslation(code):
            settingsStore.update { $0.neverTranslateLanguages.removeAll { $0 == code } }
        case .revealSettingsFile:
            guard !placement.isOffscreen else { break }
            NSWorkspace.shared.activateFileViewerSelecting([settingsStore.url])
        }
        pushSettingsState(to: tab)
    }

    // MARK: State

    /// What `tab`'s Settings page shows; a private window's in Folio Ink.
    func settingsPageState(for tab: BrowserTab?) -> [String: Any] {
        let settings = settingsStore.settings
        let handler = BrowserDefaultBrowser.currentHandler()
        let recording = shortcutRecorder != nil
        let shortcut = BrowserShortcut(settings.globalLittleArcShortcut)?.display ?? "⌥⌘N"
        let environment = BrowserSettingsWebPage.Environment(
            theme: tab?.dataContext.kind.isPrivate == true ? .folioInk : themeManager.currentTheme,
            blockerStatus: contentBlocker.statusText,
            canUpdateLists: contentBlocker.isEnabled && !contentBlocker.isUpdating,
            defaultBrowser: BrowserDefaultBrowser.displayName(of: handler),
            isDefaultBrowser: BrowserDefaultBrowser.isDefault(handler: handler),
            canBecomeDefault: BrowserDefaultBrowser.canBecomeDefault(),
            globalShortcut: recording ? "Type a shortcut…" : shortcut,
            isRecordingShortcut: recording,
            shortcutUnavailable: settings.globalLittleArcEnabled && !recording
                && globalHotKey.map { !$0.isRegistered } == true,
            settingsFile: settingsStore.displayPath,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        )
        return BrowserSettingsWebPage.state(settings: settings, environment: environment)
    }

    func pushSettingsState(to tab: BrowserTab) {
        guard BrowserSettingsWebPage.isSettings(tab.webView.url) else { return }
        tab.webView.evaluateJavaScript(
            BrowserSettingsWebPage.applyScript(settingsPageState(for: tab)),
            in: nil,
            in: .page
        ) { _ in }
    }

    /// Every open Settings page shows the current state.
    func refreshSettingsPages() {
        for controller in controllers {
            for tab in controller.tabsWithPeek where BrowserSettingsWebPage.isSettings(tab.webView.url) {
                pushSettingsState(to: tab)
            }
        }
    }

    // MARK: Sheets

    /// `sheet` over `controller`'s window (one sheet at a time).
    func openSettingsSheet(_ sheet: BrowserSettingsWebPage.Sheet, on controller: BrowserWindowController) {
        guard !placement.isOffscreen else {
            settingsSheetRequests.append(sheet)
            return
        }
        guard let window = controller.window, window.attachedSheet == nil else { return }
        switch sheet {
        case .searchEngines: showSearchEngines(on: window)
        case .shortcuts: showShortcuts(on: window)
        case .websites: showWebsites(on: window)
        case .websiteData: showWebsiteData(on: window)
        case .linkRouting: showLinkRouting(on: window)
        case .extensions: showExtensions(on: window)
        case .clearData: controller.showClearBrowsingData()
        case .importData: showImportSheet(from: controller)
        }
    }

    /// Settings ▸ Manage search engines and site search.
    func showSearchEngines(on parent: NSWindow) {
        guard searchEnginesSheet == nil else { return }
        let sheet = BrowserSearchEnginesSheet(settingsStore: settingsStore, theme: themeManager.currentTheme)
        guard let window = sheet.window else { return }
        searchEnginesSheet = sheet
        parent.beginSheet(window) { [weak self] _ in self?.searchEnginesSheet = nil }
    }

    /// Settings ▸ Customize keyboard shortcuts.
    func showShortcuts(on parent: NSWindow) {
        guard shortcutsSheet == nil else { return }
        let sheet = BrowserShortcutsSheet(settingsStore: settingsStore, theme: themeManager.currentTheme)
        guard let window = sheet.window else { return }
        shortcutsSheet = sheet
        parent.beginSheet(window) { [weak self] _ in self?.shortcutsSheet = nil }
    }

    /// Settings ▸ Downloads ▸ Change: a folder panel on the window.
    private func chooseDownloadFolder(on controller: BrowserWindowController) {
        guard let window = controller.window, window.attachedSheet == nil, !placement.isOffscreen else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settingsStore.settings.downloadDirectoryURL
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.settingsStore.update { $0.downloadDirectory = url.path }
        }
    }

    // MARK: New Little Arc shortcut

    /// The next acceptable shortcut typed on the Settings page `tab` (with
    /// ⌘ or ⌃, or ⌥ on a named key; nothing the system, text editing or
    /// another command uses: `BrowserGlobalShortcut`) becomes the global
    /// one and turns it on; anything else beeps. Esc cancels, and so does
    /// the page leaving the screen: another tab, a navigation, the tab or
    /// window closing, the window losing focus (`settingsRecorderTabLeft`).
    /// Keys typed in other windows pass by, and the registered hotkey lets
    /// go meanwhile so its own combination can be typed.
    private func recordGlobalShortcut(in controller: BrowserWindowController, tab: BrowserTab) {
        guard shortcutRecorder == nil, let window = controller.window else { return }
        globalHotKey?.suspend()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self else { return event }
            if self.isRecorderTabLeft() {
                self.finishRecordingGlobalShortcut(nil)
                return event
            }
            switch BrowserGlobalShortcut.recorderAnswer(
                keyCode: event.keyCode,
                shortcut: BrowserShortcut(event: event),
                inRecorderWindow: event.window != nil && event.window === window,
                keymap: self.settingsStore.settings.keymap
            ) {
            case .pass:
                return event
            case .cancel:
                self.finishRecordingGlobalShortcut(nil)
            case .refuse:
                NSSound.beep()
            case let .accept(shortcut):
                self.finishRecordingGlobalShortcut(shortcut)
            }
            return nil
        }
        guard let monitor else {
            globalHotKey?.resume()
            return
        }
        let observers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishRecordingGlobalShortcut(nil) }
            }
        }
        shortcutRecorder = (monitor, observers, tab.id)
        refreshSettingsPages()
    }

    /// The recording page is gone from its window's page area: the tab
    /// closed or isn't the page shown, or it left Settings.
    private func isRecorderTabLeft() -> Bool {
        guard let recorder = shortcutRecorder else { return false }
        guard let (controller, tab) = tabOrPeek(id: recorder.tabID) else { return true }
        return controller.pageTab !== tab || !BrowserSettingsWebPage.isSettings(tab.webView.url)
    }

    /// Called whenever a window's page changes (`updateChrome`: another
    /// tab, a commit, a closed tab): a recording whose page left ends,
    /// and the old hotkey comes back.
    func settingsRecorderTabLeft() {
        if isRecorderTabLeft() {
            finishRecordingGlobalShortcut(nil)
        }
    }

    private func finishRecordingGlobalShortcut(_ shortcut: BrowserShortcut?) {
        guard let recorder = shortcutRecorder else { return }
        NSEvent.removeMonitor(recorder.monitor)
        recorder.observers.forEach(NotificationCenter.default.removeObserver)
        shortcutRecorder = nil
        // The old shortcut comes back first; a new one replaces it.
        globalHotKey?.resume()
        if let shortcut {
            settingsStore.update {
                $0.globalLittleArcShortcut = shortcut.storageText
                $0.globalLittleArcEnabled = true
            }
        }
        refreshSettingsPages()
    }
}
