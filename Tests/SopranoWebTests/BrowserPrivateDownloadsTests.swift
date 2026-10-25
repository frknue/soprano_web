@testable import SopranoWeb
import AppKit
import Testing

/// Downloads from a private window: listed in that window while it is
/// open, resumable from memory, never written to `downloads.json` or
/// `DownloadResumeData/`.
@MainActor
struct BrowserPrivateDownloadsTests {
    private func store() throws -> (BrowserDownloadStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-private-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json")), directory)
    }

    @Test func privateRecordsAreListedInTheirWindowAndNeverSaved() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = UUID()
        let saved = store.begin(url: "https://example.com/a.zip", filename: "a.zip")
        store.finish(id: saved.id, path: "/tmp/a.zip")
        let hidden = store.begin(url: "https://private.example/b.zip", filename: "b.zip", privateContextID: context)
        store.finish(id: hidden.id, path: "/tmp/b.zip")

        #expect(store.matching("", privateContextID: context).map(\.filename) == ["b.zip", "a.zip"])
        #expect(store.matching("").map(\.filename) == ["a.zip"])
        #expect(store.matching("", privateContextID: UUID()).map(\.filename) == ["a.zip"])

        let reloaded = BrowserDownloadStore(url: store.url)
        #expect(reloaded.records.map(\.filename) == ["a.zip"])
        let file = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!file.contains("private.example"))
    }

    @Test func privateResumeDataStaysInMemory() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = UUID()
        let record = store.begin(url: "https://private.example/big.iso", filename: "big.iso", privateContextID: context)
        store.cancel(id: record.id, resumeData: Data("resume".utf8))

        #expect(store.records[0].canResume)
        #expect(store.resumeData(id: record.id) == Data("resume".utf8))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: store.resumeDataDirectory.path)) ?? []
        #expect(files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func closingThePrivateWindowForgetsItsRows() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = UUID()
        let other = UUID()
        let saved = store.begin(url: "https://example.com/a.zip", filename: "a.zip")
        let hidden = store.begin(url: "https://private.example/b.zip", filename: "b.zip", privateContextID: context)
        store.cancel(id: hidden.id, resumeData: Data([1, 2]))
        _ = store.begin(url: "https://private.example/c.zip", filename: "c.zip", privateContextID: other)

        store.forgetPrivateContext(context)
        #expect(store.records.map(\.filename) == ["c.zip", "a.zip"])
        #expect(store.resumeData(id: hidden.id) == nil)
        #expect(store.records.contains { $0.id == saved.id })
    }
}
