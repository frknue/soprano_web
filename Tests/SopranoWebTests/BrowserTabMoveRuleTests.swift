@testable import SopranoWeb
import AppKit
import Testing

/// Which windows may exchange live tabs: drops, Merge All Windows,
/// `move-to-window` and the menu all use this rule.
struct BrowserTabMoveRuleTests {
    private let normalContext = UUID()

    private func window(context: UUID, popup: Bool = false) -> BrowserTabMoveRule.Window {
        BrowserTabMoveRule.Window(id: UUID(), context: context, isPopup: popup)
    }

    @Test func normalWindowsExchangeTabs() {
        let a = window(context: normalContext)
        let b = window(context: normalContext)
        #expect(BrowserTabMoveRule.allows(from: a, to: b))
        #expect(BrowserTabMoveRule.allows(from: b, to: a))
        #expect(!BrowserTabMoveRule.allows(from: a, to: a))
    }

    @Test func tabsNeverMoveBetweenPrivateAndNormalWindows() {
        let normal = window(context: normalContext)
        let privateWindow = window(context: UUID())
        #expect(!BrowserTabMoveRule.allows(from: normal, to: privateWindow))
        #expect(!BrowserTabMoveRule.allows(from: privateWindow, to: normal))
    }

    @Test func twoPrivateWindowsKeepTheirTabsUnlessTheyShareAContext() {
        let first = UUID()
        let a = window(context: first)
        let other = window(context: UUID())
        // The window a private tab moved into shares its context.
        let movedInto = window(context: first)
        #expect(!BrowserTabMoveRule.allows(from: a, to: other))
        #expect(BrowserTabMoveRule.allows(from: a, to: movedInto))
        #expect(BrowserTabMoveRule.allows(from: movedInto, to: a))
    }

    @Test func popUpWindowsTakeNoTabsButGiveThem() {
        let normal = window(context: normalContext)
        let popup = window(context: normalContext, popup: true)
        #expect(!BrowserTabMoveRule.allows(from: normal, to: popup))
        #expect(BrowserTabMoveRule.allows(from: popup, to: normal))
    }

    @Test func tabsMoveOnlyBetweenWindowsOfOneProfile() {
        // Every profile's normal windows share that profile's context.
        let defaultProfile = normalContext
        let workProfile = UUID()
        let defaultWindow = window(context: defaultProfile)
        let workWindow = window(context: workProfile)
        let otherWorkWindow = window(context: workProfile)
        let workPopup = window(context: workProfile, popup: true)
        #expect(!BrowserTabMoveRule.allows(from: defaultWindow, to: workWindow))
        #expect(!BrowserTabMoveRule.allows(from: workWindow, to: defaultWindow))
        #expect(BrowserTabMoveRule.allows(from: workWindow, to: otherWorkWindow))
        // A Work pop-up's tab goes to a Work window, never a Default one.
        #expect(BrowserTabMoveRule.allows(from: workPopup, to: workWindow))
        #expect(!BrowserTabMoveRule.allows(from: workPopup, to: defaultWindow))
        // A private window over Work keeps its own context.
        let privateOverWork = window(context: UUID())
        #expect(!BrowserTabMoveRule.allows(from: privateOverWork, to: workWindow))
        #expect(!BrowserTabMoveRule.allows(from: workWindow, to: privateOverWork))
    }

    @Test func mergeTakesOnlyTheTargetProfilesWindows() {
        let workProfile = UUID()
        let target = window(context: workProfile)
        let others = [window(context: normalContext), window(context: workProfile), window(context: UUID())]
        let merged = others.filter { BrowserTabMoveRule.allows(from: $0, to: target) }
        #expect(merged == [others[1]])
    }
}
