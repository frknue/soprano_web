import AppKit

/// Little Arc: a small window with one tab of one Space, for links from
/// other apps (Settings ▸ Links from other apps), ⌥⌘N and the global
/// shortcut. ⌘O moves its tab into its Space's window; "Open in" moves it
/// to another Space (the page reloads there: every Space has its own
/// profile); 6 hours idle closes it, its tab into the Archive.
extension BrowserWindowManager {
    /// The Space a new Little Arc belongs to: the most recently active
    /// normal window's (a private window's: the Space it was opened over),
    /// else the Default Space.
    var littleArcSpace: BrowserSpace? {
        mostRecentlyActive { $0.role == .normal }.flatMap(space(of:)) ?? spaces.defaultSpace
    }

    /// The frame for a new Little Arc: the main screen's top right, a step
    /// down and left for each one already open.
    func littleArcFrame() -> NSRect {
        BrowserLittleArcFrame.frame(
            screens: placement.screens(),
            open: controllers.filter { $0.role == .little }.count
        )
    }

    /// File ▸ New Little Arc (⌥⌘N, `commandBar`: with the Command Bar on
    /// its start tab), a link from another app (`url`) and `browser
    /// little`: a Little Arc of Space `spaceID` (else `littleArcSpace`).
    @discardableResult
    func newLittleArc(url: String? = nil, spaceID: UUID? = nil, commandBar: Bool = false) -> BrowserWindowController {
        let space = spaceID.flatMap(spaces.space(id:)) ?? littleArcSpace
        let controller = makeWindow(
            frame: littleArcFrame(),
            role: .little,
            context: context(for: space?.profileID ?? BrowserProfile.defaultID),
            spaceID: space?.id
        )
        controller.newTab(url: url)
        present(controller)
        if commandBar {
            controller.showCommandBar(.editCurrent, toggles: false)
        } else {
            controller.focusPage()
        }
        scheduleSessionSave()
        return controller
    }

    /// Where a Little Arc of Space `space` sends tabs (`BrowserLittleArcLanding`):
    /// a normal window showing the Space, else the most recent normal
    /// window switched to it, else a new empty window on it. `isNew`: the
    /// window shows no tab of the Space yet, so the caller selects the tab
    /// it adds (and presents a new window).
    func littleArcLanding(space spaceID: UUID) -> (window: BrowserWindowController, isNew: Bool) {
        let ordered = mostRecentlyActiveFirst { _ in true }
        let windows = ordered.map { controller in
            BrowserLittleArcLanding.Window(
                id: controller.id,
                takesTabs: controller.role == .normal && controller.kind.acceptsOutsideRequests,
                currentSpaceID: controller.currentSpaceID
            )
        }
        switch BrowserLittleArcLanding.target(space: spaceID, windows: windows) {
        case let .showing(id):
            if let window = controllers.first(where: { $0.id == id }) {
                return (window, false)
            }
        case let .switching(id):
            if let window = controllers.first(where: { $0.id == id }) {
                return (window, window.showSpaceForIncomingTab(spaceID))
            }
        case .newWindow:
            break
        }
        let space = spaces.space(id: spaceID)
        let window = makeWindow(
            frame: frameForNewWindow(),
            context: context(for: space?.profileID ?? BrowserProfile.defaultID),
            spaceID: spaceID
        )
        return (window, true)
    }

    /// ⌘O in a Little Arc: its tab (page, history and state kept) moves into
    /// its Space's window (`littleArcLanding`), selected, and the Little
    /// Arc closes. Returns that window.
    @discardableResult
    func moveLittleArcToSpaceWindow(_ little: BrowserWindowController) -> BrowserWindowController? {
        guard little.role == .little, let tab = little.selectedTab, let spaceID = little.littleSpaceID else { return nil }
        let target = littleArcLanding(space: spaceID).window
        moveTab(tab, from: little, to: target, at: nil, select: true)
        return target
    }

    /// A Little Arc's "Open in" menu: a new Little Arc of Space `spaceID` in
    /// its place with its page, which reloads there (another profile: a web
    /// view keeps its data store for life); the old one closes. Returns
    /// the new one; nil when nothing changes.
    @discardableResult
    func moveLittleArc(_ little: BrowserWindowController, toSpace spaceID: UUID) -> BrowserWindowController? {
        guard little.role == .little, spaceID != little.littleSpaceID,
              let space = spaces.space(id: spaceID), let tab = little.selectedTab
        else { return nil }
        var state = tab.state
        state.spaceID = nil
        state.origin = .today
        let controller = makeWindow(
            frame: sessionFrame(of: little) ?? littleArcFrame(),
            role: .little,
            context: context(for: space.profileID),
            spaceID: space.id
        )
        let moved = tab.isStartPage ? controller.newTab() : controller.addRestoredTab(state)
        closeWindow(little, remember: false)
        controller.selectTab(id: moved.id, focus: true)
        present(controller)
        scheduleSessionSave()
        return controller
    }
}
