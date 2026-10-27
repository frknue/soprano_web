import Foundation

/// Reads an import source into `BrowserImportSourceData`: the readers plus
/// History counts. Blocking (JSON files, `ditto`, SQLite counts), so it
/// runs off the main thread. Nothing is ever written to the source.
enum BrowserImportLoader {
    enum Request: Sendable, Equatable {
        /// Arc's support folder.
        case arc(URL)
        /// A Chromium user-data folder (Chrome's).
        case chrome(URL)
        /// Safari's File ▸ Export Browsing Data ZIP.
        case safari(URL)
        /// A Netscape bookmarks HTML file.
        case html(URL)

        var kind: BrowserImportSourceKind {
            switch self {
            case .arc: .arc
            case .chrome: .chrome
            case .safari: .safari
            case .html: .html
            }
        }

        var url: URL {
            switch self {
            case let .arc(url), let .chrome(url), let .safari(url), let .html(url): url
            }
        }
    }

    /// The sources found on this Mac without asking for a file: Arc's and
    /// Chrome's folders when they hold data.
    static func detected() -> [Request] {
        var found: [Request] = []
        if BrowserArcImportReader().isAvailable {
            found.append(.arc(BrowserArcImportReader.defaultSupportDirectory))
        }
        let chrome = BrowserChromeBookmarksReader.chromeUserDataDirectory
        if !BrowserChromeBookmarksReader.profiles(userDataDirectory: chrome).isEmpty {
            found.append(.chrome(chrome))
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

        case let .chrome(folder):
            let profiles = BrowserChromeBookmarksReader.profiles(userDataDirectory: folder)
            guard !profiles.isEmpty else {
                throw BrowserImportError.missingFile(folder.appendingPathComponent("Local State"))
            }
            return .chrome(profiles.map { profile in
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
