import Foundation
import WebKit

/// A list in the store: WebKit's, or none from a test double.
struct BrowserCompiledRuleList {
    var list: WKContentRuleList?
}

/// Compiles and stores content rule lists. WebKit's store compiles on its
/// own background queue.
@MainActor
protocol BrowserRuleListCompiling: AnyObject {
    func compile(identifier: String, encodedRules: String) async throws -> BrowserCompiledRuleList
    /// Nil when the store doesn't have it (or can't read it any more).
    func lookUp(identifier: String) async -> BrowserCompiledRuleList?
    func remove(identifier: String) async
    func storedIdentifiers() async -> [String]
}

/// `WKContentRuleListStore(url:)` in `<support>/ContentBlocking/`.
@MainActor
final class BrowserWebKitRuleListStore: BrowserRuleListCompiling {
    private let store: WKContentRuleListStore?

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: directory)
    }

    func compile(identifier: String, encodedRules: String) async throws -> BrowserCompiledRuleList {
        guard let store else { throw CocoaError(.fileNoSuchFile) }
        let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encodedRules)
        return BrowserCompiledRuleList(list: list)
    }

    func lookUp(identifier: String) async -> BrowserCompiledRuleList? {
        guard let store, let list = try? await store.contentRuleList(forIdentifier: identifier) else { return nil }
        return BrowserCompiledRuleList(list: list)
    }

    func remove(identifier: String) async {
        try? await store?.removeContentRuleList(forIdentifier: identifier)
    }

    func storedIdentifiers() async -> [String] {
        await store?.availableIdentifiers() ?? []
    }
}

/// Settings ▸ "Block ads and trackers": downloads EasyList and EasyPrivacy,
/// converts them (`BrowserFilterConverter`) and compiles content rule lists
/// that every tab of every window gets (`activeLists`).
///
/// - Launch looks up the lists compiled last time and never waits for the
///   network or a compile; a list the store lost (or one an older
///   converter built) is rebuilt from the cached text.
/// - While blocking is on, a list is downloaded at first enable and when
///   its last check is older than `maxAge` (checked at launch and daily),
///   conditionally (`ETag`, `Last-Modified`); the text is cached in the
///   folder and recompiled only when it changed.
/// - New lists compile under new identifiers; the old ones stay active
///   until they are ready, then go away. A list WebKit rejects is
///   bisected, so one bad rule drops only itself.
@MainActor
final class BrowserContentBlocker {
    /// Lists older than this are downloaded again.
    static let maxAge: TimeInterval = 7 * 86_400
    static let checkInterval: TimeInterval = 86_400
    static let stateFileName = "content-blocking.json"

    let directory: URL
    let sources: [BrowserFilterListSource]
    private let fetcher: BrowserFilterListFetching
    private let compiler: BrowserRuleListCompiling
    var now: () -> Date
    /// Lists compiled per run; tests use small lists.
    var maxRulesPerList = BrowserFilterConverter.maxRulesPerList

    private(set) var state: BrowserContentBlockingState
    private(set) var isEnabled: Bool
    /// Lists in the store, by identifier (looked up or compiled this run).
    private var compiled: [String: BrowserCompiledRuleList] = [:]
    private var currentUpdate: Task<Void, Never>?
    /// The launch lookups (and rebuilds from cached text).
    private var launch: Task<Void, Never>?
    private var checkTimer: Timer?
    /// Enabled, lists or status changed.
    let changes = BrowserObservers<Void>()

    init(
        directory: URL,
        sources: [BrowserFilterListSource],
        isEnabled: Bool,
        fetcher: BrowserFilterListFetching = BrowserFilterListFetcher(),
        compiler: BrowserRuleListCompiling? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.sources = sources
        self.isEnabled = isEnabled
        self.fetcher = fetcher
        self.compiler = compiler ?? BrowserWebKitRuleListStore(directory: directory)
        self.now = now
        self.state = JSONFile.read(BrowserContentBlockingState.self, at: directory.appendingPathComponent(Self.stateFileName))
            ?? BrowserContentBlockingState()
    }

