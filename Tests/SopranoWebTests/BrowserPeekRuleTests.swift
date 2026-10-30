@testable import SopranoWeb
import AppKit
import Testing

/// Peek's "other site" rule (a host comparison: `www.` dropped, equal or a
/// subdomain is the same site) and which link clicks open a Peek.
struct BrowserPeekRuleTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func wwwIsDroppedAndCaseAndTrailingDotsDoNotMatter() {
        #expect(!BrowserPeekRule.isOtherSite(from: url("https://www.example.com/a"), to: url("https://example.com/b")))
        #expect(!BrowserPeekRule.isOtherSite(from: url("https://EXAMPLE.com/"), to: url("https://www.Example.COM./x")))
        #expect(BrowserPeekRule.siteHost("www.example.com") == "example.com")
        // Only a leading `www.` goes.
        #expect(BrowserPeekRule.siteHost("wwwexample.com") == "wwwexample.com")
        #expect(BrowserPeekRule.siteHost("www.") == "www")
    }

    @Test func subdomainsAreTheSameSiteEitherWay() {
        #expect(!BrowserPeekRule.isOtherSite(from: url("https://example.com/"), to: url("https://docs.example.com/")))
        #expect(!BrowserPeekRule.isOtherSite(from: url("https://a.b.example.com/"), to: url("https://example.com/")))
        #expect(!BrowserPeekRule.isOtherSite(from: url("https://www.example.com/"), to: url("https://mail.example.com/")))
        // Siblings are other sites (no public-suffix list).
        #expect(BrowserPeekRule.isOtherSite(from: url("https://docs.example.com/"), to: url("https://mail.example.com/")))
        // A suffix that is not a label boundary is another site.
        #expect(BrowserPeekRule.isOtherSite(from: url("https://example.com/"), to: url("https://notexample.com/")))
        #expect(BrowserPeekRule.isOtherSite(from: url("https://github.com/"), to: url("https://news.ycombinator.com/")))
    }

    @Test func portsNeverMatter() {
        #expect(!BrowserPeekRule.isOtherSite(from: url("http://localhost:3000/"), to: url("http://localhost:4000/x")))
        #expect(!BrowserPeekRule.isOtherSite(from: url("https://example.com:8443/"), to: url("https://example.com/")))
        #expect(BrowserPeekRule.isOtherSite(from: url("http://127.0.0.1:8765/a"), to: url("http://localhost:8765/b")))
    }

    @Test func ipAddressesAreOnlyThemselves() {
        #expect(!BrowserPeekRule.isOtherSite(from: url("http://10.0.0.1/"), to: url("http://10.0.0.1:8080/")))
        #expect(BrowserPeekRule.isOtherSite(from: url("http://10.0.0.1/"), to: url("http://10.0.0.2/")))
        // "1.2.3.4" ends in ".3.4", but addresses have no subdomains.
        #expect(!BrowserPeekRule.isSameSite("1.2.3.4", "3.4"))
        #expect(BrowserPeekRule.isOtherSite(from: url("http://1.2.3.4/"), to: url("http://2.3.4.5/")))
        #expect(!BrowserPeekRule.isOtherSite(from: url("http://[::1]:8080/"), to: url("http://[::1]/")))
        #expect(BrowserPeekRule.isOtherSite(from: url("http://[::1]/"), to: url("http://[fe80::1]/")))
        #expect(BrowserPeekRule.isIPAddress("127.0.0.1"))
        #expect(BrowserPeekRule.isIPAddress("::1"))
        #expect(!BrowserPeekRule.isIPAddress("example.com"))
        #expect(!BrowserPeekRule.isIPAddress("1.2.3"))
    }

    @Test func pagesWithoutAHostLeaveForAnyWebHost() {
        #expect(BrowserPeekRule.isOtherSite(from: url("about:blank"), to: url("https://example.com/")))
        #expect(BrowserPeekRule.isOtherSite(from: nil, to: url("https://example.com/")))
        #expect(BrowserPeekRule.isOtherSite(from: url("file:///tmp/a.html"), to: url("https://example.com/")))
        // A link without a host never leaves.
        #expect(!BrowserPeekRule.isOtherSite(from: url("https://example.com/"), to: url("about:blank")))
        #expect(!BrowserPeekRule.isOtherSite(from: url("https://example.com/"), to: nil))
    }

    // MARK: - Which clicks open a Peek

    private func disposition(
        _ flags: NSEvent.ModifierFlags = [],
        button: Int = 1,
        origin: BrowserTabOrigin,
        from page: String = "https://example.com/",
        to link: String,
        mainFrame: Bool = true
    ) -> BrowserLinkDisposition {
        BrowserLinkDisposition.disposition(
            modifierFlags: flags,
            buttonNumber: button,
            origin: origin,
            pageURL: url(page),
            linkURL: url(link),
            targetsMainFrame: mainFrame
        )
    }

    @Test func pinnedAndFavoriteTabsPeekAtOtherSites() {
        let pinned = BrowserTabOrigin.pinned(UUID())
        let favorite = BrowserTabOrigin.favorite(UUID())
        #expect(disposition(origin: pinned, to: "https://other.org/") == .peek)
        #expect(disposition(origin: favorite, to: "https://other.org/") == .peek)
        // The same site (www, subdomain) stays in the tab.
        #expect(disposition(origin: pinned, to: "https://www.example.com/page") == .currentTab)
        #expect(disposition(origin: favorite, to: "https://docs.example.com/") == .currentTab)
        // A link loading in a frame of the page stays there.
        #expect(disposition(origin: pinned, to: "https://other.org/", mainFrame: false) == .currentTab)
        // ⌘ and middle clicks keep opening tabs.
        #expect(disposition(.command, origin: pinned, to: "https://other.org/") == .backgroundTab)
        #expect(disposition(button: 4, origin: favorite, to: "https://other.org/") == .backgroundTab)
        #expect(disposition([.shift, .command], origin: pinned, to: "https://other.org/") == .foregroundTab)
        // Only web links peek.
        #expect(disposition(origin: pinned, from: "https://example.com/", to: "data:text/plain,hi") == .currentTab)
    }

    @Test func todayTabsPeekOnlyOnShift() {
        #expect(disposition(origin: .today, to: "https://other.org/") == .currentTab)
        #expect(disposition(.shift, origin: .today, to: "https://other.org/") == .peek)
        // ⇧ peeks at any link, the same site and frames included.
        #expect(disposition(.shift, origin: .today, to: "https://example.com/next") == .peek)
        #expect(disposition(.shift, origin: .pinned(UUID()), to: "https://example.com/next") == .peek)
        #expect(disposition(.shift, origin: .today, to: "https://other.org/", mainFrame: false) == .peek)
        #expect(disposition(.shift, origin: .today, to: "data:text/plain,hi") == .currentTab)
        #expect(disposition(.command, origin: .today, to: "https://other.org/") == .backgroundTab)
    }
}
