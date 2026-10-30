@testable import SopranoWeb
import AppKit
import Testing

/// Stage 4 P6: the Site Control Center's clear-site-data target, its
/// permission rows per profile (and a private window's overlay), and which
/// tab the popover acts on (a Peek's, the focused pane's).
@MainActor
@Suite(.serialized)
struct BrowserSiteControlTests {
    // MARK: Clear site data target

    @Test func aHostMatchesItsOwnRecordAndTheDomainsAboveIt() throws {
        let target = try #require(BrowserSiteDataTarget(url: URL(string: "https://mail.Example.com./inbox")))
        #expect(target.host == "mail.example.com")
        #expect(!target.isAddress)
        #expect(target.matchesRecord("example.com"))
        #expect(target.matchesRecord("mail.example.com"))
        #expect(!target.matchesRecord("other.example.com"))
        #expect(!target.matchesRecord("ample.com"))
        #expect(!target.matchesRecord("com"))
        #expect(!target.matchesRecord("example.org"))
    }

    @Test func cookiesAreOnlyTheHostsOwn() throws {
        let target = try #require(BrowserSiteDataTarget(host: "mail.example.com"))
        #expect(target.matchesCookie(domain: "mail.example.com"))
        #expect(target.matchesCookie(domain: ".mail.example.com"))
        // A parent domain's cookie also reaches sibling subdomains: kept.
        #expect(!target.matchesCookie(domain: ".example.com"))
        #expect(!target.matchesCookie(domain: "www.example.com"))
        let apex = try #require(BrowserSiteDataTarget(host: "example.com"))
        #expect(apex.matchesCookie(domain: ".example.com"))
        #expect(!apex.matchesCookie(domain: "mail.example.com"))
    }

    @Test func addressesAndLocalhostMatchOnlyThemselves() throws {
        let ip = try #require(BrowserSiteDataTarget(url: URL(string: "http://127.0.0.1:8080/")))
        #expect(ip.isAddress)
        #expect(ip.matchesRecord("127.0.0.1"))
        #expect(!ip.matchesRecord("0.0.1"))
        #expect(!ip.matchesRecord("localhost"))
        #expect(ip.matchesCookie(domain: "127.0.0.1"))
        let v6 = try #require(BrowserSiteDataTarget(url: URL(string: "http://[::1]:8080/")))
        #expect(v6.isAddress)
        #expect(v6.matchesRecord("::1"))
        let local = try #require(BrowserSiteDataTarget(url: URL(string: "http://localhost:3000/")))
        #expect(!local.isAddress)
        #expect(local.matchesRecord("localhost"))
        #expect(!local.matchesRecord("127.0.0.1"))
        #expect(!local.matchesCookie(domain: "127.0.0.1"))
        let sub = try #require(BrowserSiteDataTarget(host: "app.localhost"))
        #expect(sub.matchesRecord("localhost"))
        // Not a dotted quad: a host name.
        #expect(BrowserSiteDataTarget(host: "1.2.3.example")?.isAddress == false)
        #expect(BrowserSiteDataTarget(host: "300.1.1.1")?.isAddress == false)
    }

    @Test func pagesWithoutAnHTTPHostHaveNoTarget() {
        #expect(BrowserSiteDataTarget(url: nil) == nil)
        #expect(BrowserSiteDataTarget(url: URL(string: "file:///tmp/a.html")) == nil)
        #expect(BrowserSiteDataTarget(url: URL(string: "about:blank")) == nil)
        #expect(BrowserSiteDataTarget(host: " ") == nil)
    }

    // MARK: Permissions

    private func temporaryStore() -> BrowserSitePermissionStore {
        BrowserSitePermissionStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("site-permissions-\(UUID().uuidString).json"))
    }

    @Test func permissionRowsReadEachProfilesOwnStore() {
        let work = temporaryStore()
        let home = temporaryStore()
        work.set(.camera, .allow, host: "meet.example")
        home.set(.popups, .deny, host: "meet.example")
        let workRows = BrowserSiteControlState.permissions(host: "meet.example", store: work, isPrivate: false)
        let homeRows = BrowserSiteControlState.permissions(host: "meet.example", store: home, isPrivate: false)
        #expect(workRows.map(\.permission) == [.camera, .microphone, .notifications, .popups])
        #expect(workRows.map(\.choice) == [.allow, .ask, .ask, .ask])
        #expect(homeRows.map(\.choice) == [.ask, .ask, .ask, .deny])
        #expect(workRows.map(\.isEnabled) == [true, true, true, true])
    }

    @Test func aPrivateOverlayReadsThroughAndKeepsItsOwnAnswers() {
        let saved = temporaryStore()
        saved.set(.microphone, .allow, host: "meet.example")
        let overlay = BrowserSitePermissionStore(overlaying: saved)
        var rows = BrowserSiteControlState.permissions(host: "meet.example", store: overlay, isPrivate: true)
        #expect(rows.map(\.choice) == [.ask, .allow, .deny, .ask])
        // Notifications are always blocked in a private window.
        #expect(rows.map(\.isEnabled) == [true, true, false, true])
        overlay.set(.camera, .deny, host: "meet.example")
        overlay.forget(.microphone, host: "meet.example")
        rows = BrowserSiteControlState.permissions(host: "meet.example", store: overlay, isPrivate: true)
        #expect(rows.map(\.choice) == [.deny, .ask, .deny, .ask])
        // The saved decisions are untouched.
        #expect(saved.decision(.camera, host: "meet.example") == nil)
        #expect(saved.decision(.microphone, host: "meet.example") == .allow)
    }

    @Test func extensionAccessCoversTheSiteAndItsSubdomains() {
        typealias Access = BrowserSiteControlState.ExtensionAccess
        #expect(Access.isAllowed(host: "a.example.com", access: .specificSites, allowedSites: ["example.com"]))
        #expect(!Access.isAllowed(host: "example.org", access: .specificSites, allowedSites: ["example.com"]))
        #expect(Access.isAllowed(host: "x.test", access: .allSites, allowedSites: []))
        #expect(!Access.isAllowed(host: "x.test", access: .onClick, allowedSites: ["x.test"]))
    }
}
