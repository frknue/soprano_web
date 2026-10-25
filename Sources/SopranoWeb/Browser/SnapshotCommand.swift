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
                               [--sidebar history|bookmarks|downloads] [--find] [--settings]
                               [--vertical-tabs] [--collapsed] [--hints] [--help] [--prompt]
                               [--allow-popups <host>] [--tab <url>]... [--sheet] [--print-tabs]
                               [--click [cmd-|shift-cmd-|middle-]X,Y]...
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
                guard try parsePrivacy(option, value: { try value(option) }, into: &options.privacy) else {
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
            _ = RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.05))
            )
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

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-snapshot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let settings = BrowserSettings(
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
        let settingsStore = BrowserSettingsStore(
            url: temp.appendingPathComponent("settings.json"),
            settings: settings
        )
        if let autoplay = options.autoplay {
            settingsStore.update { $0.autoplay = autoplay }
        }
        let themeManager = ThemeManager(themeId: options.theme, appearance: .system)
        let bookmarks = BrowserBookmarkStore(url: temp.appendingPathComponent("bookmarks.json"))
        let downloads = BrowserDownloadStore(url: temp.appendingPathComponent("downloads.json"))
        let profiles = BrowserProfileStore(url: temp.appendingPathComponent("profiles.json"))
        // `--add-profile`: the profiles exist before any window opens.
        for name in options.session.profilesToAdd {
            let profile = profiles.add(name: name)
            print("profile: added \(profile.name) \(profile.id.uuidString) (\(profile.color.rawValue))")
        }
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
            bookmarks: bookmarks,
            downloads: downloads,
            faviconStore: BrowserFaviconStore(directory: temp.appendingPathComponent("Favicons", isDirectory: true)),
            sessionStore: session,
            persistsSession: false,
            placement: .offscreen(size: options.size),
            defaults: defaults
        )
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

        if options.focusAddress {
            // Focused but not edited: the field must follow the navigation.
            controller.focusAddressBar()
        }
        if let value = options.url,
           let url = BrowserAddressResolver.resolve(value, searchEngine: .duckDuckGo)
        {
            if BrowserAddressResolver.isStartPage(url) {
                // Already on the start page.
            } else if let tab = controller.selectedTab {
                if let back = options.backURL,
                   let backURL = BrowserAddressResolver.resolve(back, searchEngine: .duckDuckGo)
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

        runPrivacyScenario(options.privacy, controller: controller, wait: options.wait)

        if let section = options.sidebar {
            if history.visitCount() == 0 {
                history.importVisits(Self.seededHistory(now: Date()))
            }
            if bookmarks.bookmarks.isEmpty {
                bookmarks.toggle(url: "https://example.com", title: "Example Domain")
                bookmarks.toggle(url: "https://webkit.org", title: "WebKit")
                bookmarks.toggle(url: "https://developer.apple.com/documentation/webkit", title: "WebKit Documentation")
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
            controller.showSidebar(section: section)
        }
        if options.showFind {
            controller.showFindBar()
        }
        let deadline = Date().addingTimeInterval(options.wait)
        while Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.05))
            )
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
        // Settings, Websites and Profiles are built but never ordered in, so
        // the harness puts nothing on screen. Websites shows the captured
        // window's profile.
        let settingsPreview = options.showSettings
            ? SettingsWindowController(settingsStore: settingsStore, themeManager: themeManager)
            : nil
        let websitesSheet = options.showWebsites
            ? manager.makeWebsitesSheet(selected: controller.profileID)
            : nil
        if let websitesSheet {
            print("websites: profile picker \(websitesSheet.pickerTitle ?? "hidden")")
        }
        let profilesSheet = options.session.showProfilesSheet ? manager.makeProfilesSheet() : nil
        if settingsPreview != nil || websitesSheet != nil || profilesSheet != nil {
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
            AddressBarSnapshot.type(address, into: controller, history: history, bookmarks: bookmarks)
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
        let captured = websitesSheet?.window ?? profilesSheet?.window ?? captureWindow
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

        var pageImage: NSImage?
        if privacySheet == nil, !options.showSettings, !options.showHelp, !options.showPrompt,
           websitesSheet == nil, profilesSheet == nil, !options.showFind, captureWindow === window,
           controller.selectedTab?.lifecycle.crashView == nil,
           let webView = controller.selectedTab?.webView {
            var finished = false
            webView.takeSnapshot(with: nil) { image, _ in
                pageImage = image
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

        let output = NSImage(size: captureContent.bounds.size)
        output.lockFocus()
        NSColor.clear.setFill()
        captureContent.bounds.fill()
        base.draw(in: captureContent.bounds)
        if let pageImage, let webView = controller.selectedTab?.webView {
            let frame = webView.convert(webView.bounds, to: captureContent)
            pageImage.draw(in: frame)
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

        // The profiles' data stores live outside the temporary folder
        // (WebKit's own); delete every profile so none is left behind. A
        // window kept here would keep its profile's data store in use, so
        // the captured one is swapped for a Default window first.
        if controller.profileID != BrowserProfile.defaultID || controller.kind.isPrivate {
            controller = manager.controllers.first { $0.profileID == BrowserProfile.defaultID && !$0.kind.isPrivate }
                ?? manager.newWindow(profileID: BrowserProfile.defaultID)
            window = controller.window ?? window
        }
        for profile in manager.profiles.profiles where !profile.isDefault {
            var finished = false
            autoreleasepool {
                manager.deleteProfile(profile.id) { error in
                    if let error {
                        FileHandle.standardError.write(Data("Snapshot could not remove \(profile.name)'s data store: \(error)\n".utf8))
                    }
                    finished = true
                }
            }
            let removalDeadline = Date().addingTimeInterval(15)
            while !finished, Date() < removalDeadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        manager.isTerminating = true
        for open in manager.controllers {
            open.window?.orderOut(nil)
        }
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: temp)
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
