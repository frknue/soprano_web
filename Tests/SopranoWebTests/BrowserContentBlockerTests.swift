@testable import SopranoWeb
import AppKit
import Testing

/// Downloading, caching and compiling the filter lists, with a fake server
/// and a fake WebKit store.
@MainActor
struct BrowserContentBlockerTests {
    /// A filter list server: answers 304 to a matching `If-None-Match`
    /// when `etag` is set, and records every request.
    actor Server: BrowserFilterListFetching {
        struct Request: Equatable {
            var url: URL
            var etag: String?
            var lastModified: String?
        }

        var texts: [URL: String] = [:]
        var etag: String?
        var fails = false
        private(set) var requests: [Request] = []

        func set(_ text: String, for url: URL, etag: String?) {
            texts[url] = text
            self.etag = etag
        }

        func setFailing(_ fails: Bool) {
            self.fails = fails
        }

        func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> BrowserFilterListResponse {
            requests.append(Request(url: url, etag: etag, lastModified: lastModified))
            if fails { throw URLError(.notConnectedToInternet) }
            if let current = self.etag, current == etag {
                return .notModified
            }
            return .fetched(text: texts[url] ?? "", etag: self.etag, lastModified: nil)
        }
    }

    /// WebKit's store: rejects any list containing `rejected-by-webkit`.
    final class Store: BrowserRuleListCompiling {
        var stored: [String: String] = [:]
        private(set) var compiles: [String] = []

        func compile(identifier: String, encodedRules: String) async throws -> BrowserCompiledRuleList {
            compiles.append(identifier)
            if encodedRules.contains("rejected-by-webkit") {
                throw NSError(domain: "WKErrorDomain", code: 6, userInfo: [
                    NSHelpAnchorErrorKey: "Rule list compilation failed: Invalid or unsupported regular expression.",
                ])
            }
            stored[identifier] = encodedRules
            return BrowserCompiledRuleList(list: nil)
        }

        func lookUp(identifier: String) async -> BrowserCompiledRuleList? {
            stored[identifier] == nil ? nil : BrowserCompiledRuleList(list: nil)
        }

        func remove(identifier: String) async {
            stored[identifier] = nil
        }

        func storedIdentifiers() async -> [String] {
            Array(stored.keys)
        }
    }

    private let source = BrowserFilterListSource(
        id: "easylist",
        name: "EasyList",
        url: URL(string: "http://127.0.0.1:9/easylist.txt")!
    )
    private let list = """
    [Adblock Plus 2.0]
    ||ads.example^
    /ads/banner.js
    ##.ad-banner
    """

    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-blocker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func blocker(
        _ directory: URL,
        server: Server,
        store: Store,
        enabled: Bool = true,
        now: @escaping () -> Date = Date.init
    ) -> BrowserContentBlocker {
        BrowserContentBlocker(
            directory: directory,
            sources: [source],
            isEnabled: enabled,
            fetcher: server,
            compiler: store,
            now: now
        )
    }

    // MARK: - Downloads and caching

    @Test func firstUpdateDownloadsCachesAndCompiles() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server()
        await server.set(list, for: source.url, etag: "\"v1\"")
        let store = Store()
        let blocker = blocker(directory, server: server, store: store)
        #expect(blocker.isStale(at: Date()))

