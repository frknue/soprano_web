import CryptoKit
import Foundation

// MARK: - Source

/// What a live folder shows: the open pull requests of one GitHub
/// repository (`gh pr list`), or a GitHub pull request search (`gh search
/// prs`). Saved as the folder's `source` key, so older builds read the
/// folder as a plain (empty) one.
enum BrowserLiveFolderSource: Equatable, Hashable, Sendable {
    case githubPullRequests(repo: String)
    case githubSearch(query: String)

    /// How many pull requests a folder shows at most.
    static let limit = 50

    /// The editor's field: `owner/repo`, a github.com repository link, or
    /// anything else as a search (`review-requested:@me is:open`). Nil when
    /// empty.
    static func parse(_ text: String) -> BrowserLiveFolderSource? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let repo = repository(in: trimmed) {
            return .githubPullRequests(repo: repo)
        }
        return .githubSearch(query: trimmed)
    }

    /// `owner/repo` from `owner/repo` or a `github.com/owner/repo[/…]` link
    /// (with or without a scheme); nil for anything else.
    static func repository(in text: String) -> String? {
        var rest = text
        for prefix in ["https://", "http://"] where rest.lowercased().hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
        }
        var parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let host = parts.first?.lowercased(), host == "github.com" || host == "www.github.com" {
            parts.removeFirst()
            guard parts.count >= 2 else { return nil }
            parts = Array(parts.prefix(2))
        } else if parts.count != 2 {
            return nil
        }
        var name = parts[1]
        if name.hasSuffix(".git") { name.removeLast(4) }
        let owner = parts[0]
        guard isValidName(owner, allowsDot: false), isValidName(name, allowsDot: true) else { return nil }
        return "\(owner)/\(name)"
    }

    private static func isValidName(_ name: String, allowsDot: Bool) -> Bool {
        guard !name.isEmpty, name.count <= 100, name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                || (allowsDot && scalar == "."))
        }
    }

    /// What the editor's field shows for it.
    var text: String {
        switch self {
        case let .githubPullRequests(repo): repo
        case let .githubSearch(query): query
        }
    }

    /// A new folder's name when the editor's name is empty.
    var defaultName: String {
        switch self {
        case let .githubPullRequests(repo): repo
        case .githubSearch: "Pull Requests"
        }
    }

    /// One line for the folder's tooltip and the CLI.
    var summary: String {
        switch self {
        case let .githubPullRequests(repo): "Open pull requests in \(repo)"
        case let .githubSearch(query): "GitHub search: \(query)"
        }
    }

    /// `gh`'s arguments. A search query is split into words (quotes keep a
    /// phrase together): `gh` quotes an argument with spaces as one
    /// keyword, which breaks qualifiers such as `is:open`.
    var ghArguments: [String] {
        switch self {
        case let .githubPullRequests(repo):
            [
                "pr", "list", "--repo", repo, "--state", "open", "--limit", "\(Self.limit)",
                "--json", "number,title,url,author,isDraft,updatedAt",
            ]
        case let .githubSearch(query):
            ["search", "prs"] + Self.words(query) + [
                "--limit", "\(Self.limit)",
                "--json", "number,title,url,author,isDraft,updatedAt,repository",
            ]
        }
    }

    /// Splits on white space; a double-quoted part stays one word (without
    /// its quotes). A word starting with "-" gets "--" before the words so
    /// `gh` never reads it as an option.
    static func words(_ query: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inQuotes = false
        var hasWord = false
        for character in query {
            if character == "\"" {
                inQuotes.toggle()
                hasWord = true
            } else if character.isWhitespace, !inQuotes {
                if hasWord { words.append(current) }
                current = ""
                hasWord = false
            } else {
                current.append(character)
                hasWord = true
            }
        }
        if hasWord { words.append(current) }
        return words.contains { $0.hasPrefix("-") } ? ["--"] + words : words
    }
}

extension BrowserLiveFolderSource: Codable {
    private enum Keys: String, CodingKey {
        case kind, repo, query
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "githubPullRequests":
            let repo = try c.decode(String.self, forKey: .repo)
            guard let valid = Self.repository(in: repo) else {
                throw DecodingError.dataCorruptedError(forKey: .repo, in: c, debugDescription: "Not owner/repo")
            }
            self = .githubPullRequests(repo: valid)
        case "githubSearch":
            let query = try c.decode(String.self, forKey: .query).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .query, in: c, debugDescription: "Empty query")
            }
            self = .githubSearch(query: query)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown live folder kind")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .githubPullRequests(repo):
            try c.encode("githubPullRequests", forKey: .kind)
            try c.encode(repo, forKey: .repo)
        case let .githubSearch(query):
            try c.encode("githubSearch", forKey: .kind)
            try c.encode(query, forKey: .query)
        }
    }
}

