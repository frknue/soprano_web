@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserZoomTests {
    @Test func stepsGoFromFiftyToThreeHundredPercentLikeSafari() {
        #expect(BrowserZoom.steps.map(BrowserZoom.percent) == [
            "50%", "75%", "85%", "100%", "115%", "125%", "150%", "175%", "200%", "250%", "300%",
        ])
    }

    @Test func zoomInAndOutMoveOneStepAndStopAtTheEnds() {
        #expect(BrowserZoom.zoomedIn(from: 1) == 1.15)
        #expect(BrowserZoom.zoomedIn(from: 1.15) == 1.25)
        #expect(BrowserZoom.zoomedOut(from: 1) == 0.85)
        #expect(BrowserZoom.zoomedOut(from: 0.85) == 0.75)
        #expect(BrowserZoom.zoomedIn(from: 3) == 3)
        #expect(BrowserZoom.zoomedOut(from: 0.5) == 0.5)
    }

    @Test func aZoomBetweenStepsMovesToTheNextStepInThatDirection() {
        // Stage 1's 10% steps (1.1, 1.3) and pinch zoom land between steps.
        #expect(BrowserZoom.zoomedIn(from: 1.1) == 1.15)
        #expect(BrowserZoom.zoomedOut(from: 1.1) == 1)
        #expect(BrowserZoom.zoomedIn(from: 1.3) == 1.5)
        // Floating-point noise around a step is that step.
        #expect(BrowserZoom.zoomedIn(from: 1.2500000001) == 1.5)
        #expect(BrowserZoom.zoomedOut(from: 1.2499999999) == 1.15)
    }

    @Test func validatedAndNearestStep() {
        #expect(BrowserZoom.validated(1.25) == 1.25)
        #expect(BrowserZoom.validated(0.25) == nil)
        #expect(BrowserZoom.validated(4) == nil)
        #expect(BrowserZoom.validated(.nan) == nil)
        #expect(BrowserZoom.validated(.infinity) == nil)
        #expect(BrowserZoom.nearestStep(1.1) == 1.15)
        #expect(BrowserZoom.nearestStep(1.24) == 1.25)
        #expect(BrowserZoom.nearestStep(2.9) == 3)
    }

    @Test func defaultPageZoomSettingSnapsToAStepAndFallsBack() throws {
        #expect(BrowserSettings.default.defaultZoom == 1)
        func decode(_ json: String) throws -> BrowserSettings {
            try JSONDecoder().decode(BrowserSettings.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{ "defaultZoom": 1.25 }"#).defaultZoom == 1.25)
        #expect(try decode(#"{ "defaultZoom": 1.1 }"#).defaultZoom == 1.15)
        #expect(try decode(#"{ "defaultZoom": 9, "homepage": "https://example.com" }"#).defaultZoom == 1)
        #expect(try decode(#"{ "defaultZoom": "big", "homepage": "https://example.com" }"#).homepage
            == "https://example.com")
    }

    @Test func siteKeysArePerHostAndOnlyForPagesWithASite() {
        #expect(BrowserSitePermissionStore.siteKey(for: URL(string: "https://Docs.Example.com/a")) == "docs.example.com")
        // Per host, not per registrable domain.
        #expect(BrowserSitePermissionStore.siteKey(for: URL(string: "https://example.com/"))
            != BrowserSitePermissionStore.siteKey(for: URL(string: "https://docs.example.com/")))
        #expect(BrowserSitePermissionStore.siteKey(for: URL(string: "http://127.0.0.1:8080/x")) == "127.0.0.1")
        #expect(BrowserSitePermissionStore.siteKey(for: URL(fileURLWithPath: "/tmp/a.html")) == "file")
        #expect(BrowserSitePermissionStore.siteKey(for: BrowserStartPageSchemeHandler.url) == nil)
        #expect(BrowserSitePermissionStore.siteKey(for: URL(string: "about:blank")) == nil)
        #expect(BrowserSitePermissionStore.siteKey(for: URL(string: "data:text/html,hi")) == nil)
        #expect(BrowserSitePermissionStore.siteKey(for: nil) == nil)
    }
}
