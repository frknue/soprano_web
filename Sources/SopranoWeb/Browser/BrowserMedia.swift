import AppKit

// MARK: - Reports

/// One frame's `mediaInfo` report from `BrowserMediaScripts.reporter`
/// (isolated world): what plays there and the page's Media Session.
struct BrowserMediaReport: Equatable, Sendable {
    /// The frame token the script minted for its document.
    var frame: String
    /// A media element plays (not paused, not ended).
    var isPlaying = false
    /// A playing `<video>` with a picture, at least 160×90 CSS px and
    /// mostly inside the viewport.
    var hasVisibleVideo = false
    /// A playing element is audible (not muted, volume above 0).
    var isAudible = false
    /// An element played since the document loaded and has not ended or
    /// been emptied: the controls keep showing it while paused.
    var hasMedia = false
    /// The document left (`pagehide`).
    var isGone = false
    /// `navigator.mediaSession.metadata`, empty strings when unset.
    var title = ""
    var artist = ""
    var album = ""
    /// The largest artwork's address (http(s) or `data:image/`), or empty.
    var artwork = ""
    /// `navigator.mediaSession.playbackState`.
    var sessionState: BrowserMediaSessionState = .none

    static let maxText = 300
    static let maxArtworkLength = 64 * 1024

    init(frame: String) {
        self.frame = frame
    }

    /// Reads a message body; nil when the frame token is missing or bad.
    /// Text is trimmed and capped; an artwork that isn't http(s) or a
    /// `data:image/` URL (or is too long) is dropped.
    init?(body: [String: Any]) {
        guard let frame = body["frame"] as? String, !frame.isEmpty, frame.count <= 64 else { return nil }
        self.frame = frame
        isPlaying = body["playing"] as? Bool ?? false
        hasVisibleVideo = isPlaying && (body["video"] as? Bool ?? false)
        isAudible = isPlaying && (body["audible"] as? Bool ?? false)
        isGone = body["gone"] as? Bool ?? false
        hasMedia = !isGone && (isPlaying || (body["media"] as? Bool ?? false))
        title = Self.text(body["title"])
        artist = Self.text(body["artist"])
        album = Self.text(body["album"])
        artwork = Self.artwork(body["artwork"])
        sessionState = (body["state"] as? String).flatMap(BrowserMediaSessionState.init(rawValue:)) ?? .none
    }

    private static func text(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.count > maxText ? String(trimmed.prefix(maxText)) : trimmed
    }

    private static func artwork(_ value: Any?) -> String {
        guard let string = value as? String, !string.isEmpty, string.utf8.count <= maxArtworkLength else { return "" }
        let lower = string.prefix(16).lowercased()
        if lower.hasPrefix("data:image/") { return string }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil
        else { return "" }
        return string
    }

    /// The Media Session metadata says what plays.
    var hasSessionMetadata: Bool {
        !title.isEmpty || !artist.isEmpty
    }
}

/// `MediaSessionPlaybackState`.
enum BrowserMediaSessionState: String, Equatable, Sendable {
    case none
    case paused
    case playing
}

/// A tab's media, from its frames' latest reports. The main frame's
/// report wins when it has media; otherwise the most recent frame that
/// plays (an embedded player).
struct BrowserTabMediaInfo: Equatable, Sendable {
    private(set) var reports: [String: BrowserMediaReport] = [:]
    private(set) var mainFrame: String?
    /// Frame tokens, most recently reported last.
    private var order: [String] = []

    mutating func update(_ report: BrowserMediaReport, isMainFrame: Bool) {
        order.removeAll { $0 == report.frame }
        if report.isGone {
            reports[report.frame] = nil
            if mainFrame == report.frame { mainFrame = nil }
            return
        }
        if isMainFrame, mainFrame != report.frame {
            // A new main document (`handleMediaFrame` already dropped the
            // old document's frames).
            if let old = mainFrame { reports[old] = nil }
            mainFrame = report.frame
        }
        reports[report.frame] = report
        order.append(report.frame)
    }

    mutating func reset() {
        self = BrowserTabMediaInfo()
    }

    /// The report the controls show.
    var current: BrowserMediaReport? {
        if let mainFrame, let main = reports[mainFrame], main.hasMedia || main.hasSessionMetadata {
            return main
        }
        let recent = order.reversed().compactMap { reports[$0] }
        return recent.first { $0.isPlaying } ?? recent.first { $0.hasMedia }
    }

    var isPlaying: Bool { reports.values.contains { $0.isPlaying } }
    var hasMedia: Bool { reports.values.contains { $0.hasMedia } }
    /// Only the main frame's video fills a Mini Player (a frame's video
    /// would fill only its frame).
    var hasVisibleVideo: Bool {
        mainFrame.flatMap { reports[$0] }?.hasVisibleVideo ?? false
    }
}

// MARK: - Mini Player rule

