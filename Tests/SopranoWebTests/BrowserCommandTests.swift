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

    @Test func waitForLoadDefaultsToTenSeconds() throws {
        let request = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "wait-for-load"])
        #expect(request?.timeout == 10)
        #expect(request?.arguments == [])
    }

    @Test func timeoutFlagIsParsedAndRemoved() throws {
        let request = try BrowserCommandRequest.parse(
            ["SopranoWeb", "browser", "--tab", "3", "wait-for-load", "--timeout", "45"]
        )
        #expect(request?.timeout == 45)
        #expect(request?.arguments == [])
        #expect(request?.tabIndex == 3)
    }

    @Test func timeoutAboveTheCapIsRejected() {
        #expect(throws: BrowserAutomationError.self) {
            _ = try BrowserCommandRequest.parse(
                ["SopranoWeb", "browser", "wait-for-load", "--timeout", "121"]
            )
        }
        #expect(throws: BrowserAutomationError.self) {
            _ = try BrowserCommandRequest.parse(
                ["SopranoWeb", "browser", "wait-for", "url", "x", "--timeout", "0"]
            )
        }
        #expect(throws: BrowserAutomationError.self) {
            _ = try BrowserCommandRequest.parse(
                ["SopranoWeb", "browser", "wait-for-load", "--timeout"]
            )
        }
    }

    @Test func waitForTakesAKindAndAValue() throws {
        let selector = try BrowserCommandRequest.parse(
            ["SopranoWeb", "browser", "wait-for", "selector", "#results li", "--timeout", "2.5"]
        )
        #expect(selector?.command == "wait-for")
        #expect(selector?.arguments == ["selector", "#results li"])
        #expect(selector?.timeout == 2.5)

        let text = try BrowserCommandRequest.parse(
            ["SopranoWeb", "browser", "wait-for", "text", "Order", "placed"]
        )
        #expect(text?.arguments == ["text", "Order placed"])
        #expect(text?.timeout == 10)

        let url = try BrowserCommandRequest.parse(
            ["SopranoWeb", "browser", "wait-for", "url", "/checkout"]
        )
        #expect(url?.arguments == ["url", "/checkout"])
    }

    @Test func waitForRejectsUnknownKindsAndMissingValues() {
        #expect(throws: BrowserAutomationError.self) {
            _ = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "wait-for", "title", "x"])
        }
        #expect(throws: BrowserAutomationError.self) {
            _ = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "wait-for", "selector"])
        }
    }

    @Test func timeoutBelongsOnlyToWaits() throws {
        let request = try BrowserCommandRequest.parse(
            ["SopranoWeb", "browser", "fill", "#q", "--timeout", "5"]
        )
        #expect(request?.arguments == ["#q", "--timeout", "5"])
        #expect(request?.timeout == nil)
    }

    @Test func cliTimeoutFollowsTheWait() throws {
        let wait = try #require(try BrowserCommandRequest.parse(
            ["SopranoWeb", "browser", "wait-for", "text", "done", "--timeout", "90"]
        ))
        #expect(wait.serverTimeout > 90)
        #expect(wait.clientTimeout > wait.serverTimeout)

        let eval = try #require(try BrowserCommandRequest.parse(
            ["SopranoWeb", "browser", "eval", "1"]
        ))
        #expect(eval.clientTimeout > eval.serverTimeout)
        #expect(eval.serverTimeout == BrowserCommandRequest.commandTimeout)
    }

    @Test func requestEncodesAsJSON() throws {
        let request = BrowserCommandRequest(
            command: "wait-for",
            arguments: ["selector", "#a"],
            tabIndex: 2,
            timeout: 30
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["command"] as? String == "wait-for")
        #expect(object["arguments"] as? [String] == ["selector", "#a"])
        #expect(object["tab"] as? Int == 2)
        #expect(object["timeout"] as? Double == 30)
        #expect(try JSONDecoder().decode(BrowserCommandRequest.self, from: data) == request)
    }

    @Test func responseCarriesOutputOrError() throws {
        let success = BrowserAutomationResponse(result: .success("Example Domain"))
        #expect(success.ok)
        #expect(success.output == "Example Domain")
        #expect(success.error == nil)

        let failure = BrowserAutomationResponse(
            result: .failure(BrowserAutomationError.javascript("ReferenceError: Can't find variable: x"))
        )
        #expect(!failure.ok)
        #expect(failure.error == "ReferenceError: Can't find variable: x")

        let data = try JSONEncoder().encode(failure)
        #expect(try JSONDecoder().decode(BrowserAutomationResponse.self, from: data) == failure)
    }

    @Test func evalTrimsTrailingSemicolonsForTheExpressionForm() {
        #expect(BrowserAutomationEval.expression("document.title;  \n") == "document.title")
        #expect(BrowserAutomationEval.expression("a; b") == "a; b")
    }
}
