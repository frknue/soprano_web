@testable import SopranoWeb
import AppKit
import Testing

/// Which pages get the blocker's lists: Settings ▸ Block ads and trackers
/// and the per-site "Block ads on this site" switch (per host, per profile,
/// in memory in a private window).
@MainActor
struct BrowserContentBlockingPolicyTests {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-site-blocking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func theSettingIsOnByDefaultAndDecodesOnItsOwn() throws {
        #expect(BrowserSettings.default.blockAdsAndTrackers)
        let off = try JSONDecoder().decode(BrowserSettings.self, from: Data(#"{"blockAdsAndTrackers": false}"#.utf8))
        #expect(!off.blockAdsAndTrackers)
        let wrong = try JSONDecoder().decode(
            BrowserSettings.self,
            from: Data(#"{"blockAdsAndTrackers": "no", "homepage": "https://example.com"}"#.utf8)
        )
        #expect(wrong.blockAdsAndTrackers)
        #expect(wrong.homepage == "https://example.com")
    }

    @Test func aSiteSwitchedOffLosesTheListsOnItsPagesOnly() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("site-permissions.json")
        let store = BrowserSitePermissionStore(url: url)
        let page = URL(string: "https://news.example.com/article")!
        func blocks(_ address: String?, enabled: Bool = true) -> Bool {
            BrowserContentBlockingPolicy.blocks(
                pageURL: address.flatMap(URL.init(string:)),
                isEnabled: enabled,
                sitePermissions: store
            )
        }
        #expect(blocks(page.absoluteString))
        #expect(!blocks(page.absoluteString, enabled: false))

        store.setBlocksContent(false, host: "News.Example.com")
        #expect(!blocks(page.absoluteString))
        // Per host: the parent domain and other sites keep blocking.
        #expect(blocks("https://example.com/"))
        #expect(blocks("https://ads.example.net/"))
        // A page without a site follows the setting.
        #expect(blocks(nil))
        #expect(blocks("about:blank"))
        #expect(BrowserSitePermissionStore(url: url).sites == ["news.example.com": ["contentBlocking": "deny"]])

        // Switching it back on forgets the site.
        store.setBlocksContent(true, host: "news.example.com")
        #expect(blocks(page.absoluteString))
        #expect(store.sites.isEmpty)
    }

    @Test func aPrivateWindowReadsTheSavedSwitchAndKeepsItsOwnInMemory() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("site-permissions.json")
        let saved = BrowserSitePermissionStore(url: url)
        saved.setBlocksContent(false, host: "shop.example")
        let overlay = BrowserSitePermissionStore(overlaying: saved)
        #expect(!overlay.blocksContent(host: "shop.example"))

        overlay.setBlocksContent(true, host: "shop.example")
        overlay.setBlocksContent(false, host: "forum.example")
        #expect(overlay.blocksContent(host: "shop.example"))
        #expect(!overlay.blocksContent(host: "forum.example"))
        // Nothing the private window did reached the profile's file.
        #expect(!saved.blocksContent(host: "shop.example"))
        #expect(saved.blocksContent(host: "forum.example"))
        #expect(BrowserSitePermissionStore(url: url).sites == ["shop.example": ["contentBlocking": "deny"]])
    }

    @Test func eachProfileHasItsOwnSwitches() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultProfile = BrowserSitePermissionStore(url: directory.appendingPathComponent("site-permissions.json"))
        let work = BrowserSitePermissionStore(url: directory.appendingPathComponent("Profiles/work/site-permissions.json"))
        defaultProfile.setBlocksContent(false, host: "example.com")
        #expect(!defaultProfile.blocksContent(host: "example.com"))
        #expect(work.blocksContent(host: "example.com"))
    }

    @Test func websitesListsTheSwitchWithRemove() {
        let rows = BrowserWebsiteRow.rows(from: [
            "news.example.com": ["contentBlocking": "deny", "zoom": "1.25", "camera": "allow"],
        ])
        #expect(rows.map(\.summary) == ["Camera: Allow · Zoom: 125% · Ad blocking: Off"])
    }
}
