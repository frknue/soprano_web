import AppKit

/// Recently closed tabs for ⇧⌘T, newest last. Holds the 20 most recent and
/// is saved with the session, so it survives a relaunch.
struct BrowserClosedTabStack: Equatable, Sendable {
    static let capacity = 20

    private(set) var entries: [BrowserTabState]

    init(_ entries: [BrowserTabState] = []) {
        self.entries = Array(entries.suffix(Self.capacity))
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    mutating func push(_ state: BrowserTabState) {
        entries.append(state)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    mutating func pop() -> BrowserTabState? {
        entries.popLast()
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

extension BrowserTabState {
    /// What the session saves for a tab. A restored tab that has not loaded
    /// yet (`pending`) keeps its saved address and back/forward list; title
    /// and zoom are always the live values. `interactionState` is only read
    /// for a loaded tab.
    static func snapshot(
        pending: BrowserTabState?,
        isStartPage: Bool,
        failedURL: String?,
        currentURL: String?,
        title: String,
        zoom: Double,
        interactionState: () -> Data?
    ) -> BrowserTabState {
        if let pending {
            return BrowserTabState(
                url: pending.url,
                title: title,
                zoom: zoom,
                interactionState: pending.interactionState
            )
        }
        return BrowserTabState(
            url: isStartPage ? nil : (failedURL ?? currentURL),
            title: title,
            zoom: zoom,
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
    /// Set on a restored tab until its first selection loads it.
    var pendingRestore: BrowserTabState?
    var lastCrashAt: Date?
    var reloadsWhenSelected = false
    var crashView: BrowserCrashView?
    /// The address whose content process quit, until a page commits.
    var crashedURL: String?
}