    /// A download or compile is running (Settings shows it).
    var isUpdating: Bool {
        currentUpdate != nil
    }

    /// Settings' status: the rule count and when the lists were last
    /// checked (two lines), or what is happening.
    var statusText: String {
        if isUpdating { return "Updating lists…" }
        let errors = sources.compactMap { state.sources[$0.id]?.lastError }
        guard let checked = lastChecked, ruleCount > 0 else {
            if let error = errors.first { return "Download failed: \(error)" }
            return isEnabled ? "Lists not downloaded yet" : "Lists download when this is on"
        }
        let date = checked.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        let text = "\(ruleCount.formatted()) rules\nUpdated \(date)"
        return errors.isEmpty ? text : text + " · last check failed"
    }

    /// The compiled lists, in source order, while blocking is on.
    var activeLists: [WKContentRuleList] {
        guard isEnabled else { return [] }
        return activeIdentifiers.compactMap { compiled[$0]?.list }
    }

    /// Every source's compiled list identifiers, in order.
    var activeIdentifiers: [String] {
        sources.flatMap { state.sources[$0.id]?.lists ?? [] }
    }

    /// Rules in the active lists.
    var ruleCount: Int {
        sources.reduce(0) { $0 + (state.sources[$1.id]?.ruleCount ?? 0) }
    }

    /// The most recent download check of any list.
    var lastChecked: Date? {
        sources.compactMap { state.sources[$0.id]?.checkedAt }.max()
    }

    // MARK: - Launch and schedule

