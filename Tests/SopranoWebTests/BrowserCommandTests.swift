@testable import SopranoWeb
import AppKit
import Testing

struct BrowserCommandTests {
    @Test func nonBrowserInvocationIsNotClaimed() throws {
        #expect(try BrowserCommandRequest.parse(["SopranoWeb"]) == nil)
    }

    @Test func bareBrowserIsHelp() throws {
        let request = try BrowserCommandRequest.parse(["SopranoWeb", "browser"])
        #expect(request?.command == "help")
    }

    @Test func tabFlagIsRemovedAndParsed() throws {
        let request = try BrowserCommandRequest.parse(
            ["SopranoWeb", "browser", "--tab", "2", "goto", "example.com"]
        )
        #expect(request?.command == "goto")
        #expect(request?.arguments == ["example.com"])
        #expect(request?.tabIndex == 2)
    }

    @Test func screenshotPathIsResolvedAgainstTheCaller() throws {
        let request = try BrowserCommandRequest.parse(
            ["SopranoWeb", "browser", "screenshot", "shots/page.png"],
            environment: ["PWD": "/tmp/work"]
        )
        #expect(request?.arguments == ["/tmp/work/shots/page.png"])
    }

    @Test func absoluteScreenshotPathIsKept() throws {
        let request = try BrowserCommandRequest.parse(
            ["SopranoWeb", "browser", "screenshot", "/tmp/page.png"],
            environment: ["PWD": "/tmp/work"]
        )
        #expect(request?.arguments == ["/tmp/page.png"])
    }

    @Test func badTabRejected() {
        #expect(throws: BrowserAutomationError.self) {
            _ = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "--tab", "0", "url"])
        }
    }
}
