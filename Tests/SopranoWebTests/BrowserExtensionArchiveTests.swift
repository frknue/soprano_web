@testable import SopranoWeb
import AppKit
import Testing

/// Unpacking extension packages: hostile ZIP entries are refused before
/// anything is written, a good package lands whole, and an unpacked folder
/// with a symlink is refused.
struct BrowserExtensionArchiveTests {
    private typealias F = ExtensionTestFixtures

    private func refusal(_ entries: [F.ZipEntry]) -> BrowserExtensionArchive.Failure? {
        do {
            try BrowserExtensionArchive.validate(try BrowserExtensionArchive.entries(of: F.zip(entries)))
            return nil
        } catch {
            return error
        }
    }

    private let manifest = F.ZipEntry.file("manifest.json", F.manifest)

    @Test func pathsThatEscapeTheFolderAreRefused() {
        for path in ["../evil.js", "js/../../evil.js", "/etc/evil", "js\\evil.js", "./x.js", "js//x.js", "c:", "a/b:c"] {
            #expect(refusal([manifest, .file(path, "x")]) == .unsafePath(path), "\(path)")
        }
    }

    @Test func symlinksAreRefused() {
        #expect(refusal([manifest, .symlink("link", to: "/etc/passwd")]) == .symlink("link"))
    }

    @Test func duplicatePathsAfterFoldingAreRefused() {
        #expect(refusal([manifest, .file("App.js", "a"), .file("app.js", "b")]) == .duplicate("app.js"))
        // é precomposed and decomposed.
        #expect(refusal([manifest, .file("caf\u{e9}.js", "a"), .file("cafe\u{301}.js", "b")]) == .duplicate("cafe\u{301}.js"))
    }

    @Test func encryptedEntriesAndPackagesWithoutManifestAreRefused() {
        var secret = F.ZipEntry.file("secret.js", "x")
        secret.encrypted = true
        #expect(refusal([manifest, secret]) == .encrypted("secret.js"))
        #expect(refusal([.file("js/main.js", "x")]) == .missingManifest)
        #expect(refusal([manifest]) == nil)
    }

    @Test func notAZipIsRefused() {
        #expect(throws: BrowserExtensionArchive.Failure.notZIP) {
            try BrowserExtensionArchive.entries(of: Data("hello".utf8))
        }
    }

    @Test func aHostileArchiveWritesNothing() {
        let destination = F.temporaryURL()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        #expect(throws: BrowserExtensionArchive.Failure.unsafePath("../evil.js")) {
            try BrowserExtensionArchive.extract(F.zip([manifest, .file("../evil.js", "x")]), to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().appendingPathComponent("evil.js").path))
    }

    @Test func aGoodArchiveUnpacksWhole() throws {
        let destination = F.temporaryURL()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let manifest = try BrowserExtensionArchive.extract(F.validZip, to: destination)
        #expect(manifest["name"] as? String == "Fixture")
        let script = try String(contentsOf: destination.appendingPathComponent("js/background.js"), encoding: .utf8)
        #expect(script == "console.log('hi')")
    }

    @Test func manifestsMustBeAChromeExtension() {
        #expect(throws: BrowserExtensionArchive.Failure.badManifest("manifest_version must be 2 or 3")) {
            try BrowserExtensionArchive.checkManifest(Data(#"{"manifest_version": 4, "name": "x"}"#.utf8))
        }
        #expect(throws: BrowserExtensionArchive.Failure.badManifest("themes are not extensions")) {
            try BrowserExtensionArchive.checkManifest(Data(#"{"manifest_version": 3, "name": "x", "theme": {}}"#.utf8))
        }
        #expect(throws: BrowserExtensionArchive.Failure.badManifest("no name")) {
            try BrowserExtensionArchive.checkManifest(Data(#"{"manifest_version": 2}"#.utf8))
        }
        // A byte-order mark is fine.
        #expect((try? BrowserExtensionArchive.checkManifest(Data([0xef, 0xbb, 0xbf]) + Data(F.manifest.utf8))) != nil)
    }

    @Test func anUnpackedFolderWithASymlinkIsRefused() throws {
        let source = F.temporaryURL("source")
        let destination = source.deletingLastPathComponent().appendingPathComponent("copy", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(F.manifest.utf8).write(to: source.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("outside"),
            withDestinationURL: URL(fileURLWithPath: "/etc")
        )
        #expect(throws: BrowserExtensionArchive.Failure.symlink("outside")) {
            try BrowserExtensionArchive.copyFolder(source, to: destination)
        }
        try FileManager.default.removeItem(at: source.appendingPathComponent("outside"))
        try BrowserExtensionArchive.copyFolder(source, to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
    }
}