        await blocker.updateIfStale()
        let entry = try #require(blocker.state.sources["easylist"])
        #expect(entry.etag == "\"v1\"")
        #expect(entry.ruleCount == 4) // 2 blocks + the page rule, 1 hiding rule
        #expect(entry.filterCount == 3)
        // A network list and an element-hiding list.
        #expect(entry.lists.count == 2)
        #expect(blocker.activeIdentifiers == entry.lists)
        #expect(Set(store.stored.keys) == Set(entry.lists))
        #expect(try String(contentsOf: blocker.textURL(for: source), encoding: .utf8) == list)
        #expect(!blocker.isStale(at: Date()))
        #expect(blocker.statusText.hasPrefix("4 rules\nUpdated "))
    }

    @Test func anUnchangedListIsCheckedWithItsETagAndNotRecompiled() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server()
        await server.set(list, for: source.url, etag: "\"v1\"")
        let store = Store()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let blocker = blocker(directory, server: server, store: store) { clock }
        await blocker.update()
        let compiled = store.compiles.count
        let lists = blocker.activeIdentifiers

        clock += 8 * 86_400
        #expect(blocker.isStale(at: clock))
        await blocker.updateIfStale()
        let requests = await server.requests
        #expect(requests.map(\.etag) == [nil, "\"v1\""])
        #expect(store.compiles.count == compiled)
        #expect(blocker.activeIdentifiers == lists)
        #expect(blocker.state.sources["easylist"]?.checkedAt == clock)
        #expect(!blocker.isStale(at: clock))
    }

    @Test func aServerWithoutValidatorsSendingTheSameTextCausesNoRecompile() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server()
        await server.set(list, for: source.url, etag: nil)
        let store = Store()
        let blocker = blocker(directory, server: server, store: store)
        await blocker.update()
        let compiled = store.compiles.count
        await blocker.update()
        #expect(await server.requests.count == 2)
        #expect(store.compiles.count == compiled)
    }

    @Test func aChangedListCompilesUnderNewNamesAndTheOldListsGo() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server()
        await server.set(list, for: source.url, etag: "\"v1\"")
        let store = Store()
        let blocker = blocker(directory, server: server, store: store)
        await blocker.update()
        let old = blocker.activeIdentifiers

        await server.set(list + "\n||tracker.example^", for: source.url, etag: "\"v2\"")
        await blocker.update()
        let new = blocker.activeIdentifiers
        #expect(new.count == 2)
        #expect(Set(new).isDisjoint(with: old))
        #expect(Set(store.stored.keys) == Set(new))
        #expect(blocker.state.sources["easylist"]?.etag == "\"v2\"")
        #expect(blocker.ruleCount == 5)
    }

    @Test func aFailedDownloadKeepsTheLastLists() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server()
        await server.set(list, for: source.url, etag: "\"v1\"")
        let store = Store()
        let blocker = blocker(directory, server: server, store: store)
        await blocker.update()
        let lists = blocker.activeIdentifiers

        await server.setFailing(true)
        await blocker.update()
        #expect(blocker.activeIdentifiers == lists)
        #expect(blocker.state.sources["easylist"]?.lastError != nil)
        #expect(blocker.statusText.hasSuffix("last check failed"))
    }

    @Test func turningBlockingOnDownloadsListsNeverDownloaded() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server()
        await server.set(list, for: source.url, etag: "\"v1\"")
        let store = Store()
        let blocker = blocker(directory, server: server, store: store, enabled: false)
        await blocker.updateIfStale()
        #expect(await server.requests.isEmpty)
        #expect(blocker.statusText == "Lists download when this is on")

        blocker.setEnabled(true)
        for _ in 0..<200 where blocker.activeIdentifiers.isEmpty || blocker.isUpdating {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await server.requests.count == 1)
        #expect(blocker.activeIdentifiers.count == 2)
    }

    // MARK: - Launch

    @Test func launchLooksUpTheCompiledListsWithoutTheNetwork() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server()
        await server.set(list, for: source.url, etag: "\"v1\"")
        let store = Store()
        await blocker(directory, server: server, store: store).update()
        let compiled = store.compiles.count
        store.stored["easylist-v0-stale-1"] = "[]"

        let relaunched = blocker(directory, server: server, store: store)
        relaunched.start()
        await relaunched.waitUntilIdle()
        relaunched.stop()
        #expect(await server.requests.count == 1)
        #expect(store.compiles.count == compiled)
        #expect(relaunched.activeIdentifiers.count == 2)
        // Lists nothing uses (an interrupted update's) are removed.
        #expect(store.stored["easylist-v0-stale-1"] == nil)
    }

    @Test func listsTheStoreLostAreRebuiltFromTheCachedText() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server()
        await server.set(list, for: source.url, etag: "\"v1\"")
        let store = Store()
        await blocker(directory, server: server, store: store).update()
        let identifiers = Set(store.stored.keys)
        store.stored.removeAll()

        let relaunched = blocker(directory, server: server, store: store)
        relaunched.start()
        await relaunched.waitUntilIdle()
        relaunched.stop()
        #expect(await server.requests.count == 1)
        #expect(Set(store.stored.keys) == identifiers)
        #expect(Set(relaunched.activeIdentifiers) == identifiers)
    }

    /// A converter fix (`BrowserFilterConverter.version` bumped) reaches
    /// lists compiled before it at the next launch, from the cached text,
    /// whether or not the list changed since.
    @Test func listsAnOlderConverterBuiltAreRebuiltAtLaunchFromTheCachedText() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server()
        await server.set(list, for: source.url, etag: "\"v1\"")
        let store = Store()
        await blocker(directory, server: server, store: store).update()
        let stateURL = directory.appendingPathComponent(BrowserContentBlocker.stateFileName)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        var sources = try #require(object["sources"] as? [String: Any])
        var entry = try #require(sources["easylist"] as? [String: Any])
        entry["converterVersion"] = BrowserFilterConverter.version - 1
        sources["easylist"] = entry
        object["sources"] = sources
        try JSONSerialization.data(withJSONObject: object).write(to: stateURL)
        let compiled = store.compiles.count

        let relaunched = blocker(directory, server: server, store: store)
        relaunched.start()
        await relaunched.waitUntilIdle()
        relaunched.stop()
        #expect(await server.requests.count == 1)
        #expect(store.compiles.count == compiled + 2)
        #expect(relaunched.state.sources["easylist"]?.converterVersion == BrowserFilterConverter.version)
        #expect(relaunched.activeIdentifiers.allSatisfy { $0.contains("-v\(BrowserFilterConverter.version)-") })
    }

    @Test func aDamagedStateFileStartsOver() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        {"version": 1, "sources": {"easylist": {"url": "http://127.0.0.1:9/easylist.txt", "lists": ["a"], "ruleCount": 3},
         "broken": {"lists": 7}}}
        """.utf8).write(to: directory.appendingPathComponent(BrowserContentBlocker.stateFileName))
        let blocker = blocker(directory, server: Server(), store: Store())
        #expect(blocker.state.sources.keys.sorted() == ["easylist"])
        #expect(blocker.state.sources["easylist"]?.ruleCount == 3)
    }

    // MARK: - Bisection

    @Test func aRejectedRuleIsFoundByBisectionAndDroppedAlone() async {
        let store = Store()
        var rules = (1...16).map { BrowserContentRule(urlFilter: "/ad\($0)", action: .block) }
        rules[5] = BrowserContentRule(urlFilter: "rejected-by-webkit-1", action: .block)
        rules[12] = BrowserContentRule(urlFilter: "rejected-by-webkit-2", action: .block)
        var knownBad: Set<BrowserContentRule> = []

        let outcome = await BrowserContentBlocker.compileBisecting(
            rules,
            identifier: "list-1",
            knownBad: &knownBad,
            compiler: store
        )
        #expect(outcome.compiled)
        #expect(outcome.dropped == 2)
        #expect(knownBad == [rules[5], rules[12]])
        let compiledJSON = store.stored["list-1"]
        #expect(compiledJSON?.contains("/ad16") == true)
        #expect(compiledJSON?.contains("rejected") == false)
        // Probes are removed; far fewer compiles than one per rule.
        #expect(store.stored.keys.sorted() == ["list-1"])
        #expect(store.compiles.count < 16)

        // A later list skips known rejected rules without probing.
        let before = store.compiles.count
        let next = await BrowserContentBlocker.compileBisecting(
            [rules[0], rules[5]],
            identifier: "list-2",
            knownBad: &knownBad,
            compiler: store
        )
        #expect(next.compiled && next.dropped == 1)
        #expect(store.compiles.count == before + 1)
    }

    @Test func aRejectedFilterIsDroppedAndCounted() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server()
        await server.set(list, for: source.url, etag: "\"v1\"")
        let store = Store()
        let blocker = blocker(directory, server: server, store: store)
        await blocker.update()
        let lists = blocker.activeIdentifiers

        // One rejected filter is dropped and counted; the rest compiles.
        await server.set(list + "\n/rejected-by-webkit/", for: source.url, etag: "\"v2\"")
        await blocker.update()
        #expect(blocker.state.sources["easylist"]?.skipped["compileError"] == 1)
        #expect(blocker.ruleCount == 4)
        #expect(Set(blocker.activeIdentifiers).isDisjoint(with: lists))
    }
}
