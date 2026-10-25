@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserObserversTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebObservers-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("spaces.json")
    }

    @Test func everyWindowHearsAStoreChangeUntilItUnsubscribes() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BrowserSpaceStore(url: url, profiles: [.defaultProfile])
        let space = try #require(store.firstSpace(ofProfile: BrowserProfile.defaultID)).id
        var first = 0
        var second = 0
        let firstWindow = store.changes.observe { first += 1 }
        let secondWindow = store.changes.observe { second += 1 }

        let example = try #require(store.addPin(url: "https://example.com", title: "Example", inSpace: space))
        #expect(first == 1)
        #expect(second == 1)

        firstWindow.cancel()
        store.addPin(url: "https://webkit.org", title: "WebKit", inSpace: space)
        #expect(first == 1)
        #expect(second == 2)
        #expect(store.changes.count == 1)

        secondWindow.cancel()
        store.removePin(example.id, inSpace: space)
        #expect(second == 2)
        #expect(store.changes.count == 0)
    }

    @Test func releasingTheTokenUnsubscribes() {
        let observers = BrowserObservers<BrowserSettings>()
        var seen: [SearchEngine] = []
        var token: BrowserObservation? = observers.observe { seen.append($0.searchEngine) }
        observers.notify(BrowserSettings(searchEngine: .google))
        #expect(token != nil)
        token = nil
        observers.notify(BrowserSettings(searchEngine: .bing))
        #expect(seen == [.google])
        #expect(observers.count == 0)
    }

    @Test func observersRunInSubscriptionOrderAndMayCancelWhileNotified() {
        let observers = BrowserObservers<Int>()
        var calls: [String] = []
        var second: BrowserObservation?
        let first = observers.observe { value in
            calls.append("first \(value)")
            second?.cancel()
        }
        second = observers.observe { value in calls.append("second \(value)") }
        observers.notify(1)
        observers.notify(2)
        #expect(calls == ["first 1", "first 2"])
        first.cancel()
    }
}
