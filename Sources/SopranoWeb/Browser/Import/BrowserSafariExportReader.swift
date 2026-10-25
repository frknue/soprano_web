import Foundation

/// What Safari's File ▸ Export Browsing Data to File… ZIP holds that we
/// import: the bookmarks (the Reading List is one of their folders) and one
/// History file per Safari profile.
struct BrowserSafariExport: Sendable, Equatable {
    struct History: Sendable, Equatable {
        /// The Safari profile, from the file name's suffix; `nil` for the
        /// only or the default profile's file.
        var profileName: String?
        /// Oldest first.
        var visits: [BrowserImportedVisit]
    }

    var bookmarks: [BrowserImportedNode]
    var histories: [History]
}

/// Reads Safari's export. File names are localized (`Bookmarks.html`,
/// `History.json` in English), so files are recognised by content: the
/// Netscape doctype, and JSON whose `metadata.data_type` is `history`.
/// Blocking (it runs `ditto`); call it off the main thread.
enum BrowserSafariExportReader {
    /// Expands `zipURL` with `/usr/bin/ditto -x -k` into a temporary folder,
    /// reads it and removes the folder.
    static func read(zipURL: URL) throws -> BrowserSafariExport {
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw BrowserImportError.missingFile(zipURL)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebSafariImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try unzip(zipURL, to: folder)
        return try read(directory: folder)
    }

    /// Reads an expanded export (any depth; `__MACOSX` ignored). Throws
    /// `unreadable` when the folder holds neither bookmarks nor history.
    static func read(directory: URL) throws -> BrowserSafariExport {
        var bookmarks: [BrowserImportedNode]?
        var historyFiles: [(stem: String, visits: [BrowserImportedVisit])] = []
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { !$0.pathComponents.contains("__MACOSX") }
            .sorted { $0.path < $1.path }
        for file in files {
            switch file.pathExtension.lowercased() {
            case "html", "htm":
                guard bookmarks == nil, let data = FileManager.default.contents(atPath: file.path),
                      isNetscapeBookmarks(data)
                else { continue }
                bookmarks = BrowserNetscapeBookmarks.parse(data: data)
            case "json":
                guard let data = FileManager.default.contents(atPath: file.path),
                      let visits = history(from: data)
                else { continue }
                historyFiles.append((file.deletingPathExtension().lastPathComponent, visits))
            default:
                continue
            }
        }
        guard bookmarks != nil || !historyFiles.isEmpty else {
            throw BrowserImportError.unreadable(directory, "no Safari bookmarks or history")
        }
        return BrowserSafariExport(bookmarks: bookmarks ?? [], histories: histories(historyFiles))
    }

    /// The visits of one History JSON file, oldest first; `nil` when `data`
    /// is not a Safari history export. One visit per entry (its latest visit,
    /// `visitCount` = `visits_count`); entries that redirected elsewhere
    /// (`destination_url`), failed to load, or are not http(s)/file are
    /// skipped, as are entries without `url` or `time_usec`.
    static func history(from data: Data) -> [BrowserImportedVisit]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["history"] as? [Any]
        else { return nil }
        if let metadata = object["metadata"] as? [String: Any],
           let type = metadata["data_type"] as? String, type != "history" {
            return nil
        }
        var visits: [BrowserImportedVisit] = []
        visits.reserveCapacity(entries.count)
        for case let entry as [String: Any] in entries {
            guard let url = entry["url"] as? String, BrowserImportedVisit.isImportable(url),
                  let time = (entry["time_usec"] as? NSNumber)?.int64Value,
                  !(entry["destination_url"] is String),
                  (entry["latest_visit_was_load_failure"] as? Bool) != true
            else { continue }
            let count = (entry["visits_count"] as? NSNumber ?? entry["visit_count"] as? NSNumber)?.intValue ?? 1
            visits.append(BrowserImportedVisit(
                url: url,
                title: entry["title"] as? String ?? "",
                visitedAt: Date(timeIntervalSince1970: Double(time) / 1_000_000),
                visitCount: count
            ))
        }
        visits.sort { $0.visitedAt < $1.visitedAt }
        return visits
    }

    // MARK: Private

    private static func unzip(_ zipURL: URL, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, folder.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw BrowserImportError.unzipFailed(error.localizedDescription)
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BrowserImportError.unzipFailed(message.isEmpty ? "ditto exited with \(process.terminationStatus)" : message)
        }
    }

    /// The Netscape doctype, or (an exporter that omits it) a `<DL>` list of
    /// `<DT>` entries near the top.
    private static func isNetscapeBookmarks(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(4_096), as: UTF8.self).uppercased()
        return head.contains("NETSCAPE-BOOKMARK-FILE") || (head.contains("<DL") && head.contains("<DT>"))
    }

    /// Names each file's profile: the shortest file name is the default
    /// profile's (`History`); the others carry the profile name as a suffix
    /// (`History - Work`), whatever the locale calls the base name.
    private static func histories(_ files: [(stem: String, visits: [BrowserImportedVisit])]) -> [BrowserSafariExport.History] {
        guard files.count > 1, let base = files.map({ $0.stem }).min(by: { $0.count < $1.count }) else {
            return files.map { BrowserSafariExport.History(profileName: nil, visits: $0.visits) }
        }
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—_()"))
        return files.map { file in
            var name: String? = file.stem
            if file.stem == base {
                name = nil
            } else if file.stem.hasPrefix(base) {
                let suffix = file.stem.dropFirst(base.count).trimmingCharacters(in: separators)
                name = suffix.isEmpty ? file.stem : suffix
            }
            return BrowserSafariExport.History(profileName: name, visits: file.visits)
        }
    }
}
