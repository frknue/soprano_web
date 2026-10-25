@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserSitePermissionStoreTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebPermissions-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func decisionsPersistAndClear() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("site-permissions.json")
        let store = BrowserSitePermissionStore(url: url)
        var changes = 0
        store.onChange = { changes += 1 }

        store.set(.camera, .allow, host: "meet.example")
        store.set(.popups, .deny, host: "meet.example")
        store.set(.externalApp(scheme: "zoommtg"), .allow, host: "zoom.example")
        #expect(changes == 3)

        let reloaded = BrowserSitePermissionStore(url: url)
        #expect(reloaded.decision(.camera, host: "meet.example") == .allow)
        #expect(reloaded.decision(.popups, host: "meet.example") == .deny)
        #expect(reloaded.decision(.microphone, host: "meet.example") == nil)
        #expect(reloaded.decision(.externalApp(scheme: "ZoomMTG"), host: "zoom.example") == .allow)

        reloaded.set(.camera, nil, host: "meet.example")
        #expect(reloaded.decision(.camera, host: "meet.example") == nil)
        reloaded.removeAll(host: "zoom.example")
        #expect(BrowserSitePermissionStore(url: url).sites == ["meet.example": ["popups": "deny"]])

        reloaded.removeAll()
        #expect(BrowserSitePermissionStore(url: url).sites.isEmpty)
    }

    @Test func hostsAreNormalized() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserSitePermissionStore(url: directory.appendingPathComponent("site-permissions.json"))

        store.set(.notifications, .allow, host: "News.Example.COM.")
        #expect(store.decision(.notifications, host: "news.example.com") == .allow)
        #expect(BrowserSitePermissionStore.key(for: URL(string: "https://News.Example.com:8443/a?b")) == "news.example.com")
        #expect(BrowserSitePermissionStore.key(for: URL(fileURLWithPath: "/tmp/page.html")) == "file")
        #expect(BrowserSitePermissionStore.key(for: URL(string: "about:blank")) == nil)
        #expect(BrowserSitePermissionStore.key(for: nil) == nil)
    }

    @Test func unknownPermissionsInTheFileSurviveASave() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("site-permissions.json")
        try Data("""
        {
          "version": 1,
          "sites": {
            "meet.example": { "screenShare": "allow", "camera": "ask", "broken": 3 },
            "other.example": { "midi": "deny" }
          }
        }
        """.utf8).write(to: url)

        let store = BrowserSitePermissionStore(url: url)
        #expect(store.decision(.camera, host: "meet.example") == nil)
        store.set(.microphone, .allow, host: "meet.example")

        let reloaded = BrowserSitePermissionStore(url: url)
        #expect(reloaded.sites["meet.example"] == [
            "screenShare": "allow",
            "camera": "ask",
            "microphone": "allow",
        ])
        #expect(reloaded.sites["other.example"] == ["midi": "deny"])
    }
}
