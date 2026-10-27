@testable import SopranoWeb
import AppKit
import Testing

struct BrowserShortcutTests {
    private func shortcut(_ text: String) -> BrowserShortcut {
        BrowserShortcut(text)!
    }

    @Test func readsWordAndSymbolFormsAlike() {
        #expect(shortcut("shift+cmd+c") == shortcut("⇧⌘C"))
        #expect(shortcut("cmd+shift+C") == shortcut("shift+cmd+c"))
        #expect(shortcut("command+option+down") == BrowserShortcut("down", [.command, .option]))
        // A shifted character is its key with shift.
        #expect(shortcut("cmd++") == BrowserShortcut("=", [.command, .shift]))
        #expect(shortcut("⌘{") == BrowserShortcut("[", [.command, .shift]))
        #expect(BrowserShortcut("hyper+c") == nil)
        #expect(BrowserShortcut("") == nil)
    }

    @Test func savesAndShowsCanonically() {
        let copyMarkdown = shortcut("cmd+shift+opt+c")
        #expect(copyMarkdown.storageText == "opt+shift+cmd+c")
        #expect(copyMarkdown.display == "⌥⇧⌘C")
        #expect(BrowserShortcut(copyMarkdown.storageText) == copyMarkdown)
        #expect(shortcut("ctrl+tab").display == "⌃Tab")
        #expect(shortcut("opt+cmd+up").display == "⌥⌘↑")
        #expect(shortcut("shift+cmd+delete").keyEquivalent == "\u{8}")
    }

    @Test func onlyModifiedKeysAreAssignable() {
        #expect(!shortcut("c").isAssignable)
        #expect(!shortcut("shift+c").isAssignable)
        #expect(!shortcut("opt+c").isAssignable)
        #expect(shortcut("opt+down").isAssignable)
        #expect(shortcut("ctrl+tab").isAssignable)
        #expect(shortcut("cmd+k").isAssignable)
    }

    @Test func pageReportsMapByPhysicalKey() {
        #expect(BrowserShortcut(domCode: "KeyC", meta: true, ctrl: false, alt: false, shift: true) == shortcut("shift+cmd+c"))
        // ⌥ changes `key` (ç) but never `code`.
        #expect(BrowserShortcut(domCode: "KeyC", meta: true, ctrl: false, alt: true, shift: true) == shortcut("opt+shift+cmd+c"))
        #expect(BrowserShortcut(domCode: "Digit1", meta: false, ctrl: true, alt: false, shift: false) == shortcut("ctrl+1"))
        #expect(BrowserShortcut(domCode: "BracketLeft", meta: true, ctrl: false, alt: false, shift: false) == shortcut("cmd+["))
        #expect(BrowserShortcut(domCode: "IntlBackslash", meta: true, ctrl: false, alt: false, shift: false) == nil)
    }

    // MARK: Settings

    @Test func decodesShortcutsEntryByEntry() throws {
        let json = """
        {
          "copy-url": {"shortcut": "shift+cmd+u", "priority": "site"},
          "print": {"shortcut": "none"},
          "reload": {"shortcut": "not a key", "priority": "twice"},
          "find": {"priority": "sometimes"},
          "no-such-command": {"shortcut": "cmd+j"},
          "copy": {"shortcut": "cmd+j"},
          "back": "cmd+b",
          "stop": {"shortcut": "j"}
        }
        """
        let settings = try JSONDecoder().decode(BrowserShortcutSettings.self, from: Data(json.utf8))
        let keymap = BrowserKeymap(settings)
        #expect(keymap.shortcut(for: .copyURL) == shortcut("shift+cmd+u"))
        #expect(keymap.priority(for: .copyURL) == .site)
        #expect(keymap.shortcut(for: .print) == nil)
        // A bad shortcut keeps the default; its priority still reads.
        #expect(keymap.shortcut(for: .reload) == shortcut("cmd+r"))
        #expect(keymap.priority(for: .reload) == .twice)
        #expect(keymap.priority(for: .find) == .app)
        // Fixed commands keep their keys; a bare key is not a shortcut.
        #expect(keymap.shortcut(for: .copy) == shortcut("cmd+c"))
        #expect(keymap.shortcut(for: .back) == shortcut("cmd+["))
        #expect(keymap.shortcut(for: .stop) == shortcut("cmd+."))
        #expect(Set(settings.entries.keys) == [.copyURL, .print, .reload])
    }

