@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserExternalAppPolicyTests {
    @Test func remembersAllowPerSiteAndScheme() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebExternal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let permissions = BrowserSitePermissionStore(url: directory.appendingPathComponent("site-permissions.json"))
        permissions.set(.externalApp(scheme: "zoommtg"), .allow, host: "zoom.example")
        permissions.set(.externalApp(scheme: "slack"), .deny, host: "zoom.example")

        let zoom = URL(string: "zoommtg://zoom.us/join?confno=1")!
        let page = URL(string: "https://Zoom.example/j/1")!
        #expect(BrowserExternalAppPolicy.decision(for: zoom, pageURL: page, permissions: permissions) == .open)
        // Scheme case does not matter.
        #expect(BrowserExternalAppPolicy.decision(
            for: URL(string: "ZOOMMTG://zoom.us/join")!, pageURL: page, permissions: permissions
        ) == .open)
        // Another scheme on the same site asks.
        #expect(BrowserExternalAppPolicy.decision(
            for: URL(string: "mailto:a@example.com")!, pageURL: page, permissions: permissions
        ) == .prompt(host: "zoom.example"))
        // The same scheme on another site asks.
        #expect(BrowserExternalAppPolicy.decision(
            for: zoom, pageURL: URL(string: "https://evil.example/")!, permissions: permissions
        ) == .prompt(host: "evil.example"))
        #expect(BrowserExternalAppPolicy.decision(
            for: URL(string: "slack://open")!, pageURL: page, permissions: permissions
        ) == .block)
        // A page without a host can be asked but not remembered.
        #expect(BrowserExternalAppPolicy.decision(for: zoom, pageURL: nil, permissions: permissions)
            == .prompt(host: nil))
    }

    @Test func webSchemesStayInTheBrowser() {
        for value in ["https://a.example", "HTTP://a.example", "file:///tmp/a.html", "about:blank", "data:text/plain,a"] {
            #expect(BrowserWebSchemes.isWeb(URL(string: value)!), "\(value)")
        }
        for value in ["mailto:a@example.com", "zoommtg://join", "slack://open", "tel:123"] {
            #expect(!BrowserWebSchemes.isWeb(URL(string: value)!), "\(value)")
        }
    }
}
