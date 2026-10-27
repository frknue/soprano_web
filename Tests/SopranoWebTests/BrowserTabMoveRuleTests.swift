@testable import SopranoWeb
import AppKit
import Testing

/// Which windows may exchange live tabs: drops, `move-to-window` and the
/// menu ask `allows` (the tab's context against the target's current
/// Space); Merge All Windows asks `merges`.
struct BrowserTabMoveRuleTests {
    private let defaultContext = UUID()
    private let workContext = UUID()

    private func window(context: UUID, role: BrowserWindowRole = .normal, spaces: Bool = true) -> BrowserTabMoveRule.Window {
        BrowserTabMoveRule.Window(id: UUID(), context: context, role: role, hasSpaces: spaces && role == .normal)
    }

    @Test func aTabMovesIntoAWindowWhoseCurrentSpaceUsesItsContext() {
        let a = window(context: defaultContext)
        let b = window(context: defaultContext)
        #expect(BrowserTabMoveRule.allows(tabContext: defaultContext, from: a.id, to: b))
        #expect(!BrowserTabMoveRule.allows(tabContext: defaultContext, from: a.id, to: a))
        // Window b shows a Work Space now: a Default tab can't land there,
        // a Work tab (from any window, of any current Space) can.
        let bOnWork = BrowserTabMoveRule.Window(id: b.id, context: workContext, role: .normal, hasSpaces: true)
        #expect(!BrowserTabMoveRule.allows(tabContext: defaultContext, from: a.id, to: bOnWork))
        #expect(BrowserTabMoveRule.allows(tabContext: workContext, from: a.id, to: bOnWork))
    }

    @Test func tabsNeverMoveBetweenPrivateAndNormalWindows() {
        let normal = window(context: defaultContext)
        let privateContext = UUID()
        let privateWindow = window(context: privateContext, spaces: false)
        #expect(!BrowserTabMoveRule.allows(tabContext: defaultContext, from: normal.id, to: privateWindow))
        #expect(!BrowserTabMoveRule.allows(tabContext: privateContext, from: privateWindow.id, to: normal))
    }

    @Test func twoPrivateWindowsKeepTheirTabsUnlessTheyShareAContext() {
        let first = UUID()
        let a = window(context: first, spaces: false)
        let other = window(context: UUID(), spaces: false)
        // The window a private tab moved into shares its context.
        let movedInto = window(context: first, spaces: false)
        #expect(!BrowserTabMoveRule.allows(tabContext: first, from: a.id, to: other))
        #expect(BrowserTabMoveRule.allows(tabContext: first, from: a.id, to: movedInto))
        #expect(BrowserTabMoveRule.allows(tabContext: first, from: movedInto.id, to: a))
    }

    @Test func popUpWindowsTakeNoTabsButGiveThem() {
        let normal = window(context: workContext)
        let popup = window(context: workContext, role: .popup)
        #expect(!BrowserTabMoveRule.allows(tabContext: workContext, from: normal.id, to: popup))
        // A Work pop-up's tab goes to a window showing a Work Space only.
        #expect(BrowserTabMoveRule.allows(tabContext: workContext, from: popup.id, to: normal))
        #expect(!BrowserTabMoveRule.allows(tabContext: workContext, from: popup.id, to: window(context: defaultContext)))
    }

    @Test func littleArcsTakeNoTabsButGiveThemToTheirSpacesWindows() {
        // A Little Arc of the Work Space uses the Work context.
        let little = window(context: workContext, role: .little)
        let onWork = window(context: workContext)
        let onDefault = window(context: defaultContext)
        // ⌘O, a drop or `move-to-window`: into a window showing Work only.
        #expect(BrowserTabMoveRule.allows(tabContext: workContext, from: little.id, to: onWork))
        #expect(!BrowserTabMoveRule.allows(tabContext: workContext, from: little.id, to: onDefault))
        // Nothing moves into a Little Arc, whatever its context.
        #expect(!BrowserTabMoveRule.allows(tabContext: workContext, from: onWork.id, to: little))
        #expect(!BrowserTabMoveRule.allows(tabContext: workContext, from: UUID(), to: window(context: workContext, role: .little)))
    }

    @Test func mergeTakesEveryNormalWindowWhateverItsCurrentSpace() {
        let target = window(context: workContext)
        let onDefault = window(context: defaultContext)
        let onWork = window(context: workContext)
        let privateWindow = window(context: UUID(), spaces: false)
        let popup = window(context: workContext, role: .popup)
        let little = window(context: workContext, role: .little)
        let merged = [onDefault, onWork, privateWindow, popup, little].filter { BrowserTabMoveRule.merges($0, into: target) }
        #expect(merged == [onDefault, onWork])
        #expect(!BrowserTabMoveRule.merges(target, into: target))
        #expect(!BrowserTabMoveRule.merges(onWork, into: little))
    }

    @Test func privateWindowsMergeOnlyWithinTheirContext() {
        let context = UUID()
        let target = window(context: context, spaces: false)
        let sameContext = window(context: context, spaces: false)
        let otherPrivate = window(context: UUID(), spaces: false)
        let normal = window(context: defaultContext)
        #expect(BrowserTabMoveRule.merges(sameContext, into: target))
        #expect(!BrowserTabMoveRule.merges(otherPrivate, into: target))
        #expect(!BrowserTabMoveRule.merges(normal, into: target))
        #expect(!BrowserTabMoveRule.merges(target, into: normal))
    }
}
