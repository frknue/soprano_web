@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserSessionRestoreTests {
    private let history = Data("archived back/forward list".utf8)

    private func temporaryStore() -> (BrowserSessionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebRestore-\(UUID().uuidString)", isDirectory: true)
        return (BrowserSessionStore(url: directory.appendingPathComponent("session.json")), directory)
    }

    private func write(_ json: String, to store: BrowserSessionStore, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.url)
    }

    @Test func versionThreeRoundTripsWindowsSpacesSelectionsAndClosedEntries() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = UUID()
        let work = UUID()
        let pin = UUID()
        let favorite = UUID()
        let first = BrowserWindowState(
            frame: BrowserWindowFrame(NSRect(x: 40, y: 60, width: 1280, height: 800)),
            tabs: [
                BrowserTabState(url: "https://example.com/b", title: "B", interactionState: history, spaceID: home),
                BrowserTabState(url: nil, title: "New Tab", spaceID: work),
                BrowserTabState(url: "https://example.com/p", title: "P", spaceID: work, origin: .pinned(pin)),
                BrowserTabState(url: "https://example.com/f", title: "F", spaceID: home, origin: .favorite(favorite)),
            ],
            selectedIndex: 1,
            currentSpaceID: work,
            spaceSelections: [
                BrowserSpaceSelection(spaceID: home, index: 3),
                BrowserSpaceSelection(spaceID: work, index: 1),
            ]
        )
        let second = BrowserWindowState(
            frame: BrowserWindowFrame(NSRect(x: 900, y: 20, width: 900, height: 700)),
            tabs: [BrowserTabState(url: "https://webkit.org", title: "WebKit", spaceID: home)],
            selectedIndex: 0,
            currentSpaceID: home
        )
        let closedWindow = BrowserWindowState(
            frame: BrowserWindowFrame(NSRect(x: 10, y: 10, width: 800, height: 600)),
            tabs: [
                BrowserTabState(url: "https://example.com/x", title: "X", interactionState: history, spaceID: home),
                BrowserTabState(url: "https://example.com/y", title: "Y", spaceID: home),
            ],
            selectedIndex: 1,
            currentSpaceID: home
        )
        let session = BrowserSession(
            windows: [first, second],
            activeWindowIndex: 1,
            recentlyClosed: [
                BrowserClosedEntry(.tab(
                    BrowserTabState(url: "https://example.com/c", title: "C", spaceID: work),
                    windowID: first.id,
                    index: 2
                )),
                BrowserClosedEntry(.window(closedWindow)),
            ],
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.save(session)

        let loaded = store.load()
        #expect(loaded == session)
        #expect(loaded?.version == 3)
        #expect(loaded?.windows.map(\.frame?.rect) == [
            NSRect(x: 40, y: 60, width: 1280, height: 800),
            NSRect(x: 900, y: 20, width: 900, height: 700),
        ])
        let window = loaded?.windows.first
        #expect(window?.selectedIndex == 1)
        #expect(window?.currentSpaceID == work)
        #expect(window?.spaceSelections.map(\.index) == [3, 1])
        #expect(window?.tabs.map(\.spaceID) == [home, work, work, home])
        #expect(window?.tabs.map(\.origin) == [.today, .today, .pinned(pin), .favorite(favorite)])
        #expect(window?.tabs.first?.interactionState == history)
        // Closed tabs carry their Space.
        guard case let .tab(closed, _, _) = loaded?.recentlyClosed.first?.content else {
            Issue.record("a closed tab")
            return
        }
        #expect(closed.spaceID == work)
        #expect(loaded?.recentlyClosed.last?.content == .window(closedWindow))
        // A current file is not a migration.
        #expect(!FileManager.default.fileExists(atPath: store.migratedURL.path))
    }

    @Test func pinAndFavoriteLinksAreSavedAsIds() throws {
        let pin = UUID()
        let data = try JSONEncoder().encode(BrowserTabState(url: "https://example.com", title: "E", origin: .pinned(pin)))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["pinID"] as? String == pin.uuidString)
        #expect(object?["favoriteID"] == nil)
        #expect(object?["spaceID"] == nil)
        // A link that isn't a UUID is a Today tab.
        let odd = try JSONDecoder().decode(
            BrowserTabState.self,
            from: Data(#"{"url": "https://example.com", "pinID": "nope", "spaceID": 4}"#.utf8)
        )
        #expect(odd.origin == .today)
        #expect(odd.spaceID == nil)
    }

    @Test func versionTwoMigratesIntoTheFirstSpaceOfEachWindowsProfile() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = BrowserProfile(name: "Work", color: .green)
        var list = BrowserSpaceList()
        let defaultSpace = list.ensureSpace(for: .defaultProfile)
        let workSpace = list.ensureSpace(for: work)
        let research = try #require(list.create(name: "Research", color: .blue, profileID: work.id))
        let original = """
        {"version": 2, "activeWindowIndex": 1, "savedAt": "2026-10-01T10:00:00Z", "windows": [
          {"tabs": [{"url": "https://example.com", "title": "E"}, {"url": "https://webkit.org", "title": "W"}], "selectedIndex": 1},
          {"tabs": [{"url": "https://work.example", "title": "Work"}], "profileID": "\(work.id.uuidString)"}
        ], "recentlyClosed": [{"kind": "tab", "tab": {"url": "https://example.com/c"}, "profileID": "\(work.id.uuidString)"}]}
        """
        try write(original, to: store, in: directory)

        let loaded = try #require(store.load())
        #expect(loaded.version == 2)
        // The version 2 file is kept once, as for version 1.
        #expect(try Data(contentsOf: store.migratedURL) == Data(original.utf8))
        let placed = loaded.windows.map { $0.placedInSpaces(list) }
        #expect(placed.map(\.currentSpaceID) == [defaultSpace.id, workSpace.id])
        #expect(placed[0].tabs.map(\.spaceID) == [defaultSpace.id, defaultSpace.id])
        #expect(placed[0].selectedIndex == 1)
        #expect(placed[1].tabs.map(\.spaceID) == [workSpace.id])
        #expect(placed[1].profileID == work.id)
        #expect(research.profileID == work.id)
        // A closed tab of the version 2 file has no Space; reopening puts it
        // in its profile's first Space.
        guard case let .tab(state, _, _) = loaded.recentlyClosed.first?.content else {
            Issue.record("a closed tab")
            return
        }
        #expect(state.spaceID == nil)
        #expect(loaded.recentlyClosed.first?.profileID == work.id)

        // The next save is version 3 with every tab in its Space.
        store.save(BrowserSession(windows: placed, savedAt: Date()))
        let resaved = try #require(store.load())
        #expect(resaved.version == 3)
        #expect(resaved.windows == placed)
        #expect(try Data(contentsOf: store.migratedURL) == Data(original.utf8))
    }

    @Test func placingAWindowKeepsLiveSpacesAndRepairsTheRest() throws {
        let work = BrowserProfile(name: "Work", color: .green)
        var list = BrowserSpaceList()
        let defaultSpace = list.ensureSpace(for: .defaultProfile)
        let workSpace = list.ensureSpace(for: work)
        let pinned = BrowserPin(url: "https://pinned.example", title: "Pinned")
        #expect(list.updatePins(in: workSpace.id) { $0.insert(.pin(pinned), into: BrowserPinTree.rootID, at: nil) })
        let gone = UUID()
        let window = BrowserWindowState(
            tabs: [
                BrowserTabState(url: "https://a.example", spaceID: workSpace.id, origin: .pinned(pinned.id)),
                BrowserTabState(url: "https://b.example", spaceID: gone, origin: .pinned(UUID())),
                BrowserTabState(url: "https://c.example", spaceID: defaultSpace.id, origin: .favorite(UUID())),
            ],
            selectedIndex: 0,
            profileID: BrowserProfile.defaultID,
            currentSpaceID: workSpace.id,
            spaceSelections: [
                BrowserSpaceSelection(spaceID: workSpace.id, index: 0),
                // Points at a tab of another Space: dropped.
                BrowserSpaceSelection(spaceID: defaultSpace.id, index: 0),
                BrowserSpaceSelection(spaceID: gone, index: 1),
            ]
        )
        let placed = window.placedInSpaces(list)
        #expect(placed.currentSpaceID == workSpace.id)
        // The current Space decides the window's profile.
        #expect(placed.profileID == work.id)
        // A deleted Space's tab joins the window's Space; a stale link is a
        // Today tab; a live pin stays linked.
        #expect(placed.tabs.map(\.spaceID) == [workSpace.id, workSpace.id, defaultSpace.id])
        #expect(placed.tabs.map(\.origin) == [.pinned(pinned.id), .today, .today])
        #expect(placed.spaceSelections == [BrowserSpaceSelection(spaceID: workSpace.id, index: 0)])

        // A window whose Space is gone opens on its profile's first Space.
        var orphan = window
        orphan.currentSpaceID = gone
        orphan.profileID = work.id
        #expect(orphan.placedInSpaces(list).currentSpaceID == workSpace.id)
    }

    @Test func windowsKeepTheirProfileAndADeletedOneFallsBackToDefault() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var profiles = BrowserProfileList()
        let work = profiles.add(name: "Work")
        let gone = profiles.add(name: "Gone")
        let workWindow = BrowserWindowState(tabs: [BrowserTabState(url: "https://work.example", title: "W")], profileID: work.id)
        let goneWindow = BrowserWindowState(tabs: [BrowserTabState(url: "https://gone.example", title: "G")], profileID: gone.id)
        let defaultWindow = BrowserWindowState(tabs: [BrowserTabState(url: nil)])
        store.save(BrowserSession(windows: [defaultWindow, workWindow, goneWindow], savedAt: Date()))
        profiles.remove(id: gone.id)

        let loaded = try #require(store.load())
        #expect(loaded.windows.map(\.profileID) == [BrowserProfile.defaultID, work.id, gone.id])
        // Restoring opens each window in its profile; Gone's in Default.
        #expect(loaded.windows.map { profiles.resolvedID($0.profileID) } == [
            BrowserProfile.defaultID, work.id, BrowserProfile.defaultID,
        ])
    }

    @Test func windowsWithoutAProfileIdBelongToDefault() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(
            #"{"version": 2, "windows": [{"tabs": [{"url": "https://example.com"}]}, {"tabs": [{"url": "https://webkit.org"}], "profileID": "not-a-uuid"}], "savedAt": "2026-10-01T10:00:00Z"}"#,
            to: store,
            in: directory
        )
        let loaded = try #require(store.load())
        #expect(loaded.windows.map(\.profileID) == [BrowserProfile.defaultID, BrowserProfile.defaultID])
    }

    @Test func versionOneMigratesToOneWindowAndKeepsTheOldFile() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = """
        {
          "version": 1,
          "tabs": [
            { "url": "https://example.com", "title": "Example", "zoom": 1 },
            { "url": "https://webkit.org", "title": "WebKit", "interactionState": "YXJjaGl2ZQ==" }
          ],
          "selectedIndex": 1,
          "savedAt": "2023-11-14T22:13:20Z",
          "closedTabs": [
            { "url": "https://example.com/old", "title": "Old" },
            { "url": "https://example.com/newer", "title": "Newer" }
          ]
        }
        """
        try write(original, to: store, in: directory)

        let loaded = try #require(store.load())
        #expect(loaded.version == 1)
        let window = try #require(loaded.windows.first)
        #expect(loaded.windows.count == 1)
        #expect(window.frame == nil)
        #expect(window.selectedIndex == 1)
        #expect(window.tabs == [
            BrowserTabState(url: "https://example.com", title: "Example"),
            BrowserTabState(url: "https://webkit.org", title: "WebKit", interactionState: Data("archive".utf8)),
        ])
        #expect(loaded.activeWindowIndex == 0)
        // The closed tabs keep their order (newest last) and return to the
        // migrated window.
        #expect(loaded.recentlyClosed.map(\.content) == [
            .tab(BrowserTabState(url: "https://example.com/old", title: "Old"), windowID: window.id, index: nil),
            .tab(BrowserTabState(url: "https://example.com/newer", title: "Newer"), windowID: window.id, index: nil),
        ])
        #expect(try Data(contentsOf: store.migratedURL) == Data(original.utf8))

        // The next save is the current version; the kept file stays the
        // original.
        store.save(BrowserSession(windows: loaded.windows, recentlyClosed: loaded.recentlyClosed, savedAt: Date()))
        let resaved = try #require(store.load())
        #expect(resaved.version == BrowserSession.currentVersion)
        #expect(resaved.windows == loaded.windows)
        #expect(resaved.recentlyClosed == loaded.recentlyClosed)
        #expect(try Data(contentsOf: store.migratedURL) == Data(original.utf8))
    }

    @Test func versionOneWithoutTabsMigratesToNoWindowAndHomelessClosedTabs() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("""
        { "tabs": [], "selectedIndex": 0, "closedTabs": [{ "url": "https://example.com/a", "title": "A" }] }
        """, to: store, in: directory)

        let loaded = try #require(store.load())
        #expect(loaded.windows.isEmpty)
        #expect(loaded.activeWindowIndex == nil)
        #expect(loaded.recentlyClosed.map(\.content) == [
            .tab(BrowserTabState(url: "https://example.com/a", title: "A"), windowID: nil, index: nil),
        ])
    }

    @Test func entriesThatDoNotDecodeAreSkipped() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("""
        {
          "version": 2,
          "windows": [
            { "tabs": [{ "url": "https://example.com", "title": "Example" }], "selectedIndex": 0 },
            42
          ],
          "recentlyClosed": [
            { "kind": "split-view", "tabs": [] },
            { "kind": "tab", "tab": { "url": "https://webkit.org", "title": "WebKit" }, "index": 3 }
          ],
          "savedAt": "2023-11-14T22:13:20Z"
        }
        """, to: store, in: directory)

        let loaded = try #require(store.load())
        #expect(loaded.windows.map(\.tabs) == [[BrowserTabState(url: "https://example.com", title: "Example")]])
        #expect(loaded.windows.first?.frame == nil)
        #expect(loaded.recentlyClosed.map(\.content) == [
            .tab(BrowserTabState(url: "https://webkit.org", title: "WebKit"), windowID: nil, index: 3),
        ])
    }

    @Test func notYetLoadedTabKeepsAddressAndHistoryThroughASave() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = BrowserTabState(url: "https://example.com/b", title: "B", interactionState: history)
        // A lazy tab's empty web view has no URL and no history of its own.
        let state = BrowserTabState.snapshot(
            pending: saved,
            isStartPage: false,
            failedURL: nil,
            currentURL: nil,
            title: "B",
            interactionState: {
                Issue.record("A lazy tab must not read its empty web view's history")
                return nil
            }
        )
        store.save(BrowserSession(windows: [BrowserWindowState(tabs: [state])], savedAt: Date()))
        #expect(store.load()?.windows.first?.tabs == [saved])
    }

    @Test func loadedTabSavesItsLiveAddressAndHistory() {
        let state = BrowserTabState.snapshot(
            pending: nil,
            isStartPage: false,
            failedURL: nil,
            currentURL: "https://example.com/c",
            title: "C",
            interactionState: { history }
        )
        #expect(state == BrowserTabState(url: "https://example.com/c", title: "C", interactionState: history))
    }

    /// Stage 1 saved a zoom per tab; a page now takes its site's zoom, so a
    /// saved one is read past and never written again.
    @Test func savedPerTabZoomIsNoLongerUsed() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {
          "version": 2,
          "windows": [{ "tabs": [
            { "url": "https://example.com/", "title": "Example", "zoom": 1.5 }
          ] }],
          "savedAt": "2026-10-01T10:00:00Z"
        }
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.url)
        let loaded = try #require(store.load())
        #expect(loaded.windows.first?.tabs == [BrowserTabState(url: "https://example.com/", title: "Example")])

        store.save(loaded)
        let written = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!written.contains("zoom"))
    }
}
