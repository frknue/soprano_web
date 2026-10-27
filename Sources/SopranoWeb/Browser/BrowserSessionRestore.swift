import AppKit

/// One History ▸ Recently Closed entry: a tab or a whole window, and the
/// profile it reopens in. A tab's state carries its Space; it reopens
/// there (the profile's first Space when that one is gone).
struct BrowserClosedEntry: Codable, Equatable, Sendable, Identifiable {
    enum Content: Equatable, Sendable {
        /// A tab, the window it was in and its index there (nil: the end).
        case tab(BrowserTabState, windowID: UUID?, index: Int?)
        /// A window with its tabs, selection, frame and profile.
        case window(BrowserWindowState)
    }

    var id: UUID
    var content: Content
    /// The profile a closed tab reopens in; a closed window's own
    /// `profileID`.
    var profileID: UUID

    /// `profileID` is a tab's profile; a window entry takes its state's.
    init(_ content: Content, profileID: UUID = BrowserProfile.defaultID, id: UUID = UUID()) {
        self.id = id
        self.content = content
        if case .window(let state) = content {
            self.profileID = state.profileID
        } else {
            self.profileID = profileID
        }
    }

    /// The menu title: the tab's title, or the window's selected tab and its
    /// tab count.
    var title: String {
        switch content {
        case .tab(let state, _, _):
            return state.displayTitle
        case .window(let window):
            let count = window.tabs.count
            return "\(window.title) — \(count) \(count == 1 ? "tab" : "tabs")"
        }
    }

    var isWindow: Bool {
        if case .window = content { return true }
        return false
    }

    /// Where reopening puts this entry, given the normal windows that take
    /// reopened tabs, most recently active first: a tab returns to its
    /// window at its old index while that window is open, otherwise to the
    /// most recently active window (at the end of its Space; every normal
    /// window holds every Space); a window, or a tab with no window open,
    /// opens a new window.
    func reopenTarget(openWindows: [UUID]) -> BrowserReopenTarget {
        switch content {
        case .window:
            return .newWindow
        case .tab(_, let windowID, let index):
            if let windowID, openWindows.contains(windowID) {
                return .window(windowID, index: index)
            }
            if let window = openWindows.first {
                return .window(window, index: nil)
            }
            return .newWindow
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, tab, windowID, index, window, profileID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        switch try c.decode(String.self, forKey: .kind) {
        case "tab":
            content = .tab(
                try c.decode(BrowserTabState.self, forKey: .tab),
                windowID: try? c.decodeIfPresent(UUID.self, forKey: .windowID),
                index: try? c.decodeIfPresent(Int.self, forKey: .index)
            )
            profileID = ((try? c.decodeIfPresent(UUID.self, forKey: .profileID)) ?? nil) ?? BrowserProfile.defaultID
        case "window":
            let window = try c.decode(BrowserWindowState.self, forKey: .window)
            content = .window(window)
            profileID = window.profileID
        case let kind:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: c,
                debugDescription: "Unknown closed entry kind \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        switch content {
        case let .tab(state, windowID, index):
            try c.encode("tab", forKey: .kind)
            try c.encode(state, forKey: .tab)
            try c.encodeIfPresent(windowID, forKey: .windowID)
            try c.encodeIfPresent(index, forKey: .index)
            try c.encode(profileID, forKey: .profileID)
        case .window(let window):
            try c.encode("window", forKey: .kind)
            try c.encode(window, forKey: .window)
        }
    }
}

enum BrowserReopenTarget: Equatable, Sendable {
    /// Into this open window, at `index` of the tab's Space (nil or past
    /// the end: the end).
    case window(UUID, index: Int?)
    /// A new window on the tab's Space.
    case newWindow
}

/// Recently closed tabs and windows for ⇧⌘T and History ▸ Recently Closed,
/// newest last. One stack for the app; holds the 20 most recent and is
/// saved with the session, so it survives a relaunch.
struct BrowserRecentlyClosedStack: Equatable, Sendable {
    static let capacity = 20

    private(set) var entries: [BrowserClosedEntry]

