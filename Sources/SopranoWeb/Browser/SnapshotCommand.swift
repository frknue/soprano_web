import AppKit
import WebKit

/// `SopranoWeb snapshot --out <png> [--url <url>] [--size 1500x940]
/// [--theme folio-paper|folio-ink|<id>] [--wait <seconds>]`
///
/// Builds the real window off-screen with volatile stores, waits for the page,
/// captures the chrome with AppKit and the page with WebKit, and writes a PNG.
@MainActor
enum SnapshotCommand {
    struct Options {
        var out: URL
        var url: String?
        var size = NSSize(width: 1440, height: 900)
        var theme = AppTheme.folioPaper.id
        var wait: Double = 1.0
        var sidebar: BrowserSidebarSection?
        var showFind = false
        var showSettings = false
        var verticalTabs = false
        var collapsed = false
        var showHints = false
        var showHelp = false
        var showPrompt = false
        var allowPopups: String?
        var extraTabs: [String] = []
        var clicks: [Click] = []
        var showSheet = false
        var printTabs = false
        var signIn: String?
        var sheetButton: String?
        var elementClicks: [String] = []
        var showSecurityInfo = false
        var session = SnapshotSessionOptions()
        var tabAudio = false
        var hoverSelector: String?
        var backURL: String?
        var address: String?
        var focusAddress = false
        /// `--site-permission host:permission=allow|deny`, seeded before the window.
        var sitePermissions: [(host: String, permission: SitePermission, decision: SitePermissionDecision)] = []
        var autoplay: AutoplayPolicy?
        /// Toggles the selected tab's mute this many seconds after the load starts.
        var muteAfter: Double?
        /// Prints the selected tab's audio/mute state on every change.
        var traceAudio = false
        var showWebsites = false
        var captureStatus: BrowserCaptureStatus?
        var pageTools = SnapshotPageTools.Options()
        var privacy = PrivacyOptions()
        var pins = PinOptions()
        var sleep = SnapshotSleepOptions()
        var blocker = SnapshotBlockerOptions()
        var searchEngines = SnapshotSearchEngineOptions()
        /// `--shortcuts-sheet`: capture Settings ▸ Keyboard shortcuts.
        var showsShortcutsSheet = false
        var imports = SnapshotImportOptions()
        var extensions = SnapshotExtensionOptions()
    }

    enum OptionError: Error, CustomStringConvertible {
        case missingValue(String)
        case unknownOption(String)
        case badSize(String)
        case missingOut

        var description: String {
            switch self {
            case .missingValue(let option): "\(option) needs a value"
            case .unknownOption(let option): "unknown option \(option)"
            case .badSize(let value): "--size must be WIDTHxHEIGHT, got \(value)"
            case .missingOut: "--out <png> is required"
            }
        }
    }

    static let usage = """
    usage: SopranoWeb snapshot --out <png> [--url <url>] [--size 1500x940]
                               [--theme folio-paper|folio-ink|<id>] [--wait <seconds>]
                               [--sidebar history|archive|downloads] [--find] [--settings]
                               [--vertical-tabs] [--collapsed] [--hints] [--help] [--prompt]
                               [--allow-popups <host>] [--tab <url>]... [--sheet] [--print-tabs]
                               [--click [cmd-|shift-cmd-|shift-|opt-|middle-]X,Y]...
                               [--sign-in <user:password>] [--sheet-button <title>]
                               [--click-element <css selector>]... [--security-info]
    \(SnapshotSessionOptions.usage)
                               [--tabs <url>,<url>…] [--tab-audio] [--hover <css selector>]
                               [--back-url <url>]
                               [--address <text>] [--focus-address]
                               [--site-permission host:permission=allow|deny] [--autoplay <policy>]
                               [--mute-after <seconds>] [--trace-audio] [--websites]
                               [--capture camera|microphone|camera-muted-mic|microphone-muted]
    \(SnapshotPageTools.usage)
    \(privacyUsage)
    \(pinsUsage)
    \(SnapshotSleepOptions.usage)
    \(SnapshotBlockerOptions.usage)
    \(SnapshotSearchEngineOptions.usage)
    \(SnapshotImportOptions.usage)
    \(SnapshotExtensionOptions.usage)
    """

