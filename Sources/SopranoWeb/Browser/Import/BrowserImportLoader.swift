import Foundation

/// Reads an import source into `BrowserImportSourceData`: the readers plus
/// History counts. Blocking (JSON files, `ditto`, SQLite counts), so it
/// runs off the main thread. Nothing is ever written to the source.
enum BrowserImportLoader {
    enum Request: Sendable, Equatable {
        /// Arc's support folder.
        case arc(URL)
        /// A Chromium browser's user-data folder (`kind.isChromium`).
        case chromium(BrowserImportSourceKind, URL)
        /// Safari's File ▸ Export Browsing Data ZIP.
        case safari(URL)
        /// A Netscape bookmarks HTML file.
        case html(URL)

        var kind: BrowserImportSourceKind {
            switch self {
            case .arc: .arc
            case let .chromium(kind, _): kind
            case .safari: .safari
            case .html: .html
            }
        }

        var url: URL {
            switch self {
            case let .arc(url), let .chromium(_, url), let .safari(url), let .html(url): url
            }
        }
    }

    /// The sources found on this Mac without asking for a file: Arc's
    /// folder and each Chromium browser's (Chrome, Brave, Edge, Vivaldi,
    /// Chromium) when it holds profiles, or exists but macOS won't let the
    /// app read it (reading then says so).
    static func detected(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Request] {
        var found: [Request] = []
        if BrowserArcImportReader().isAvailable {
            found.append(.arc(BrowserArcImportReader.defaultSupportDirectory))
        }
        for browser in BrowserImportSourceKind.chromiumBrowsers {
            guard let folder = BrowserChromeBookmarksReader.userDataDirectory(of: browser, home: home) else { continue }
            if !BrowserChromeBookmarksReader.profiles(userDataDirectory: folder).isEmpty
                || BrowserChromeBookmarksReader.isUnreadable(folder)
            {
                found.append(.chromium(browser, folder))
            }
        }
        return found
    }

    /// `historyCutoff`: the visits History keeps start there (what the
    /// counts' `kept` counts).
    static func read(_ request: Request, historyCutoff: Date?) throws -> BrowserImportSourceData {
        let empty = BrowserImportSourceData.HistoryCounts(visits: 0, importable: 0, kept: 0)
        func counts(_ file: URL) -> BrowserImportSourceData.HistoryCounts {
            (try? BrowserChromiumHistoryReader(fileURL: file).counts(since: historyCutoff)) ?? empty
        }
        switch request {
        case let .arc(folder):
            let reader = BrowserArcImportReader(supportDirectory: folder)
            let arc = try reader.read()
            return .arc(arc, historyCounts: arc.historyFiles.mapValues(counts))

        case let .chromium(browser, folder):
            if BrowserChromeBookmarksReader.isUnreadable(folder) {
                throw BrowserImportError.unreadable(
                    folder,
                    "macOS didn't let Soprano Web read \(browser.title)'s data. Allow it in System Settings ▸ Privacy & Security, then try again."
                )
            }
            let profiles = BrowserChromeBookmarksReader.profiles(userDataDirectory: folder)
            guard !profiles.isEmpty else {
                throw BrowserImportError.missingFile(folder.appendingPathComponent("Local State"))
            }
            return .chromium(browser, profiles.map { profile in
                let directory = profile.directory
                let bookmarks = directory
                    .flatMap { try? BrowserChromeBookmarksReader.read(fileURL: $0.appendingPathComponent("Bookmarks")) } ?? []
                let history = directory?.appendingPathComponent("History")
                let historyFile = history.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                return BrowserImportSourceData.ChromeProfile(
                    profile: profile,
                    bookmarks: bookmarks,
                    historyFile: historyFile,
                    historyCounts: historyFile.map(counts) ?? empty
                )
            })

        case let .safari(zip):
            return .safari(try BrowserSafariExportReader.read(zipURL: zip), name: zip.lastPathComponent)

        case let .html(file):
            guard let data = FileManager.default.contents(atPath: file.path) else {
                throw BrowserImportError.missingFile(file)
            }
            let nodes = BrowserNetscapeBookmarks.parse(data: data)
            guard !nodes.isEmpty else {
                throw BrowserImportError.unreadable(file, "no bookmarks")
            }
            return .html(nodes, name: file.lastPathComponent)
        }
    }
}
