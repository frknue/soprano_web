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
            default:
                throw OptionError.unknownOption(option)
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
            restoreSession: false,
            downloadDirectory: temp.path,
            verticalTabs: options.verticalTabs
        )
        let settingsStore = BrowserSettingsStore(
            url: temp.appendingPathComponent("settings.json"),
            settings: settings
        )
        let themeManager = ThemeManager(themeId: options.theme, appearance: .system)
        let history = BrowserHistoryStore(url: temp.appendingPathComponent("history.json"))
        let bookmarks = BrowserBookmarkStore(url: temp.appendingPathComponent("bookmarks.json"))
        let downloads = BrowserDownloadStore(url: temp.appendingPathComponent("downloads.json"))
        let sitePermissions = BrowserSitePermissionStore(
            url: temp.appendingPathComponent("site-permissions.json")
        )
        if let host = options.allowPopups {
            sitePermissions.set(.popups, .allow, host: host)
        }
        let session = BrowserSessionStore(url: temp.appendingPathComponent("session.json"))

        let defaultsSuite = "com.soprano.web.snapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.set(options.collapsed, forKey: BrowserWindowController.verticalSidebarCollapsedKey)

        let controller = BrowserWindowController(
            themeManager: themeManager,
            settingsStore: settingsStore,
            history: history,
            bookmarks: bookmarks,
            downloads: downloads,
            sitePermissions: sitePermissions,
            sessionStore: session,
            persistsSession: false,
            frame: NSRect(origin: .zero, size: options.size),
            defaults: defaults
        )
        guard let window = controller.window else {
            FileHandle.standardError.write(Data("Snapshot could not create the window.\n".utf8))
            exit(1)
        }
        window.setContentSize(options.size)
        window.setFrameOrigin(NSPoint(x: 120, y: 120))
        window.orderBack(nil)
        window.displayIfNeeded()

        if let value = options.url,
           let url = BrowserAddressResolver.resolve(value, searchEngine: .duckDuckGo)
        {
            if BrowserAddressResolver.isStartPage(url) {
                // Already on the start page.
            } else if let tab = controller.selectedTab {
                controller.navigate(tab, to: url)
            }
        }
        for url in options.extraTabs {
            controller.newTab(url: url, select: false)
        }

        if let section = options.sidebar {
            if history.entries.isEmpty {
                history.record(url: "https://example.com", title: "Example Domain")
                history.record(url: "https://www.iana.org/domains/reserved", title: "IANA-managed Reserved Domains")
                history.record(url: "https://webkit.org", title: "WebKit")
            }
            if bookmarks.bookmarks.isEmpty {
                bookmarks.toggle(url: "https://example.com", title: "Example Domain")
                bookmarks.toggle(url: "https://webkit.org", title: "WebKit")
                bookmarks.toggle(url: "https://developer.apple.com/documentation/webkit", title: "WebKit Documentation")
            }
            if downloads.records.isEmpty {
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
        if options.showSettings {
            controller.showSettings()
        }

        let deadline = Date().addingTimeInterval(options.wait)
        while Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.05))
            )
        }

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
        if options.printTabs {
            printTabs(controller)
        }

        let captureWindow: NSWindow
        if options.showSettings {
            captureWindow = NSApp.windows.first { $0.title == "Settings" } ?? window
        } else if options.showHelp {
            captureWindow = NSApp.windows.first { $0.title == "Vimium Help" } ?? window
        } else if options.showPrompt {
            captureWindow = NSApp.windows.first { $0 is VimiumPromptPanel } ?? window
        } else if options.showSheet, let sheet = window.attachedSheet {
            captureWindow = sheet
        } else {
            captureWindow = window
        }
        guard let captureContent = captureWindow.contentView else {
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
        if !options.showSettings, !options.showHelp, !options.showPrompt,
           !options.showFind, captureWindow === window, let webView = controller.selectedTab?.webView {
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

        window.orderOut(nil)
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: temp)
        exit(0)
    }
}
