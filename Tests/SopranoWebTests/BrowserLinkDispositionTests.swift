@testable import SopranoWeb
import AppKit
import Testing

struct BrowserLinkDispositionTests {
    @Test func plainClicksStayInTheTab() {
        #expect(BrowserLinkDisposition.disposition(modifierFlags: [], buttonNumber: 1) == .currentTab)
        #expect(BrowserLinkDisposition.disposition(modifierFlags: [], buttonNumber: 0) == .currentTab)
        #expect(BrowserLinkDisposition.disposition(modifierFlags: .option, buttonNumber: 1) == .splitPane)
        // Right button (2) is not a middle click.
        #expect(BrowserLinkDisposition.disposition(modifierFlags: [], buttonNumber: 2) == .currentTab)
    }

    @Test func shiftAloneOpensAPeek() {
        #expect(BrowserLinkDisposition.disposition(modifierFlags: .shift, buttonNumber: 1) == .peek)
        #expect(BrowserLinkDisposition.disposition(modifierFlags: [.shift, .capsLock], buttonNumber: 1) == .peek)
        // ⇧ with ⌘ or the middle button still brings a tab to the front.
        #expect(BrowserLinkDisposition.disposition(modifierFlags: [.shift, .command], buttonNumber: 1) == .foregroundTab)
        #expect(BrowserLinkDisposition.disposition(modifierFlags: .shift, buttonNumber: 4) == .foregroundTab)
    }

    @Test func commandAndMiddleClicksOpenBackgroundTabs() {
        #expect(BrowserLinkDisposition.disposition(modifierFlags: .command, buttonNumber: 1) == .backgroundTab)
        #expect(BrowserLinkDisposition.disposition(modifierFlags: [], buttonNumber: 4) == .backgroundTab)
        // buttonNumber is a bitmask: middle held with left still counts.
        #expect(BrowserLinkDisposition.disposition(modifierFlags: [], buttonNumber: 5) == .backgroundTab)
        #expect(BrowserLinkDisposition.disposition(modifierFlags: [.command, .option], buttonNumber: 1) == .backgroundTab)
        // Non-device flags such as caps lock do not change the result.
        #expect(BrowserLinkDisposition.disposition(modifierFlags: [.command, .capsLock], buttonNumber: 1) == .backgroundTab)
    }

    @Test func shiftBringsTheNewTabToTheFront() {
        #expect(BrowserLinkDisposition.disposition(modifierFlags: [.shift, .command], buttonNumber: 1) == .foregroundTab)
        #expect(BrowserLinkDisposition.disposition(modifierFlags: .shift, buttonNumber: 4) == .foregroundTab)
    }

    @Test func linkTabsOpenAfterTheOpenerInClickOrder() {
        let opener = UUID()
        let other = UUID()
        // [a, opener, b]: first link tab goes right after the opener.
        #expect(BrowserLinkDisposition.insertionIndex(
            openerIndex: 1, openerID: opener, openerIDs: [nil, nil, nil]
        ) == 2)
        // [a, opener, child, child, b]: the next one goes after its siblings.
        #expect(BrowserLinkDisposition.insertionIndex(
            openerIndex: 1, openerID: opener, openerIDs: [nil, nil, opener, opener, other]
        ) == 4)
        // Opener is the last tab.
        #expect(BrowserLinkDisposition.insertionIndex(
            openerIndex: 2, openerID: opener, openerIDs: [nil, nil, nil]
        ) == 3)
        // A tab opened by another tab breaks the run.
        #expect(BrowserLinkDisposition.insertionIndex(
            openerIndex: 0, openerID: opener, openerIDs: [nil, other, opener]
        ) == 1)
    }
}
