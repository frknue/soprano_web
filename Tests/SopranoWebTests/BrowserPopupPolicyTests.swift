@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserPopupPolicyTests {
    private func store() -> (BrowserSitePermissionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebPopups-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (BrowserSitePermissionStore(url: directory.appendingPathComponent("site-permissions.json")), directory)
    }

    @Test func onlyAllowedHostsOpenWindowsWithoutAClick() {
        let (permissions, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        permissions.set(.popups, .allow, host: "pay.example")
        permissions.set(.popups, .deny, host: "ads.example")

        #expect(BrowserPopupPolicy.opensWithoutGesture(
            pageURL: URL(string: "https://PAY.example/checkout"), permissions: permissions
        ))
        #expect(!BrowserPopupPolicy.opensWithoutGesture(
            pageURL: URL(string: "https://ads.example/"), permissions: permissions
        ))
        #expect(!BrowserPopupPolicy.opensWithoutGesture(
            pageURL: URL(string: "https://other.example/"), permissions: permissions
        ))
        #expect(!BrowserPopupPolicy.opensWithoutGesture(pageURL: nil, permissions: permissions))
    }

    @Test func reportsOnlyOpenableBlockedURLs() {
        let url = URL(string: "https://login.example/oauth?x=1")!
        #expect(BrowserPopupPolicy.blockedURL(url.absoluteString, noopener: false, recentlyOpened: []) == url)
        #expect(BrowserPopupPolicy.blockedURL("about:blank", noopener: false, recentlyOpened: [])
            == URL(string: "about:blank"))
        #expect(BrowserPopupPolicy.blockedURL("javascript:alert(1)", noopener: false, recentlyOpened: []) == nil)
        #expect(BrowserPopupPolicy.blockedURL("zoommtg://join", noopener: false, recentlyOpened: []) == nil)
        #expect(BrowserPopupPolicy.blockedURL("", noopener: false, recentlyOpened: []) == nil)
        #expect(BrowserPopupPolicy.blockedURL(nil, noopener: false, recentlyOpened: []) == nil)
    }

    @Test func noopenerWindowThatOpenedIsNotReportedAsBlocked() {
        let url = URL(string: "https://share.example/post")!
        // window.open(url, "_blank", "noopener") returns null after opening.
        #expect(BrowserPopupPolicy.blockedURL(url.absoluteString, noopener: true, recentlyOpened: [url]) == nil)
        // A noopener call that never opened is still blocked.
        #expect(BrowserPopupPolicy.blockedURL(url.absoluteString, noopener: true, recentlyOpened: []) == url)
        // Without noopener, a null result means blocked even if the URL opened before.
        #expect(BrowserPopupPolicy.blockedURL(url.absoluteString, noopener: false, recentlyOpened: [url]) == url)
    }

    @Test func blockedListKeepsNewestUniqueURLs() {
        let a = URL(string: "https://a.example/")!
        let b = URL(string: "https://b.example/")!
        #expect(BrowserPopupPolicy.appending(a, to: [a, b]) == [b, a])
        var list: [URL] = []
        for index in 0..<15 {
            list = BrowserPopupPolicy.appending(URL(string: "https://x.example/\(index)")!, to: list)
        }
        #expect(list.count == BrowserPopupPolicy.maxBlocked)
        #expect(list.first == URL(string: "https://x.example/5"))
        #expect(list.last == URL(string: "https://x.example/14"))
    }
}
