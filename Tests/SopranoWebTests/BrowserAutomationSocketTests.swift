@testable import SopranoWeb
import AppKit
import Testing

struct BrowserAutomationSocketTests {
    /// Short temp paths: `sun_path` holds 103 bytes.
    private func temporarySocketPath() throws -> (directory: URL, path: String) {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("sw-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("a.sock").path)
    }

    private func send(
        _ request: BrowserCommandRequest,
        to path: String
    ) async throws -> BrowserAutomationResponse {
        try await Task.detached {
            try BrowserAutomationClient.send(request, to: path, timeout: 5)
        }.value
    }

    @Test func roundTripReachesTheHandlerAndReturnsItsReply() async throws {
        let (directory, path) = try temporarySocketPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try BrowserAutomationServer(path: path) { request, reply in
            let summary = "\(request.command) \(request.arguments.joined(separator: ",")) tab=\(request.tabIndex ?? 0)"
            reply(BrowserAutomationResponse(result: .success(summary)))
        }
        defer { server.stop() }

        let response = try await send(
            BrowserCommandRequest(command: "get", arguments: ["text", "h1"], tabIndex: 2),
            to: path
        )
        #expect(response == BrowserAutomationResponse(result: .success("get text,h1 tab=2")))

        let failing = try BrowserAutomationServer(path: path + "2") { _, reply in
            reply(BrowserAutomationResponse(result: .failure(BrowserAutomationError.javascript("boom"))))
        }
        defer { failing.stop() }
        let error = try await send(BrowserCommandRequest(command: "eval", arguments: ["x"], tabIndex: nil), to: path + "2")
        #expect(!error.ok)
        #expect(error.error == "boom")
    }

    @Test func socketIsUserOnly() throws {
        let (directory, path) = try temporarySocketPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try BrowserAutomationServer(path: path) { _, reply in
            reply(BrowserAutomationResponse(result: .success("")))
        }
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect(attributes[.type] as? FileAttributeType == .typeSocket)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func stopRemovesTheSocketFile() throws {
        let (directory, path) = try temporarySocketPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try BrowserAutomationServer(path: path) { _, reply in
            reply(BrowserAutomationResponse(result: .success("")))
        }
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: BrowserAutomationSocketError.notRunning) {
            _ = try BrowserAutomationClient.send(
                BrowserCommandRequest(command: "url", arguments: [], tabIndex: nil),
                to: path,
                timeout: 1
            )
        }
    }

    @Test func staleSocketFromACrashIsReplaced() async throws {
        let (directory, path) = try temporarySocketPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A bound socket whose process is gone: the file stays, nobody listens.
        var address = try UnixSocket.address(path)
        let stale = try UnixSocket.make()
        #expect(UnixSocket.withSockaddr(&address) { bind(stale, $0, $1) } == 0)
        close(stale)
        #expect(FileManager.default.fileExists(atPath: path))

        let server = try BrowserAutomationServer(path: path) { _, reply in
            reply(BrowserAutomationResponse(result: .success("fresh")))
        }
        defer { server.stop() }
        let response = try await send(BrowserCommandRequest(command: "url", arguments: [], tabIndex: nil), to: path)
        #expect(response.output == "fresh")
    }

    @Test func liveSocketOfAnotherInstanceIsLeftAlone() throws {
        let (directory, path) = try temporarySocketPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try BrowserAutomationServer(path: path) { _, reply in
            reply(BrowserAutomationResponse(result: .success("")))
        }
        defer { first.stop() }
        #expect(throws: BrowserAutomationSocketError.inUse(path)) {
            _ = try BrowserAutomationServer(path: path) { _, reply in
                reply(BrowserAutomationResponse(result: .success("")))
            }
        }
    }

    @Test func handlerThatNeverRepliesTimesOut() async throws {
        let (directory, path) = try temporarySocketPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try BrowserAutomationServer(path: path) { _, _ in }
        defer { server.stop() }
        await #expect(throws: BrowserAutomationSocketError.timedOut) {
            try await Task.detached {
                try BrowserAutomationClient.send(
                    BrowserCommandRequest(command: "url", arguments: [], tabIndex: nil),
                    to: path,
                    timeout: 0.5
                )
            }.value
        }
    }

    @Test func devAndReleaseUseSeparateSockets() throws {
        let base = URL(fileURLWithPath: "/Users/me/Library/Application Support", isDirectory: true)
        let release = BrowserAutomationSocket.path(for: BrowserAutomationSocket.release, supportBase: base)
        let dev = BrowserAutomationSocket.path(for: BrowserAutomationSocket.dev, supportBase: base)
        #expect(release == "/Users/me/Library/Application Support/Soprano Web/automation.sock")
        #expect(dev == "/Users/me/Library/Application Support/Soprano Web Dev/automation.sock")
    }

    @Test func longSupportPathFallsBackToTheUserTemporaryDirectory() {
        let base = URL(
            fileURLWithPath: "/Users/\(String(repeating: "n", count: 80))/Library/Application Support",
            isDirectory: true
        )
        let path = BrowserAutomationSocket.path(
            for: BrowserAutomationSocket.dev,
            supportBase: base,
            temporaryDirectory: "/var/folders/ab/cdef/T/"
        )
        #expect(path == "/var/folders/ab/cdef/T/soprano-web-dev.sock")

        let none = BrowserAutomationSocket.path(
            for: BrowserAutomationSocket.dev,
            supportBase: base,
            temporaryDirectory: "/" + String(repeating: "t", count: 100)
        )
        #expect(none == nil)
        #expect(BrowserAutomationSocket.maxPathLength == 103)
    }

    @Test func cliFromTheDevBundleTriesTheDevAppFirst() {
        #expect(
            BrowserAutomationSocket.candidateVariants(ownBundleIdentifier: "com.soprano.web.dev")
                == [BrowserAutomationSocket.dev, BrowserAutomationSocket.release]
        )
        #expect(
            BrowserAutomationSocket.candidateVariants(ownBundleIdentifier: nil)
                == [BrowserAutomationSocket.release, BrowserAutomationSocket.dev]
        )
    }
}