    nonisolated static func parse(_ arguments: [String]) throws -> Options {
        var out: URL?
        var options = Options(out: URL(fileURLWithPath: "/dev/null"))
        var index = 0
        func value(_ option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw OptionError.missingValue(option) }
            return arguments[index]
        }
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--out":
                out = URL(fileURLWithPath: try value(option))
            case "--url":
                options.url = try value(option)
            case "--size":
                let size = try value(option)
                let parts = size.split(separator: "x", maxSplits: 1)
                guard parts.count == 2,
                      let width = Double(parts[0]),
                      let height = Double(parts[1]),
                      width > 0, height > 0
                else {
                    throw OptionError.badSize(size)
                }
                options.size = NSSize(width: width, height: height)
            case "--theme":
                options.theme = try value(option)
            case "--wait":
                let value = try value(option)
                guard let seconds = Double(value), seconds >= 0 else {
                    throw OptionError.missingValue("--wait")
                }
                options.wait = seconds
            case "--sidebar":
                let value = try value(option)
                guard let section = BrowserSidebarSection(rawValue: value) else {
                    throw OptionError.unknownOption("--sidebar \(value)")
                }
                options.sidebar = section
            case "--find":
                options.showFind = true
            case "--settings":
                options.showSettings = true
            case "--vertical-tabs":
                options.verticalTabs = true
            case "--collapsed":
                options.collapsed = true
            case "--hints":
                options.showHints = true
            case "--help":
                options.showHelp = true
            case "--prompt":
                options.showPrompt = true
            case "--allow-popups":
                options.allowPopups = try value(option)
            case "--tab":
                options.extraTabs.append(try value(option))
            case "--click":
                let value = try value(option)
                guard let click = Click.parse(value) else {
                    throw OptionError.unknownOption("--click \(value)")
                }
                options.clicks.append(click)
            case "--sheet":
                options.showSheet = true
            case "--print-tabs":
                options.printTabs = true
            case "--sign-in":
                options.signIn = try value(option)
            case "--sheet-button":
                options.sheetButton = try value(option)
            case "--click-element":
                options.elementClicks.append(try value(option))
            case "--security-info":
                options.showSecurityInfo = true
            case let flag where SnapshotSessionOptions.flags.contains(flag):
                try options.session.parse(flag) { try value(flag) }
            case let flag where SnapshotCommandBarAction.flags.contains(flag):
                if let action = try SnapshotCommandBarAction.parse(
                    flag,
                    value: { try value(flag) },
                    peek: { index + 1 < arguments.count ? arguments[index + 1] : nil },
                    skip: { index += 1 }
                ) {
                    options.session.actions.append(.commandBar(action))
                }
            case let flag where SnapshotImportOptions.flags.contains(flag):
                try options.imports.parse(
                    flag,
                    value: { try value(flag) },
                    peek: { index + 1 < arguments.count ? arguments[index + 1] : nil },
                    skip: { index += 1 }
                )
            case "--shortcuts-sheet":
                options.showsShortcutsSheet = true
            case "--tabs":
                options.extraTabs += try value(option)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "--tab-audio":
                options.tabAudio = true
            case "--hover":
                options.hoverSelector = try value(option)
            case "--back-url":
                options.backURL = try value(option)
            case "--address":
                options.address = try value(option)
            case "--focus-address":
                options.focusAddress = true
            case "--site-permission":
                let value = try value(option)
                let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      let colon = parts[0].firstIndex(of: ":"),
                      let decision = SitePermissionDecision(rawValue: parts[1])
                else {
                    throw OptionError.unknownOption("--site-permission \(value)")
                }
                options.sitePermissions.append((
                    String(parts[0][..<colon]),
                    SitePermission(rawValue: String(parts[0][parts[0].index(after: colon)...])),
                    decision
                ))
            case "--autoplay":
                let value = try value(option)
                guard let policy = AutoplayPolicy(rawValue: value) else {
                    throw OptionError.unknownOption("--autoplay \(value)")
                }
                options.autoplay = policy
            case "--mute-after":
                guard let seconds = Double(try value(option)), seconds >= 0 else {
                    throw OptionError.missingValue("--mute-after")
                }
                options.muteAfter = seconds
            case "--trace-audio":
                options.traceAudio = true
            case "--websites":
                options.showWebsites = true
            case "--capture":
                switch try value(option) {
                case "camera": options.captureStatus = BrowserCaptureStatus(camera: .active, microphone: .active)
                case "camera-muted-mic": options.captureStatus = BrowserCaptureStatus(camera: .active, microphone: .muted)
                case "microphone": options.captureStatus = BrowserCaptureStatus(camera: .off, microphone: .active)
                case "microphone-muted": options.captureStatus = BrowserCaptureStatus(camera: .off, microphone: .muted)
                default: throw OptionError.unknownOption("--capture")
                }
            case _ where SnapshotPageTools.flags.contains(option):
                SnapshotPageTools.parse(option, try value(option), into: &options.pageTools)
            default:
                guard try parsePins(option, value: { try value(option) }, into: &options.pins)
                    || parsePrivacy(option, value: { try value(option) }, into: &options.privacy)
                    || SnapshotSleepOptions.parse(option, value: { try value(option) }, into: &options.sleep)
                    || SnapshotBlockerOptions.parse(option, value: { try value(option) }, into: &options.blocker)
                    || SnapshotSearchEngineOptions.parse(option, value: { try value(option) }, into: &options.searchEngines)
                    || SnapshotExtensionOptions.parse(option, value: { try value(option) }, into: &options.extensions)
                else {
                    throw OptionError.unknownOption(option)
                }
            }
            index += 1
        }
        guard let out else { throw OptionError.missingOut }
        options.out = out
        return options
    }

    private static func wait(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            // Each turn drains its pool, as the app's event loop does, so a
            // released web view (a tab falling asleep) really goes away.
            autoreleasepool {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: min(deadline, Date().addingTimeInterval(0.05))
                )
            }
        }
    }

    static func run(arguments: [String]) {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n\(usage)\n".utf8))
            exit(2)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // `--support-dir` keeps the folder for a second run; otherwise a
        // temporary one goes away at the end.
        let temp = options.sleep.supportDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-snapshot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        var settings = BrowserSettings(
            searchEngine: .duckDuckGo,
            homepage: "",
            themeID: options.theme,
            appearance: .system,
            restoreSession: options.session.restoresSession,
            downloadDirectory: temp.path,
            verticalTabs: options.verticalTabs,
            // Never reach a search engine from the harness; `--address`
            // injects canned suggestions instead.
            includeSearchSuggestions: false
        )
        let settingsURL = temp.appendingPathComponent("settings.json")
        // `--support-dir`: a second run reads the shortcuts the first saved
        // (Settings ▸ Keyboard shortcuts), decoded as the app decodes them.
        if let saved = JSONFile.read(BrowserSettings.self, at: settingsURL) {
            settings.shortcuts = saved.shortcuts
        }
        let settingsStore = BrowserSettingsStore(url: settingsURL, settings: settings)
        if let autoplay = options.autoplay {
            settingsStore.update { $0.autoplay = autoplay }
        }
        options.sleep.apply(to: settingsStore)
        options.searchEngines.apply(to: settingsStore)
        let themeManager = ThemeManager(themeId: options.theme, appearance: .system)
        let downloads = BrowserDownloadStore(url: temp.appendingPathComponent("downloads.json"))
        let profiles = BrowserProfileStore(url: temp.appendingPathComponent("profiles.json"))
        let bookmarksURL = temp.appendingPathComponent("bookmarks.json")
        prepareBookmarksFile(options.pins, at: bookmarksURL)
        let spaces = BrowserSpaceStore(
            url: temp.appendingPathComponent("spaces.json"),
            profiles: profiles.profiles,
            bookmarksURL: bookmarksURL
        )
        // Spaces that shared a profile in the support folder's files were
        // separated on load (the manager adds their profiles).
        for separation in spaces.separations {
            let name = spaces.space(id: separation.spaceID)?.displayName ?? "?"
            print("spaces: separated \(name) from \(separation.from?.uuidString ?? "a missing profile") -> profile \(separation.spaceID.uuidString)")
        }
        if options.pins.seedTree {
            seedPinTree(spaces, inSpace: spaces.space(ofProfile: BrowserProfile.defaultID)?.id)
        }
        // `--create-space`: the Spaces exist before any window opens.
        options.session.createSpaces(in: spaces, profiles: profiles)
        let session = BrowserSessionStore(url: temp.appendingPathComponent("session.json"))
        options.session.prepare(sessionURL: session.url)

        let defaultsSuite = "com.soprano.web.snapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.set(options.collapsed, forKey: BrowserWindowController.verticalSidebarCollapsedKey)

        // Every window the manager makes stays off every display and is
        // never ordered front or made key. The temporary folder is the
        // support folder: Default's files, and `Profiles/<id>/`.
        let manager = BrowserWindowManager(
            themeManager: themeManager,
            settingsStore: settingsStore,
            profiles: profiles,
            supportDirectory: temp,
            spaces: spaces,
            archive: BrowserArchiveStore(url: temp.appendingPathComponent("archive.json")),
            downloads: downloads,
            faviconStore: BrowserFaviconStore(directory: temp.appendingPathComponent("Favicons", isDirectory: true)),
            sessionStore: session,
            persistsSession: false,
            placement: .offscreen(size: options.size),
            defaults: defaults,
            filterLists: options.blocker.sources,
            extensionStorage: .volatile,
            checksExtensionUpdates: false
        )
        options.sleep.apply(to: manager)
        // ⇧⌘C and ⌥⇧⌘C copy to a pasteboard of the harness's own, never
        // the user's general one.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.soprano.web.snapshot.\(UUID().uuidString)"))
        manager.pasteboard = pasteboard
        let history = manager.defaultContext.history
        let sitePermissions = manager.defaultContext.sitePermissions
        if let host = options.allowPopups {
            sitePermissions.set(.popups, .allow, host: host)
        }
        for seed in options.sitePermissions {
            sitePermissions.set(seed.permission, seed.decision, host: seed.host)
        }
        manager.restoreSession()
        guard var controller = manager.controllers.first, var window = controller.window else {
            FileHandle.standardError.write(Data("Snapshot could not create the window.\n".utf8))
            exit(1)
        }
        window.displayIfNeeded()
        options.extensions.prepare(manager, wait: wait)

        if options.focusAddress {
            // Focused but not edited: the field must follow the navigation.
            controller.focusAddressBar()
        }
        if let value = options.url,
           let url = BrowserAddressResolver.resolve(value, searchEngines: settingsStore.settings.searchEngines)
        {
            if BrowserAddressResolver.isStartPage(url) {
                // Already on the start page.
            } else if let tab = controller.selectedTab {
                if let back = options.backURL,
                   let backURL = BrowserAddressResolver.resolve(back, searchEngines: settingsStore.settings.searchEngines)
                {
                    // Load a first page so Back has somewhere to go.
                    controller.navigate(tab, to: backURL)
                    let backDeadline = Date().addingTimeInterval(5)
                    repeat {
                        wait(0.05)
                    } while (tab.webView.isLoading || tab.webView.url != backURL) && Date() < backDeadline
                }
                controller.navigate(tab, to: url)
            }
        }
        for value in options.extraTabs {
            controller.newTab(url: value, select: false)
        }
        if options.tabAudio {
            // The second tab plays audio, the third is muted (or the
            // selected tab plays when there is only one).
            let tabs = controller.tabs
            let playing = tabs.count > 1 ? tabs[1] : tabs.first
            playing?.isPlayingAudio = true
            if let playing { controller.metadataChanged(playing) }
            if tabs.count > 2 {
                tabs[2].isMuted = true
                controller.metadataChanged(tabs[2])
            }
        }
        if let tab = controller.selectedTab {
            if let muteAfter = options.muteAfter {
                let muting = controller
                Timer.scheduledTimer(withTimeInterval: muteAfter, repeats: false) { _ in
                    MainActor.assumeIsolated { muting.toggleMute(tab) }
                }
            }
            if options.traceAudio {
                let start = Date()
                var last: (Bool, Bool)?
                Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let state = (tab.isPlayingAudio, tab.isMuted)
                        guard last.map({ $0 != state }) ?? true else { return }
                        last = state
                        print(String(
                            format: "audio t=%.2fs playing=%@ muted=%@",
                            Date().timeIntervalSince(start),
                            state.0 ? "true" : "false",
                            state.1 ? "true" : "false"
                        ))
                    }
                }
            }
        }

        // Imports (and exports) before every other action, so the pins,
        // Spaces and Archive flags print what they made. In a pool of its
        // own, so the tabs it makes go when closed (an imported profile's
        // data store is removed at the end).
        let importOutcome = options.imports.isActive
            ? autoreleasepool { options.imports.run(manager: manager, controller: controller) }
            : SnapshotImportOptions.Outcome()

        runPrivacyScenario(options.privacy, controller: controller, wait: options.wait)

        if let section = options.sidebar {
            if history.visitCount() == 0 {
                history.importVisits(Self.seededHistory(now: Date()))
            }
            if downloads.records.isEmpty, !options.session.startsDownloads {
                let finished = downloads.begin(
                    url: "https://example.com/files/report.pdf",
                    filename: "report.pdf"
                )
                downloads.finish(id: finished.id, path: "/tmp/report.pdf")
                let failed = downloads.begin(
                    url: "https://webkit.org/archive.zip",
                    filename: "archive.zip"
                )
                downloads.fail(id: failed.id, message: "The network connection was lost.")
                let active = downloads.begin(
                    url: "https://example.com/files/large-report.pdf",
                    filename: "large-report.pdf"
                )
                downloads.updateProgress(id: active.id, fraction: 0.42)
            }
            if section == .archive {
                SnapshotArchiveAction.seed(manager.archive, spaces: manager.spaces, now: Date())
            }
            controller.showSidebar(section: section)
        }
        if options.pins.isActive {
            runPinScenario(options.pins, controller: controller)
        }
        if options.showFind {
            controller.showFindBar()
        }
        let deadline = Date().addingTimeInterval(options.wait)
        while Date() < deadline {
            autoreleasepool {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: min(deadline, Date().addingTimeInterval(0.05))
                )
            }
        }
        if let credentials = options.signIn {
            submitSignIn(credentials, controller: controller)
            wait(options.wait)
        }
        for selector in options.elementClicks {
            click(selector, controller: controller)
            wait(options.wait)
        }
        if options.showSecurityInfo {
            controller.showConnectionInfo()
            wait(0.35)
        }
        if let title = options.sheetButton {
            pressSheetButton(title, window: window)
            wait(options.wait)
        }
        options.session.run(manager, wait: options.wait)
        // Everything below works on the captured window: `--capture-window
        // n`, else the most recently active one. (Bound in a block, so only
        // `controller` and `window` keep it.)
        if let target = options.session.captureController(in: manager), let targetWindow = target.window {
            if target !== controller {
                controller = target
                window = targetWindow
                if let section = options.sidebar {
                    controller.showSidebar(section: section)
                }
                wait(0.3)
            }
        } else {
            FileHandle.standardError.write(Data("Snapshot has no window to capture.\n".utf8))
            exit(1)
        }
        // Settings and its sheets are built but never ordered in, so the
        // harness puts nothing on screen. Websites shows the captured
        // window's Space.
        let settingsPreview = options.showSettings
            ? SettingsWindowController(
                settingsStore: settingsStore,
                themeManager: themeManager,
                contentBlocker: manager.contentBlocker
            )
            : nil
        let websitesSheet = options.showWebsites
            ? manager.makeWebsitesSheet(selected: controller.profileID)
            : nil
        if let websitesSheet {
            print("websites: space picker \(websitesSheet.pickerTitle ?? "hidden")")
        }
        let searchEnginesSheet = options.searchEngines.makeSheet(
            settingsStore: settingsStore,
            theme: themeManager.currentTheme
        )
        let shortcutsSheet = options.showsShortcutsSheet ? SnapshotCommandBarAction.sheet(for: manager) : nil
        let extensionsSheet = options.extensions.showsSheet ? manager.makeExtensionsSheet() : nil
        if let extensionsSheet {
            extensionsSheet.apply(theme: themeManager.currentTheme)
            extensionsSheet.dump.forEach { print("extensions-sheet: \($0)") }
        }
        if let shortcutsSheet {
            shortcutsSheet.apply(theme: themeManager.currentTheme)
            shortcutsSheet.dump.forEach { print("shortcuts: \($0)") }
        }
        if settingsPreview != nil || websitesSheet != nil || searchEnginesSheet != nil
            || shortcutsSheet != nil || extensionsSheet != nil
        {
            wait(0.3)
        }

        if options.focusAddress, let tab = controller.selectedTab {
            let editor = controller.toolbar.addressEditor
            let shown = editor?.string ?? controller.toolbar.addressField.stringValue
            let page = tab.failedURL ?? tab.webView.url?.absoluteString ?? ""
            let follows = editor != nil && shown == page && !page.isEmpty
            print("address-field: \(shown) (focused: \(editor != nil ? "yes" : "no"))")
            print("address-follows-navigation: \(follows ? "yes" : "no") (page \(page))")
        }
        if let address = options.address {
            AddressBarSnapshot.type(address, into: controller, history: history)
            wait(0.3)
        }
        SnapshotPageTools.run(options.pageTools, controller: controller)

        if options.showHints {
            controller.selectedTab?.vimium?.startHintsForSnapshot()
            let hintDeadline = Date().addingTimeInterval(0.6)
            while Date() < hintDeadline {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: min(hintDeadline, Date().addingTimeInterval(0.05))
                )
            }
        }
        if options.showHelp {
            controller.showVimiumHelp()
            wait(0.35)
        }
        if options.showPrompt {
            controller.presentVimiumPrompt(initialText: "", newTab: false)
            wait(0.35)
        }
        for click in options.clicks {
            if let webView = controller.selectedTab?.webView {
                perform(click, in: webView)
            }
            wait(options.wait)
        }
        if let selector = options.hoverSelector,
           let webView = controller.selectedTab?.webView,
           let argument = try? JSONSerialization.data(withJSONObject: [selector]),
           let literal = String(data: argument, encoding: .utf8)
        {
            // A synthetic mouseover runs the real link-hover script.
            webView.evaluateJavaScript(
                "document.querySelector(\(literal)[0])?.dispatchEvent(new MouseEvent('mouseover', {bubbles: true}))"
            ) { _, _ in }
            wait(0.5)
        }
        if let status = options.captureStatus {
            controller.toolbar.captureIndicator.update(status)
        }
        if options.printTabs {
            printTabs(controller)
        }
        let extensionPopup = options.extensions.performActions(in: controller, wait: wait)
        options.extensions.report(manager, controller: controller)
        let bookmarkPopover = makePinPopover(options.pins, controller: controller)
        let pinPreview = makePinPreview(options.pins, controller: controller)
        let spaceSheet = makeSpaceSheet(options.pins, controller: controller)

        let captureWindow: NSWindow
        let privacySheet = makePrivacySheet(options.privacy, controller: controller)
        if let privacySheet {
            captureWindow = privacySheet
        } else if options.showSettings {
            captureWindow = settingsPreview?.window ?? window
        } else if options.showHelp {
            captureWindow = NSApp.windows.first { $0.title == "Vimium Help" } ?? window
        } else if options.showPrompt {
            captureWindow = NSApp.windows.first { $0 is VimiumPromptPanel } ?? window
        } else {
            captureWindow = window
        }
        if options.showSheet, let sheet = captureWindow.attachedSheet {
            // NSAlert draws through a visual effect view the cached pass
            // leaves blank, so the prompt is printed instead.
            var texts: [String] = []
            var queue = sheet.contentView.map { [$0] } ?? []
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let field = view as? NSTextField, !field.stringValue.isEmpty {
                    texts.append(field.stringValue)
                } else if let button = view as? NSButton, !button.title.isEmpty {
                    texts.append("[\(button.title)]")
                }
                queue.append(contentsOf: view.subviews)
            }
            print("sheet: " + texts.joined(separator: " | "))
        }
        let settingsSheetWindow: NSWindow? = websitesSheet?.window ?? searchEnginesSheet?.window ?? extensionsSheet?.window
        let otherSheetWindow: NSWindow? = shortcutsSheet?.window ?? spaceSheet?.window ?? importOutcome.window
        let captured: NSWindow = settingsSheetWindow ?? otherSheetWindow ?? captureWindow
        guard let captureContent = captured.contentView else {
            FileHandle.standardError.write(Data("Snapshot could not find the window to capture.\n".utf8))
            exit(1)
        }
        captureContent.layoutSubtreeIfNeeded()
        captureContent.displayIfNeeded()

        guard let baseRep = captureContent.bitmapImageRepForCachingDisplay(in: captureContent.bounds) else {
            FileHandle.standardError.write(Data("Snapshot could not allocate the image.\n".utf8))
            exit(1)
        }
        captureContent.cacheDisplay(in: captureContent.bounds, to: baseRep)
        let base = NSImage(size: captureContent.bounds.size)
        base.addRepresentation(baseRep)

        // Every page on screen: the selected tab, or each pane of its split.
        var pageImages: [(webView: BrowserWebView, image: NSImage)] = []
        if privacySheet == nil, !options.showSettings, !options.showHelp, !options.showPrompt,
           websitesSheet == nil, searchEnginesSheet == nil, shortcutsSheet == nil, spaceSheet == nil,
           extensionsSheet == nil,
           importOutcome.window == nil,
           !options.showFind,
           captureWindow === window
        {
            for tab in controller.shownTabs where tab.lifecycle.crashView == nil {
                let webView = tab.webView
                var finished = false
                webView.takeSnapshot(with: nil) { image, _ in
                    if let image { pageImages.append((webView, image)) }
                    finished = true
                }
                let pageDeadline = Date().addingTimeInterval(5)
                while !finished, Date() < pageDeadline {
                    _ = RunLoop.current.run(
                        mode: .default,
                        before: min(pageDeadline, Date().addingTimeInterval(0.05))
                    )
                }
            }
        }
        // A Peek's page is a second web view over the page.
        var peekImage: NSImage?
        if !pageImages.isEmpty, let peekWebView = controller.peek?.tab.webView {
            var finished = false
            peekWebView.takeSnapshot(with: nil) { image, _ in
                peekImage = image
                finished = true
            }
            let peekDeadline = Date().addingTimeInterval(5)
            while !finished, Date() < peekDeadline {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: min(peekDeadline, Date().addingTimeInterval(0.05))
                )
            }
        }

        let output = NSImage(size: captureContent.bounds.size)
        output.lockFocus()
        NSColor.clear.setFill()
        captureContent.bounds.fill()
        base.draw(in: captureContent.bounds)
        for (webView, image) in pageImages {
            image.draw(in: webView.convert(webView.bounds, to: captureContent))
        }
        // A split's focus ring sits over the focused pane's page.
        let ring = controller.splitPage.focusRing
        if pageImages.count > 1, !ring.isHidden, ring.window === captureWindow,
           let rep = ring.bitmapImageRepForCachingDisplay(in: ring.bounds)
        {
            ring.cacheDisplay(in: ring.bounds, to: rep)
            let image = NSImage(size: ring.bounds.size)
            image.addRepresentation(rep)
            image.draw(in: ring.convert(ring.bounds, to: captureContent))
        }
        if let peekImage, let peek = controller.peek,
           let rep = peek.view.bitmapImageRepForCachingDisplay(in: peek.view.bounds)
        {
            // The backdrop and panel chrome, then the Peek's page in it.
            peek.view.cacheDisplay(in: peek.view.bounds, to: rep)
            let chrome = NSImage(size: peek.view.bounds.size)
            chrome.addRepresentation(rep)
            chrome.draw(in: peek.view.convert(peek.view.bounds, to: captureContent))
            let webView = peek.tab.webView
            // The panel's rounded clip, as the layer mask draws it.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(
                roundedRect: peek.view.panel.convert(peek.view.panel.bounds, to: captureContent),
                xRadius: Chrome.Radius.panel,
                yRadius: Chrome.Radius.panel
            ).addClip()
            peekImage.draw(in: webView.convert(webView.bounds, to: captureContent))
            NSGraphicsContext.restoreGraphicsState()
        }
        // The page snapshot covers the web area; draw the link bubble over it.
        let status = controller.linkStatus
        if !status.isHidden, status.window === captureWindow,
           let rep = status.bitmapImageRepForCachingDisplay(in: status.bounds)
        {
            status.cacheDisplay(in: status.bounds, to: rep)
            let image = NSImage(size: status.bounds.size)
            image.addRepresentation(rep)
            image.draw(in: status.convert(status.bounds, to: captureContent))
        }
        let dropdown = controller.addressBar.dropdown
        if !dropdown.isHidden, let rep = dropdown.bitmapImageRepForCachingDisplay(in: dropdown.bounds) {
            // The dropdown floats over the page, which is drawn after the chrome.
            dropdown.cacheDisplay(in: dropdown.bounds, to: rep)
            let image = NSImage(size: dropdown.bounds.size)
            image.addRepresentation(rep)
            image.draw(in: dropdown.convert(dropdown.bounds, to: captureContent))
        }
        // The Command Bar and ⌃Tab's switcher float over the page too.
        let commandBarSurface = controller.commandBar.isOpen ? controller.commandBar.view.surface : nil
        let recentTabs = controller.recentTabsOverlay?.superview == nil ? nil : controller.recentTabsOverlay
        for overlay in [bookmarkPopover, pinPreview, commandBarSurface, recentTabs].compactMap({ $0 })
            where overlay.window === captureWindow && spaceSheet == nil && shortcutsSheet == nil
        {
            // Popovers hang over the page, which is drawn after the chrome.
            guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { continue }
            overlay.cacheDisplay(in: overlay.bounds, to: rep)
            let image = NSImage(size: overlay.bounds.size)
            image.addRepresentation(rep)
            image.draw(in: overlay.convert(overlay.bounds, to: captureContent))
        }
        // An extension's popup hangs under its toolbar button.
        if let popup = extensionPopup, let anchor = controller.toolbar.extensionButton(id: popup.extensionID),
           anchor.window === captureWindow
        {
            drawPopup(popup, under: anchor, in: captureContent)
        }
        if options.showSheet {
            drawAttachedSheet(of: window, in: captureContent)
        }
        output.unlockFocus()

        guard let tiff = output.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("Snapshot could not encode the PNG.\n".utf8))
            exit(1)
        }
        do {
            try FileManager.default.createDirectory(
                at: options.out.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try png.write(to: options.out, options: .atomic)
            print(options.out.path)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }

        // An import's sheet finishes (or cancels) before anything goes.
        SnapshotImportOptions.finish(importOutcome)

        // The Spaces' data stores live outside the temporary folder
        // (WebKit's own); delete every Space's profile so none is left
        // behind. A window kept here would keep its Space's data store in
        // use, so the captured one is swapped for a Default Space window
        // first. A `--support-dir` run keeps its Spaces for the next run
        // and removes only the data stores its windows made.
        if controller.profileID != BrowserProfile.defaultID || controller.kind.isPrivate {
            controller = manager.controllers.first { $0.profileID == BrowserProfile.defaultID && !$0.kind.isPrivate }
                ?? manager.newWindow(spaceID: manager.spaces.defaultSpace?.id)
            window = controller.window ?? window
        }
        let keepsProfiles = options.sleep.supportDirectory != nil
        for profile in manager.profiles.profiles where !profile.isDefault {
            if keepsProfiles, manager.profileContexts[profile.id] == nil {
                continue
            }
            var finished = false
            let report: @MainActor (Error?) -> Void = { error in
                if let error {
                    FileHandle.standardError.write(Data("Snapshot could not remove \(profile.name)'s data store: \(error)\n".utf8))
                }
                finished = true
            }
            autoreleasepool {
                if keepsProfiles {
                    manager.releaseDataStore(ofProfile: profile.id, completion: report)
                } else {
                    manager.deleteProfile(profile.id, completion: report)
                }
            }
            let removalDeadline = Date().addingTimeInterval(15)
            while !finished, Date() < removalDeadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        // The run's extension controller leaves nothing stored behind.
        var extensionDataRemoved = false
        Task { @MainActor in
            await manager.extensions.removeAllData()
            extensionDataRemoved = true
        }
        let extensionDeadline = Date().addingTimeInterval(10)
        while !extensionDataRemoved, Date() < extensionDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        manager.isTerminating = true
        for open in manager.controllers {
            open.window?.orderOut(nil)
        }
        defaults.removePersistentDomain(forName: defaultsSuite)
        pasteboard.releaseGlobally()
        if options.sleep.supportDirectory == nil {
            try? FileManager.default.removeItem(at: temp)
        }
        exit(0)
    }
}

