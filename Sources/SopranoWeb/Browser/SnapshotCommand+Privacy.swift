import AppKit
import CryptoKit
import WebKit

/// Snapshot flags for Clear Browsing Data, Website Data and downloads.
/// Scenario results are printed to stdout, one `privacy:` line each.
extension SnapshotCommand {
    struct PrivacyOptions {
        /// `--clear-data`: capture the Clear Browsing Data sheet.
        var showClearData = false
        /// `--website-data`: capture Settings ▸ Website Data.
        var showWebsiteData = false
        /// `--privacy-settings`: capture Settings (with the Ask where to
        /// save, Website data and Default browser rows) without showing it.
        var showSettingsPane = false
        /// `--clear-data-now <range>`: after the page loads, print its
        /// cookies, clear everything for `range`, print them again.
        var clearDataNow: BrowserClearRange?
        /// `--download <url>`: start a download in the selected tab.
        var download: String?
        /// `--cancel-after <s>`: cancel it (keeping resume data) after s.
        var cancelAfter: Double?
        /// `--quit-after <s>`: stop it the way quitting does after s, then
        /// reload the download list from disk like a relaunch.
        var quitAfter: Double?
        /// `--resume`: resume the stopped download and wait for it.
        var resume = false
        /// `--print-downloads`: print every download record at the end.
        var printDownloads = false
    }

    static let privacyUsage = """
                                   [--clear-data] [--website-data] [--privacy-settings] [--clear-data-now lastHour|today|todayAndYesterday|allTime]
                                   [--download <url>] [--cancel-after <s>] [--quit-after <s>] [--resume]
                                   [--print-downloads]
    """

    /// Parses `option` if it is a privacy flag; false means not ours.
    nonisolated static func parsePrivacy(
        _ option: String,
        value: () throws -> String,
        into options: inout PrivacyOptions
    ) throws -> Bool {
        func seconds() throws -> Double {
            let text = try value()
            guard let seconds = Double(text), seconds >= 0 else { throw OptionError.missingValue(option) }
            return seconds
        }
        switch option {
        case "--clear-data":
            options.showClearData = true
        case "--website-data":
            options.showWebsiteData = true
        case "--privacy-settings":
            options.showSettingsPane = true
        case "--clear-data-now":
            let text = try value()
            guard let range = BrowserClearRange(rawValue: text) else {
                throw OptionError.unknownOption("\(option) \(text)")
            }
            options.clearDataNow = range
        case "--download":
            options.download = try value()
        case "--cancel-after":
            options.cancelAfter = try seconds()
        case "--quit-after":
            options.quitAfter = try seconds()
        case "--resume":
            options.resume = true
        case "--print-downloads":
            options.printDownloads = true
        default:
            return false
        }
        return true
    }

    /// Runs the clear and download scenarios once the window exists.
    static func runPrivacyScenario(_ options: PrivacyOptions, controller: BrowserWindowController, wait: Double) {
        if let range = options.clearDataNow {
            spin(seconds: wait)
            clearNow(range: range, controller: controller)
        }
        if let address = options.download, let url = URL(string: address) {
            spin(seconds: wait)
            downloadScenario(url: url, options: options, controller: controller)
        }
        if options.printDownloads {
            if options.download == nil, options.clearDataNow == nil {
                // A --url that downloads (attachment) needs the page wait.
                spin(seconds: wait)
            }
            for record in controller.downloads.records {
                printDownload("record", record, store: controller.downloads)
            }
        }
    }

    /// Builds the requested sheet's window without ordering it in (nothing
    /// becomes visible) and returns it for capture.
    static func makePrivacySheet(_ options: PrivacyOptions, controller: BrowserWindowController) -> NSWindow? {
        if options.showClearData {
            let (alert, accessory) = BrowserClearBrowsingDataSheet.makeAlert(
                theme: controller.theme,
                profileName: controller.clearDataProfileName
            )
            print("privacy: clear-data sheet: \(alert.messageText) | \(alert.informativeText)")
            privacySheetOwner = accessory
            // cacheDisplay draws the accessory (our controls); NSAlert's own
            // title, icon and buttons are system glass and stay blank.
            return alert.window
        }
        if options.showSettingsPane {
            let settings = SettingsWindowController(
                settingsStore: controller.settingsStore,
                themeManager: controller.themeManager
            )
            privacySheetOwner = settings
            return settings.window
        }
        if options.showWebsiteData {
            let sheet = controller.manager.makeWebsiteDataSheet(selected: controller.profileID)
            print("privacy: website-data sheet shows profile \(sheet.profileName)")
            privacySheetOwner = sheet
            sheet.reload()
            spin(seconds: 1.5)
            return sheet.window
        }
        return nil
    }