// MARK: - Pull requests

/// One pull request a live folder shows; never saved.
struct BrowserPullRequest: Equatable, Sendable {
    var number: Int
    var title: String
    var url: String
    /// `owner/repo`.
    var repository: String
    var author: String
    var isDraft: Bool
    var updatedAt: Date

    /// `gh`'s JSON array (`pr list` or `search prs`). `pr list` has no
    /// repository field: it is the source's. Items without a number, title
    /// or https URL are skipped.
    static func decode(_ data: Data, source: BrowserLiveFolderSource) throws -> [BrowserPullRequest] {
        struct Author: Decodable { var login: String? }
        struct Repository: Decodable { var nameWithOwner: String? }
        struct Raw: Decodable {
            var number: Int?
            var title: String?
            var url: String?
            var author: Author?
            var isDraft: Bool?
            var updatedAt: String?
            var repository: Repository?
        }
        let raws = try JSONDecoder().decode([LossyItem<Raw>].self, from: data).compactMap(\.value)
        let dates = ISO8601DateFormatter()
        let sourceRepo: String? = if case let .githubPullRequests(repo) = source { repo } else { nil }
        return raws.compactMap { raw in
            guard let number = raw.number, let title = raw.title, let url = raw.url,
                  url.lowercased().hasPrefix("https://")
            else { return nil }
            return BrowserPullRequest(
                number: number,
                title: title,
                url: url,
                repository: raw.repository?.nameWithOwner ?? sourceRepo ?? "",
                author: raw.author?.login ?? "",
                isDraft: raw.isDraft ?? false,
                updatedAt: raw.updatedAt.flatMap(dates.date(from:)) ?? BrowserPinTree.unknownDate
            )
        }
    }

    /// The tooltip line under the title: "owner/repo #12 · author · Draft".
    var detail: String {
        var parts = ["\(repository) #\(number)"]
        if !author.isEmpty { parts.append(author) }
        if isDraft { parts.append("Draft") }
        return parts.joined(separator: " · ")
    }
}

/// An array element that decodes or is skipped.
private struct LossyItem<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Why a live folder has nothing new to show.
enum BrowserLiveFolderError: Error, Equatable, Sendable {
    case ghMissing
    case signedOut
    case timedOut
    case failed(String)

    var message: String {
        switch self {
        case .ghMissing: "GitHub CLI not found. Install it with “brew install gh”."
        case .signedOut: "Not signed in to GitHub CLI. Run “gh auth login” in Terminal."
        case .timedOut: "GitHub didn't answer in time."
        case let .failed(reason): reason
        }
    }

    /// What `gh`'s exit and stderr mean.
    static func from(exitCode: Int32, stderr: String) -> BrowserLiveFolderError {
        if stderr.contains("gh auth login") || stderr.contains("GH_TOKEN") {
            return .signedOut
        }
        let line = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return .failed(line.map { String($0.prefix(300)) } ?? "gh exited with status \(exitCode).")
    }
}

// MARK: - State

/// What the app knows about one live folder right now.
struct BrowserLiveFolderState: Equatable, Sendable {
    var source: BrowserLiveFolderSource
    var items: [BrowserPullRequest] = []
    /// When the last fetch succeeded.
    var fetchedAt: Date?
    var isLoading = false
    /// The last fetch's failure; earlier items stay shown.
    var error: BrowserLiveFolderError?

    /// The folder row's status line (tooltip), nil when there is nothing to
    /// say beyond the count.
    var status: String? {
        if let error { return error.message }
        if fetchedAt == nil { return isLoading ? "Loading…" : nil }
        return items.isEmpty ? "No pull requests" : nil
    }
}