/// What the automatic Mini Player decides on for one tab leaving the screen.
struct BrowserMiniPlayerCandidate: Equatable, Sendable {
    /// Settings ▸ General ▸ Mini Player.
    var isEnabled = true
    var hasVisibleVideo = false
    var isPlaying = false
    /// The tab is a Peek's: its video never moves.
    var isPeek = false
    /// The tab stays on screen (a pane of the split now shown).
    var staysVisible = false
    /// A pop-up window's tab.
    var isPopup = false
}

enum BrowserMiniPlayerDecision: String, Equatable, Sendable {
    case open
    case disabled
    case noVideo
    case peek
    case visible
    case popup
}

/// When leaving a tab moves its video into the Mini Player: a playing,
/// visible main-frame video in a tab that leaves the screen. Audio alone
/// never does (the rail's controls show it). A private window's tab may
/// open one (leaving it was the user's action); its position is not saved.
enum BrowserMiniPlayerRule {
    static func decide(_ candidate: BrowserMiniPlayerCandidate) -> BrowserMiniPlayerDecision {
        if !candidate.isEnabled { return .disabled }
        if candidate.isPeek { return .peek }
        if candidate.staysVisible { return .visible }
        if candidate.isPopup { return .popup }
        if !candidate.isPlaying || !candidate.hasVisibleVideo { return .noVideo }
        return .open
    }
}

// MARK: - Panel frame

/// Where the Mini Player sits: the remembered frame when it still fits a
/// screen, else the bottom-right corner of `visible` (inset), 16:9 by
/// default, sized to `width`.
enum BrowserMiniPlayerFrame {
    static let defaultWidth: CGFloat = 400
    static let minimumSize = NSSize(width: 240, height: 135)
    static let inset: CGFloat = 20
    static let defaultsKey = "miniPlayerFrame"

    static func defaultFrame(in visible: NSRect, aspect: CGFloat = 16.0 / 9.0) -> NSRect {
        let ratio = aspect.isFinite && aspect > 0.3 && aspect < 4 ? aspect : 16.0 / 9.0
        var width = min(defaultWidth, max(minimumSize.width, visible.width - 2 * inset))
        var height = (width / ratio).rounded()
        if height > visible.height / 2 {
            height = max(minimumSize.height, (visible.height / 2).rounded())
            width = (height * ratio).rounded()
        }
        return NSRect(
            x: visible.maxX - inset - width,
            y: visible.minY + inset,
            width: width,
            height: height
        )
    }

    /// The remembered frame when at least its middle lies on one of
    /// `screens` and it is no smaller than the minimum; else the default
    /// in the first screen.
    static func frame(remembered: NSRect?, screens: [NSRect], fallback: NSRect) -> NSRect {
        if let remembered, remembered.width >= minimumSize.width, remembered.height >= minimumSize.height,
           screens.contains(where: { $0.contains(NSPoint(x: remembered.midX, y: remembered.midY)) })
        {
            return remembered
        }
        return defaultFrame(in: screens.first ?? fallback)
    }

    static func string(_ rect: NSRect) -> String {
        NSStringFromRect(rect)
    }

    static func rect(_ string: String?) -> NSRect? {
        guard let string, !string.isEmpty else { return nil }
        let rect = NSRectFromString(string)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }
}

// MARK: - Controls

/// What the rail's media bar and the toolbar's media control show.
struct BrowserMediaControlItem: Equatable {
    let tabID: UUID
    var title: String
    var subtitle: String
    var isPlaying: Bool
    var isMuted: Bool
    /// Next track goes to the page's Media Session handler.
    var canSkip: Bool
    var inMiniPlayer: Bool
    var image: NSImage?

    static func == (lhs: BrowserMediaControlItem, rhs: BrowserMediaControlItem) -> Bool {
        lhs.tabID == rhs.tabID && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && lhs.isPlaying == rhs.isPlaying && lhs.isMuted == rhs.isMuted && lhs.canSkip == rhs.canSkip
            && lhs.inMiniPlayer == rhs.inMiniPlayer && lhs.image === rhs.image
    }
}

/// Which tab the media controls show: one off screen with media, playing
/// ones first, then the most recently reported.
enum BrowserMediaTabChoice {
    struct Entry: Equatable {
        var id: UUID
        var isShown: Bool
        var isPlaying: Bool
        var hasMedia: Bool
        var changedAt: Date
    }

    static func pick(_ entries: [Entry]) -> UUID? {
        let eligible = entries.filter { !$0.isShown && ($0.hasMedia || $0.isPlaying) }
        return eligible.max { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return !lhs.isPlaying }
            return lhs.changedAt < rhs.changedAt
        }?.id
    }
}

/// `browser media` actions.
enum BrowserMediaAction: String, CaseIterable, Sendable {
    case play
    case pause
    case next = "nexttrack"
    case previous = "previoustrack"

    /// The CLI word.
    var word: String {
        switch self {
        case .play: "play"
        case .pause: "pause"
        case .next: "next"
        case .previous: "previous"
        }
    }

    init?(word: String) {
        guard let action = Self.allCases.first(where: { $0.word == word }) else { return nil }
        self = action
    }
}