extension SnapshotCommand {
    /// `--sidebar` History: visits spread over today, yesterday, earlier
    /// this week and older days, so the list shows its day headers.
    static func seededHistory(now: Date, calendar: Calendar = .current) -> [BrowserHistoryImport] {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, hour: Int, minute: Int = 0) -> Date {
            let start = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: start) ?? start
        }
        let visits: [(String, String, Date)] = [
            ("https://example.com/", "Example Domain", min(now.addingTimeInterval(-300), day(0, hour: 23))),
            ("https://webkit.org/", "WebKit", min(now.addingTimeInterval(-1_800), day(0, hour: 22))),
            ("https://developer.apple.com/documentation/webkit", "WebKit | Apple Developer Documentation", day(1, hour: 17, minute: 40)),
            ("https://www.iana.org/domains/reserved", "IANA-managed Reserved Domains", day(1, hour: 9, minute: 15)),
            ("https://www.swift.org/documentation/", "Documentation | Swift.org", day(3, hour: 11, minute: 5)),
            ("https://github.com/frknue/soprano_web", "frknue/soprano_web: Soprano Web", day(5, hour: 16, minute: 30)),
            ("https://news.ycombinator.com/", "Hacker News", day(12, hour: 8, minute: 50)),
            ("https://en.wikipedia.org/wiki/WebKit", "WebKit - Wikipedia", day(40, hour: 20, minute: 10)),
        ]
        return visits.map { BrowserHistoryImport(url: $0.0, title: $0.1, visitedAt: $0.2, kind: .link) }
    }
}
