@testable import SopranoWeb
import AppKit
import Testing

/// The Downloads button at the bottom of the rail (as in Arc), through a
/// real window manager (off-screen windows, a temporary support folder):
/// what it opens and closes, its lit state, and which windows keep the
/// toolbar's button instead.
@MainActor
@Suite(.serialized)
struct BrowserRailDownloadsTests {
    @MainActor
    private struct Fixture {
        let manager: BrowserWindowManager
        let directory: URL

        func tearDown() {
            for controller in manager.controllers {
                manager.closeWindow(controller, remember: false)
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebRailDownloads-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profiles = BrowserProfileStore(url: directory.appendingPathComponent("profiles.json"))
        let spaces = BrowserSpaceStore(
            url: directory.appendingPathComponent("spaces.json"),
            profiles: profiles.profiles,
            bookmarksURL: directory.appendingPathComponent("bookmarks.json")
        )
        let defaults = UserDefaults(suiteName: "com.soprano.web.tests.\(UUID().uuidString)")!
        let manager = BrowserWindowManager(
            themeManager: ThemeManager(themeId: "folio", appearance: .light),
            settingsStore: BrowserSettingsStore(url: directory.appendingPathComponent("settings.json"), settings: .default),
            profiles: profiles,
            supportDirectory: directory,
            spaces: spaces,
            archive: BrowserArchiveStore(url: directory.appendingPathComponent("archive.json")),
            downloads: BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json")),
            faviconStore: BrowserFaviconStore(directory: directory.appendingPathComponent("Favicons", isDirectory: true)),
            sessionStore: BrowserSessionStore(url: directory.appendingPathComponent("session.json")),
            persistsSession: false,
            placement: .offscreen(size: NSSize(width: 1200, height: 800)),
            defaults: defaults,
            filterLists: [],
            extensionStorage: .volatile,
            checksExtensionUpdates: false
        )
        return Fixture(manager: manager, directory: directory)
    }

    /// The button's action as a click sends it (`performClick` spins a
    /// nested run loop, which the test runner must not see).
    private func press(_ button: NSButton) {
        NSApp.sendAction(button.action!, to: button.target, from: button)
    }

    @Test func theRailButtonOpensAndClosesDownloadsAndLightsUp() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let button = window.verticalTabsView.switcher.downloadsButton

        press(button)
        #expect(window.isSidebarVisible)
        #expect(window.sidebarSection == .downloads)
        #expect(button.isToggledOn)

        press(button)
        #expect(!window.isSidebarVisible)
        #expect(!button.isToggledOn)

        // Another section showing: the button switches it to Downloads.
        window.showSidebar(section: .history)
        #expect(!button.isToggledOn)
        press(button)
        #expect(window.isSidebarVisible)
        #expect(window.sidebarSection == .downloads)
        #expect(button.isToggledOn)
    }

    @Test func switchingSectionsInTheSidebarMovesTheLitButton() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let button = window.verticalTabsView.switcher.downloadsButton
        press(button)
        #expect(button.isToggledOn)

        // The sidebar's own History button: Downloads no longer shows.
        press(window.sidebar.sectionButtons[.history]!)
        #expect(window.sidebarSection == .history)
        #expect(!button.isToggledOn)

        // So the rail's button shows Downloads again rather than closing.
        press(button)
        #expect(window.isSidebarVisible)
        #expect(window.sidebarSection == .downloads)
        #expect(button.isToggledOn)
    }

    /// The switcher at the rail's width: Downloads first, then the Space
    /// icons, "More Spaces" and "+", none over another; the current Space
    /// keeps its icon when the rest overflow.
    @Test func downloadsLeavesRoomForTheSpacesAtTheRailsWidth() {
        for count in [1, 5, 12] {
            let switcher = BrowserRailSpaceSwitcher(theme: .folioPaper)
            switcher.frame = NSRect(x: 0, y: 0, width: BrowserVerticalTabsView.preferredWidth, height: BrowserRailSpaceSwitcher.height)
            let spaces = (0..<count).map { index in
                BrowserRailSpace(id: UUID(), name: "S\(index)", icon: .none, color: .blue, isCurrent: index == count - 1)
            }
            switcher.update(spaces)
            switcher.layoutSubtreeIfNeeded()
            let shown = switcher.subviews.filter { !$0.isHidden && !($0 is ChromeRuleView) }
                .map(\.frame)
                .sorted { $0.minX < $1.minX }
            #expect(shown.first == switcher.downloadsButton.frame, "\(count) Spaces")
            for (left, right) in zip(shown, shown.dropFirst()) {
                #expect(left.maxX <= right.minX, "\(count) Spaces: \(left) overlaps \(right)")
            }
            #expect((shown.last?.maxX ?? 0) <= switcher.bounds.width, "\(count) Spaces")
            let overflowed = Set(switcher.overflow.map(\.id))
            #expect(!overflowed.contains(spaces[count - 1].id), "\(count) Spaces: the current one overflowed")
            #expect(overflowed.isEmpty == (count <= 5), "\(count) Spaces")
        }
    }

    @Test func onlyWindowsWithoutTheRailsBottomBarKeepTheToolbarButton() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        // The rail's bottom bar has it; the toolbar's would be a second one.
        #expect(!window.toolbar.showsDownloadsButton)

        // ⌘S hides the rail: the toolbar's button comes back, and goes
        // again with the rail.
        window.toggleVerticalSidebar()
        #expect(window.toolbar.showsDownloadsButton)
        window.toggleVerticalSidebar()
        #expect(!window.toolbar.showsDownloadsButton)

        // A private window's rail has no Space switcher.
        let privateWindow = fixture.manager.newPrivateWindow()
        #expect(privateWindow.toolbar.showsDownloadsButton)
    }
}
