@testable import SopranoWeb
import AppKit
import Testing

/// Capture through a real window manager (off-screen windows, a temporary
/// support and download folder, a pasteboard of its own; pages are not
/// loaded): the overlay's page, the command, delivery.
@MainActor
@Suite(.serialized)
struct BrowserCaptureWindowTests {
    @MainActor
    private struct Fixture {
        let manager: BrowserWindowManager
        let directory: URL
        let pasteboard: NSPasteboard

        func tearDown() {
            for controller in manager.controllers {
                manager.closeWindow(controller, remember: false)
            }
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebCapture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profiles = BrowserProfileStore(url: directory.appendingPathComponent("profiles.json"))
        let spaces = BrowserSpaceStore(
            url: directory.appendingPathComponent("spaces.json"),
            profiles: profiles.profiles,
            bookmarksURL: directory.appendingPathComponent("bookmarks.json")
        )
        var settings = BrowserSettings.default
        settings.downloadDirectory = directory.appendingPathComponent("Downloads", isDirectory: true).path
        let manager = BrowserWindowManager(
            themeManager: ThemeManager(themeId: "folio", appearance: .light),
            settingsStore: BrowserSettingsStore(url: directory.appendingPathComponent("settings.json"), settings: settings),
            profiles: profiles,
            supportDirectory: directory,
            spaces: spaces,
            archive: BrowserArchiveStore(url: directory.appendingPathComponent("archive.json")),
            downloads: BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json")),
            faviconStore: BrowserFaviconStore(directory: directory.appendingPathComponent("Favicons", isDirectory: true)),
            sessionStore: BrowserSessionStore(url: directory.appendingPathComponent("session.json")),
            persistsSession: false,
            placement: .offscreen(size: NSSize(width: 1200, height: 800)),
            defaults: UserDefaults(suiteName: "com.soprano.web.tests.\(UUID().uuidString)")!,
            filterLists: [],
            extensionStorage: .volatile,
            checksExtensionUpdates: false
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.soprano.web.tests.\(UUID().uuidString)"))
        manager.pasteboard = pasteboard
        return Fixture(manager: manager, directory: directory, pasteboard: pasteboard)
    }

    /// ⇧⌘2 by default, remappable, in the Command Bar as `/capture`.
    @Test func captureIsARegistryCommand() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        #expect(BrowserCommandID.capture.defaultShortcut == BrowserShortcut("shift+cmd+2"))
        #expect(BrowserCommandID.capture.isRemappable)
        let others = BrowserCommandID.allCases.filter { $0 != .capture && $0.defaultShortcut == BrowserShortcut("shift+cmd+2") }
        #expect(others.isEmpty)
        #expect(!BrowserGlobalShortcut.systemChords.contains(BrowserShortcut("shift+cmd+2")!))
        #expect(BrowserShortcut.reservedOwner(of: BrowserShortcut("shift+cmd+2")!) == nil)

        let window = fixture.manager.newWindow(url: "https://a.example/")
        let input = window.commandBarInput("/capture", mode: .actions, siteSearch: nil)
        let rows = BrowserCommandBarEngine.groups(for: input).flatMap(\.rows)
        #expect(rows.first?.target == .command(.capture))
    }

    /// The overlay covers the page the user looks at — the Peek's, the
    /// focused pane's — takes the keyboard, and goes when that page does.
    @Test func theOverlayFollowsThePageTab() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let first = try #require(window.selectedTab)
        let context = BrowserCommandContext(manager: fixture.manager, controller: window)
        #expect(BrowserCommandID.capture.command.state(context).isEnabled)

        BrowserCommandID.capture.command.perform(in: context)
        let overlay = try #require(window.captureOverlay)
        #expect(overlay.tabID == first.id)
        #expect(window.window?.firstResponder === overlay)
        // ⇧⌘2 again closes it.
        BrowserCommandID.capture.command.perform(in: context)
        #expect(window.captureOverlay == nil)

        // Over a Peek: the Peek's page; closing the Peek ends it.
        let peekTab = window.openPeek(URL(string: "https://b.example/")!, from: first)
        window.toggleCaptureOverlay()
        #expect(window.captureOverlay?.tabID == peekTab.id)
        window.closePeek()
        #expect(window.captureOverlay == nil)