    @Test func decodedRemapsFollowTheAssignRules() throws {
        let json = """
        {
          "reload": {"shortcut": "cmd+q"},
          "zoom-in": {"shortcut": "cmd+;"},
          "find": {"shortcut": "ctrl+e"},
          "print": {"shortcut": "cmd+j"},
          "export-pdf": {"shortcut": "cmd+j"},
          "save-as": {"shortcut": "cmd+r"}
        }
        """
        let keymap = BrowserKeymap(try JSONDecoder().decode(BrowserShortcutSettings.self, from: Data(json.utf8)))
        // A fixed command's key or a reserved one: the remap is dropped.
        #expect(keymap.shortcut(for: .zoomIn) == shortcut("cmd+="))
        #expect(keymap.shortcut(for: .find) == shortcut("cmd+f"))
        // Two commands on one key: the later in registry order gets none.
        #expect(keymap.shortcut(for: .print) == nil)
        #expect(keymap.shortcut(for: .exportPDF) == shortcut("cmd+j"))
        // Reload's remap onto ⌘Q dropped, it is back on ⌘R, which Save As
        // (File, before View) took in the file: Reload has none.
        #expect(keymap.shortcut(for: .saveAs) == shortcut("cmd+r"))
        #expect(keymap.shortcut(for: .reload) == nil)
        let all = BrowserCommandID.allCases.compactMap { keymap.shortcut(for: $0) }
        #expect(Set(all).count == all.count)
    }

    @Test func reservedKeysAreRefused() {
        var keymap = BrowserKeymap()
        for text in ["cmd+;", "shift+cmd+;", "cmd+`", "ctrl+cmd+space", "shift+cmd+/", "opt+delete", "opt+left", "ctrl+a",
                     "ctrl+e", "ctrl+k", "ctrl+["] {
            guard case .reserved = keymap.assign(shortcut(text), to: .copyURL) else {
                Issue.record("\(text) was not refused")
                continue
            }
        }
        #expect(keymap == BrowserKeymap())
        #expect(BrowserShortcut.reservedOwner(of: shortcut("ctrl+e")) == "Vimium")
        // Shifted punctuation keys the menu on its shifted character.
        #expect(shortcut("shift+cmd+[").keyEquivalent == "{")
        #expect(shortcut("shift+cmd+[").modifierMask == [.command])
        #expect(shortcut("shift+cmd+c").modifierMask == [.command, .shift])
    }

