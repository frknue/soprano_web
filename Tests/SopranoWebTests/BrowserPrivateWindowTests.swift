@testable import SopranoWeb
import AppKit
import Testing

/// What a private window keeps compared with a normal one, through the
/// rules windows consult before writing anything.
@MainActor
struct BrowserPrivateWindowTests {
    @Test func normalWindowRecordsEverythingPrivateWindowNothing() {
        let normal = BrowserWindowKind.normal
        #expect(normal.recordsHistory)
        #expect(normal.savesSession)
        #expect(normal.usesAppRecentlyClosed)
        #expect(normal.savesSiteDecisions)
        #expect(normal.writesFavicons)
        #expect(normal.savesDownloadRecords)
        #expect(normal.suggestsHistory)
        #expect(normal.allowsWebNotifications)
        #expect(normal.acceptsOutsideRequests)

        let hidden = BrowserWindowKind.private
        #expect(!hidden.recordsHistory)
        #expect(!hidden.savesSession)
        #expect(!hidden.usesAppRecentlyClosed)
        #expect(!hidden.savesSiteDecisions)
        #expect(!hidden.writesFavicons)
        #expect(!hidden.savesDownloadRecords)
        #expect(!hidden.suggestsHistory)
        #expect(!hidden.allowsWebNotifications)
        #expect(!hidden.acceptsOutsideRequests)
    }

    @Test func privateWindowTitleIsPrefixed() {
        #expect(BrowserWindowKind.private.windowTitle("Example Domain") == "Private — Example Domain")
        #expect(BrowserWindowKind.normal.windowTitle("Example Domain") == "Example Domain")
    }

    @Test func privateWindowAlwaysUsesFolioInk() {
        #expect(BrowserWindowController.theme(for: .private, appTheme: .folioPaper).id == AppTheme.folioInk.id)
        #expect(BrowserWindowController.theme(for: .normal, appTheme: .folioPaper).id == AppTheme.folioPaper.id)
    }

    @Test func privateSuggestionsComeFromBookmarksTabsAndSearchNeverHistory() {
        let history = [BrowserHistoryPage(url: "https://visited.example/", title: "Visited Example")]
        let bookmarks = [BrowserBookmark(url: "https://saved.example/", title: "Saved Example")]
        let tab = AddressSuggestionTab(id: UUID(), title: "Open Example", url: "https://open.example/")
        func rows(_ kind: BrowserWindowKind) -> [AddressSuggestion] {
            var input = AddressSuggestionInput(
                query: "example",
                kind: kind,
                history: history,
                bookmarks: bookmarks,
                tabs: [tab],
                searchEngine: .duckDuckGo
            )
            input.remoteSuggestions = ["example phrase"]
            return AddressSuggestionEngine.suggestions(for: input).rows
        }
        func targets(_ rows: [AddressSuggestion]) -> [String] {
            rows.compactMap { row in
                if case .url(let url) = row.target, row.kind != .url { return url }
                return nil
            }
        }

        let normal = rows(.normal)
        #expect(targets(normal).contains("https://visited.example/"))

        let hidden = rows(.private)
        #expect(!targets(hidden).contains("https://visited.example/"))
        #expect(!hidden.contains { $0.kind == .history })
        #expect(targets(hidden).contains("https://saved.example/"))
        #expect(hidden.contains { $0.target == .tab(tab.id) })
        #expect(hidden.contains { $0.kind == .search })
        #expect(hidden.contains { $0.kind == .searchSuggestion })
    }

    @Test func privateStartPageShowsNoRecentPages() {
        let history = [BrowserHistoryPage(url: "https://visited.example/", title: "Visited Example")]
        let html = BrowserStartPage.html(
            theme: .folioInk,
            settings: BrowserSettings(searchEngine: .duckDuckGo),
            bookmarks: [],
            history: history,
            kind: .private
        )
        #expect(!html.contains("visited.example"))
        #expect(!html.contains("Recent"))
        #expect(html.contains("Private window"))
    }

    @Test func eachPrivateContextHasItsOwnStoreAndInMemoryLayers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-private-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workID = UUID()
        let base = BrowserDataContext(
            kind: .normal,
            profileID: workID,
            websiteDataStore: .nonPersistent(),
            history: BrowserHistoryStore(directory: directory),
            sitePermissions: BrowserSitePermissionStore(url: directory.appendingPathComponent("site-permissions.json")),
            faviconStore: BrowserFaviconStore(directory: directory.appendingPathComponent("Favicons")),
            connectionSecurity: BrowserConnectionSecurity()
        )
        let first = BrowserDataContext.makePrivate(over: base)
        let second = BrowserDataContext.makePrivate(over: base)

        #expect(first.kind == .private)
        #expect(first.websiteDataStore !== base.websiteDataStore)
        #expect(first.websiteDataStore !== second.websiteDataStore)
        #expect(!first.websiteDataStore.isPersistent)
        #expect(first.sitePermissions.url == nil)
        #expect(first.faviconStore.directory == nil)
        #expect(first.connectionSecurity !== base.connectionSecurity)
        // A private window opened from a Work window layers over Work.
        #expect(first.profileID == workID)
        #expect(first.history === base.history)
        #expect(first.downloadContextID == first.id)
        #expect(base.downloadContextID == nil)
    }
}