        // In a split: the focused pane; another pane focused ends it.
        let second = try #require(window.addSplitPane(url: "https://c.example/", commandBar: false))
        window.toggleCaptureOverlay()
        #expect(window.captureOverlay?.tabID == second.id)
        _ = window.focusPane(number: 1)
        #expect(window.captureOverlay == nil)
    }

    /// Esc, the Cancel button and a right click cancel without a capture.
    @Test func escCancels() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        window.toggleCaptureOverlay()
        let overlay = try #require(window.captureOverlay)
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.window?.windowNumber ?? 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        overlay.keyDown(with: escape)
        #expect(window.captureOverlay == nil)
        #expect(overlay.superview == nil)
        #expect(window.window?.firstResponder === window.selectedTab?.webView)

        window.toggleCaptureOverlay()
        let again = try #require(window.captureOverlay)
        NSApp.sendAction(#selector(BrowserCaptureOverlay.cancel), to: again, from: nil)
        #expect(window.captureOverlay == nil)
        #expect(fixture.pasteboard.data(forType: .png) == nil)
    }

    /// A capture lands on the pasteboard and in the download folder under a
    /// unique name, private windows alike; the toast names the file.
    @Test func aCaptureIsCopiedAndSavedUniquely() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newPrivateWindow(url: "https://a.example/")
        let png = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )?.representation(using: .png, properties: [:]))
        let image = BrowserCaptureImage(png: png, pixelWidth: 4, pixelHeight: 2)
        let date = Date()
        let first = await window.deliverCapture(image, date: date)
        let second = await window.deliverCapture(image, date: date)
        let downloads = fixture.directory.appendingPathComponent("Downloads", isDirectory: true)
        #expect(first.fileURL?.deletingLastPathComponent().standardizedFileURL == downloads.standardizedFileURL)
        #expect(first.fileURL != second.fileURL)
        #expect(second.fileURL?.lastPathComponent.hasSuffix(" (2).png") == true)
        #expect(try Data(contentsOf: try #require(second.fileURL)) == png)
        #expect(fixture.pasteboard.data(forType: .png) == png)

        window.showCaptureToast(second, thumbnail: nil)
        let toast = try #require(window.captureToast)
        #expect(toast.detailLabel.stringValue == second.fileURL?.lastPathComponent)
        #expect(toast.titleLabel.stringValue == "Copied and saved to Downloads")
    }

    /// P8 review P3-1: an overlay that closes because its tab left the
    /// screen (a CLI selection, without focus) hands the keyboard to the
    /// page now shown, not to the hidden one.
    @Test func aClosedOverlayFocusesThePageNowShown() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let second = window.newTab(url: "https://b.example/", select: false)
        window.toggleCaptureOverlay()
        #expect(window.captureOverlay != nil)
        window.selectTab(id: second.id, focus: false)
        #expect(window.captureOverlay == nil)
        #expect(window.window?.firstResponder === second.webView)
    }

    /// P8 review P3-2: the overlay ends when it loses the keyboard (⌘L,
    /// ⌘T, a click into the page), so Esc never goes elsewhere while the
    /// page stays dimmed.
    @Test func losingTheKeyboardCancelsTheOverlay() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        window.toggleCaptureOverlay()
        let overlay = try #require(window.captureOverlay)
        window.window?.makeFirstResponder(window.selectedTab?.webView)
        for _ in 0..<50 where window.captureOverlay != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(window.captureOverlay == nil)
        #expect(overlay.superview == nil)
        #expect(fixture.pasteboard.data(forType: .png) == nil)
    }

    /// P9 review P2-4: the overlay's own buttons never take the keyboard
    /// (a Full Keyboard Access click would otherwise cancel the overlay
    /// before the button acts); another view taking it still cancels it.
    @Test func itsOwnButtonTakingFocusKeepsTheOverlay() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        window.toggleCaptureOverlay()
        let overlay = try #require(window.captureOverlay)
        let nsWindow = try #require(window.window)
        #expect(!overlay.fullPageButton.acceptsFirstResponder)
        #expect(!overlay.cancelButton.acceptsFirstResponder)
        nsWindow.makeFirstResponder(overlay.fullPageButton)
        nsWindow.makeFirstResponder(overlay.cancelButton)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(nsWindow.firstResponder === overlay)
        #expect(window.captureOverlay != nil)
        #expect(overlay.superview != nil)

        nsWindow.makeFirstResponder(window.toolbar.addressField)
        for _ in 0..<50 where window.captureOverlay != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(window.captureOverlay == nil)
    }
}