    init(_ entries: [BrowserClosedEntry] = []) {
        self.entries = Array(entries.suffix(Self.capacity))
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
    var newest: BrowserClosedEntry? { entries.last }
    /// The menu order.
    var newestFirst: [BrowserClosedEntry] { entries.reversed() }

    mutating func push(_ entry: BrowserClosedEntry) {
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    mutating func pop() -> BrowserClosedEntry? {
        entries.popLast()
    }

    /// Takes one entry out (reopened from the menu).
    mutating func remove(id: UUID) -> BrowserClosedEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: index)
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// A deleted profile (or one whose history is cleared): its closed
    /// tabs go, and its tabs leave closed windows — the tabs of `spaces`
    /// (its Spaces) and, in a window saved before Spaces, every tab of a
    /// window of the profile. A window left without tabs goes.
    mutating func removeEntries(ofProfile profileID: UUID, spaces: Set<UUID>) {
        entries = entries.compactMap { entry in
            switch entry.content {
            case .tab:
                return entry.profileID == profileID ? nil : entry
            case .window(let state):
                let kept = state.keepingTabs { tab in
                    guard let spaceID = tab.spaceID else { return state.profileID != profileID }
                    return !spaces.contains(spaceID)
                }
                return kept.tabs.isEmpty ? nil : BrowserClosedEntry(.window(kept), id: entry.id)
            }
        }
    }
}

extension BrowserWindowState {
    /// The window with only the tabs `keep` accepts; the selection and each
    /// Space's selection follow their tabs (a removed one is dropped, the
    /// window's falls back to the first tab).
    func keepingTabs(where keep: (BrowserTabState) -> Bool) -> BrowserWindowState {
        var state = self
        var newIndex: [Int: Int] = [:]
        state.tabs = []
        for (index, tab) in tabs.enumerated() where keep(tab) {
            newIndex[index] = state.tabs.count
            state.tabs.append(tab)
        }
        state.selectedIndex = newIndex[selectedIndex] ?? 0
        state.spaceSelections = spaceSelections.compactMap { selection in
            newIndex[selection.index].map { BrowserSpaceSelection(spaceID: selection.spaceID, index: $0) }
        }
        return state
    }

    /// The window as it opens with today's Spaces. Its Space is the saved
    /// one, else the first Space of its profile (a version 2 window), else
    /// the first Space; `profileID` becomes that Space's. A tab whose
    /// Space is gone (or that has none: version 2) joins the window's
    /// Space; a pin or favorite link that no longer resolves in the tab's
    /// Space becomes a Today tab. Selections of other Spaces keep only
    /// tabs still in that Space. A Little Arc keeps its one Today tab out
    /// of every Space (the window belongs to one). Unchanged when there are
    /// no Spaces.
    func placedInSpaces(_ list: BrowserSpaceList) -> BrowserWindowState {
        guard let home = currentSpaceID.flatMap(list.space(id:))
            ?? list.space(ofProfile: profileID)
            ?? list.spaces.first
        else { return self }
        var state = self
        state.currentSpaceID = home.id
        state.profileID = home.profileID
        if role == .little {
            let selected = tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : tabs.first
            state.tabs = selected.map { [$0] } ?? []
            state.selectedIndex = 0
            state.spaceSelections = []
            state.splits = []
            for index in state.tabs.indices {
                state.tabs[index].spaceID = nil
                state.tabs[index].origin = .today
            }
            return state
        }
        for index in state.tabs.indices {
            let space = state.tabs[index].spaceID.flatMap(list.space(id:)) ?? home
            state.tabs[index].spaceID = space.id
            state.tabs[index].origin = BrowserPinLinks.validated(
                state.tabs[index].origin,
                in: list.linkTargets(of: space)
            )
        }
        var seen: Set<UUID> = []
        state.spaceSelections = spaceSelections.filter { selection in
            state.tabs.indices.contains(selection.index)
                && state.tabs[selection.index].spaceID == selection.spaceID
                && seen.insert(selection.spaceID).inserted
        }
        return state
    }
}

/// Window frames for restore and new windows.
enum BrowserWindowFrames {
    /// How far a new window steps down and right from the key window.
    static let cascadeOffset: CGFloat = 22

    /// Fits a saved frame on today's screens: the screen it overlaps most
    /// (or the first one when it overlaps none) holds the whole frame, which
    /// shrinks to fit but not below `minSize`.
    static func clamped(_ frame: NSRect, to screens: [NSRect], minSize: NSSize) -> NSRect {
        guard let screen = bestScreen(for: frame, in: screens) else { return frame }
        var result = frame
        result.size.width = min(max(frame.width, minSize.width), screen.width)
        result.size.height = min(max(frame.height, minSize.height), screen.height)
        result.origin.x = min(max(frame.minX, screen.minX), screen.maxX - result.width)
        result.origin.y = min(max(frame.minY, screen.minY), screen.maxY - result.height)
        return result
    }

