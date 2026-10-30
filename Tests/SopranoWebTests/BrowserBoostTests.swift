@testable import SopranoWeb
import Foundation
import JavaScriptCore
import Testing
import WebKit

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
        #expect(BrowserBoostScripts.hidingRule(".x > b") == ".x > b { display: none !important; }")
        #expect(BrowserBoost(host: "a", zaps: ["#ad"]).hasStyle)
        #expect(BrowserBoost(host: "a", css: "p{}").hasStyle)
        #expect(!BrowserBoost(host: "a", js: "1").hasStyle)
        #expect(BrowserBoostScripts.literal(["a\"", "b"]) == "[\"a\\\"\", \"b\"]")
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
        // P7 review P3-3: `CSS.escape`'s rules.
        #expect(BrowserZapSelector.escape("-1ad") == "-\\31 ad")
        #expect(BrowserZapSelector.escape("\u{663}x") == "\u{663}x")
        #expect(BrowserZapSelector.escape("-") == "\\-")
        #expect(BrowserZapSelector.escape("a\u{1}b") == "a\\1 b")
        #expect(BrowserZapSelector.escape("x-ui_card") == "x-ui_card")
        #expect(BrowserZapSelector.Node(["tag": "DIV", "index": 2, "count": 2]) == Node(tag: "div", index: 2, count: 2))
        #expect(BrowserZapSelector.Node(["tag": "a b"]) == nil)
        // Custom element names may use `_` and `.`; the dot is escaped.
        let custom = BrowserZapSelector.Node(["tag": "my_el.v2-x", "index": 1, "count": 1])
        #expect(custom != nil)
        #expect(custom.flatMap { BrowserZapSelector.selector(for: [$0]) } == "body > my_el\\.v2-x")
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
        // P7 review P3-7: pages report punycode, so a Unicode host is refused with that hint.
        #expect(throws: BrowserAutomationError.self) { try parse(["boost", "css", "bücher.de", "-"], stdin: "p{}") }
        do {
            _ = try parse(["boost", "show", "bücher.de"])
            Issue.record("a Unicode host was accepted")
        } catch {
            #expect(error.localizedDescription.contains("punycode"))
        }
        #expect(try parse(["boost", "show", "xn--bcher-kva.de"])?.arguments == ["show", "xn--bcher-kva.de"])
        // P3-8: input the app can't take is refused client-side, by name.
        let large = String(repeating: "a", count: BrowserAutomationServer.maxRequestBytes)
        do {
            _ = try parse(["boost", "css", "a.example", "-"], stdin: large)
            Issue.record("a 16 MB stdin was accepted")
        } catch {
            #expect(error.localizedDescription == "The standard input is larger than 16 MB")
        }
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

    // MARK: In a page

    /// A web view with `boost`'s user scripts, showing `html` as
    /// https://boost.test/, loaded.
    private func boostPage(_ boost: BrowserBoost, html: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        BrowserBoostScripts.userScripts([boost]).forEach(configuration.userContentController.addUserScript)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.loadHTMLString("<!doctype html><title>loaded</title>" + html, baseURL: URL(string: "https://boost.test/")!)
        let deadline = Date().addingTimeInterval(10)
        while (try? await run("document.readyState === 'complete' ? document.title : ''", in: webView)) == "", Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return webView
    }

    private func run(_ script: String, in webView: WKWebView, world: WKContentWorld = .page) async throws -> String {
        let value = try await webView.evaluateJavaScript(script, contentWorld: world)
        return value.map { "\($0)" } ?? ""
    }

    private func color(of id: String, in webView: WKWebView) async throws -> String {
        try await run("getComputedStyle(document.getElementById('\(id)')).color", in: webView)
    }

    /// P7 review: a page whose CSP has `style-src 'self'` blocks an added
    /// `<style>`, even one an isolated world adds. The Boost sheet is a
    /// constructed sheet in `adoptedStyleSheets`, which CSP leaves alone,
    /// both at document start and when the editor re-applies it live.
    @Test func aStrictStyleCSPKeepsTheBoostSheet() async throws {
        let webView = try await boostPage(
            BrowserBoost(host: "boost.test", css: "p { color: rgb(255, 0, 0); }"),
            html: "<meta http-equiv=\"Content-Security-Policy\" content=\"style-src 'self'\"><p id=p>text</p><b id=b>bold</b>"
        )
        #expect(try await color(of: "p", in: webView) == "rgb(255, 0, 0)")

        // The policy is in force: a `<style>` the Boost world adds is blocked.
        _ = try await run(
            "var s = document.createElement('style'); s.textContent = '#b { color: rgb(0, 0, 255); }';"
                + " document.head.appendChild(s); 'ok'",
            in: webView,
            world: BrowserBoostScripts.world
        )
        #expect(try await color(of: "b", in: webView) != "rgb(0, 0, 255)")

        // The live update (`applyBoostStyle`) replaces the rules, and empty CSS takes the sheet out.
        _ = try await run(
            BrowserBoostScripts.styleSource(host: "boost.test", css: "p { color: rgb(0, 128, 0); }"),
            in: webView,
            world: BrowserBoostScripts.world
        )
        #expect(try await color(of: "p", in: webView) == "rgb(0, 128, 0)")
        _ = try await run(BrowserBoostScripts.styleSource(host: "boost.test", css: ""), in: webView, world: BrowserBoostScripts.world)
        #expect(try await color(of: "p", in: webView) == "rgb(0, 0, 0)")
        #expect(try await run("String(document.adoptedStyleSheets.length)", in: webView) == "0")
    }

    /// P7 review P2-2: the Boost sheet cascades after the page's own
    /// sheets, so it wins a tie from the first load (the old `<style>`
    /// landed before `<head>` at document start and lost).
    @Test func theBoostWinsTiesWithThePagesSheets() async throws {
        let webView = try await boostPage(
            BrowserBoost(host: "boost.test", css: "p { color: rgb(255, 0, 0); }"),
            html: "<style>p { color: rgb(0, 0, 255); }</style><p id=p>text</p>"
        )
        #expect(try await color(of: "p", in: webView) == "rgb(255, 0, 0)")
    }

    /// P7 review P2-1: the host guard declares nothing, so a Boost's own
    /// top-level `const h` runs.
    @Test func boostCodeMayUseAnyNames() async throws {
        let webView = try await boostPage(
            BrowserBoost(host: "boost.test", js: "const h = 1; let host = 2; document.title = 'ran ' + (h + host);"),
            html: "<p>text</p>"
        )
        #expect(try await run("document.title", in: webView) == "ran 3")
    }

    /// P7 review P3-4: a zap that isn't one valid rule drops only itself.
    @Test func aBadZapDropsOnlyItself() async throws {
        let webView = try await boostPage(
            BrowserBoost(host: "boost.test", css: "p { color: rgb(255, 0, 0); }", zaps: ["div:not(.x", "a} p {color: blue", ".ad"]),
            html: "<p id=p>text</p><div class=ad id=ad>ad</div>"
        )
        #expect(try await run("getComputedStyle(document.getElementById('ad')).display", in: webView) == "none")
        #expect(try await color(of: "p", in: webView) == "rgb(255, 0, 0)")
    }
}
