@testable import SopranoWeb
import AppKit
import Testing

/// The app's side of the shim: only shimmed extensions and their own
/// stand-ins are answered, Chrome's notification semantics (generated ids,
/// replace, update merges, clear, per-extension ids), events held until the
/// background's port opens, and the socket messages a worker may send.
@MainActor
struct BrowserExtensionNativeHostTests {
    private let one = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
    private let other = "ddkjiahejlhfcafbddmgiahcphecmpfh"
    private let notifications = ["notifications"]

    @MainActor
    final class Recorder: BrowserExtensionNotificationPosting {
        var posted: [BrowserExtensionNotification] = []
        var removed: [String] = []
        var failure: Error?

        func post(_ notification: BrowserExtensionNotification) async throws {
            if let failure { throw failure }
            posted.append(notification)
        }

        func remove(identifiers: [String]) {
            removed += identifiers
        }

        func permissionLevel() async -> String { "granted" }
    }

    private func call(_ host: BrowserExtensionNativeHost, _ api: String, _ args: [Any], id: String? = nil, standIns: [String]? = nil) async -> [String: Any] {
        await host.answer(["api": api, "args": args], extensionID: id ?? one, standIns: standIns ?? notifications)
    }

    @Test func onlyShimmedExtensionsAndTheirStandInsAreAnswered() async {
        let host = BrowserExtensionNativeHost(poster: Recorder())
        let unshimmed = await call(host, "notifications.getAll", [], standIns: [])
        #expect((unshimmed["error"] as? String)?.contains("No native messaging host") == true)
        let otherStandIn = await call(host, "clients.pages", [], standIns: ["notifications"])
        #expect((otherStandIn["error"] as? String)?.contains("not available") == true)
        let unknown = await call(host, "notifications.explode", [])
        #expect(unknown["error"] as? String == "notifications.explode is not supported.")
        let notAMessage = await host.answer("hello", extensionID: one, standIns: notifications)
        #expect(notAMessage["error"] as? String == "The message names no API.")
        let badArgs = await host.answer(["api": "notifications.clear", "args": "x"], extensionID: one, standIns: notifications)
        #expect(badArgs["error"] as? String == "notifications.clear: arguments must be a list.")
        let wrongType = await call(host, "notifications.clear", [42])
        #expect(wrongType["error"] as? String == "notifications.clear: argument 1 must be a string.")
    }

