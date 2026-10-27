import AppKit

/// What a window is for, apart from its data kind (`BrowserWindowKind`,
/// normal or private): a normal window holds tabs of every Space; a
/// pop-up holds the one tab a page's `window.open` made; a Little Arc holds
/// one tab of one Space (a link from another app, ⌥⌘N) with compact
/// chrome. Pop-ups and Little Arcs use their tab's data context, so their
/// tabs move into windows showing that context's Space.
enum BrowserWindowRole: String, Codable, Sendable {
    case normal
    case popup
    case little

    /// Toolbar only: no rail, no tab strip, no tab list to open into.
    var isCompact: Bool { self != .normal }
}

// MARK: - Links from other apps

/// Settings ▸ Links from other apps ▸ "Open links from other apps in", for
/// links no rule matches.
enum BrowserOutsideLinkDestination: String, Codable, CaseIterable, Sendable {
    case littleArc
    case mostRecentWindow

    var title: String {
        switch self {
        case .littleArc: "Little Arc"
        case .mostRecentWindow: "The most recent window"
        }
    }
}

/// Where one link from another app goes.
enum BrowserOutsideLinkRoute: Equatable, Sendable {
    /// A rule matched; it picks the Space (or the most recent window).
    case rule(BrowserLinkRoutingRule)
    case littleArc
    case mostRecentWindow
}

extension BrowserLinkRouting {
    /// A matching rule wins; otherwise the setting decides.
    static func route(
        for address: String,
        rules: [BrowserLinkRoutingRule],
        otherLinks: BrowserOutsideLinkDestination
    ) -> BrowserOutsideLinkRoute {
        if let rule = rule(for: address, in: rules) {
            return .rule(rule)
        }
        return switch otherLinks {
        case .littleArc: .littleArc
        case .mostRecentWindow: .mostRecentWindow
        }
    }
}

// MARK: - ⌘O and "Open in"

/// Where a Little Arc's tab (⌘O) and its new tabs (target=_blank, ⌘-click)
/// land: a normal window showing its Space, else the most recent normal
/// window switched to that Space, else a new window on it.
enum BrowserLittleArcLanding {
    struct Window: Equatable, Sendable {
        var id: UUID
        /// A normal window the CLI and other apps reach (not private, not a
        /// pop-up or Little Arc).
        var takesTabs: Bool
        var currentSpaceID: UUID?
    }

    enum Target: Equatable, Sendable {
        case showing(UUID)
        case switching(UUID)
        case newWindow
    }

    /// `windows`: most recently active first.
    static func target(space: UUID, windows: [Window]) -> Target {
        let normal = windows.filter(\.takesTabs)
        if let showing = normal.first(where: { $0.currentSpaceID == space }) {
            return .showing(showing.id)
        }
        if let recent = normal.first {
            return .switching(recent.id)
        }
        return .newWindow
    }
}

// MARK: - Frame

/// A Little Arc's frame: a small window at the main screen's top right,
/// each further one a step down and left of the last.
enum BrowserLittleArcFrame {
    static let size = NSSize(width: 640, height: 720)
    static let minimumSize = NSSize(width: 420, height: 320)
    /// Distance from the screen's top and right edges.
    static let inset: CGFloat = 16

    /// `screens[0]` is the main screen's visible frame; `open` counts the
    /// Little Arcs already open.
    static func frame(screens: [NSRect], open: Int) -> NSRect {
        guard let screen = screens.first else { return NSRect(origin: .zero, size: size) }
        // A screen smaller than the window: it shrinks to fit inside the
        // insets.
        let width = min(size.width, max(1, screen.width - 2 * inset))
        let height = min(size.height, max(1, screen.height - 2 * inset))
        let top = NSPoint(x: screen.maxX - inset - width, y: screen.maxY - inset - height)
        let step = BrowserWindowFrames.cascadeOffset
        // Steps that still fit on the screen, then around again.
        let fitX = max(1, Int((top.x - screen.minX) / step) + 1)
        let fitY = max(1, Int((top.y - screen.minY) / step) + 1)
        let index = CGFloat(max(0, open) % min(fitX, fitY))
        return NSRect(x: top.x - step * index, y: top.y - step * index, width: width, height: height)
    }
}

// MARK: - Idle

/// A Little Arc left alone for 6 hours goes: its tab into the Archive
/// (when it holds a page), the window closed. Its tab is always the
/// selected one, so the selection does not count as use; audio, capture,
/// an open prompt or a pop-up it opened keep it.
enum BrowserLittleArcIdle {
    static let closeAfter: TimeInterval = 6 * 60 * 60

    static func closes(_ candidate: BrowserArchiveCandidate, now: Date) -> Bool {
        var candidate = candidate
        candidate.activity.isSelected = false
        candidate.isStartPage = false
        candidate.isToday = true
        guard BrowserArchivePolicy.exemption(for: candidate) == nil else { return false }
        return now.timeIntervalSince(candidate.activity.lastActive) >= closeAfter
    }
}
