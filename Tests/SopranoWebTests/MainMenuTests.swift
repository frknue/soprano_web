@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct MainMenuTests {
    @Test func verticalSidebarShortcutIsCommandS() {
        _ = NSApplication.shared
        let menu = MainMenuController { nil }
        menu.install()
        let viewMenu = NSApp.mainMenu?.item(withTitle: "View")?.submenu
        let item = viewMenu?.item(withTitle: "Toggle Vertical Sidebar")
        #expect(item?.keyEquivalent == "s")
        #expect(item?.keyEquivalentModifierMask == [.command])
    }

    @Test func commandLOpensLocationAndIsUnique() {
        _ = NSApplication.shared
        let menu = MainMenuController { nil }
        menu.install()
        let matches = (NSApp.mainMenu?.items ?? [])
            .compactMap(\.submenu)
            .flatMap(\.items)
            .filter { $0.keyEquivalent == "l" && $0.keyEquivalentModifierMask == [.command] }
        #expect(matches.map(\.title) == ["Open Location…"])
    }

    @Test func printPaletteAndStopShortcuts() {
        _ = NSApplication.shared
        let menu = MainMenuController { nil }
        menu.install()
        let items = (NSApp.mainMenu?.items ?? []).compactMap(\.submenu).flatMap(\.items)
        func titles(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> [String] {
            items.filter { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }.map(\.title)
        }
        #expect(titles("p", [.command]) == ["Print…"])
        #expect(titles("p", [.command, .shift]) == ["Command Palette…"])
        #expect(titles("s", [.command, .shift]) == ["Save As…"])
        let stop = items.first { $0.title == "Stop" }
        #expect(stop?.keyEquivalent == ".")
        #expect(stop?.action == NSSelectorFromString("stop"))
        #expect(items.first { $0.title == "Reload" }?.action != stop?.action)
    }

    @Test func newWindowIsCommandNAndHistoryListsRecentlyClosed() {
        _ = NSApplication.shared
        let menu = MainMenuController { nil }
        menu.install()
        let items = (NSApp.mainMenu?.items ?? []).compactMap(\.submenu).flatMap(\.items)
        let newWindow = items.filter { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == [.command] }
        #expect(newWindow.map(\.title) == ["New Window"])
        let reopen = items.filter { $0.keyEquivalent == "t" && $0.keyEquivalentModifierMask == [.command, .shift] }
        #expect(reopen.count == 1)
        let history = NSApp.mainMenu?.item(withTitle: "History")?.submenu
        #expect(history?.item(withTitle: "Recently Closed")?.submenu != nil)
    }

    @Test func newPrivateWindowIsShiftCommandN() {
        _ = NSApplication.shared
        let menu = MainMenuController { nil }
        menu.install()
        let items = (NSApp.mainMenu?.items ?? []).compactMap(\.submenu).flatMap(\.items)
        let matches = items.filter { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == [.command, .shift] }
        #expect(matches.map(\.title) == ["New Private Window"])
    }

    @Test func windowMenuMovesAndMergesTabs() {
        _ = NSApplication.shared
        let menu = MainMenuController { nil }
        menu.install()
        let window = NSApp.mainMenu?.item(withTitle: "Window")?.submenu
        #expect(window?.item(withTitle: "Move Tab to New Window") != nil)
        #expect(window?.item(withTitle: "Merge All Windows") != nil)
    }

    @Test func newWindowWithProfileIsHiddenWithOneProfile() {
        _ = NSApplication.shared
        let menu = MainMenuController { nil }
        menu.install()
        let file = NSApp.mainMenu?.item(withTitle: "File")?.submenu
        let item = file?.item(withTitle: "New Window With Profile")
        #expect(item?.submenu != nil)
        #expect(item?.isHidden == true)
    }

    @Test func spacesMenuReplacesBookmarksWithItsCommands() {
        _ = NSApplication.shared
        let menu = MainMenuController { nil }
        let main = menu.buildMenu()
        #expect(main.item(withTitle: "Bookmarks") == nil)
        let spaces = main.item(withTitle: "Spaces")?.submenu
        let commands = spaces?.items.filter { !$0.isSeparatorItem } ?? []
        #expect(commands.map(\.title) == [
            "Next Space", "Previous Space", "Bookmark This Page", "Show Pinned Tabs", "Archive Today Tabs",
        ])
        let right = String(Character(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!))
        let left = String(Character(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!))
        #expect(commands[0].keyEquivalent == right)
        #expect(commands[1].keyEquivalent == left)
        #expect(commands[0].keyEquivalentModifierMask == [.command, .option])
        #expect(commands[2].keyEquivalent == "d")
        #expect(commands[3].keyEquivalentModifierMask == [.command, .option])
    }

    @Test func spaceShortcutsCollideWithNothingElse() {
        _ = NSApplication.shared
        let menu = MainMenuController { nil }
        let items = menu.buildMenu().items.compactMap(\.submenu).flatMap(\.items)
        let arrows = [NSLeftArrowFunctionKey, NSRightArrowFunctionKey].map {
            String(Character(UnicodeScalar(UInt16($0))!))
        }
        // ⌥⌘←/⌥⌘→ only switch Spaces; ⌃1…⌃9 are free for them.
        let optionCommandArrows = items.filter {
            arrows.contains($0.keyEquivalent) && $0.keyEquivalentModifierMask == [.command, .option]
        }
        #expect(optionCommandArrows.map(\.title) == ["Next Space", "Previous Space"])
        let controlDigits = items.filter {
            $0.keyEquivalentModifierMask == [.control] && Int($0.keyEquivalent) != nil
        }
        #expect(controlDigits.isEmpty)
    }

    @Test func shiftCommandKArchivesTodayTabsFromTheSpacesMenu() {
        _ = NSApplication.shared
        let menu = MainMenuController { nil }
        let main = menu.buildMenu()
        let items = main.items.compactMap(\.submenu).flatMap(\.items)
        let matches = items.filter { $0.keyEquivalent == "k" && $0.keyEquivalentModifierMask == [.command, .shift] }
        #expect(matches.map(\.title) == ["Archive Today Tabs"])
        let spaces = main.item(withTitle: "Spaces")?.submenu
        #expect(spaces?.item(withTitle: "Archive Today Tabs") != nil)
        #expect(main.item(withTitle: "History")?.submenu?.item(withTitle: "Show Archive") != nil)
    }
}