    /// A new window's frame: the key window's size, one step down and right,
    /// back at the screen's top left when the step would leave the screen.
    static func cascaded(from frame: NSRect, screens: [NSRect]) -> NSRect {
        var next = frame.offsetBy(dx: cascadeOffset, dy: -cascadeOffset)
        guard let screen = bestScreen(for: frame, in: screens) else { return next }
        if next.maxX > screen.maxX || next.minY < screen.minY {
            next.origin = NSPoint(x: screen.minX, y: screen.maxY - next.height)
        }
        return next
    }

    /// Where the pointer sits on a window made from a tab dragged out: over
    /// its first tab, this far right of and below the top-left corner.
    static let dropGrabOffset = NSPoint(x: 100, y: 15)

    /// A window for a tab dropped where no window took it: `size`, placed
    /// so the drop point lands `dropGrabOffset` into it, kept on a screen.
    static func dropped(at point: NSPoint, size: NSSize, screens: [NSRect], minSize: NSSize) -> NSRect {
        let frame = NSRect(
            x: point.x - dropGrabOffset.x,
            y: point.y + dropGrabOffset.y - size.height,
            width: size.width,
            height: size.height
        )
        return clamped(frame, to: screens, minSize: minSize)
    }

    /// The frame stage 1 autosaved under `NSWindow Frame SopranoWebMainWindow`
    /// ("x y width height screenX screenY screenWidth screenHeight"); a
    /// migrated version 1 window opens there.
    static func autosavedFrame(_ value: String?) -> NSRect? {
        let numbers = (value ?? "").split(separator: " ").compactMap { Double($0) }
        guard numbers.count >= 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    private static func bestScreen(for frame: NSRect, in screens: [NSRect]) -> NSRect? {
        func overlap(_ screen: NSRect) -> CGFloat {
            let shared = screen.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        let best = screens.max { overlap($0) < overlap($1) }
        if let best, overlap(best) > 0 {
            return best
        }
        return screens.first
    }
}

extension BrowserTabState {
    /// What the session saves for a tab. A tab that is not loaded (restored
    /// and never selected, or asleep: `pending`) keeps its saved address
    /// and back/forward list; the title is always the live value.
    /// `interactionState` is only read for a loaded tab.
    static func snapshot(
        pending: BrowserTabState?,
        isStartPage: Bool,
        failedURL: String?,
        currentURL: String?,
        title: String,
        interactionState: () -> Data?
    ) -> BrowserTabState {
        if let pending {
            return BrowserTabState(
                url: pending.url,
                title: title,
                interactionState: pending.interactionState
            )
        }
        return BrowserTabState(
            url: isStartPage ? nil : (failedURL ?? currentURL),
            title: title,
            interactionState: interactionState()
        )
    }
}

/// What happens when a tab's web content process quits.
enum BrowserCrashPolicy {
    enum Action: Equatable {
        /// Reload the visible tab and say so in a toast.
        case reload
        /// The visible tab crashed again soon after the last crash: stop
        /// and show the crash page with a Reload button.
        case showCrashPage
        /// A background tab: reload it the next time it is selected.
        case reloadWhenSelected
    }

    /// A second crash closer than this to the previous one is a loop.
    static let loopInterval: TimeInterval = 20

    static func action(isSelected: Bool, previousCrash: Date?, now: Date) -> Action {
        guard isSelected else { return .reloadWhenSelected }
        if let previousCrash, now.timeIntervalSince(previousCrash) < loopInterval {
            return .showCrashPage
        }
        return .reload
    }
}

/// Per-tab restore and crash bookkeeping, stored on `BrowserTab.lifecycle`.
@MainActor
struct BrowserTabLifecycle {
    /// Set on a tab that is not loaded: restored and not selected yet, or
    /// asleep. Its first selection (or a CLI command) loads it.
    var pendingRestore: BrowserTabState?
    /// Set while the tab sleeps (with `pendingRestore`).
    var sleep: BrowserTabSleepState?
    /// Set while a snapshot is taken before the tab sleeps.
    var sleepAttempt: UUID?
    /// When the tab was last selected or left; idle time counts from here.
    var lastActiveAt = Date()
    /// Dialogs, sheets and prompts the page is waiting on.
    var openPrompts = 0
    /// Frames whose page reported `beforeunload` listeners or edited
    /// fields, and frames capturing the screen (`sleepGuard` messages).
    var unsavedFrames: Set<String> = []
    var capturingFrames: Set<String> = []
    /// The sleeping page's snapshot over the waking web view.
    var wakeSnapshotView: NSView?
    var lastCrashAt: Date?
    var reloadsWhenSelected = false
    var crashView: BrowserCrashView?
    /// The address whose content process quit, until a page commits.
    var crashedURL: String?
}
