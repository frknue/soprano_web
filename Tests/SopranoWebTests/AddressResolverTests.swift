@testable import SopranoWeb
import AppKit
import Testing

struct BrowserAddressResolverTests {
    @Test func localhostGetsHTTP() {
        #expect(BrowserAddressResolver.resolve("localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(BrowserAddressResolver.resolve("127.0.0.1:8080")?.absoluteString == "http://127.0.0.1:8080")
    }

    @Test func bareHostGetsHTTPS() {
        #expect(BrowserAddressResolver.resolve("example.com")?.absoluteString == "https://example.com")
        #expect(BrowserAddressResolver.resolve("example.com/shop")?.absoluteString == "https://example.com/shop")
    }

    @Test func absoluteURLIsKept() {
        #expect(
            BrowserAddressResolver.resolve("https://example.com/a?b=1")?.absoluteString
                == "https://example.com/a?b=1"
        )
        #expect(BrowserAddressResolver.resolve("mailto:hi@example.com")?.absoluteString == "mailto:hi@example.com")
    }

    @Test func emptyInputIsStartPage() {
        #expect(BrowserAddressResolver.isStartPage(BrowserAddressResolver.resolve("")))
        #expect(BrowserAddressResolver.isStartPage(BrowserAddressResolver.resolve("about:start")))
        #expect(BrowserAddressResolver.isStartPage(URL(string: "soprano-web://start")))
    }

    @Test func wordsBecomeASearch() {
        let url = BrowserAddressResolver.resolve("swift appkit browser", searchEngine: .duckDuckGo)
        #expect(url?.host == "duckduckgo.com")
        #expect(URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value == "swift appkit browser")
    }

    @Test func searchEngineIsHonoured() {
        let url = BrowserAddressResolver.resolve("soprano", searchEngine: .google)
        #expect(url?.host == "www.google.com")
        #expect(url?.path == "/search")
    }

    @Test func localDetection() {
        #expect(BrowserAddressResolver.isLocal(URL(string: "http://localhost:3000")))
        #expect(BrowserAddressResolver.isLocal(URL(string: "http://127.0.0.1:3000")))
        #expect(!BrowserAddressResolver.isLocal(URL(string: "https://example.com")))
    }
}
