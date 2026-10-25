@testable import SopranoWeb
import AppKit
import Testing

/// A private window's site decisions: the saved ones apply, new answers
/// stay in the window's overlay and never reach the file.
@MainActor
struct BrowserSitePermissionOverlayTests {
    private func savedStore() throws -> (BrowserSitePermissionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-overlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (BrowserSitePermissionStore(url: directory.appendingPathComponent("site-permissions.json")), directory)
    }

    @Test func overlayReadsSavedDecisionsAndKeepsNewOnesInMemory() throws {
        let (saved, directory) = try savedStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        saved.set(.camera, .allow, host: "meet.example")
        saved.set(.popups, .deny, host: "meet.example")
        let fileBefore = try Data(contentsOf: try #require(saved.url))

        let overlay = BrowserSitePermissionStore(overlaying: saved)
        #expect(overlay.decision(.camera, host: "Meet.Example") == .allow)

        overlay.set(.notifications, .allow, host: "meet.example")
        overlay.set(.popups, .allow, host: "meet.example")
        overlay.set(.externalApp(scheme: "zoommtg"), .allow, host: "zoom.example")
        #expect(overlay.decision(.notifications, host: "meet.example") == .allow)
        #expect(overlay.decision(.popups, host: "meet.example") == .allow)

        // Nothing reached the saved decisions or their file.
        #expect(saved.decision(.notifications, host: "meet.example") == nil)
        #expect(saved.decision(.popups, host: "meet.example") == .deny)
        #expect(saved.decision(.externalApp(scheme: "zoommtg"), host: "zoom.example") == nil)
        #expect(try Data(contentsOf: try #require(saved.url)) == fileBefore)
        let reloaded = BrowserSitePermissionStore(url: try #require(saved.url))
        #expect(reloaded.sites == ["meet.example": ["camera": "allow", "popups": "deny"]])

        // Clearing the overlay's answer shows the saved one again.
        overlay.set(.popups, nil, host: "meet.example")
        #expect(overlay.decision(.popups, host: "meet.example") == .deny)
    }

    @Test func overlayFollowsSavedChangesAndDiesWithTheWindow() throws {
        let (saved, directory) = try savedStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var overlay: BrowserSitePermissionStore? = BrowserSitePermissionStore(overlaying: saved)
        var changes = 0
        let observation = overlay?.changes.observe { changes += 1 }
        defer { observation?.cancel() }

        saved.set(.microphone, .deny, host: "call.example")
        #expect(changes == 1)
        #expect(overlay?.decision(.microphone, host: "call.example") == .deny)

        overlay?.set(.microphone, .allow, host: "call.example")
        #expect(changes == 2)
        weak var released = overlay
        overlay = nil
        #expect(released == nil)
        // A second private window starts from the saved decisions only.
        let next = BrowserSitePermissionStore(overlaying: saved)
        #expect(next.decision(.microphone, host: "call.example") == .deny)
    }
}