    /// Looks up the compiled lists, rebuilds missing ones from the cached
    /// text and, while blocking is on, downloads stale lists, all without
    /// blocking launch; then checks once a day.
    func start() {
        launch = Task { [weak self] in
            await self?.loadCompiledLists()
            self?.launch = nil
            await self?.updateIfStale()
        }
        checkTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.updateIfStale() }
            }
        }
    }

    func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    /// Settings ▸ Block ads and trackers. Turning it on downloads lists
    /// that were never downloaded (or are stale).
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        changes.notify()
        if enabled {
            Task { await updateIfStale() }
        }
    }

    /// Whether any list was never checked or was last checked more than
    /// `maxAge` ago.
    func isStale(at date: Date) -> Bool {
        sources.contains { source in
            guard let entry = state.sources[source.id], entry.url == source.url.absoluteString,
                  let checked = entry.checkedAt
            else { return true }
            return date.timeIntervalSince(checked) >= Self.maxAge
        }
    }

    func updateIfStale() async {
        guard isEnabled, isStale(at: now()) else { return }
        await update()
    }

    /// Settings ▸ Update Now (and the scheduled check): every list is
    /// checked with its validators; changed text is recompiled. A running
    /// update is awaited instead of starting a second one.
    func update() async {
        if let launch {
            await launch.value
        }
        if let currentUpdate {
            await currentUpdate.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            for source in self.sources {
                await self.update(source)
            }
        }
        currentUpdate = task
        changes.notify()
        await task.value
        finishUpdate()
    }

    /// Waits for the launch lookups and a running update (the harness).
    func waitUntilIdle() async {
        if let launch {
            await launch.value
        }
        if let currentUpdate {
            await currentUpdate.value
        }
    }

    private func finishUpdate() {
        currentUpdate = nil
        changes.notify()
    }

    // MARK: - Updating one list

    private func update(_ source: BrowserFilterListSource) async {
        var entry = state.sources[source.id] ?? .init(url: source.url.absoluteString)
        if entry.url != source.url.absoluteString {
            entry = .init(url: source.url.absoluteString)
            entry.lists = state.sources[source.id]?.lists ?? []
        }
        let response: BrowserFilterListResponse
        do {
            response = try await fetcher.fetch(source.url, etag: entry.etag, lastModified: entry.lastModified)
        } catch {
            entry.lastError = error.localizedDescription
            save(entry, for: source)
            return
        }
        entry.checkedAt = now()
        entry.lastError = nil
        guard case let .fetched(text, etag, lastModified) = response else {
            save(entry, for: source)
            if needsRebuild(entry), let text = cachedText(for: source) {
                await rebuild(source, text: text)
            }
            return
        }
        entry.etag = etag
        entry.lastModified = lastModified
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: textURL(for: source), options: .atomic)
        let hash = BrowserContentBlockingState.hash(text)
        let unchanged = hash == entry.textHash && !needsRebuild(entry)
        save(entry, for: source)
        if !unchanged {
            await rebuild(source, text: text, hash: hash)
        }
    }

    /// Whether `entry`'s lists are missing from the store or were built by
    /// another converter version.
    private func needsRebuild(_ entry: BrowserContentBlockingState.Source) -> Bool {
        entry.converterVersion != BrowserFilterConverter.version
            || entry.textHash == nil
            || entry.lists.contains { compiled[$0] == nil }
    }

    /// Converts `text` off the main thread and compiles its lists under new
    /// identifiers. The source's previous lists stay active until every new
    /// one compiled, then are removed.
    private func rebuild(_ source: BrowserFilterListSource, text: String, hash: String? = nil) async {
        let hash = hash ?? BrowserContentBlockingState.hash(text)
        let started = Date()
        let capacity = maxRulesPerList
        let conversion = await Task.detached(priority: .utility) {
            BrowserFilterConverter.convert(text, maxRulesPerList: capacity)
        }.value

        var identifiers: [String] = []
        var lists: [String: BrowserCompiledRuleList] = [:]
        var skipped = conversion.skipped
        var ruleCount = 0
        var knownBad: Set<BrowserContentRule> = []
        var failure: String?
        for (index, rules) in conversion.lists.enumerated() {
            let identifier = "\(source.id)-v\(BrowserFilterConverter.version)-\(hash.prefix(12))-\(index + 1)"
            let outcome = await Self.compileBisecting(
                rules,
                identifier: identifier,
                knownBad: &knownBad,
                compiler: compiler
            )
            if outcome.compiled {
                identifiers.append(identifier)
                lists[identifier] = outcome.list
                ruleCount += rules.count - outcome.dropped
            } else {
                failure = outcome.error
            }
            if outcome.dropped > 0 {
                skipped[.compileError, default: 0] += outcome.dropped
            }
        }

        var entry = state.sources[source.id] ?? .init(url: source.url.absoluteString)
        guard failure == nil || !identifiers.isEmpty || conversion.lists.isEmpty else {
            // Nothing compiled: the previous lists stay.
            entry.lastError = failure
            save(entry, for: source)
            return
        }
        let previous = entry.lists
        compiled.merge(lists) { _, new in new }
        entry.lists = identifiers
        entry.textHash = hash
        entry.converterVersion = BrowserFilterConverter.version
        entry.ruleCount = ruleCount
        entry.filterCount = conversion.filterCount
        entry.skipped = Dictionary(uniqueKeysWithValues: skipped.map { ($0.key.rawValue, $0.value) })
        entry.compileSeconds = Date().timeIntervalSince(started)
        entry.updatedAt = now()
        entry.lastError = failure
        save(entry, for: source)
        changes.notify()
        for identifier in previous where !identifiers.contains(identifier) {
            compiled[identifier] = nil
            await compiler.remove(identifier: identifier)
        }
    }

    /// Launch: the lists compiled last time, a rebuild from the cached text
    /// for any the store no longer has, and removal of lists nothing uses
    /// (an interrupted update's, bisection probes).
    private func loadCompiledLists() async {
        var missing: [BrowserFilterListSource] = []
        for source in sources {
            guard let entry = state.sources[source.id] else { continue }
            for identifier in entry.lists where compiled[identifier] == nil {
                guard let list = await compiler.lookUp(identifier: identifier) else {
                    missing.append(source)
                    break
                }
                compiled[identifier] = list
            }
            if entry.converterVersion != BrowserFilterConverter.version, !missing.contains(source) {
                missing.append(source)
            }
        }
        changes.notify()
        for source in missing {
            if let text = cachedText(for: source) {
                await rebuild(source, text: text)
            }
        }
        let used = Set(state.sources.values.flatMap(\.lists))
        for identifier in await compiler.storedIdentifiers() where !used.contains(identifier) {
            await compiler.remove(identifier: identifier)
        }
    }

    // MARK: - Files

    private var stateURL: URL {
        directory.appendingPathComponent(Self.stateFileName)
    }

    func textURL(for source: BrowserFilterListSource) -> URL {
        directory.appendingPathComponent("\(source.id).txt")
    }

    private func cachedText(for source: BrowserFilterListSource) -> String? {
        (try? Data(contentsOf: textURL(for: source))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func save(_ entry: BrowserContentBlockingState.Source, for source: BrowserFilterListSource) {
        state.sources[source.id] = entry
        try? JSONFile.write(state, to: stateURL)
    }

    // MARK: - Bisection

    struct CompileOutcome {
        var compiled: Bool
        var list: BrowserCompiledRuleList?
        /// Rules left out because WebKit rejected them.
        var dropped: Int
        var error: String?
    }

    /// Compiles `rules` as `identifier`. When WebKit rejects the list, its
    /// halves are compiled as probes until each rejected rule is alone;
    /// those rules are left out (and remembered in `knownBad`, so later
    /// lists skip them without probing) and the rest compiles.
    static func compileBisecting(
        _ rules: [BrowserContentRule],
        identifier: String,
        knownBad: inout Set<BrowserContentRule>,
        compiler: BrowserRuleListCompiling
    ) async -> CompileOutcome {
        let known = knownBad
        let candidates = known.isEmpty ? rules : rules.filter { !known.contains($0) }
        var dropped = rules.count - candidates.count
        do {
            let list = try await compiler.compile(identifier: identifier, encodedRules: await encode(candidates))
            return CompileOutcome(compiled: true, list: list, dropped: dropped)
        } catch {
            let probe = identifier + "-probe"
            let bad = await rejectedRules(candidates[...], probe: probe, knownToFail: true, compiler: compiler)
            await compiler.remove(identifier: probe)
            knownBad.formUnion(bad)
            let rejected = Set(bad)
            let remaining = candidates.filter { !rejected.contains($0) }
            dropped += candidates.count - remaining.count
            guard !bad.isEmpty, !remaining.isEmpty else {
                return CompileOutcome(compiled: false, dropped: dropped, error: Self.message(error))
            }
            do {
                let list = try await compiler.compile(identifier: identifier, encodedRules: await encode(remaining))
                return CompileOutcome(compiled: true, list: list, dropped: dropped)
            } catch {
                return CompileOutcome(compiled: false, dropped: dropped, error: Self.message(error))
            }
        }
    }

    /// The rules WebKit rejects among `rules`. A half that compiles leaves
    /// the other half of a rejected list known to fail, so it isn't probed
    /// as a whole.
    private static func rejectedRules(
        _ rules: ArraySlice<BrowserContentRule>,
        probe: String,
        knownToFail: Bool,
        compiler: BrowserRuleListCompiling
    ) async -> [BrowserContentRule] {
        if !knownToFail {
            if (try? await compiler.compile(identifier: probe, encodedRules: await encode(Array(rules)))) != nil {
                return []
            }
        }
        guard rules.count > 1 else { return Array(rules) }
        let middle = rules.startIndex + rules.count / 2
        let left = await rejectedRules(rules[..<middle], probe: probe, knownToFail: false, compiler: compiler)
        let right = await rejectedRules(
            rules[middle...],
            probe: probe,
            knownToFail: left.isEmpty,
            compiler: compiler
        )
        return left + right
    }

    /// The JSON, built off the main thread.
    private static func encode(_ rules: [BrowserContentRule]) async -> String {
        await Task.detached(priority: .utility) { BrowserContentRule.json(rules) }.value
    }

    private static func message(_ error: Error) -> String {
        let nsError = error as NSError
        return (nsError.userInfo[NSHelpAnchorErrorKey] as? String) ?? nsError.localizedDescription
    }
}
