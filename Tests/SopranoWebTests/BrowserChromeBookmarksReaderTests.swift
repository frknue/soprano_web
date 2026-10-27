@testable import SopranoWeb
import AppKit
import Testing

struct BrowserChromeBookmarksReaderTests {
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

    /// 13 000 000 000 000 000 µs after 1601-01-01 is 2012-12-15 00:00:00 UTC.
    private let chromeTime = "13000000000000000"
    private let chromeDate = Date(timeIntervalSince1970: 1_355_526_400)

    @Test func rootsBecomeFoldersAndNodesKeepOrderNamesAndDates() {
        let json = """
            {
              "checksum": "x", "version": 1,
              "roots": {
                "bookmark_bar": {
                  "name": "Bookmarks bar", "type": "folder", "date_added": "\(chromeTime)",
                  "children": [
                    { "type": "url", "name": "Example", "url": "https://example.com/", "date_added": "\(chromeTime)" },
                    { "type": "folder", "name": "Work", "children": [
                        { "type": "url", "name": "", "url": "https://work.example/" },
                        { "type": "folder", "name": "Empty", "children": [] }
                    ] },
                    { "type": "url", "name": "No URL" },
                    { "type": "separator", "name": "Odd" },
                    "not a node"
                  ]
                },
                "other": { "name": "Other bookmarks", "type": "folder", "children": [] },
                "synced": { "type": "folder", "children": [
                    { "type": "url", "name": "Phone", "url": "https://phone.example/", "date_added": "0" }
                ] }
              }
            }
            """
        let nodes = BrowserChromeBookmarksReader.nodes(from: Data(json.utf8))
        #expect(nodes == [
            .folder(BrowserImportedFolder(name: "Bookmarks bar", addedAt: chromeDate, children: [
                .link(BrowserImportedLink(url: "https://example.com/", title: "Example", addedAt: chromeDate)),
                .folder(BrowserImportedFolder(name: "Work", children: [
                    .link(BrowserImportedLink(url: "https://work.example/", title: "https://work.example/")),
                    .folder(BrowserImportedFolder(name: "Empty")),
                ])),
            ])),
            .folder(BrowserImportedFolder(name: "Mobile Bookmarks", children: [
                .link(BrowserImportedLink(url: "https://phone.example/", title: "Phone")),
            ])),
        ])
    }

    @Test func notABookmarksFileIsRejected() throws {
        #expect(BrowserChromeBookmarksReader.nodes(from: Data("[1, 2]".utf8)) == nil)
        #expect(BrowserChromeBookmarksReader.nodes(from: Data("garbage".utf8)) == nil)
        #expect(BrowserChromeBookmarksReader.nodes(from: Data(#"{"roots": {}}"#.utf8)) == [])

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("Bookmarks")
        #expect(throws: BrowserImportError.missingFile(missing)) {
            try BrowserChromeBookmarksReader.read(fileURL: missing)
        }
        try write("garbage", to: missing)
        #expect(throws: BrowserImportError.unreadable(missing, "not a Chrome Bookmarks file")) {
            try BrowserChromeBookmarksReader.read(fileURL: missing)
        }
    }

    @Test func profilesFollowLocalStateOrderAndSkipMissingFolders() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Default", "Profile 3", "Profile 4"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try write("""
            { "profile": {
                "info_cache": {
                  "Default": { "name": "Person 1" },
                  "Profile 3": { "name": "Work" },
                  "Profile 4": { "name": "" },
                  "Profile 9": { "name": "Deleted" }
                },
                "profiles_order": ["Profile 3", "Profile 9", "Default"]
            } }
            """, to: directory.appendingPathComponent("Local State"))

        let profiles = BrowserChromeBookmarksReader.profiles(userDataDirectory: directory)
        #expect(profiles.map(\.key) == ["Profile 3", "Default", "Profile 4"])
        #expect(profiles.map(\.displayName) == ["Work", "Person 1", "Profile 4"])
        #expect(profiles.map { $0.directory?.lastPathComponent } == ["Profile 3", "Default", "Profile 4"])
        #expect(profiles[1].isDefault)
    }

    @Test func withoutLocalStateProfileFoldersAreListed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Profile 10", "System Profile", "Default", "Profile 2", "Crashpad"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let profiles = BrowserChromeBookmarksReader.profiles(userDataDirectory: directory)
        #expect(profiles.map(\.key) == ["Default", "Profile 2", "Profile 10"])
        #expect(BrowserChromeBookmarksReader.profiles(userDataDirectory: directory.appendingPathComponent("nope")).isEmpty)
    }
}