    /// Keeps the captured sheet's owner alive until the PNG is written.
    private static var privacySheetOwner: AnyObject?

    private static func clearNow(range: BrowserClearRange, controller: BrowserWindowController) {
        guard let host = controller.selectedTab?.webView.url?.host else {
            print("privacy: clear-data-now needs a loaded --url")
            return
        }
        print("privacy: cookies before clear: \(cookieNames(host: host, controller: controller))")
        var done = false
        let options = BrowserClearOptions(
            range: range,
            history: true,
            cookiesAndSiteData: true,
            cachedFiles: true,
            downloadList: true
        )
        controller.clearBrowsingData(options) { done = true }
        spin(seconds: 10) { done }
        print("privacy: cookies after clear (\(range.rawValue)): \(cookieNames(host: host, controller: controller))")
        print("privacy: history visits after clear: \(controller.history.visitCount())")
        guard let tab = controller.selectedTab else { return }
        tab.webView.reload()
        spin(seconds: 1.5)
        var pageCookie = "?"
        var evaluated = false
        tab.webView.evaluateJavaScript("document.cookie") { result, _ in
            pageCookie = result as? String ?? ""
            evaluated = true
        }
        spin(seconds: 3) { evaluated }
        print("privacy: document.cookie after reload: \"\(pageCookie)\"")
    }

    private static func cookieNames(host: String, controller: BrowserWindowController) -> String {
        var names: [String]?
        controller.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            names = cookies.filter { $0.domain == host || host.hasSuffix($0.domain) }
                .map { "\($0.name)=\($0.value)" }
                .sorted()
        }
        spin(seconds: 3) { names != nil }
        guard let names else { return "(timeout)" }
        return names.isEmpty ? "(none)" : names.joined(separator: ", ")
    }

    private static func downloadScenario(url: URL, options: PrivacyOptions, controller: BrowserWindowController) {
        let store = controller.downloads
        let before = Set(store.records.map(\.id))
        controller.startDownload(URLRequest(url: url))
        spin(seconds: 10) { store.records.contains { !before.contains($0.id) } }
        guard let id = store.records.first(where: { !before.contains($0.id) })?.id else {
            print("privacy: download did not start")
            return
        }
        func record() -> BrowserDownloadRecord? { store.records.first { $0.id == id } }

        if let delay = options.cancelAfter {
            spin(seconds: delay)
            printDownload("before cancel", record(), store: store)
            controller.cancelDownload(id: id)
            spin(seconds: 5) { record()?.canResume == true }
            printDownload("after cancel", record(), store: store)
        } else if let delay = options.quitAfter {
            spin(seconds: delay)
            printDownload("before quit", record(), store: store)
            var settled = false
            controller.downloadManager.interruptForQuit { settled = true }
            spin(seconds: 5) { settled }
            let relaunched = BrowserDownloadStore(url: store.url)
            printDownload("after relaunch", relaunched.records.first { $0.id == id }, store: relaunched)
        } else {
            spin(seconds: 120) { record()?.state != .inProgress }
            printDownload("finished", record(), store: store)
            return
        }

        guard options.resume else { return }
        if record()?.canResume == true {
            controller.resumeDownload(id: id)
        } else {
            controller.retryDownload(id: id)
        }
        spin(seconds: 0.5)
        printDownload("resumed", record(), store: store)
        spin(seconds: 120) { record()?.state != .inProgress }
        printDownload("after resume", record(), store: store)
    }

    private static func printDownload(_ label: String, _ record: BrowserDownloadRecord?, store: BrowserDownloadStore) {
        guard let record else {
            print("privacy: \(label): no record")
            return
        }
        var line = "privacy: \(label): \(record.filename) state=\(record.state.rawValue)"
            + " progress=\(Int((record.fractionCompleted * 100).rounded()))%"
        if let file = record.resumeDataFile,
           let size = try? store.resumeDataDirectory.appendingPathComponent(file)
               .resourceValues(forKeys: [.fileSizeKey]).fileSize
        {
            line += " resumeData=\(size)B"
        }
        if let path = record.path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            line += " file=\(data.count)B sha256=\(digest.prefix(16))"
        }
        if let message = record.errorMessage {
            line += " error=\"\(message)\""
        }
        print(line)
    }

    private static func spin(seconds: Double, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }
}
