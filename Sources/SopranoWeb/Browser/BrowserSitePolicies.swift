import WebKit

// MARK: - Autoplay

/// Settings ▸ Autoplay, applied to tabs opened after the change.
enum AutoplayPolicy: String, Codable, CaseIterable, Sendable {
    case allowAll
    case stopMediaWithSound
    case never

    var name: String {
        switch self {
        case .allowAll: "Allow All"
        case .stopMediaWithSound: "Stop Media with Sound"
        case .never: "Never Autoplay"
        }
    }

    /// `WKWebViewConfiguration.mediaTypesRequiringUserActionForPlayback`.
    var mediaTypesRequiringUserAction: WKAudiovisualMediaTypes {
        switch self {
        case .allowAll: []
        case .stopMediaWithSound: .audio
        case .never: .all
        }
    }
}

// MARK: - Camera and microphone

/// What a page asked to capture, as the site permissions it needs.
enum MediaCaptureRequest: Equatable, Sendable {
    case camera
    case microphone
    case cameraAndMicrophone

    init(_ type: WKMediaCaptureType) {
        switch type {
        case .camera: self = .camera
        case .microphone: self = .microphone
        case .cameraAndMicrophone: self = .cameraAndMicrophone
        @unknown default: self = .cameraAndMicrophone
        }
    }

    var permissions: [SitePermission] {
        switch self {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        }
    }

    var name: String {
        switch self {
        case .camera: "camera"
        case .microphone: "microphone"
        case .cameraAndMicrophone: "camera and microphone"
        }
    }

    /// The remembered answer for the whole request: allowed only when every
    /// permission it needs is allowed, denied as soon as one is denied, and
    /// nil (ask) otherwise.
    @MainActor
    func rememberedDecision(
        in store: BrowserSitePermissionStore,
        host: String
    ) -> SitePermissionDecision? {
        let decisions = permissions.map { store.decision($0, host: host) }
        if decisions.contains(.deny) {
            return .deny
        }
        if decisions.allSatisfy({ $0 == .allow }) {
            return .allow
        }
        return nil
    }
}

extension BrowserSitePermissionStore {
    /// The host key for a security origin, matching `key(for:)` on URLs.
    static func key(for origin: WKSecurityOrigin) -> String? {
        if origin.protocol.lowercased() == "file" {
            return "file"
        }
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        return key(for: components.url)
    }
}

// MARK: - Web notifications

/// The value of the shim's `Notification.permission` for a host.
enum NotificationPermissionState: String, Sendable {
    case granted
    case denied
    case `default`

    /// Remembered decisions win; without one, a site may ask only while
    /// Settings ▸ "Allow websites to ask to send notifications" is on.
    init(decision: SitePermissionDecision?, askingAllowed: Bool) {
        switch decision {
        case .allow: self = .granted
        case .deny: self = .denied
        case nil: self = askingAllowed ? .default : .denied
        }
    }

    /// Every remembered notification decision as host key → state, the map
    /// the page shim reads at document start.
    @MainActor
    static func states(in store: BrowserSitePermissionStore) -> [String: String] {
        var states: [String: String] = [:]
        for host in store.sites.keys {
            guard let decision = store.decision(.notifications, host: host) else { continue }
            states[host] = NotificationPermissionState(decision: decision, askingAllowed: true).rawValue
        }
        return states
    }
}

// MARK: - Audio

/// Whether a tab plays audible media, from the per-frame reports of the
/// media script. A frame reports only its own elements; the tab is audible
/// while any live frame is.
struct BrowserTabAudioState: Equatable, Sendable {
    private(set) var audibleFrames: Set<String> = []

    var isPlayingAudio: Bool {
        !audibleFrames.isEmpty
    }

    /// Records one frame's report; `gone` means the frame's document went
    /// away (it reports `pagehide`).
    mutating func report(frame: String, audible: Bool, gone: Bool = false) {
        if audible, !gone {
            audibleFrames.insert(frame)
        } else {
            audibleFrames.remove(frame)
        }
    }

    /// A new main document: every earlier frame is gone.
    mutating func reset() {
        audibleFrames.removeAll()
    }
}

/// Per-tab media bookkeeping: the audio reducer and the frames that run the
/// media script, so a mute toggle reaches every frame of the current page.
@MainActor
final class BrowserTabMedia {
    var audio = BrowserTabAudioState()
    /// Frame token (minted by the media script per document) → the frame.
    var frames: [String: WKFrameInfo] = [:]
}

// MARK: - Settings ▸ Websites

/// The rows of Settings ▸ Websites: one per host, its decisions in a fixed
/// order (camera, microphone, notifications, pop-ups, zoom, keep awake,
/// external apps, then anything this build does not know by name).
struct BrowserWebsiteRow: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let label: String
        let decision: String
    }

    let host: String
    let entries: [Entry]

    var summary: String {
        entries.map { "\($0.label): \($0.decision)" }.joined(separator: " · ")
    }

    static func rows(from sites: [String: [String: String]]) -> [BrowserWebsiteRow] {
        sites.keys.sorted().compactMap { host in
            let decisions = (sites[host] ?? [:]).filter { $0.value != BrowserSitePermissionStore.forgotten }
            let entries = decisions.keys
                .sorted { order($0) == order($1) ? $0 < $1 : order($0) < order($1) }
                .map { Entry(label: label(for: $0), decision: valueName(decisions[$0] ?? "", for: $0)) }
            return entries.isEmpty ? nil : BrowserWebsiteRow(host: host, entries: entries)
        }
    }

    private static let known: [String] = [
        SitePermission.camera.rawValue,
        SitePermission.microphone.rawValue,
        SitePermission.notifications.rawValue,
        SitePermission.popups.rawValue,
        SitePermission.zoom.rawValue,
        SitePermission.keepAwake.rawValue,
    ]
    private static let externalPrefix = "externalApp:"

    private static func order(_ raw: String) -> Int {
        if let index = known.firstIndex(of: raw) {
            return index
        }
        return raw.hasPrefix(externalPrefix) ? known.count : known.count + 1
    }

    private static func label(for raw: String) -> String {
        switch raw {
        case SitePermission.camera.rawValue: return "Camera"
        case SitePermission.microphone.rawValue: return "Microphone"
        case SitePermission.notifications.rawValue: return "Notifications"
        case SitePermission.popups.rawValue: return "Pop-ups"
        case SitePermission.zoom.rawValue: return "Zoom"
        case SitePermission.keepAwake.rawValue: return "Keep awake"
        default:
            if raw.hasPrefix(externalPrefix) {
                return "Open \(raw.dropFirst(externalPrefix.count)) links"
            }
            return raw
        }
    }

    private static func valueName(_ raw: String, for key: String) -> String {
        if key == SitePermission.zoom.rawValue, let zoom = Double(raw).flatMap(BrowserZoom.validated) {
            return BrowserZoom.percent(zoom)
        }
        switch SitePermissionDecision(rawValue: raw) {
        case .allow: return key == SitePermission.keepAwake.rawValue ? "On" : "Allow"
        case .deny: return "Block"
        case nil: return raw
        }
    }
}
