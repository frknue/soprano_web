@testable import SopranoWeb
import AppKit
import Testing

struct VimiumKeyMapTests {
    @Test func ggIsATwoKeySequence() {
        var map = VimiumKeyMap()
        #expect(map.feed("g") == .pending)
        #expect(map.feed("g") == .execute(.scrollToTop, 1))
        #expect(!map.hasPendingInput)
    }

    @Test func countsApplyToCommands() {
        var map = VimiumKeyMap()
        #expect(map.feed("5") == .pending)
        #expect(map.feed("j") == .execute(.scroll(dx: 0, dy: 60), 5))

        #expect(map.feed("5") == .pending)
        #expect(map.feed("g") == .pending)
        #expect(map.feed("0") == .execute(.firstTab, 5))
    }

    @Test func yPrefixCoversYankAndTabCommands() {
        var map = VimiumKeyMap()
        #expect(map.feed("y") == .pending)
        #expect(map.feed("y") == .execute(.copyCurrentURL, 1))

        #expect(map.feed("y") == .pending)
        #expect(map.feed("t") == .execute(.duplicateTab, 1))

        #expect(map.feed("y") == .pending)
        #expect(map.feed("f") == .execute(.hints(.copyLink), 1))
    }

    @Test func bracketAndZSequences() {
        var map = VimiumKeyMap()
        #expect(map.feed("[") == .pending)
        #expect(map.feed("[") == .execute(.previousLink, 1))

        #expect(map.feed("z") == .pending)
        #expect(map.feed("H") == .execute(.scrollToLeft, 1))

        #expect(map.feed("<") == .pending)
        #expect(map.feed("<") == .execute(.moveTabLeft, 1))
    }

    @Test func plainAAndCAreNotPrefixes() {
        var map = VimiumKeyMap()
        #expect(map.feed("a") == .unknown)
        #expect(map.feed("c") == .unknown)
        #expect(!map.hasPendingInput)
    }

    @Test func unknownSecondKeyClearsTheSequence() {
        var map = VimiumKeyMap()
        #expect(map.feed("g") == .pending)
        #expect(map.feed("a") == .unknown)
        #expect(!map.hasPendingInput)
    }

    @Test func helpListsAllSections() {
        let help = VimiumKeyMap.helpText
        #expect(help.contains("SCROLLING"))
        #expect(help.contains("HINTS"))
        #expect(help.contains("TABS"))
        #expect(help.contains("g0 / g$"))
        #expect(help.contains("m / `"))
        #expect(help.contains("gs"))
    }

    @Test func capitalWMovesTheTabToANewWindow() {
        var map = VimiumKeyMap()
        #expect(map.feed("W") == .execute(.moveTabToNewWindow, 1))
        let tabs = VimiumKeyMap.helpSections.first { $0.title == "Tabs" }?.rows ?? []
        #expect(tabs.first { $0.keys == "W" }?.action == "move tab to a new window")
        // Pins are still not modeled.
        #expect(tabs.first { $0.keys == "⌥P" }?.action == "not available")
    }
}
