@testable import SopranoWeb
import AppKit
import Testing

struct BrowserUserAgentTests {
    @Test func usesSafarisMajorAndMinorVersion() {
        #expect(BrowserUserAgent.applicationName(safariVersion: "26.0.1") == "Version/26.0 Safari/605.1.15")
        #expect(BrowserUserAgent.applicationName(safariVersion: "18.4") == "Version/18.4 Safari/605.1.15")
        #expect(BrowserUserAgent.applicationName(safariVersion: "27") == "Version/27.0 Safari/605.1.15")
    }

    @Test func fallsBackWhenTheVersionIsMissingOrMalformed() {
        let fallback = "Version/\(BrowserUserAgent.fallbackVersion) Safari/605.1.15"
        #expect(BrowserUserAgent.applicationName(safariVersion: nil) == fallback)
        #expect(BrowserUserAgent.applicationName(safariVersion: "") == fallback)
        #expect(BrowserUserAgent.applicationName(safariVersion: "beta") == fallback)
        #expect(BrowserUserAgent.applicationName(safariVersion: "26.x") == "Version/26.0 Safari/605.1.15")
    }
}