    @Test func settingsKeepOtherKeysWhenShortcutsAreBad() throws {
        let json = #"{"homepage": "https://example.com", "shortcuts": ["cmd+t"], "verticalTabs": false}"#
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: Data(json.utf8))
        #expect(settings.homepage == "https://example.com")
        #expect(settings.verticalTabs == false)
        #expect(settings.shortcuts == BrowserShortcutSettings())
    }

    @Test func savesOnlyWhatDiffersAndReadsItBack() throws {
        var settings = BrowserSettings()
        settings.keymap.assign(shortcut("shift+cmd+u"), to: .copyURL)
        settings.keymap.setPriority(.twice, for: .copyMarkdown)
        settings.keymap.assign(nil, to: .print)
        let data = try JSONEncoder().encode(settings)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let shortcuts = try #require(object["shortcuts"] as? [String: [String: String]])
        #expect(shortcuts == [
            "copy-url": ["shortcut": "shift+cmd+u"],
            "copy-markdown": ["priority": "twice"],
            "print": ["shortcut": "none"],
        ])
        let decoded = try JSONDecoder().decode(BrowserSettings.self, from: data)
        #expect(decoded.keymap == settings.keymap)
    }

    // MARK: Keymap

    @Test func registryDefaultsNeverCollide() {
        let shortcuts = BrowserCommandID.allCases.compactMap(\.defaultShortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
        #expect(BrowserKeymap().command(for: shortcut("shift+cmd+c")) == .copyURL)
        #expect(BrowserKeymap().command(for: shortcut("ctrl+tab")) == .recentTab)
    }

    @Test func aTakenShortcutIsAConflictUntilSwapped() {
        var keymap = BrowserKeymap()
        #expect(keymap.assign(shortcut("shift+cmd+c"), to: .newTab) == .conflict(.copyURL))
        #expect(keymap.shortcut(for: .newTab) == shortcut("cmd+t"))
        #expect(keymap.assign(shortcut("shift+cmd+c"), to: .newTab, swap: true) == .assigned)
        #expect(keymap.shortcut(for: .newTab) == shortcut("shift+cmd+c"))
        #expect(keymap.shortcut(for: .copyURL) == shortcut("cmd+t"))
        #expect(keymap.command(for: shortcut("cmd+t")) == .copyURL)
    }

    @Test func fixedAndBareShortcutsAreRefused() {
        var keymap = BrowserKeymap()
        #expect(keymap.assign(shortcut("cmd+q"), to: .copyURL) == .refused(.quit))
        #expect(keymap.assign(shortcut("cmd+q"), to: .copyURL, swap: true) == .refused(.quit))
        #expect(keymap.assign(shortcut("c"), to: .copyURL) == .invalid)
        #expect(keymap.assign(shortcut("cmd+j"), to: .copy) == .refused(.copy))
        #expect(keymap == BrowserKeymap())
    }

    @Test func resetBringsBackTheDefaultUnlessItWasTaken() {
        var keymap = BrowserKeymap()
        keymap.assign(shortcut("cmd+j"), to: .copyURL)
        keymap.setPriority(.site, for: .copyURL)
        keymap.reset(.copyURL)
        #expect(keymap == BrowserKeymap())
        keymap.assign(shortcut("cmd+j"), to: .copyURL)
        keymap.assign(shortcut("shift+cmd+c"), to: .print)
        keymap.reset(.copyURL)
        #expect(keymap.shortcut(for: .copyURL) == nil)
        #expect(keymap.command(for: shortcut("shift+cmd+c")) == .print)
        // Giving a command its default back stores nothing for it.
        keymap.assign(shortcut("cmd+p"), to: .print)
        #expect(!keymap.isCustomized(.print))
    }

    // MARK: Priority gate

    private let copy = BrowserShortcut("shift+cmd+c")!
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func appWinsRunsAtOnce() {
        var gate = BrowserShortcutGate()
        #expect(gate.keyPressed(.copyURL, shortcut: copy, priority: .app, token: 1, at: start) == .run)
        #expect(gate.pending.isEmpty)
    }

    @Test func siteWinsRunsOnlyWhenThePageLetsTheKeyThrough() {
        var gate = BrowserShortcutGate()
        // WebKit hands the key back: the page didn't handle it.
        #expect(gate.keyPressed(.copyURL, shortcut: copy, priority: .site, token: 1, at: start) == .forward)
        #expect(gate.pageDidNotHandle(token: 1, at: start.addingTimeInterval(0.05)) == (.run, .copyURL))

        // The page called preventDefault: nothing runs, nothing comes back.
        #expect(gate.keyPressed(.copyURL, shortcut: copy, priority: .site, token: 2, at: start) == .forward)
        #expect(gate.pageReported(copy, prevented: true, at: start.addingTimeInterval(0.05)) == nil)
        #expect(gate.pending.isEmpty)

        // The report comes first: it runs, and WebKit's late hand-back is
        // swallowed rather than run twice.
        #expect(gate.keyPressed(.copyURL, shortcut: copy, priority: .site, token: 3, at: start) == .forward)
        #expect(gate.pageReported(copy, prevented: false, at: start.addingTimeInterval(0.05)) == .copyURL)
        #expect(gate.pageDidNotHandle(token: 3, at: start.addingTimeInterval(0.06)) == (.swallow, nil))
    }

    @Test func siteWinsIgnoresOtherKeysAndRunsOnALateHandBack() {
        var gate = BrowserShortcutGate()
        #expect(gate.keyPressed(.copyURL, shortcut: copy, priority: .site, token: 1, at: start) == .forward)
        #expect(gate.pageReported(BrowserShortcut("cmd+c")!, prevented: false, at: start) == nil)
        // A report after the timeout no longer matches…
        #expect(gate.pageReported(copy, prevented: false, at: start.addingTimeInterval(5)) == nil)
        // …but WebKit's hand-back is proof the page left the key alone,
        // however busy the page was.
        #expect(gate.pageDidNotHandle(token: 1, at: start.addingTimeInterval(5)) == (.run, .copyURL))
        // A token the gate never issued isn't its business.
        #expect(gate.pageDidNotHandle(token: 99, at: start) == (.pass, nil))
    }

    @Test func pressTwiceRunsOnTheSecondPressWithinASecond() {
        var gate = BrowserShortcutGate()
        #expect(gate.keyPressed(.copyURL, shortcut: copy, priority: .twice, token: 1, at: start) == .forward)
        // The page didn't want the first press: still not the app's.
        #expect(gate.pageDidNotHandle(token: 1, at: start.addingTimeInterval(0.05)) == (.swallow, nil))
        #expect(gate.pageReported(copy, prevented: false, at: start.addingTimeInterval(0.05)) == nil)
        #expect(gate.keyPressed(.copyURL, shortcut: copy, priority: .twice, token: 2, at: start.addingTimeInterval(0.6)) == .run)
        // Too slow: the second press starts over.
        let later = start.addingTimeInterval(10)
        #expect(gate.keyPressed(.copyURL, shortcut: copy, priority: .twice, token: 3, at: later) == .forward)
        #expect(gate.keyPressed(.copyURL, shortcut: copy, priority: .twice, token: 4, at: later.addingTimeInterval(1.5)) == .forward)
        #expect(gate.keyPressed(.copyURL, shortcut: copy, priority: .twice, token: 5, at: later.addingTimeInterval(2)) == .run)
    }

    @Test func pressTwiceRaceRunsOnce() {
        // A busy page: the second press arrives before WebKit hands the
        // first back. The second runs; the first's late hand-back must not
        // run it again (or reach the menu).
        var gate = BrowserShortcutGate()
        #expect(gate.keyPressed(.copyURL, shortcut: copy, priority: .twice, token: 1, at: start) == .forward)
        #expect(gate.keyPressed(.copyURL, shortcut: copy, priority: .twice, token: 2, at: start.addingTimeInterval(0.3)) == .run)
        #expect(gate.pageDidNotHandle(token: 1, at: start.addingTimeInterval(0.5)) == (.swallow, nil))
        #expect(gate.pending.isEmpty)
    }

    @Test func twoQuickSiteWinsPressesRunOncePerPress() {
        // Key repeat: two presses forwarded before either answer.
        var gate = BrowserShortcutGate()
        #expect(gate.keyPressed(.closeTab, shortcut: copy, priority: .site, token: 1, at: start) == .forward)
        #expect(gate.keyPressed(.closeTab, shortcut: copy, priority: .site, token: 2, at: start.addingTimeInterval(0.03)) == .forward)
        var runs = 0
        // Reports first (oldest press first), then both hand-backs.
        if gate.pageReported(copy, prevented: false, at: start.addingTimeInterval(0.05)) != nil { runs += 1 }
        if gate.pageReported(copy, prevented: false, at: start.addingTimeInterval(0.06)) != nil { runs += 1 }
        #expect(gate.pageDidNotHandle(token: 1, at: start.addingTimeInterval(0.07)) == (.swallow, nil))
        #expect(gate.pageDidNotHandle(token: 2, at: start.addingTimeInterval(0.08)) == (.swallow, nil))
        // A third report has no press left to run.
        if gate.pageReported(copy, prevented: false, at: start.addingTimeInterval(0.09)) != nil { runs += 1 }
        #expect(runs == 2)

        // Hand-backs first: each runs its own press; the reports find none.
        #expect(gate.keyPressed(.closeTab, shortcut: copy, priority: .site, token: 3, at: start) == .forward)
        #expect(gate.keyPressed(.closeTab, shortcut: copy, priority: .site, token: 4, at: start) == .forward)
        #expect(gate.pageDidNotHandle(token: 3, at: start) == (.run, .closeTab))
        #expect(gate.pageDidNotHandle(token: 4, at: start) == (.run, .closeTab))
        #expect(gate.pageReported(copy, prevented: false, at: start) == nil)
    }

    @Test func aHandBackAfterTheReportRanIsSwallowedWhereverFocusWent() {
        // The report ran ⌘L-like command that moved focus; the hand-back
        // still belongs to the gate (the window checks it before focus).
        var gate = BrowserShortcutGate()
        #expect(gate.keyPressed(.openLocation, shortcut: copy, priority: .site, token: 7, at: start) == .forward)
        #expect(gate.pageReported(copy, prevented: false, at: start.addingTimeInterval(0.01)) == .openLocation)
        #expect(gate.pageDidNotHandle(token: 7, at: start.addingTimeInterval(0.2)) == (.swallow, nil))
    }

    // MARK: Recent tabs and the rail

    @Test func recentTabsAreMostRecentFirst() {
        let ids = (0..<7).map { _ in UUID() }
        var recent = BrowserRecentTabs()
        for id in [ids[0], ids[3], ids[1], ids[3], ids[5]] {
            recent.touch(id)
        }
        // Closed ids drop out; never-selected tabs follow in window order.
        #expect(recent.recent(among: ids.filter { $0 != ids[1] }) == [ids[5], ids[3], ids[0], ids[2], ids[4]])
        var switcher = BrowserRecentTabSwitcher(items: [ids[5], ids[3], ids[0]], forward: true)!
        #expect(switcher.selected == ids[3])
        switcher.advance(forward: true)
        switcher.advance(forward: true)
        #expect(switcher.selected == ids[5])
        #expect(BrowserRecentTabSwitcher(items: [ids[0], ids[1]], forward: false)?.selected == ids[1])
        #expect(BrowserRecentTabSwitcher(items: [ids[0]], forward: true) == nil)
    }

    @Test func railWalkWraps() {
        let a = UUID(), b = UUID(), c = UUID()
        let items: [BrowserRailWalk.Item] = [.favorite(a), .pin(b), .tab(c)]
        #expect(BrowserRailWalk.step(items, from: .pin(b), by: 1) == .tab(c))
        #expect(BrowserRailWalk.step(items, from: .tab(c), by: 1) == .favorite(a))
        #expect(BrowserRailWalk.step(items, from: .favorite(a), by: -1) == .tab(c))
        #expect(BrowserRailWalk.step(items, from: .tab(UUID()), by: -1) == .tab(c))
        #expect(BrowserRailWalk.step([], from: nil, by: 1) == nil)
    }
}
