import AppKit

/// The standard AppKit submenus. Their actions go to the first responder,
/// so they act on the focused web view or text field.
@MainActor
enum StandardMenus {
    static func spellingAndGrammar() -> NSMenuItem {
        submenu("Spelling and Grammar", [
            item("Show Spelling and Grammar", "showGuessPanel:", ":"),
            item("Check Document Now", "checkSpelling:", ";"),
            .separator(),
            item("Check Spelling While Typing", "toggleContinuousSpellChecking:"),
            item("Check Grammar With Spelling", "toggleGrammarChecking:"),
            item("Correct Spelling Automatically", "toggleAutomaticSpellingCorrection:"),
        ])
    }

    static func substitutions() -> NSMenuItem {
        submenu("Substitutions", [
            item("Show Substitutions", "orderFrontSubstitutionsPanel:"),
            .separator(),
            item("Smart Copy/Paste", "toggleSmartInsertDelete:"),
            item("Smart Quotes", "toggleAutomaticQuoteSubstitution:"),
            item("Smart Dashes", "toggleAutomaticDashSubstitution:"),
            item("Smart Links", "toggleAutomaticLinkDetection:"),
            item("Text Replacement", "toggleAutomaticTextReplacement:"),
        ])
    }

    static func transformations() -> NSMenuItem {
        submenu("Transformations", [
            item("Make Upper Case", "uppercaseWord:"),
            item("Make Lower Case", "lowercaseWord:"),
            item("Capitalize", "capitalizeWord:"),
        ])
    }

    static func speech() -> NSMenuItem {
        submenu("Speech", [
            item("Start Speaking", "startSpeaking:"),
            item("Stop Speaking", "stopSpeaking:"),
        ])
    }

    /// The app menu's Services submenu; AppKit fills it once it is
    /// `NSApp.servicesMenu`.
    static func services() -> NSMenuItem {
        let menu = NSMenu(title: "Services")
        NSApp.servicesMenu = menu
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: String, _ key: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
    }
}

/// Keeps File ▸ Share pointing at the selected page: AppKit's standard share
/// item belongs to one `NSSharingServicePicker`, so a fresh picker replaces
/// it each time the File menu opens.
@MainActor
final class ShareMenuUpdater: NSObject, NSMenuDelegate {
    private let items: () -> [Any]
    private var picker: NSSharingServicePicker?

    init(items: @escaping () -> [Any]) {
        self.items = items
        super.init()
    }

    /// A placeholder until the menu first opens.
    static func placeholder() -> NSMenuItem {
        let item = NSMenuItem(title: "Share…", action: nil, keyEquivalent: "")
        item.identifier = identifier
        item.isEnabled = false
        return item
    }

    static let identifier = NSUserInterfaceItemIdentifier("SopranoWebShare")

    /// `menuWillOpen`, not `menuNeedsUpdate`: AppKit also calls the latter
    /// while it searches key equivalents, on every ⌘ keystroke.
    func menuWillOpen(_ menu: NSMenu) {
        guard let index = menu.items.firstIndex(where: { $0.identifier == Self.identifier }) else { return }
        let current = items()
        let replacement: NSMenuItem
        if current.isEmpty {
            picker = nil
            replacement = Self.placeholder()
        } else {
            let picker = NSSharingServicePicker(items: current)
            self.picker = picker
            replacement = picker.standardShareMenuItem
            replacement.identifier = Self.identifier
        }
        menu.removeItem(at: index)
        menu.insertItem(replacement, at: index)
    }
}
