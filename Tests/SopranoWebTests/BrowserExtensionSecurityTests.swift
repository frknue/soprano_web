@testable import SopranoWeb
import AppKit
import Testing
import WebKit

/// The extension runtime's gates: a web page never opens an extension's
/// page app-side, extensions never load local files or launch other apps
/// unasked, an update grants nothing new, a folder can't take over an
/// installed extension's id, and native hosts answer only their own
/// extensions.
@MainActor
struct BrowserExtensionSecurityTests {
    private let id = String(repeating: "a", count: 32)
    private let other = String(repeating: "b", count: 32)

    // MARK: Pages

    @Test func aWebPageNeverOpensAnExtensionPage() {
        for (scheme, host) in [("https", "evil.example"), ("http", id), ("file", ""), ("chrome-extension", other), (nil, nil)] as [(String?, String?)] {
            #expect(!BrowserExtensions.mayShowPage(
                ofExtension: id,
                sourceScheme: scheme,
                sourceHost: host,
                isPrivate: false,
                hasPrivateAccess: true
            ), "\(scheme ?? "nil")://\(host ?? "nil")")
        }
        // Its own frames may, in a private window only with access.
        #expect(BrowserExtensions.mayShowPage(ofExtension: id, sourceScheme: "chrome-extension", sourceHost: id, isPrivate: false, hasPrivateAccess: false))
        #expect(BrowserExtensions.mayShowPage(ofExtension: id, sourceScheme: "chrome-extension", sourceHost: id, isPrivate: true, hasPrivateAccess: true))
        #expect(!BrowserExtensions.mayShowPage(ofExtension: id, sourceScheme: "chrome-extension", sourceHost: id, isPrivate: true, hasPrivateAccess: false))
    }

    @Test func extensionLoadsOfLocalFilesAndOtherAppsAreGated() {
        let cases: [(String, BrowserExtensions.PageLoad)] = [
            ("https://example.com/", .load),
            ("http://example.com/", .load),
            ("about:blank", .load),
            ("data:text/html,hi", .load),
            ("chrome-extension://\(id)/options.html", .load),
            ("chrome-extension://\(other)/options.html", .refuse),
            ("file:///Users/me/.ssh/id_rsa", .refuse),
            ("FILE:///etc/passwd", .refuse),
            ("javascript:alert(1)", .refuse),
            ("blob:https://example.com/1", .refuse),
            ("soprano-web://start", .refuse),
            ("smb://attacker/share", .external),
            ("zoommtg://zoom.us/join", .external),
            ("vscode://file/x", .external),
        ]
        for (address, expected) in cases {
            #expect(BrowserExtensions.pageLoad(URL(string: address)!, extensionID: id) == expected, "\(address)")
        }
        // An unknown context opens no extension page at all.
        #expect(BrowserExtensions.pageLoad(URL(string: "chrome-extension://\(id)/a.html")!, extensionID: nil) == .refuse)
    }

    // MARK: Native hosts

    @Test func aNativeHostAnswersOnlyItsAllowlist() {
        let hosts: [String: BrowserExtensions.NativeHost] = [
            "soprano": BrowserExtensions.NativeHost(allows: { $0 == String(repeating: "a", count: 32) }, message: { _, _ in nil }),
        ]
        #expect(BrowserExtensions.allowedNativeHost(hosts, application: "soprano", extensionID: id) != nil)
        #expect(BrowserExtensions.allowedNativeHost(hosts, application: "soprano", extensionID: other) == nil)
        #expect(BrowserExtensions.allowedNativeHost(hosts, application: "soprano", extensionID: nil) == nil)
        #expect(BrowserExtensions.allowedNativeHost(hosts, application: "com.example.app", extensionID: id) == nil)
    }

    // MARK: Updates

    @Test func anUpdateGrantsNothingNew() {
        var record = BrowserExtensionRecord(id: id, source: .webStore, name: "X", version: "1")
        BrowserExtensions.grantRequested(permissions: ["storage"], patterns: ["https://example.com/*"], to: &record)
        record.deniedPermissions["tabs"] = .distantFuture
        let additions = BrowserExtensions.applyUpdate(
            to: &record,
            requestedPermissions: ["storage", "cookies", "tabs", "nativeMessaging"],
            requestedPatterns: ["https://example.com/*", "<all_urls>", "file:///*"],
            standIns: ["clients"]
        )
        #expect(Set(record.grantedPermissions.keys) == ["storage", "nativeMessaging"])
        #expect(Set(record.grantedMatchPatterns.keys) == ["https://example.com/*"])
        // The shim's own native messaging is granted with it; local files never.
        #expect(additions == BrowserExtensions.Additions(permissions: ["cookies"], matchPatterns: ["<all_urls>"]))
        BrowserExtensions.grant(additions, to: &record)
        #expect(record.grantedPermissions["cookies"] != nil)
        #expect(record.grantedMatchPatterns["<all_urls>"] != nil)
    }

    @Test func narrowedSiteAccessAsksForNoSites() {
        var record = BrowserExtensionRecord(id: id, source: .webStore, name: "X", version: "1")
        record.siteAccess = .onClick
        let additions = BrowserExtensions.applyUpdate(
            to: &record,
            requestedPermissions: [],
            requestedPatterns: ["<all_urls>"],
            standIns: []
        )
        #expect(additions.isEmpty)
    }

    @Test func aNewRecordNeverGetsLocalFiles() {
        var record = BrowserExtensionRecord(id: id, source: .webStore, name: "X", version: "1")
        BrowserExtensions.grantRequested(permissions: [], patterns: ["<all_urls>", "file:///*"], to: &record)
        #expect(Set(record.grantedMatchPatterns.keys) == ["<all_urls>"])
    }

    // MARK: Installs through the controller

    private func makeExtensions() -> (BrowserExtensions, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let extensions = BrowserExtensions(
            supportDirectory: directory.appendingPathComponent("Support", isDirectory: true),
            storage: .volatile,
            checksForUpdates: false
        )
        return (extensions, directory)
    }

    private func writeFolder(_ folder: URL, manifest: [String: Any]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
    }

    @Test func aFolderCarryingAnInstalledExtensionsKeyIsRefused() async throws {
        let (extensions, directory) = makeExtensions()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data((0..<64).map { UInt8($0) }).base64EncodedString()
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Original", "version": "1.0", "key": key]
        let original = directory.appendingPathComponent("original", isDirectory: true)
        try writeFolder(original, manifest: manifest)
        let installed = try await extensions.install(original.path)
        #expect(installed.source == .folder(original.path))
        try extensions.setAllowsPrivate(installed.id, true)

        var impostor = manifest
        impostor["name"] = "Impostor"
        let other = directory.appendingPathComponent("impostor", isDirectory: true)
        try writeFolder(other, manifest: impostor)
        await #expect(throws: BrowserExtensions.InstallError.self) {
            try await extensions.install(other.path)
        }
        let record = try #require(extensions.store.record(id: installed.id))
        #expect(record.name == "Original")
        #expect(record.source == .folder(original.path))
        #expect(record.allowsPrivate)

        // Confirmed in Settings, the replacement starts over.
        var asked: [BrowserExtensions.InstallReview.Kind] = []
        let replaced = try await extensions.install(other.path) { review in
            asked.append(review.kind)
            return true
        }
        #expect(asked == [.replace(installed: .folder(original.path), new: .folder(other.path))])
        #expect(replaced.name == "Impostor")
        #expect(!replaced.allowsPrivate)
        await extensions.removeAllData()
    }

    @Test func anUpdateOfAnInstalledFolderGrantsNothingNew() async throws {
        let (extensions, directory) = makeExtensions()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try writeFolder(folder, manifest: ["manifest_version": 3, "name": "Grows", "version": "1.0", "permissions": ["storage"]])
        let first = try await extensions.install(folder.path)
        #expect(first.grantedPermissions["storage"] != nil)

        try writeFolder(folder, manifest: [
            "manifest_version": 3, "name": "Grows", "version": "2.0",
            "permissions": ["storage", "cookies"], "host_permissions": ["<all_urls>"],
        ])
        let updated = try await extensions.install(folder.path)
        #expect(updated.version == "2.0")
        #expect(updated.grantedPermissions["cookies"] == nil)
        #expect(updated.grantedMatchPatterns["<all_urls>"] == nil)
        #expect(extensions.pendingAdditions[first.id] == BrowserExtensions.Additions(permissions: ["cookies"], matchPatterns: ["<all_urls>"]))
        await extensions.removeAllData()
    }

    @Test func aSheetDecidesOnlyWhatItShowed() async throws {
        let (extensions, directory) = makeExtensions()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try writeFolder(folder, manifest: ["manifest_version": 3, "name": "Grows", "version": "1.0", "permissions": ["storage"]])
        let first = try await extensions.install(folder.path)
        try writeFolder(folder, manifest: ["manifest_version": 3, "name": "Grows", "version": "2.0", "permissions": ["storage", "cookies"]])
        _ = try await extensions.install(folder.path)
        let shown = try #require(extensions.pendingAdditions[first.id])
        #expect(shown == BrowserExtensions.Additions(permissions: ["cookies"]))
        // Another update lands while that sheet is open.
        try writeFolder(folder, manifest: [
            "manifest_version": 3, "name": "Grows", "version": "3.0",
            "permissions": ["storage", "cookies"], "host_permissions": ["<all_urls>"],
        ])
        _ = try await extensions.install(folder.path)
        #expect(extensions.pendingAdditions[first.id] == BrowserExtensions.Additions(permissions: ["cookies"], matchPatterns: ["<all_urls>"]))

        extensions.decideAdditions(first.id, allowed: true, shown: shown)
        let record = try #require(extensions.store.record(id: first.id))
        #expect(record.grantedPermissions["cookies"] != nil)
        #expect(record.grantedMatchPatterns["<all_urls>"] == nil)
        #expect(extensions.pendingAdditions[first.id] == BrowserExtensions.Additions(matchPatterns: ["<all_urls>"]))
        await extensions.removeAllData()
    }

    @Test func removingOrDisablingWhileTheUpdateSheetIsOpenSticks() async throws {
        let (extensions, directory) = makeExtensions()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        let v1: [String: Any] = ["manifest_version": 3, "name": "Grows", "version": "1.0", "permissions": ["storage"]]
        let v2: [String: Any] = ["manifest_version": 3, "name": "Grows", "version": "2.0", "permissions": ["storage", "cookies"]]
        try writeFolder(folder, manifest: v1)
        let first = try await extensions.install(folder.path)
        try writeFolder(folder, manifest: v2)
        await #expect(throws: BrowserExtensions.InstallError.self) {
            try await extensions.install(folder.path) { _ in
                try? await extensions.remove(first.id)
                return true
            }
        }
        #expect(extensions.store.record(id: first.id) == nil)

        try writeFolder(folder, manifest: v1)
        _ = try await extensions.install(folder.path)
        try writeFolder(folder, manifest: v2)
        let updated = try await extensions.install(folder.path) { _ in
            try? await extensions.setEnabled(first.id, false)
            return true
        }
        #expect(!updated.isEnabled)
        #expect(updated.version == "2.0")
        #expect(updated.grantedPermissions["cookies"] != nil)
        await extensions.removeAllData()
    }
}