    @Test func createGeneratesIdsAndReplacesAnIdInUse() async throws {
        let recorder = Recorder()
        let host = BrowserExtensionNativeHost(poster: recorder)
        let first = await call(host, "notifications.create", ["", ["title": "A", "message": "a"]])
        let second = await call(host, "notifications.create", [])
        let firstID = try #require(first["value"] as? String)
        let secondID = try #require(second["value"] as? String)
        #expect(!firstID.isEmpty && firstID != secondID)
        _ = await call(host, "notifications.create", ["saved", ["title": "Login saved", "message": "x", "buttons": [["title": "Open"], ["title": "Edit"], ["title": "Third"]]]])
        _ = await call(host, "notifications.create", ["saved", ["title": "Again"]])
        #expect(host.notifications[one]?.count == 3)
        #expect(recorder.posted.filter { $0.notificationID == "saved" }.map(\.identifier) == [
            "extension/\(one)/saved", "extension/\(one)/saved",
        ])
        #expect(recorder.posted[2].buttons == ["Open", "Edit"])
    }

    @Test func updateMergesOnlyLiveOnesAndClearReportsWhetherItWasLive() async {
        let recorder = Recorder()
        let host = BrowserExtensionNativeHost(poster: recorder)
        let missing = await call(host, "notifications.update", ["nope", ["title": "x"]])
        #expect(missing["value"] as? Bool == false)
        #expect(recorder.posted.isEmpty)
        _ = await call(host, "notifications.create", ["n", ["title": "Title", "message": "old", "contextMessage": "ctx"]])
        let updated = await call(host, "notifications.update", ["n", ["message": "new"]])
        #expect(updated["value"] as? Bool == true)
        #expect(recorder.posted.last.map { [$0.title, $0.body, $0.subtitle] } == ["Title", "new", "ctx"])
        #expect((await call(host, "notifications.clear", ["n"]))["value"] as? Bool == true)
        #expect((await call(host, "notifications.clear", ["n"]))["value"] as? Bool == false)
        #expect(recorder.removed == ["extension/\(one)/n"])
    }

    @Test func extensionsNeverSeeEachOthersNotifications() async {
        let recorder = Recorder()
        let host = BrowserExtensionNativeHost(poster: recorder)
        _ = await call(host, "notifications.create", ["same", ["title": "1"]])
        _ = await call(host, "notifications.create", ["same", ["title": "2"]], id: other)
        #expect(Set(recorder.posted.map(\.identifier)).count == 2)
        #expect((await call(host, "notifications.clear", ["same"], id: other))["value"] as? Bool == true)
        let all = await call(host, "notifications.getAll", [])
        #expect(all["value"] as? [String: Bool] == ["same": true])
        host.forget(one)
        #expect(host.notifications.isEmpty)
        #expect(recorder.removed == ["extension/\(other)/same", "extension/\(one)/same"])
    }

    @Test func aFailedPostIsNotKeptAndSaysWhy() async {
        let recorder = Recorder()
        recorder.failure = BrowserNotificationCenter.PostError.notAuthorized
        let host = BrowserExtensionNativeHost(poster: recorder)
        let reply = await call(host, "notifications.create", ["n", ["title": "x"]])
        #expect(reply["error"] as? String != nil)
        #expect(host.notifications.isEmpty)
    }

    @Test func listsProgressAndItemsBecomeTheBody() {
        let notification = BrowserExtensionNotification(extensionID: one, notificationID: "n", options: [
            "title": "T", "message": "m", "items": [["title": "a", "message": "1"], ["title": "", "message": "2"], "bad"],
            "progress": 140, "silent": true,
        ])
        #expect(notification.body == "m\na: 1\n2\n100 %")
        #expect(notification.silent)
    }

    @Test func eventsWaitForThePortInOrderAndWakeTheBackground() {
        let host = BrowserExtensionNativeHost(poster: Recorder())
        var woken: [String] = []
        host.wake = { woken.append($0) }
        host.respond(.clicked, extensionID: one, notificationID: "a")
        host.respond(.button(1), extensionID: one, notificationID: "a")
        host.respond(.clicked, extensionID: other, notificationID: "b")
        #expect(woken == [one, one, other])
        var received: [[String: Any]] = []
        host.attach(extensionID: one) { received.append($0) }
        #expect(received.map { $0["event"] as? String } == ["notifications.onClicked", "notifications.onButtonClicked"])
        #expect(received[1]["args"] as? [AnyHashable] == ["a", 1])
        #expect(host.pendingEvents[one] == nil)
        #expect(host.pendingEvents[other]?.count == 1)
        host.respond(.closed(byUser: true), extensionID: one, notificationID: "a")
        #expect(received.count == 3)
        host.detach(extensionID: one)
        for index in 0..<(BrowserExtensionNativeHost.maximumPendingEvents + 5) {
            host.respond(.clicked, extensionID: one, notificationID: "\(index)")
        }
        #expect(host.pendingEvents[one]?.count == BrowserExtensionNativeHost.maximumPendingEvents)
        #expect((host.pendingEvents[one]?.first?["args"] as? [String])?.first == "5")
        host.forget(one)
        #expect(host.pendingEvents[one] == nil)
    }

    @Test func socketMessagesOpenOnlyWebSocketAddresses() {
        #expect(BrowserExtensionSocket.request(from: ["open": "wss://b5n.1password.com/ws", "protocols": ["a", 3], "userAgent": "UA"])
            == .open(url: URL(string: "wss://b5n.1password.com/ws")!, protocols: ["a"], userAgent: "UA"))
        for address in ["https://example.com", "file:///etc/passwd", "ws://user:pw@example.com/", "ws:///nohost", "javascript:alert(1)"] {
            #expect(BrowserExtensionSocket.request(from: ["open": address]) == nil, "\(address)")
        }
        #expect(BrowserExtensionSocket.request(from: ["send": "hi"]) == .send("hi"))
        #expect(BrowserExtensionSocket.request(from: ["sendBinary": "AAE="]) == .sendBinary(Data([0, 1])))
        #expect(BrowserExtensionSocket.request(from: ["sendBinary": "%%%"]) == nil)
        #expect(BrowserExtensionSocket.request(from: ["close": 1000]) == .close(code: 1000, reason: ""))
        #expect(BrowserExtensionSocket.request(from: "nonsense") == nil)
    }
}
