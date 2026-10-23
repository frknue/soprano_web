@testable import SopranoWeb
import AppKit
import Testing

/// Settings ▸ Websites rows and the capture indicator menu.
struct BrowserWebsitesTests {
    @Test func rowsAreSortedByHostWithDecisionsInAFixedOrder() {
        let rows = BrowserWebsiteRow.rows(from: [
            "zoom.example": ["externalApp:zoommtg": "allow", "popups": "deny"],
            "meet.example": [
                "notifications": "deny",
                "microphone": "allow",
                "camera": "allow",
                "geolocation": "allow",
            ],
            "empty.example": [:],
        ])
        #expect(rows.map(\.host) == ["meet.example", "zoom.example"])
        #expect(rows[0].summary == "Camera: Allow · Microphone: Allow · Notifications: Block · geolocation: Allow")
        #expect(rows[1].summary == "Pop-ups: Block · Open zoommtg links: Allow")
    }

    @Test func captureMenuOffersStopCameraMuteAndStop() {
        let both = BrowserCaptureStatus(camera: .active, microphone: .active)
        #expect(both.isVisible && both.isLive)
        #expect(both.symbolName == "video.fill")
        #expect(both.menuItems.map { $0?.action } == [.stopCamera, .muteMicrophone, nil, .stopAll])

        let mutedMic = BrowserCaptureStatus(camera: .off, microphone: .muted)
        #expect(mutedMic.symbolName == "mic.slash.fill")
        #expect(!mutedMic.isLive)
        #expect(mutedMic.menuItems.map { $0?.title } == ["Unmute Microphone", nil, "Stop Microphone"])

        #expect(BrowserCaptureStatus(camera: .active, microphone: .off).menuItems.map { $0?.action } == [.stopCamera])
        #expect(!BrowserCaptureStatus().isVisible)
    }
}
