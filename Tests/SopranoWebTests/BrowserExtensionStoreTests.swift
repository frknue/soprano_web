@testable import SopranoWeb
import AppKit
import Testing

/// `extensions.json`: tolerant decoding (bad records skipped, repeated ids
/// dropped, unreadable fields defaulted), saving and reading back, a
/// damaged file kept aside, and packages replaced whole.
@MainActor
struct BrowserExtensionStoreTests {
    private let ublock = "ddkjiahejlhfcafbddmgiahcphecmpfh"
    private let wappalyzer = "gppongmhjkpfnbhagpmjfkannfbllamg"

    private func decode(_ json: String) throws -> BrowserExtensionsFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BrowserExtensionsFile.self, from: Data(json.utf8))
    }

    @Test func badRecordsAreSkippedAndRepeatedIdsKeepTheFirst() throws {
        let file = try decode("""
        { "version": 1, "extensions": [
          { "id": "\(ublock)", "source": "webStore", "name": "uBlock Origin Lite", "version": "2025.1", "enabled": false },
          { "id": "not-an-id", "source": "webStore" },
          { "id": "\(wappalyzer)", "source": "ftp" },
          { "id": "\(wappalyzer)", "source": "folder" },
          { "id": "\(ublock)", "source": "webStore", "name": "Second" },
          42,
          { "id": "\(wappalyzer)", "source": "folder", "folder": "/tmp/w", "siteAccess": "nonsense",
            "privateAccess": "yes", "grantedMatchPatterns": { "*://*/*": "2030-01-01T00:00:00Z", "bad": "soon" } }
        ] }
        """)
        #expect(file.extensions.map(\.id) == [ublock, wappalyzer])
        #expect(file.extensions[0].name == "uBlock Origin Lite")
        #expect(file.extensions[0].isEnabled == false)
        let folder = file.extensions[1]
        #expect(folder.source == .folder("/tmp/w"))
        #expect(folder.name == wappalyzer)
        #expect(folder.isEnabled)
        #expect(folder.siteAccess == .allSites)
        #expect(!folder.allowsPrivate)
        #expect(Array(folder.grantedMatchPatterns.keys) == ["*://*/*"])
    }

    @Test func aFileWithoutExtensionsReadsEmpty() throws {
        #expect(try decode(#"{"version": 1}"#).extensions.isEmpty)
        #expect(try decode(#"{"extensions": "nope"}"#).extensions.isEmpty)
    }

    @Test func recordsRoundTripThroughTheStore() throws {
        let support = ExtensionTestFixtures.temporaryURL("support")
        defer { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
        let store = BrowserExtensionStore(supportDirectory: support)
        // ISO 8601 keeps whole seconds.
        var record = BrowserExtensionRecord(
            id: ublock,
            source: .webStore,
            name: "uBlock Origin Lite",
            version: "1.0",
            installedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        record.allowsPrivate = true
        record.siteAccess = .specificSites
        record.allowedSites = ["example.com"]
        record.grantedPermissions = ["declarativeNetRequest": .distantFuture]
        record.deniedMatchPatterns = ["*://bank.example/*": .distantFuture]
        store.save(record)
        store.update(id: ublock) { $0.isEnabled = false }

        let reread = BrowserExtensionStore(supportDirectory: support)
        record.isEnabled = false
        #expect(reread.records == [record])
        reread.remove(id: ublock)
        #expect(BrowserExtensionStore(supportDirectory: support).records.isEmpty)
    }

    @Test func anUnreadableFileIsKeptAside() throws {
        let support = ExtensionTestFixtures.temporaryURL("support")
        defer { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: support.appendingPathComponent("extensions.json"))
        let store = BrowserExtensionStore(supportDirectory: support)
        #expect(store.records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("extensions.json.corrupt").path))
    }

    @Test func aNewPackageReplacesTheOldOneWhole() throws {
        let support = ExtensionTestFixtures.temporaryURL("support")
        defer { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
        let store = BrowserExtensionStore(supportDirectory: support)
        for version in ["1", "2"] {
            let staged = store.stagingFolder()
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try Data(version.utf8).write(to: staged.appendingPathComponent("v\(version).txt"))
            try store.installPackage(staged, id: ublock)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: store.folder(for: ublock).path)
        #expect(files == ["v2.txt"])
    }
}
