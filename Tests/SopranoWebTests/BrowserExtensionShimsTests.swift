@testable import SopranoWeb
import AppKit
import Testing

/// The shim put into an installed copy: which stand-ins a manifest asks
/// for, the background of each kind (module worker, classic worker,
/// background scripts) and every page getting it first, a re-apply that
/// changes nothing, an update that gets it again, and a package that asks
/// for nothing left alone.
struct BrowserExtensionShimsTests {
    private func package(_ manifest: String, files: [String: String] = [:]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return folder
    }

    /// The file's text with a byte-order mark kept (U+FEFF).
    private func read(_ folder: URL, _ path: String) throws -> String {
        String(decoding: try Data(contentsOf: folder.appendingPathComponent(path)), as: UTF8.self)
    }

    private func manifest(_ folder: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any] ?? [:]
    }

    @Test func standInsFollowTheManifest() {
        let policy = "default-src 'self'; connect-src 'self' https://*.1password.com wss://*.1password.com "
            + "wss://*.1password.ca; script-src 'self' 'wasm-unsafe-eval'"
        let onePassword: [String: Any] = [
            "permissions": ["notifications", "webNavigation", "storage"],
            "host_permissions": ["<all_urls>"],
            "storage": ["managed_schema": "schema.json"],
            "minimum_chrome_version": "140",
            "content_security_policy": ["extension_pages": policy],
            "background": ["service_worker": "background.js", "type": "module"],
        ]
        #expect(BrowserExtensionShims.standIns(for: onePassword) == [
            "notifications", "webNavigation", "storage.managed", "userAgent", "permissions", "wasm", "clients", "webSocket",
        ])
        // A storage permission alone is no managed schema; an optional
        // permission is not granted yet and asks for nothing.
        let small: [String: Any] = ["permissions": ["storage"], "optional_permissions": ["notifications"]]
        #expect(BrowserExtensionShims.standIns(for: small).isEmpty)
        #expect(BrowserExtensionShims.standIns(for: ["permissions": ["tabs"]]).isEmpty)
    }

    @Test func everyWorkerWhosePolicyCouldPermitASocketGetsTheWebSocket() {
        let worker: [String: Any] = ["background": ["service_worker": "w.js"]]
        func standIns(_ policy: Any?) -> [String] {
            var manifest = worker
            manifest["content_security_policy"] = policy
            return BrowserExtensionShims.standIns(for: manifest)
        }
        // No policy, one that bounds no connection, `*`, http(s) (they
        // cover ws/wss) or a scheme-less host: the policy permits a socket,
        // so the worker gets the app's (WebKit's own would freeze it).
        #expect(standIns(nil) == ["clients", "webSocket"])
        #expect(standIns(["extension_pages": "script-src 'self'"]) == ["clients", "webSocket"])
        #expect(standIns(["extension_pages": "connect-src https://api.example.com"]) == ["clients", "webSocket"])
        #expect(standIns(["extension_pages": "connect-src *"]) == ["clients", "webSocket"])
        #expect(standIns(["extension_pages": "connect-src http:"]) == ["clients", "webSocket"])
        #expect(standIns(["extension_pages": "connect-src api.example.com"]) == ["clients", "webSocket"])
        // A scheme source or a host source with a socket scheme, in
        // `connect-src` or in `default-src` without one; MV2's string too.
        #expect(standIns(["extension_pages": "connect-src 'self' wss:"]) == ["clients", "webSocket"])
        #expect(standIns(["extension_pages": "default-src 'self' WS://localhost:8080"]) == ["clients", "webSocket"])
        #expect(standIns("script-src 'self'; connect-src wss://push.example.com/") == ["clients", "webSocket"])
        #expect(standIns(["extension_pages": "default-src wss:; connect-src https:"]) == ["clients", "webSocket"])
        // Only keywords or other schemes: no socket can open.
        #expect(standIns(["extension_pages": "connect-src 'self'"]) == ["clients"])
        #expect(standIns(["extension_pages": "connect-src 'none'"]) == ["clients"])
        #expect(standIns(["extension_pages": "default-src 'self' data: blob:; script-src 'self'"]) == ["clients"])
        #expect(standIns(["extension_pages": "connect-src ftp://files.example.com"]) == ["clients"])
        // `connect-src` wins over `default-src`.
        #expect(standIns(["extension_pages": "default-src wss:; connect-src 'self'"]) == ["clients"])
        // Background pages are no worker.
        #expect(BrowserExtensionShims.standIns(for: [
            "background": ["scripts": ["a.js"]],
            "content_security_policy": "connect-src wss:",
        ]).isEmpty)
    }

    @Test func moduleWorkerImportsTheShimFirstAndReapplyChangesNothing() throws {
        let folder = try package(
            #"{"manifest_version":3,"name":"M","version":"1","permissions":["notifications","nativeMessaging"],"background":{"service_worker":"bg/worker.js","type":"module"},"action":{"default_popup":"popup.html"}}"#,
            files: [
                "bg/worker.js": "import x from \"./x.js\";\nx();\n",
                "popup.html": "<!doctype html>\n<html><head><meta charset=\"utf-8\"></head><body></body></html>",
                "page.htm": "<p>no head</p>",
            ]
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifestBefore = try read(folder, "manifest.json")
        let names = try BrowserExtensionShims.prepare(folder, fresh: true)
        #expect(names.contains("notifications"))
        #expect(try read(folder, "bg/worker.js") == "import \"/soprano-shim.js\";\nimport x from \"./x.js\";\nx();\n")
        #expect(try read(folder, "popup.html").contains("<head><script src=\"/soprano-shim.js\"></script><meta"))
        #expect(try read(folder, "page.htm") == "<script src=\"/soprano-shim.js\"></script><p>no head</p>")
        let shim = try read(folder, "soprano-shim.js")
        #expect(shim.contains(#"new Set(["notifications","clients","webSocket"])"#))
        #expect(!shim.contains("__SOPRANO_"))
        // nativeMessaging was already asked for: the manifest is untouched.
        #expect(try read(folder, "manifest.json") == manifestBefore)

        // Again (a launch), and again with the stamp gone (a newer shim):
        // still one import and one tag.
        try BrowserExtensionShims.prepare(folder, fresh: false)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(BrowserExtensionShims.stampFile))
        try BrowserExtensionShims.prepare(folder, fresh: false)
        let worker = try read(folder, "bg/worker.js")
        #expect(worker.components(separatedBy: "soprano-shim.js").count == 2)
        #expect(try read(folder, "popup.html").components(separatedBy: "soprano-shim.js").count == 2)
        #expect(try read(folder, "manifest.json") == manifestBefore)
    }

    @Test func classicWorkerKeepsItsUseStrictDirective() throws {
        let folder = try package(
            #"{"manifest_version":3,"name":"C","version":"1","permissions":["webNavigation"],"background":{"service_worker":"worker.js"}}"#,
            files: ["worker.js": "\u{FEFF}\"use strict\";\nconst a = 1;\n"]
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        try BrowserExtensionShims.prepare(folder, fresh: true)
        #expect(try read(folder, "worker.js") == "\u{FEFF}\"use strict\";\nimportScripts(\"/soprano-shim.js\");\nconst a = 1;\n")
        // The shim reaches the app through native messaging: added, and
        // written down as ours.
        let permissions = try manifest(folder)["permissions"] as? [String]
        #expect(permissions == ["webNavigation", "nativeMessaging"])
        #expect(try read(folder, BrowserExtensionShims.addedFile) == #"["nativeMessaging"]"#)
        // Re-applied with a changed shim: nativeMessaging still once.
        try FileManager.default.removeItem(at: folder.appendingPathComponent(BrowserExtensionShims.stampFile))
        try BrowserExtensionShims.prepare(folder, fresh: false)
        #expect(try manifest(folder)["permissions"] as? [String] == ["webNavigation", "nativeMessaging"])
        #expect(try read(folder, "worker.js").components(separatedBy: "importScripts").count == 2)
    }

    @Test func backgroundScriptsGetTheShimAsTheirFirstScript() throws {
        let folder = try package(
            #"{"manifest_version":2,"name":"S","version":"1","permissions":["notifications"],"background":{"scripts":["a.js","b.js"]}}"#,
            files: ["a.js": "", "b.js": ""]
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        try BrowserExtensionShims.prepare(folder, fresh: true)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(BrowserExtensionShims.stampFile))
        try BrowserExtensionShims.prepare(folder, fresh: false)
        let background = try manifest(folder)["background"] as? [String: Any]
        #expect(background?["scripts"] as? [String] == ["soprano-shim.js", "a.js", "b.js"])
    }

    @Test func anUpdateGetsTheShimAgainAndOneAskingForNothingIsLeftAlone() throws {
        let manifest = #"{"manifest_version":3,"name":"U","version":"2","permissions":["notifications"],"background":{"service_worker":"w.js"}}"#
        let folder = try package(manifest, files: ["w.js": "self.x = 1;\n"])
        defer { try? FileManager.default.removeItem(at: folder) }
        try BrowserExtensionShims.prepare(folder, fresh: true)
        // An update replaces the package whole; a stamp it brings along is
        // not ours.
        try FileManager.default.removeItem(at: folder)
        let updated = try package(manifest, files: ["w.js": "self.x = 2;\n", ".soprano-shim": "forged"])
        defer { try? FileManager.default.removeItem(at: updated) }
        try BrowserExtensionShims.prepare(updated, fresh: true)
        #expect(try read(updated, "w.js") == "importScripts(\"/soprano-shim.js\");\nself.x = 2;\n")

        let plain = try package(
            #"{"manifest_version":3,"name":"P","version":"1","permissions":["tabs"]}"#,
            files: ["popup.html": "<html><head></head></html>"]
        )
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(try BrowserExtensionShims.prepare(plain, fresh: true).isEmpty)
        #expect(try read(plain, "popup.html") == "<html><head></head></html>")
        #expect(!FileManager.default.fileExists(atPath: plain.appendingPathComponent("soprano-shim.js").path))
    }

    @Test func aWorkerOutsideThePackageIsRefused() throws {
        let folder = try package(
            #"{"manifest_version":3,"name":"E","version":"1","permissions":["notifications"],"background":{"service_worker":"../outside.js"}}"#
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: BrowserExtensionShims.Failure.self) {
            try BrowserExtensionShims.inside("../outside.js", of: folder)
        }
        // The rest of the package still gets its shim; nothing is written
        // outside it.
        try BrowserExtensionShims.prepare(folder, fresh: true)
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("outside.js").path))
    }
}
