@testable import SopranoWeb
import AppKit
import Testing

/// Live folders: what the editor's field means, what `gh` is asked and
/// what its answer becomes, how a live folder is saved (and read by older
/// builds), and the runtime's fetches with a stand-in for `gh`.
@MainActor
@Suite(.serialized)
struct BrowserLiveFoldersTests {
    // MARK: - Source

    @Test func theFieldReadsARepositoryALinkOrASearch() {
        #expect(BrowserLiveFolderSource.parse("frknue/soprano_web") == .githubPullRequests(repo: "frknue/soprano_web"))
        #expect(BrowserLiveFolderSource.parse(" https://github.com/Valkental/shop-theme/pulls ")
            == .githubPullRequests(repo: "Valkental/shop-theme"))
        #expect(BrowserLiveFolderSource.parse("github.com/owner/repo.git") == .githubPullRequests(repo: "owner/repo"))
        #expect(BrowserLiveFolderSource.parse("review-requested:@me is:open")
            == .githubSearch(query: "review-requested:@me is:open"))
        // Not a repository: a path with more parts, another host, odd names.
        #expect(BrowserLiveFolderSource.parse("a/b/c") == .githubSearch(query: "a/b/c"))
        #expect(BrowserLiveFolderSource.parse("https://gitlab.com/owner/repo") == .githubSearch(query: "https://gitlab.com/owner/repo"))
        #expect(BrowserLiveFolderSource.parse("own.er/repo") == .githubSearch(query: "own.er/repo"))
        #expect(BrowserLiveFolderSource.parse("   ") == nil)
    }

    @Test func aSearchSplitsIntoWordsAndNeverPassesAnOption() throws {
        #expect(BrowserLiveFolderSource.words("is:open  author:@me") == ["is:open", "author:@me"])
        #expect(BrowserLiveFolderSource.words("label:\"needs review\" is:pr") == ["label:needs review", "is:pr"])
        #expect(BrowserLiveFolderSource.words("-label:bug is:open") == ["--", "-label:bug", "is:open"])
        // gh's own options come before the "--": everything after it is a
        // search word, so `--json` there would print no JSON.
        let search = BrowserLiveFolderSource.githubSearch(query: "-label:bug --repo=evil").ghArguments
        let separator = try #require(search.firstIndex(of: "--"))
        #expect(Array(search[separator...]) == ["--", "-label:bug", "--repo=evil"])
        #expect(search.firstIndex(of: "--json").map { $0 < separator } == true)
        #expect(search.firstIndex(of: "--limit").map { $0 < separator } == true)
        let list = BrowserLiveFolderSource.githubPullRequests(repo: "o/r").ghArguments
        #expect(Array(list.prefix(4)) == ["pr", "list", "--repo", "o/r"])
        #expect(list.contains("open"))
    }

    // MARK: - gh's answer

    @Test func ghsJSONBecomesPullRequests() throws {
        let json = """
        [
          {"number": 82, "title": "Return policy", "url": "https://github.com/o/r/pull/82",
           "author": {"login": "eric"}, "isDraft": false, "updatedAt": "2026-10-05T16:38:17Z"},
          {"number": 3, "title": "Draft", "url": "https://github.com/x/y/pull/3", "isDraft": true,
           "repository": {"name": "y", "nameWithOwner": "x/y"}},
          {"number": 4, "title": "Not a web link", "url": "javascript:alert(1)"},
          {"title": "No number", "url": "https://github.com/o/r/pull/5"},
          "garbage"
        ]
        """
        let items = try BrowserPullRequest.decode(Data(json.utf8), source: .githubPullRequests(repo: "o/r"))
        #expect(items.map(\.number) == [82, 3])
        #expect(items[0].repository == "o/r")
        #expect(items[0].author == "eric")
        #expect(items[0].updatedAt == ISO8601DateFormatter().date(from: "2026-10-05T16:38:17Z"))
        #expect(items[1].repository == "x/y")
        #expect(items[1].detail == "x/y #3 · Draft")
        #expect(throws: (any Error).self) {
            try BrowserPullRequest.decode(Data("To get started with GitHub CLI".utf8), source: .githubSearch(query: "q"))
        }
    }

    @Test func ghsFailuresSayWhatToDo() {
        #expect(BrowserLiveFolderError.from(exitCode: 4, stderr: "To get started with GitHub CLI, please run:  gh auth login") == .signedOut)
        #expect(BrowserLiveFolderError.from(exitCode: 1, stderr: "\nGraphQL: Could not resolve to a Repository\nmore")
            == .failed("GraphQL: Could not resolve to a Repository"))
        #expect(BrowserLiveFolderError.from(exitCode: 2, stderr: "") == .failed("gh exited with status 2."))
    }

    @Test func ghIsFoundWhereAGUIAppsPATHDoesntLook() {
        let found = BrowserGitHubCLI.resolve(environment: ["PATH": "/usr/bin:/bin"], home: "/Users/me") {
            $0 == "/Users/me/.local/bin/gh"
        }
        #expect(found?.path == "/Users/me/.local/bin/gh")
        #expect(BrowserGitHubCLI.resolve(environment: ["PATH": "/usr/bin"], home: "/h") { _ in false } == nil)
        let path = BrowserGitHubCLI.environment(inherited: ["PATH": "/usr/bin:/opt/homebrew/bin"], home: "/h")["PATH"]
        #expect(path?.hasPrefix("/opt/homebrew/bin:/usr/local/bin:") == true)
        #expect(path?.components(separatedBy: ":").filter { $0 == "/opt/homebrew/bin" }.count == 1)
    }

    // MARK: - Saving

    @Test func aLiveFolderSavesItsSourceAndNeverItsPullRequests() throws {
        let folder = BrowserPinFolder(name: "PRs", source: .githubSearch(query: "is:open author:@me"))
        var tree = BrowserPinTree(children: [.folder(folder)])
        let changed = tree.setSource(folder: folder.id, to: .githubPullRequests(repo: "o/r"))
        #expect(changed)
        let shown = tree.fillingLiveFolders { _ in [BrowserPin(url: "https://github.com/o/r/pull/1", title: "One")] }
        #expect(shown.folder(id: folder.id)?.allPins.count == 1)
        #expect(tree.folder(id: folder.id)?.allPins.isEmpty == true)

        let data = try JSONEncoder().encode(tree.root)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let child = try #require((object["children"] as? [[String: Any]])?.first)
        #expect(child["type"] as? String == "folder")
        #expect((child["source"] as? [String: String]) == ["kind": "githubPullRequests", "repo": "o/r"])
        #expect((child["children"] as? [Any])?.isEmpty == true)
        let decoded = BrowserPinTree(root: try JSONDecoder().decode(BrowserPinFolder.self, from: data))
        #expect(decoded == tree)
    }

    @Test func anUnknownSourceLeavesAPlainFolderWithItsChildren() throws {
        let json = """
        {"type": "folder", "id": "6F1D7A5E-0000-4000-8000-000000000001", "name": "Later",
         "source": {"kind": "gitlabMergeRequests", "project": 1},
         "children": [{"type": "pin", "url": "https://example.com/", "title": "Example"}]}
        """
        let folder = try JSONDecoder().decode(BrowserPinFolder.self, from: Data(json.utf8))
        #expect(folder.source == nil)
        #expect(folder.allPins.map(\.url) == ["https://example.com/"])
        let bad = """
        {"type": "folder", "name": "X", "source": {"kind": "githubPullRequests", "repo": "not a repo"}}
        """
        #expect(try JSONDecoder().decode(BrowserPinFolder.self, from: Data(bad.utf8)).source == nil)
    }

    @Test func nothingMovesIntoALiveFolder() {
        let live = BrowserPinFolder(name: "PRs", source: .githubPullRequests(repo: "o/r"))
        let plain = BrowserPinFolder(name: "Work")
        let pin = BrowserPin(url: "https://example.com/", title: "Example")
        var tree = BrowserPinTree(children: [.folder(live), .folder(plain), .pin(pin)])
        #expect(!tree.canMove(pin.id, into: live.id))
        let movedIn = tree.move(pin.id, to: live.id, at: 0)
        #expect(!movedIn)
        #expect(tree.canMove(pin.id, into: plain.id))
        // The live folder itself moves like any folder.
        let movedLive = tree.move(live.id, to: plain.id, at: 0)
        #expect(movedLive)
        #expect(!tree.folderEntries().contains { $0.id == live.id })
        #expect(tree.folderForNewPin(lastUsed: live.id) == BrowserPinTree.rootID)
        #expect(tree.liveFolders().map(\.id) == [live.id])
    }

    // MARK: - Runtime

    private func makeStore() -> (BrowserSpaceStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebLive-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profiles = BrowserProfileStore(url: directory.appendingPathComponent("profiles.json"))
        let store = BrowserSpaceStore(
            url: directory.appendingPathComponent("spaces.json"),
            profiles: profiles.profiles,
            bookmarksURL: directory.appendingPathComponent("bookmarks.json")
        )
        return (store, directory)
    }

    private final class Answers: @unchecked Sendable {
        let lock = NSLock()
        var calls: [BrowserLiveFolderSource] = []
        var next: Result<[BrowserPullRequest], BrowserLiveFolderError> = .success([])

        func answer(_ source: BrowserLiveFolderSource) -> Result<[BrowserPullRequest], BrowserLiveFolderError> {
            lock.lock()
            defer { lock.unlock() }
            calls.append(source)
            return next
        }
    }

    private func pullRequest(_ number: Int) -> BrowserPullRequest {
        BrowserPullRequest(
            number: number, title: "PR \(number)", url: "https://github.com/o/r/pull/\(number)",
            repository: "o/r", author: "a", isDraft: false, updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func fetchesShowAndAFailureKeepsWhatWasShown() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spaceID = try #require(store.spaces.first?.id)
        let answers = Answers()
        answers.next = .success([pullRequest(1), pullRequest(2)])
        let live = BrowserLiveFolders(spaces: store, fetch: { answers.answer($0) })
        let folder = try #require(store.addLiveFolder(name: "PRs", source: .githubPullRequests(repo: "o/r"), inSpace: spaceID))

        live.refresh(folder.id)
        #expect(live.state(of: folder.id)?.isLoading == true)
        await live.waitForFetches()
        #expect(live.state(of: folder.id)?.items.map(\.number) == [1, 2])
        let rowID = browserLiveItemID(folderID: folder.id, url: "https://github.com/o/r/pull/2")
        #expect(live.item(id: rowID)?.item.number == 2)
        let shown = live.display(store.pinTree(inSpace: spaceID))
        #expect(shown.folder(id: folder.id)?.allPins.map(\.id).last == rowID)
        // Saved: the folder and its source, no pull request.
        let saved = try String(contentsOf: store.url, encoding: .utf8)
        #expect(saved.contains("githubPullRequests"))
        #expect(!saved.contains("pull/1"))

        answers.next = .failure(.signedOut)
        live.refresh(folder.id)
        await live.waitForFetches()
        let state = try #require(live.state(of: folder.id))
        #expect(state.error == .signedOut)
        #expect(state.items.count == 2)
        #expect(state.status == BrowserLiveFolderError.signedOut.message)
    }

    @Test func folderChangesStartOverOrDropTheirPullRequests() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spaceID = try #require(store.spaces.first?.id)
        let answers = Answers()
        answers.next = .success([pullRequest(7)])
        let live = BrowserLiveFolders(spaces: store, fetch: { answers.answer($0) })
        let folder = try #require(store.addLiveFolder(name: "PRs", source: .githubPullRequests(repo: "o/r"), inSpace: spaceID))
        live.refresh(folder.id)
        await live.waitForFetches()
        let rowID = browserLiveItemID(folderID: folder.id, url: "https://github.com/o/r/pull/7")
        #expect(live.isItem(rowID))

        // A new source: what the old one fetched goes.
        store.editLiveFolder(folder.id, name: "Mine", source: .githubSearch(query: "author:@me"), inSpace: spaceID)
        #expect(live.state(of: folder.id)?.items.isEmpty == true)
        #expect(!live.isItem(rowID))

        store.removePin(folder.id, inSpace: spaceID)
        #expect(live.state(of: folder.id) == nil)
        #expect(live.states.isEmpty)
    }

    @Test func openingAFolderRefetchesOnlyWhenItsPullRequestsAreOld() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spaceID = try #require(store.spaces.first?.id)
        let answers = Answers()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let live = BrowserLiveFolders(spaces: store, fetch: { answers.answer($0) }, now: { clock })
        let folder = try #require(store.addLiveFolder(name: "PRs", source: .githubPullRequests(repo: "o/r"), inSpace: spaceID))

        live.folderOpened(folder.id)
        await live.waitForFetches()
        live.folderOpened(folder.id)
        await live.waitForFetches()
        #expect(answers.calls.count == 1)
        clock += BrowserLiveFolders.openRefreshAge + 1
        live.folderOpened(folder.id)
        await live.waitForFetches()
        #expect(answers.calls.count == 2)
    }
}
