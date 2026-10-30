@testable import SopranoWeb
import Foundation
import JavaScriptCore
import Testing

@MainActor
struct BrowserBoostTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebBoosts-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("boosts.json")
    }

    // MARK: Host matching

    @Test func aHostAndItsWwwFormShareABoost() {
        #expect(BrowserBoost.key("WWW.Example.com.") == "example.com")
        #expect(BrowserBoost.key("example.com") == "example.com")
        #expect(BrowserBoost.key("mail.example.com") == "mail.example.com")
        #expect(BrowserBoost.key("www.") == "www")
        #expect(BrowserBoost.key("  ") == nil)
        #expect(BrowserBoost.key(for: URL(string: "https://www.example.com/a")) == "example.com")
        #expect(BrowserBoost.key(for: URL(string: "http://127.0.0.1:8080/")) == "127.0.0.1")
        #expect(BrowserBoost.key(for: URL(string: "file:///tmp/a.html")) == nil)
        #expect(BrowserBoost.key(for: URL(string: "about:blank")) == nil)
    }

    /// Runs `BrowserBoostScripts.scriptSource` in JavaScriptCore with a fake
    /// `location`; true when the Boost's code ran.
    private func runs(boostHost: String, on hostname: String) -> Bool {
        let context = JSContext()!
        context.evaluateScript("var location = { hostname: \(BrowserBoostScripts.literal(hostname)) }; var ran = false;")
        context.evaluateScript(BrowserBoostScripts.scriptSource(host: boostHost, js: "ran = true;"))
        return context.objectForKeyedSubscript("ran").toBool()
    }

    @Test func everyScriptChecksTheHostname() {
        #expect(runs(boostHost: "example.com", on: "example.com"))
        #expect(runs(boostHost: "example.com", on: "www.example.com"))
        #expect(runs(boostHost: "example.com", on: "EXAMPLE.com."))
        #expect(!runs(boostHost: "example.com", on: "mail.example.com"))
        #expect(!runs(boostHost: "example.com", on: "example.org"))
        #expect(!runs(boostHost: "example.com", on: "notexample.com"))
        #expect(runs(boostHost: "127.0.0.1", on: "127.0.0.1"))
        #expect(BrowserBoostScripts.scriptSource(host: "a", js: "").hasPrefix(BrowserBoostScripts.marker))
        #expect(BrowserBoostScripts.styleSource(host: "a", css: "").hasPrefix(BrowserBoostScripts.marker))
    }

    @Test func userScriptsCoverOnlyEnabledBoostsWithCode() {
        let scripts = BrowserBoostScripts.userScripts([
            BrowserBoost(host: "a.example", css: "p{}", js: "1"),
            BrowserBoost(host: "b.example", isEnabled: false, css: "p{}"),
            BrowserBoost(host: "c.example", zaps: ["#ad"]),
            BrowserBoost(host: "d.example"),
        ])
        #expect(scripts.count == 3)
        #expect(scripts.map(\.injectionTime) == [.atDocumentStart, .atDocumentEnd, .atDocumentStart])
        let mainFrameOnly = scripts.allSatisfy { $0.isForMainFrameOnly }
        #expect(mainFrameOnly)
    }

    @Test func zapsBecomeHidingRules() {
        let boost = BrowserBoost(host: "a", css: "p { color: red }", zaps: ["#ad", ".x > b"])
        #expect(boost.stylesheet == "p { color: red }\n#ad { display: none !important; }\n.x > b { display: none !important; }")
        #expect(BrowserBoost(host: "a").stylesheet.isEmpty)
    }

    // MARK: Store

    @Test func theStoreDecodesTolerantly() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {"version": 1, "entries": [
          {"host": "WWW.A.example", "css": "p{}", "enabled": "yes", "zaps": ["#x", ""], "future": 1},
          {"name": "no host"},
          {"host": "b.example", "js": 5},
          {"host": "a.example", "css": "duplicate"}
        ]}
        """.utf8).write(to: url)
        let store = BrowserBoostStore(url: url)
        #expect(store.boosts.map(\.host) == ["a.example", "b.example"])
        let a = try #require(store.boost(host: "www.a.example"))
        #expect(a.css == "p{}")
        #expect(a.isEnabled)
        #expect(a.zaps == ["#x"])
        #expect(a.name == "a.example")
        #expect(store.boost(host: "b.example")?.js == "")
    }

    @Test func anUnreadableFileIsKeptAsCorrupt() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let store = BrowserBoostStore(url: url)
        #expect(store.boosts.isEmpty)
        #expect(try String(contentsOf: store.corruptURL, encoding: .utf8) == "{ not json")
    }

    @Test func changesPersistAndNotify() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BrowserBoostStore(url: url)
        var notified = 0
        let observation = store.changes.observe { notified += 1 }
        store.update(host: "www.b.example") { $0.css = "a{}" }
        store.zap("#ad", host: "b.example")
        store.zap("#ad", host: "b.example")
        store.update(host: "a.example") { $0.name = "" }
        #expect(store.boosts.map(\.host) == ["a.example", "b.example"])
        #expect(store.boost(host: "a.example")?.name == "a.example")
        #expect(notified == 3)
        let reread = BrowserBoostStore(url: url)
        #expect(reread.boosts == store.boosts)
        #expect(store.remove(host: "www.b.example"))
        #expect(!store.remove(host: "b.example"))
        #expect(BrowserBoostStore(url: url).boosts.map(\.host) == ["a.example"])
        _ = observation
    }

    // MARK: Zap selectors

    @Test func zapSelectorsAnchorOnStableIDs() {
        typealias Node = BrowserZapSelector.Node
        #expect(BrowserZapSelector.selector(for: [
            Node(tag: "div", classes: ["promo", "is-hovered", "x123abc"], index: 2, count: 3),
            Node(tag: "main", id: "content"),
            Node(tag: "div", id: "app"),
        ]) == "#content > div.promo:nth-of-type(2)")
        #expect(BrowserZapSelector.selector(for: [
            Node(tag: "span"),
            Node(tag: "section", id: "ember1234", index: 3, count: 4),
        ]) == "body > section:nth-of-type(3) > span")
        #expect(BrowserZapSelector.selector(for: [Node(tag: "aside", id: "sidebar")]) == "#sidebar")
        #expect(BrowserZapSelector.selector(for: [Node(tag: "a", id: ":r1:")]) == "body > a")
        #expect(BrowserZapSelector.selector(for: []) == nil)
        #expect(BrowserZapSelector.escape("1st.item") == "\\31 st\\.item")
        #expect(BrowserZapSelector.Node(["tag": "DIV", "index": 2, "count": 2]) == Node(tag: "div", index: 2, count: 2))
        #expect(BrowserZapSelector.Node(["tag": "a b"]) == nil)
    }

    // MARK: CLI

    private func parse(_ words: [String], stdin: String = "", pwd: String = "/tmp") throws -> BrowserCommandRequest? {
        try BrowserCommandRequest.parse(
            ["soprano-web", "browser"] + words,
            environment: ["PWD": pwd],
            standardInput: { Data(stdin.utf8) }
        )
    }

    @Test func theBoostCommandParses() throws {
        #expect(try parse(["boost"])?.arguments == ["list"])
        #expect(try parse(["boost", "list"])?.arguments == ["list"])
        #expect(try parse(["boost", "show", "www.example.com"])?.arguments == ["show", "www.example.com"])
        #expect(try parse(["boost", "disable", "127.0.0.1"])?.arguments == ["disable", "127.0.0.1"])
        #expect(try parse(["boost", "css", "127.0.0.1", "-"], stdin: "body{background:red}\n")?.arguments
            == ["css", "127.0.0.1", "body{background:red}\n"])
        #expect(try parse(["boost", "zap", "a.example", "div", ">", "p"])?.arguments == ["zap", "a.example", "div > p"])
        for bad in [
            ["boost", "show"], ["boost", "show", "https://a.example/"], ["boost", "css", "a.example"],
            ["boost", "zap", "a.example"], ["boost", "wipe", "a.example"], ["boost", "list", "x"],
        ] {
            #expect(throws: BrowserAutomationError.self) { try parse(bad) }
        }
    }

    @Test func theBoostCommandReadsFilesClientSide() throws {
        let directory = temporaryURL().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("document.title = 'x'".utf8).write(to: directory.appendingPathComponent("boost.js"))
        #expect(try parse(["boost", "js", "a.example", "boost.js"], pwd: directory.path)?.arguments
            == ["js", "a.example", "document.title = 'x'"])
        #expect(throws: BrowserAutomationError.self) {
            try parse(["boost", "js", "a.example", "missing.js"], pwd: directory.path)
        }
    }

    @Test func theAppRunsBoostCommands() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BrowserBoostStore(url: url)
        #expect(try BrowserBoostCommands.perform(["list"], in: store).get() == "No Boosts.")
        #expect(throws: BrowserAutomationError.self) { try BrowserBoostCommands.perform(["show", "a.example"], in: store).get() }
        _ = try BrowserBoostCommands.perform(["css", "www.a.example", "p{}"], in: store).get()
        _ = try BrowserBoostCommands.perform(["zap", "a.example", "#ad"], in: store).get()
        _ = try BrowserBoostCommands.perform(["disable", "a.example"], in: store).get()
        let shown = try BrowserBoostCommands.perform(["show", "a.example"], in: store).get()
        #expect(shown.contains("enabled: no"))
        #expect(shown.contains("zap: #ad"))
        #expect(shown.contains("css:\np{}"))
        #expect(try BrowserBoostCommands.perform(["list"], in: store).get().hasPrefix("a.example\toff"))
        _ = try BrowserBoostCommands.perform(["remove", "a.example"], in: store).get()
        #expect(store.boosts.isEmpty)
    }
}
