@testable import SopranoWeb
import AppKit
import Testing

/// Unpacking extension packages: hostile ZIP entries and archives that
/// could read differently to different readers are refused before
/// anything is written, a good package (stored or deflated) lands whole,
/// a bomb stops at the cap, and an unpacked folder with a symlink is
/// refused.
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

    /// Extracting `archive` fails with `failure` and leaves nothing at
    /// the destination.
    private func expectRefusal(
        _ archive: Data,
        _ failure: BrowserExtensionArchive.Failure,
        limit: UInt64 = BrowserExtensionArchive.maxUncompressedSize,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let destination = F.temporaryURL()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        #expect(throws: failure, sourceLocation: sourceLocation) {
            try BrowserExtensionArchive.extract(archive, to: destination, limit: limit)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path), sourceLocation: sourceLocation)
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

    @Test func aDecoyEndRecordIsRefused() {
        // The real end record's comment holds a decoy directory and end
        // record listing only the manifest.
        let archive = F.decoyZip([manifest, .file("../evil.js", "x")], listing: ["manifest.json"])
        expectRefusal(archive, .ambiguous)
    }

    @Test func aLocalHeaderThatDiffersFromTheCentralDirectoryIsRefused() {
        var renamed = F.ZipEntry.file("script.js", "x")
        renamed.localPath = "../evil.js"
        expectRefusal(F.zip([manifest, renamed]), .badLocalHeader("script.js"))
        // Same length, different bytes.
        renamed.localPath = "SCRIPT.js"
        expectRefusal(F.zip([manifest, renamed]), .badLocalHeader("script.js"))
    }

    @Test func aSymlinkFromAnotherHostIsRefused() {
        var link = F.ZipEntry.symlink("link", to: "/etc/passwd")
        link.host = 0
        expectRefusal(F.zip([manifest, link]), .symlink("link"))
    }

    @Test func aFileAndAFolderOfTheSameNameAreRefused() {
        expectRefusal(F.zip([manifest, .file("a", "x"), .file("a/b.js", "y")]), .clash("a"))
        expectRefusal(F.zip([manifest, .file("a/b.js", "y"), .file("A", "x")]), .clash("A"))
        expectRefusal(F.zip([manifest, .file("lib", "x"), .directory("LIB/sub/")]), .clash("lib"))
    }

    @Test func aZipBombIsStoppedAtTheCap() {
        let limit: UInt64 = 64 << 10
        let zeros = Data(count: 1 << 20)
        // Declared honestly: refused before anything is written.
        expectRefusal(
            F.zip([manifest, .deflated("bomb.js", zeros)]),
            .tooLarge(UInt64(F.manifest.utf8.count) + (1 << 20)),
            limit: limit
        )
        // Declared small: inflating stops once it passes the declared size.
        var liar = F.ZipEntry.deflated("bomb.js", zeros)
        liar.declaredSize = 16
        expectRefusal(F.zip([manifest, liar]), .corrupt("bomb.js"), limit: limit)
        // Shorter than declared is refused too.
        var short = F.ZipEntry.file("short.js", "x")
        short.declaredSize = 1000
        expectRefusal(F.zip([manifest, short]), .corrupt("short.js"), limit: limit)
    }

    @Test func aDeflatedArchiveUnpacksWhole() throws {
        let destination = F.temporaryURL()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        // Larger than one inflation chunk.
        let script = Data(String(repeating: "console.log('hi');\n", count: 10_000).utf8)
        var fromDOS = F.ZipEntry.deflated("js/dos.js", Data("made on DOS".utf8))
        fromDOS.host = 0
        var executable = F.ZipEntry.file("run.sh", "#!/bin/sh")
        executable.mode = 0o100755
        let archive = F.zip([
            .deflated("manifest.json", Data(F.manifest.utf8)),
            .directory("js/"),
            .deflated("js/background.js", script),
            fromDOS,
            executable,
        ], comment: Data("a comment".utf8))
        let unpacked = try BrowserExtensionArchive.extract(archive, to: destination)
        #expect(unpacked["name"] as? String == "Fixture")
        #expect(try Data(contentsOf: destination.appendingPathComponent("js/background.js")) == script)
        #expect(try Data(contentsOf: destination.appendingPathComponent("js/dos.js")) == Data("made on DOS".utf8))
        // Stored modes are ignored.
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("run.sh").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
    }

    /// Archives the way real tools write them: `ditto -c -k` (deflated
    /// entries with data descriptors, bit 3, zeroed local CRC and sizes,
    /// empty files as 2-byte deflate streams), `zip` to a file (empty files
    /// stored) and `zip` to a pipe (data descriptors).
    @Test func archivesFromDittoAndZipUnpackWhole() throws {
        let root = F.temporaryURL().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ext", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("js"), withIntermediateDirectories: true)
        let script = Data(String(repeating: "console.log('hi');\n", count: 5_000).utf8)
        try Data(F.manifest.utf8).write(to: source.appendingPathComponent("manifest.json"))
        try script.write(to: source.appendingPathComponent("js/background.js"))
        try Data().write(to: source.appendingPathComponent("empty.txt"))

        func run(_ tool: String, _ arguments: [String], output: URL? = nil) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.currentDirectoryURL = source
            if let output {
                FileManager.default.createFile(atPath: output.path, contents: nil)
                process.standardOutput = try FileHandle(forWritingTo: output)
            }
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        let ditto = root.appendingPathComponent("ditto.zip")
        try run("/usr/bin/ditto", ["-c", "-k", source.path, ditto.path])
        let zipped = root.appendingPathComponent("zip.zip")
        try run("/usr/bin/zip", ["-q", "-r", zipped.path, "."])
        let piped = root.appendingPathComponent("piped.zip")
        try run("/usr/bin/zip", ["-q", "-r", "-", "."], output: piped)

        for archive in [ditto, zipped, piped] {
            let destination = root.appendingPathComponent("out-\(archive.lastPathComponent)", isDirectory: true)
            let manifest = try BrowserExtensionArchive.extract(Data(contentsOf: archive), to: destination)
            #expect(manifest["name"] as? String == "Fixture", "\(archive.lastPathComponent)")
            #expect(try Data(contentsOf: destination.appendingPathComponent("js/background.js")) == script)
            #expect(try Data(contentsOf: destination.appendingPathComponent("empty.txt")).isEmpty)
        }
        // Data descriptors (general purpose bit 3) were really exercised.
        func usesDescriptors(_ url: URL) throws -> Bool {
            let bytes = [UInt8](try Data(contentsOf: url))
            return bytes.indices.dropLast(8).contains { i in
                bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 3 && bytes[i + 3] == 4 && bytes[i + 6] & 0x08 != 0
            }
        }
        #expect(try usesDescriptors(ditto) || usesDescriptors(piped))
    }
}
