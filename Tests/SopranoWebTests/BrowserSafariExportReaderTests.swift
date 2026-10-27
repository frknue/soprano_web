@testable import SopranoWeb
import AppKit
import Testing

struct BrowserSafariExportReaderTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// 2024-07-30 19:21:42.951213 UTC, as Apple's documentation example.
    private let time: Int64 = 1_722_367_302_951_213
    private var date: Date { at(time) }

    private func at(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }

    private func historyJSON(_ entries: String, type: String = "history") -> String {
        """
        {
          "metadata": { "browser_name": "Safari", "browser_version": "18.2", "data_type": "\(type)",
                        "export_time_usec": \(time + 10_000_000), "schema_version": 1 },
          "history": [\(entries)]
        }
        """
    }

    @Test func historyKeepsLatestVisitsAndSkipsRedirectsFailuresAndInternalURLs() {
        let json = historyJSON("""
            { "url": "https://www.apple.com/maps/", "title": "Maps - Apple", "time_usec": \(time + 2_000_000),
              "source_url": "https://maps.apple.com/", "source_time_usec": \(time), "visits_count": 3 },
            { "url": "https://maps.apple.com/", "time_usec": \(time),
              "destination_url": "https://www.apple.com/maps/", "destination_time_usec": \(time + 2_000_000) },
            { "url": "https://broken.example/", "time_usec": \(time), "latest_visit_was_load_failure": true },
            { "url": "about:blank", "time_usec": \(time) },
            { "url": "https://no-time.example/" },
            { "title": "No URL", "time_usec": \(time) },
            "not an entry",
            { "url": "https://first.example/", "time_usec": \(time - 1_000_000), "latest_visit_was_http_get": true }
            """)
        #expect(BrowserSafariExportReader.history(from: Data(json.utf8)) == [
            BrowserImportedVisit(url: "https://first.example/", title: "", visitedAt: at(time - 1_000_000)),
            BrowserImportedVisit(url: "https://www.apple.com/maps/", title: "Maps - Apple", visitedAt: at(time + 2_000_000), visitCount: 3),
        ])
    }

    @Test func otherJSONIsNotHistory() {
        #expect(BrowserSafariExportReader.history(from: Data(historyJSON("", type: "extensions").utf8)) == nil)
        #expect(BrowserSafariExportReader.history(from: Data(#"{"extensions": []}"#.utf8)) == nil)
        #expect(BrowserSafariExportReader.history(from: Data("garbage".utf8)) == nil)
        #expect(BrowserSafariExportReader.history(from: Data(#"{"history": []}"#.utf8)) == [])
    }

    @Test func readsAnExportZipWithBookmarksAndOneHistoryPerProfile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let export = directory.appendingPathComponent("Safari Export", isDirectory: true)
        try write("""
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <HTML><META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
            <Title>Bookmarks</Title><H1>Bookmarks</H1>
            <DT><H3 FOLDED>Favourites</H3>
            <DL><p>
                <DT><A HREF="https://www.apple.com/">Apple</A>
            </DL><p>
            <DT><H3 FOLDED id="com.apple.ReadingList">Reading List</H3>
            <DL><p>
                <DT><A HREF="https://read.example/">Later</A>
            </DL><p>
            </HTML>
            """, to: export.appendingPathComponent("Bookmarks.html"))
        try write(historyJSON(#"{ "url": "https://personal.example/", "time_usec": \#(time) }"#),
                  to: export.appendingPathComponent("History.json"))
        try write(historyJSON(#"{ "url": "https://work.example/", "time_usec": \#(time), "visits_count": 2 }"#),
                  to: export.appendingPathComponent("History - Work.json"))
        try write(historyJSON("", type: "extensions"), to: export.appendingPathComponent("Extensions.json"))
        try write("Title,URL,Username,Password\n", to: export.appendingPathComponent("Passwords.csv"))
        try write("<html>not bookmarks</html>", to: export.appendingPathComponent("Other.html"))

        let zip = directory.appendingPathComponent("Safari Export.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", export.path, zip.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let result = try BrowserSafariExportReader.read(zipURL: zip)
        #expect(result.bookmarks == [
            .folder(BrowserImportedFolder(name: "Favourites", children: [
                .link(BrowserImportedLink(url: "https://www.apple.com/", title: "Apple")),
            ])),
            .folder(BrowserImportedFolder(name: "Reading List", children: [
                .link(BrowserImportedLink(url: "https://read.example/", title: "Later")),
            ])),
        ])
        #expect(result.histories.count == 2)
        let personal = result.histories.first { $0.profileName == nil }
        let work = result.histories.first { $0.profileName == "Work" }
        #expect(personal?.visits == [BrowserImportedVisit(url: "https://personal.example/", title: "", visitedAt: date)])
        #expect(work?.visits == [BrowserImportedVisit(url: "https://work.example/", title: "", visitedAt: date, visitCount: 2)])
    }

    @Test func aSingleHistoryFileHasNoProfileName() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(historyJSON(#"{ "url": "https://a.example/", "time_usec": \#(time) }"#),
                  to: directory.appendingPathComponent("Verlauf.json"))
        let result = try BrowserSafariExportReader.read(directory: directory)
        #expect(result.bookmarks.isEmpty)
        #expect(result.histories.map(\.profileName) == [nil])
    }

    @Test func missingDamagedAndEmptyExportsThrow() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = directory.appendingPathComponent("Export.zip")
        #expect(throws: BrowserImportError.missingFile(zip)) {
            try BrowserSafariExportReader.read(zipURL: zip)
        }

        try write("not a zip", to: zip)
        var unzipFailed = false
        do {
            _ = try BrowserSafariExportReader.read(zipURL: zip)
        } catch let error as BrowserImportError {
            if case .unzipFailed = error { unzipFailed = true }
        }
        #expect(unzipFailed)

        let empty = directory.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: BrowserImportError.unreadable(empty, "no Safari bookmarks or history")) {
            try BrowserSafariExportReader.read(directory: empty)
        }
    }
}
