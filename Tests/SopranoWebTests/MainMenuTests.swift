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
}
