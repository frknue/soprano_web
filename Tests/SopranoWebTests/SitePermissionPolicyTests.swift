@testable import SopranoWeb
import AppKit
import Testing
import WebKit

/// Camera/microphone memory, autoplay mapping, the shim's notification
/// state, and the per-tab audio reducer.
@MainActor
struct SitePermissionPolicyTests {
    private func store() -> (BrowserSitePermissionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebPolicies-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (BrowserSitePermissionStore(url: directory.appendingPathComponent("site-permissions.json")), directory)
    }

    @Test func cameraAndMicrophoneNeedBothAllowedAndOneDenialDenies() {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = "meet.example"
        #expect(MediaCaptureRequest.camera.rememberedDecision(in: store, host: host) == nil)

        store.set(.camera, .allow, host: host)
        #expect(MediaCaptureRequest.camera.rememberedDecision(in: store, host: host) == .allow)
        #expect(MediaCaptureRequest.microphone.rememberedDecision(in: store, host: host) == nil)
        // Only the camera is remembered: a camera+mic request still asks.
        #expect(MediaCaptureRequest.cameraAndMicrophone.rememberedDecision(in: store, host: host) == nil)

        store.set(.microphone, .allow, host: host)
        #expect(MediaCaptureRequest.cameraAndMicrophone.rememberedDecision(in: store, host: host) == .allow)

        store.set(.microphone, .deny, host: host)
        #expect(MediaCaptureRequest.cameraAndMicrophone.rememberedDecision(in: store, host: host) == .deny)
        #expect(MediaCaptureRequest.camera.rememberedDecision(in: store, host: host) == .allow)
        // Decisions are per host; the lookup normalizes the key.
        #expect(MediaCaptureRequest.camera.rememberedDecision(in: store, host: "MEET.example.") == .allow)
        #expect(MediaCaptureRequest.camera.rememberedDecision(in: store, host: "other.example") == nil)
    }

    @Test func captureRequestsMapWebKitTypesToTheirPermissions() {
        #expect(MediaCaptureRequest(.camera).permissions == [.camera])
        #expect(MediaCaptureRequest(.microphone).permissions == [.microphone])
        #expect(MediaCaptureRequest(.cameraAndMicrophone).permissions == [.camera, .microphone])
    }

    @Test func autoplayPoliciesMapToUserActionMediaTypes() {
        #expect(AutoplayPolicy.allowAll.mediaTypesRequiringUserAction == [])
        #expect(AutoplayPolicy.stopMediaWithSound.mediaTypesRequiringUserAction == .audio)
        #expect(AutoplayPolicy.never.mediaTypesRequiringUserAction == .all)
        #expect(BrowserSettings.default.autoplay == .stopMediaWithSound)
    }

    @Test func permissionSettingsDecodeKeyByKey() throws {
        let decoded = try JSONDecoder().decode(
            BrowserSettings.self,
            from: Data(#"{"autoplay": "never", "allowsNotificationRequests": false}"#.utf8)
        )
        #expect(decoded.autoplay == .never)
        #expect(!decoded.allowsNotificationRequests)

        let unknown = try JSONDecoder().decode(
            BrowserSettings.self,
            from: Data(#"{"autoplay": "sometimes", "restoreSession": false}"#.utf8)
        )
        #expect(unknown.autoplay == .stopMediaWithSound)
        #expect(unknown.allowsNotificationRequests)
        #expect(!unknown.restoreSession)
    }

    @Test func notificationPermissionFollowsDecisionsAndTheAskSetting() {
        #expect(NotificationPermissionState(decision: .allow, askingAllowed: false) == .granted)
        #expect(NotificationPermissionState(decision: .deny, askingAllowed: true) == .denied)
        #expect(NotificationPermissionState(decision: nil, askingAllowed: true) == .default)
        #expect(NotificationPermissionState(decision: nil, askingAllowed: false) == .denied)
    }

    @Test func notificationStatesListOnlyRememberedNotificationDecisions() {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.set(.notifications, .allow, host: "chat.example")
        store.set(.notifications, .deny, host: "news.example")
        store.set(.camera, .allow, host: "meet.example")
        #expect(NotificationPermissionState.states(in: store) == [
            "chat.example": "granted",
            "news.example": "denied",
        ])
    }

    @Test func tabPlaysAudioWhileAnyLiveFrameIsAudible() {
        var audio = BrowserTabAudioState()
        #expect(!audio.isPlayingAudio)
        audio.report(frame: "main", audible: true)
        audio.report(frame: "embed", audible: true)
        audio.report(frame: "main", audible: false)
        #expect(audio.isPlayingAudio)
        // An iframe that navigates away reports `gone` from `pagehide`.
        audio.report(frame: "embed", audible: true, gone: true)
        #expect(!audio.isPlayingAudio)

        audio.report(frame: "embed", audible: true)
        audio.reset()
        #expect(!audio.isPlayingAudio)
    }
}
