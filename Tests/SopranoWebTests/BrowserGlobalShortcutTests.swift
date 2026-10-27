@testable import SopranoWeb
import AppKit
import Testing

/// The global New Little Arc shortcut: which chords it may take, what
/// Settings' recorder does with a key, and the key-code lookup's layout
/// fallback.
struct BrowserGlobalShortcutTests {
    private let keymap = BrowserKeymap(BrowserShortcutSettings())

    private func shortcut(_ text: String) -> BrowserShortcut { BrowserShortcut(text)! }

    @Test func systemEditingAndInAppChordsAreRefused() {
        // Copy and paste would break in every app.
        #expect(!BrowserGlobalShortcut.isAcceptable(shortcut("cmd+c"), keymap: keymap))
        #expect(!BrowserGlobalShortcut.isAcceptable(shortcut("cmd+v"), keymap: keymap))
        // An in-app command (New Tab) and a text-editing chord.
        #expect(!BrowserGlobalShortcut.isAcceptable(shortcut("cmd+t"), keymap: keymap))
        #expect(!BrowserGlobalShortcut.isAcceptable(shortcut("ctrl+a"), keymap: keymap))
        #expect(!BrowserGlobalShortcut.isAcceptable(shortcut("cmd+tab"), keymap: keymap))
        #expect(!BrowserGlobalShortcut.isAcceptable(shortcut("shift+cmd+4"), keymap: keymap))
        // Not assignable: no ⌘ or ⌃.
        #expect(!BrowserGlobalShortcut.isAcceptable(shortcut("shift+n"), keymap: keymap))
    }

    @Test func newLittleArcsOwnChordAndFreeChordsAreAccepted() {
        #expect(BrowserGlobalShortcut.isAcceptable(shortcut("opt+cmd+n"), keymap: keymap))
        #expect(BrowserGlobalShortcut.isAcceptable(shortcut("ctrl+opt+space"), keymap: keymap))
        #expect(BrowserGlobalShortcut.isAcceptable(shortcut(BrowserGlobalShortcut.fallback), keymap: keymap))
    }

    @Test func theRecorderHandlesOnlyItsOwnWindowsKeys() {
        func answer(_ text: String?, keyCode: UInt16 = 45, own: Bool = true) -> BrowserGlobalShortcut.RecorderAnswer {
            BrowserGlobalShortcut.recorderAnswer(
                keyCode: keyCode,
                shortcut: text.map(shortcut),
                inRecorderWindow: own,
                keymap: keymap
            )
        }
        // Typing in a browser window while Settings records goes on.
        #expect(answer("cmd+c", own: false) == .pass)
        #expect(answer(nil, own: false) == .pass)
        #expect(answer(nil, keyCode: 53) == .cancel)
        #expect(answer("cmd+c") == .refuse)
        #expect(answer(nil) == .refuse)
        #expect(answer("opt+cmd+n") == .accept(shortcut("opt+cmd+n")))
    }

    @Test func aStoredChordThatIsTakenFallsBackOnDecode() throws {
        for (stored, expected) in [("cmd+c", "opt+cmd+n"), ("cmd+t", "opt+cmd+n"), ("ctrl+opt+space", "ctrl+opt+space")] {
            let json = Data(#"{"globalLittleArcShortcut": "\#(stored)"}"#.utf8)
            let settings = try JSONDecoder().decode(BrowserSettings.self, from: json)
            #expect(settings.globalLittleArcShortcut == BrowserShortcut(expected)!.storageText)
        }
    }

    @Test func aLayoutWithoutTheCharacterFallsBackToTheNextOne() {
        // A Cyrillic layout types no "n"; the ASCII-capable one does at 45.
        let cyrillic: (UInt16) -> Character? = { $0 == 45 ? "т" : ($0 == 0 ? "ф" : nil) }
        let ascii: (UInt16) -> Character? = { $0 == 45 ? "n" : ($0 == 0 ? "a" : nil) }
        #expect(BrowserGlobalHotKey.keyCode(forCharacter: "n", layouts: [cyrillic, ascii]) == 45)
        #expect(BrowserGlobalHotKey.keyCode(forCharacter: "N", layouts: [ascii]) == 45)
        #expect(BrowserGlobalHotKey.keyCode(forCharacter: "n", layouts: [cyrillic]) == nil)
        // The first layout that has the character wins, at its lowest code.
        let both: (UInt16) -> Character? = { $0 == 3 || $0 == 9 ? "n" : nil }
        #expect(BrowserGlobalHotKey.keyCode(forCharacter: "n", layouts: [both, ascii]) == 3)
    }
}