/// The id of a pull request's row in folder `folderID`: the same for the
/// same address on every fetch, so the outline keeps its place, and never
/// a saved node's (it is derived, not random).
func browserLiveItemID(folderID: UUID, url: String) -> UUID {
    var bytes = Array(SHA256.hash(data: Data("soprano-web.live-folder|\(folderID.uuidString)|\(url)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

// MARK: - gh

/// Runs the GitHub CLI. A GUI app gets launchd's short `PATH`, so `gh` is
/// looked up in the Homebrew and user tool folders first (Soprano Git's
/// `GitRunner` does the same for git).
enum BrowserGitHubCLI {
    static let timeout: TimeInterval = 30

    static func toolDirectories(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin"]
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in toolDirectories(home: home) + inherited where !directory.isEmpty {
            let path = (directory as NSString).appendingPathComponent("gh")
            if isExecutable(path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static func environment(
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String: String] {
        var environment = inherited
        var seen = Set<String>()
        let path = (toolDirectories(home: home) + (inherited["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        environment["PATH"] = path.joined(separator: ":")
        // Plain JSON, no prompts, no pager, no update notice.
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["NO_COLOR"] = "1"
        environment["GH_PAGER"] = "cat"
        return environment
    }

    /// The pull requests for `source`, or why there are none.
    static func fetch(_ source: BrowserLiveFolderSource) async -> Result<[BrowserPullRequest], BrowserLiveFolderError> {
        guard let gh = resolve() else { return .failure(.ghMissing) }
        let output = await run(gh, arguments: source.ghArguments, environment: environment(), timeout: timeout)
        if output.timedOut { return .failure(.timedOut) }
        guard output.exitCode == 0 else {
            return .failure(.from(exitCode: output.exitCode, stderr: String(decoding: output.stderr, as: UTF8.self)))
        }
        do {
            return .success(try BrowserPullRequest.decode(output.stdout, source: source))
        } catch {
            let stderr = String(decoding: output.stderr, as: UTF8.self)
            // `gh` without a token prints its hint and exits 0 on some versions.
            return .failure(stderr.isEmpty ? .failed("gh printed no pull requests.") : .from(exitCode: 0, stderr: stderr))
        }
    }

    struct Output: Sendable {
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32 = -1
        var timedOut = false
    }

    /// Runs `executable` off the main thread, both pipes drained while it
    /// runs; past `timeout` it is terminated (SIGKILL 2 s later).
    static func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(executable, arguments: arguments, environment: environment, timeout: timeout))
            }
        }
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var stdout = Data()
        var stderr = Data()
        var timedOut = false
    }

    private static func runBlocking(_ executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            var output = Output()
            output.stderr = Data(error.localizedDescription.utf8)
            return output
        }
        let box = Box()
        let group = DispatchGroup()
        for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                box.lock.lock()
                if isStdout { box.stdout = data } else { box.stderr = data }
                box.lock.unlock()
                group.leave()
            }
        }
        let pid = process.processIdentifier
        let timer = DispatchWorkItem {
            guard process.isRunning else { return }
            box.lock.lock()
            box.timedOut = true
            box.lock.unlock()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        process.waitUntilExit()
        timer.cancel()
        // A child still holding the pipes open must not hold the folder.
        _ = group.wait(timeout: .now() + 2)
        box.lock.lock()
        defer { box.lock.unlock() }
        return Output(stdout: box.stdout, stderr: box.stderr, exitCode: process.terminationStatus, timedOut: box.timedOut)
    }
}

// MARK: - Runtime

/// The manager's live folders: every Space's folders with a `source`,
/// their fetched pull requests (memory only, never in `children`), the
/// 5-minute refresh and the refresh when a folder opens.
@MainActor
final class BrowserLiveFolders {
    typealias Fetch = @Sendable (BrowserLiveFolderSource) async -> Result<[BrowserPullRequest], BrowserLiveFolderError>

    static let refreshInterval: TimeInterval = 5 * 60
    /// Opening a folder refetches when its last fetch is older than this.
    static let openRefreshAge: TimeInterval = 30

    /// A folder's items, state or source changed.
    let changes = BrowserObservers<Void>()
    private(set) var states: [UUID: BrowserLiveFolderState] = [:]
    /// Item id → (folder id, pull request), for opening a row.
    private var itemIndex: [UUID: (folderID: UUID, item: BrowserPullRequest)] = [:]
    private let spaces: BrowserSpaceStore
    /// `gh` by default; the harness and tests put their own in.
    var fetch: Fetch
    private let now: () -> Date
    private var observation: BrowserObservation?
    private var timer: Timer?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(spaces: BrowserSpaceStore, fetch: @escaping Fetch = BrowserGitHubCLI.fetch, now: @escaping () -> Date = Date.init) {
        self.spaces = spaces
        self.fetch = fetch
        self.now = now
        reconcile(fetchingNew: false)
        observation = spaces.changes.observe { [weak self] in self?.reconcile(fetchingNew: true) }
    }

    /// Fetches every folder now and every 5 minutes.
    func start() {
        guard timer == nil else { return }
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }

    func state(of folderID: UUID) -> BrowserLiveFolderState? {
        states[folderID]
    }

    /// The pull request behind row `id`.
    func item(id: UUID) -> (folderID: UUID, item: BrowserPullRequest)? {
        itemIndex[id]
    }

    func isItem(_ id: UUID) -> Bool {
        itemIndex[id] != nil
    }

    func refreshAll() {
        for id in states.keys { refresh(id) }
    }

    /// Opening folder `id` (the outline's chevron, its preview): refetch
    /// unless a fetch is running or the last one is recent.
    func folderOpened(_ id: UUID) {
        guard let state = states[id] else { return }
        if let fetchedAt = state.fetchedAt, now().timeIntervalSince(fetchedAt) < Self.openRefreshAge, state.error == nil {
            return
        }
        refresh(id)
    }

    /// Fetches folder `id` unless a fetch for it is running.
    func refresh(_ id: UUID) {
        guard var state = states[id], tasks[id] == nil else { return }
        let source = state.source
        state.isLoading = true
        states[id] = state
        changes.notify()
        let fetch = self.fetch
        tasks[id] = Task { [weak self] in
            let result = await fetch(source)
            guard !Task.isCancelled else { return }
            self?.finish(id, source: source, result: result)
        }
    }

    /// Waits for every running fetch (the harness and tests).
    func waitForFetches() async {
        while let task = tasks.values.first {
            await task.value
        }
    }

    private func finish(_ id: UUID, source: BrowserLiveFolderSource, result: Result<[BrowserPullRequest], BrowserLiveFolderError>) {
        tasks[id] = nil
        // The folder was deleted or now shows something else.
        guard var state = states[id], state.source == source else {
            if states[id] != nil { refresh(id) }
            return
        }
        state.isLoading = false
        switch result {
        case let .success(items):
            state.items = items
            state.fetchedAt = now()
            state.error = nil
        case let .failure(error):
            state.error = error
        }
        states[id] = state
        rebuildIndex()
        changes.notify()
    }

    /// Follows the Spaces' trees: new folders get a state (and a fetch once
    /// started), changed sources start over, deleted folders go.
    private func reconcile(fetchingNew: Bool) {
        var sources: [UUID: BrowserLiveFolderSource] = [:]
        for space in spaces.spaces {
            for (id, source) in space.pinned.liveFolders() {
                sources[id] = source
            }
        }
        var changed = false
        var toFetch: [UUID] = []
        for (id, source) in sources where states[id]?.source != source {
            states[id] = BrowserLiveFolderState(source: source)
            toFetch.append(id)
            changed = true
        }
        for id in states.keys where sources[id] == nil {
            states[id] = nil
            tasks[id]?.cancel()
            tasks[id] = nil
            changed = true
        }
        guard changed else { return }
        rebuildIndex()
        changes.notify()
        if fetchingNew, timer != nil {
            toFetch.forEach(refresh)
        }
    }

    private func rebuildIndex() {
        itemIndex = [:]
        for (folderID, state) in states {
            for item in state.items {
                itemIndex[browserLiveItemID(folderID: folderID, url: item.url)] = (folderID, item)
            }
        }
    }

    /// `tree` as the rail, menus and start page show it: each live folder
    /// holds its pull requests (as pins with derived ids) before anything
    /// saved in it.
    func display(_ tree: BrowserPinTree) -> BrowserPinTree {
        guard !states.isEmpty else { return tree }
        return tree.fillingLiveFolders { folderID in
            guard let state = states[folderID] else { return [] }
            return state.items.map { item in
                BrowserPin(
                    id: browserLiveItemID(folderID: folderID, url: item.url),
                    url: item.url,
                    title: item.title,
                    addedAt: item.updatedAt
                )
            }
        }
    }

    /// Test seam: states as a fetch left them.
    func setState(_ state: BrowserLiveFolderState, for id: UUID) {
        states[id] = state
        rebuildIndex()
        changes.notify()
    }
}
