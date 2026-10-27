@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct MainMenuTests {
    private func items() -> [NSMenuItem] {
        _ = NSApplication.shared
        let menu = MainMenuController { nil }
        func flatten(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(flatten) ?? []) }
        }
        return flatten(menu.buildMenu())
    }

    private func titles(_ items: [NSMenuItem], _ shortcut: String) -> [String] {
        let shortcut = BrowserShortcut(shortcut)!
        return items.filter {
            $0.keyEquivalent == shortcut.keyEquivalent && $0.keyEquivalentModifierMask == shortcut.modifierMask
        }.map(\.title)
    }

    @Test func everyRegistryCommandIsOneMenuItemWithItsShortcut() {
        let items = items()
        for command in BrowserAppCommand.all where command.hasMenuItem {
            let matches = items.filter { $0.identifier?.rawValue == command.id.rawValue }
            #expect(matches.count == 1, "\(command.id.rawValue)")
            #expect(matches.first?.title == command.title)
            #expect(matches.first?.keyEquivalent == (command.shortcut?.keyEquivalent ?? ""), "\(command.id.rawValue)")
        }
    }

    @Test func noTwoItemsShareAShortcut() {
        let shortcuts = items()
            .filter { !$0.keyEquivalent.isEmpty }
            .map { "\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)" }
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test func commandTOpensTheCommandBarAndCommandLEditsTheAddress() {
        let items = items()
        #expect(titles(items, "cmd+t") == ["New Tab"])
        #expect(titles(items, "cmd+l") == ["Open Location…"])
        #expect(titles(items, "cmd+s") == ["Toggle Vertical Sidebar"])
        #expect(titles(items, "cmd+p") == ["Print…"])
        #expect(titles(items, "shift+cmd+p") == ["Search Actions…"])
        #expect(titles(items, "shift+cmd+s") == ["Save As…"])
        #expect(titles(items, "cmd+.") == ["Stop"])
        #expect(items.first { $0.title == "Stop" }?.identifier?.rawValue == "stop")
    }

    @Test func arcShortcutsHaveTheirPlanBindings() {
        let items = items()
        #expect(titles(items, "ctrl+tab") == ["Switch to Recent Tab"])
        #expect(titles(items, "ctrl+shift+tab") == ["Switch to Recent Tab Backward"])
        #expect(titles(items, "opt+cmd+down") == ["Next Tab"])
        #expect(titles(items, "opt+cmd+up") == ["Previous Tab"])
        #expect(titles(items, "shift+cmd+c") == ["Copy URL"])
        #expect(titles(items, "opt+shift+cmd+c") == ["Copy URL as Markdown"])
        #expect(titles(items, "shift+cmd+d") == ["Hide Toolbar"])
        #expect(titles(items, "shift+cmd+k") == ["Archive Today Tabs"])
    }

    @Test func newWindowIsCommandNAndHistoryListsRecentlyClosed() {
        _ = NSApplication.shared
        let main = MainMenuController { nil }.buildMenu()
        let items = items()
        #expect(titles(items, "cmd+n") == ["New Window"])
        #expect(titles(items, "shift+cmd+n") == ["New Private Window"])
        #expect(titles(items, "shift+cmd+t").count == 1)
        #expect(main.item(withTitle: "History")?.submenu?.item(withTitle: "Recently Closed")?.submenu != nil)
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

    @Test func spacesMenuHoldsTheSpaceCommands() {
        _ = NSApplication.shared
        let main = MainMenuController { nil }.buildMenu()
        #expect(main.item(withTitle: "Bookmarks") == nil)
        let spaces = main.item(withTitle: "Spaces")?.submenu
        let commands = spaces?.items.filter { !$0.isSeparatorItem } ?? []
        #expect(commands.map(\.title) == [
            "Next Space", "Previous Space", "Pin This Page", "Show Pinned Tabs", "Archive Today Tabs",
        ])
        #expect(titles(commands, "opt+cmd+right") == ["Next Space"])
        #expect(titles(commands, "opt+cmd+left") == ["Previous Space"])
        #expect(titles(commands, "cmd+d") == ["Pin This Page"])
        #expect(titles(commands, "opt+cmd+b") == ["Show Pinned Tabs"])
        // ⌃1…⌃9 belong to the Space items (none without Spaces).
        #expect(items().filter { $0.keyEquivalentModifierMask == [.control] && Int($0.keyEquivalent) != nil }.isEmpty)
    }

    @Test func systemCommandsUseTheResponderChain() {
        let items = items()
        let copy = items.first { $0.identifier?.rawValue == "copy" }
        #expect(copy?.action == #selector(NSText.copy(_:)))
        #expect(copy?.target == nil)
        let reload = items.first { $0.identifier?.rawValue == "reload" }
        #expect(reload?.action == NSSelectorFromString("runCommand:"))
    }
}
