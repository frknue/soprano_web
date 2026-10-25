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

    @Test func windowsListsWindows() throws {
        let request = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "windows"])
        #expect(request?.command == "windows")
        #expect(request?.arguments == [])
        #expect(request?.windowIndex == nil)
    }

    @Test func windowFlagIsRemovedAndParsedNextToTab() throws {
        let request = try BrowserCommandRequest.parse(
            ["SopranoWeb", "browser", "--window", "2", "--tab", "3", "goto", "example.com"]
        )
        #expect(request?.command == "goto")
        #expect(request?.arguments == ["example.com"])
        #expect(request?.windowIndex == 2)
        #expect(request?.tabIndex == 3)

        let after = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "tabs", "--window", "1"])
        #expect(after?.command == "tabs")
        #expect(after?.windowIndex == 1)
        #expect(after?.arguments == [])
    }

    @Test func badWindowRejected() {
        #expect(throws: BrowserAutomationError.self) {
            _ = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "--window", "0", "tabs"])
        }
        #expect(throws: BrowserAutomationError.self) {
            _ = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "--window", "two", "tabs"])
        }
        #expect(throws: BrowserAutomationError.self) {
            _ = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "tabs", "--window"])
        }
    }

    @Test func newWindowTakesAnOptionalURL() throws {
        let bare = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "new-window"])
        #expect(bare?.command == "new-window")
        #expect(bare?.arguments == [])

        let withURL = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "new-window", "https://webkit.org"])
        #expect(withURL?.arguments == ["https://webkit.org"])
    }

    @Test func closeWindowTakesTheWindowFlagOrANumber() throws {
        let flagged = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "--window", "2", "close-window"])
        #expect(flagged?.command == "close-window")
        #expect(flagged?.windowIndex == 2)
        #expect(flagged?.arguments == [])

        let numbered = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "close-window", "3"])
        #expect(numbered?.arguments == ["3"])
        #expect(numbered?.windowIndex == nil)
    }

    @Test func helpDocumentsTheWindowCommands() {
        for usage in ["browser windows", "browser new-window [url]", "browser [--window n] close-window [n]", "[--window n] [--tab n] goto"] {
            #expect(BrowserCommand.help.contains(usage), "help is missing \(usage)")
        }
    }

    @Test func moveToWindowTakesAWindowNumberOrNew() throws {
        let numbered = try BrowserCommandRequest.parse(
            ["SopranoWeb", "browser", "--window", "1", "--tab", "3", "move-to-window", "2"]
        )
        #expect(numbered?.command == "move-to-window")
        #expect(numbered?.arguments == ["2"])
        #expect(numbered?.windowIndex == 1)
        #expect(numbered?.tabIndex == 3)

        let new = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "move-to-window", "new"])
        #expect(new?.arguments == ["new"])
        #expect(new?.windowIndex == nil)
        #expect(new?.tabIndex == nil)
    }

    @Test func moveToWindowRejectsAMissingOrBadDestination() {
        for destination in [[], ["0"], ["-1"], ["two"], ["2", "3"], ["New"]] {
            #expect(throws: BrowserAutomationError.self, "accepted \(destination)") {
                _ = try BrowserCommandRequest.parse(["SopranoWeb", "browser", "move-to-window"] + destination)
            }
        }
    }

    @Test func helpDocumentsMoveToWindow() {
        #expect(BrowserCommand.help.contains("browser [--window n] [--tab m] move-to-window <k|new>"))
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
            windowIndex: 3,
            timeout: 30
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["command"] as? String == "wait-for")
        #expect(object["arguments"] as? [String] == ["selector", "#a"])
        #expect(object["tab"] as? Int == 2)
        #expect(object["window"] as? Int == 3)
        #expect(object["timeout"] as? Double == 30)
        #expect(try JSONDecoder().decode(BrowserCommandRequest.self, from: data) == request)

        // A request from an older CLI has no window.
        let older = try JSONDecoder().decode(
            BrowserCommandRequest.self,
            from: Data(#"{"command":"tabs","arguments":[]}"#.utf8)
        )
        #expect(older.windowIndex == nil)
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
