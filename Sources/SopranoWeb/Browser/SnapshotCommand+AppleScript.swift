import AppKit

/// Snapshot flags for AppleScript and the Dock menu, run in order after the
/// first window:
/// - `--applescript <file|text>` (repeatable): runs the script in the
///   harness's own process (`NSAppleScript` on the main thread), so no other
///   app is asked for Automation permission; address the app as `current
///   application`. Prints `applescript: <result>` or `applescript: error
///   <number> <message>`. The dictionary loads only from an app bundle: run
///   the harness as `"Soprano Web Dev.app/Contents/MacOS/SopranoWeb"
///   snapshot …`. `execute javascript` waits for the page, which a script
///   in the app's own process can't (it answers -1712 here, and an event to
///   itself from another thread runs off the main thread): check it with
///   `osascript` against the dev app.
/// - `--allow-applescript-javascript`: turns on Settings ▸ "Allow
///   JavaScript from Apple Events" for the scripts after it.
/// - `--print-dock-menu`: the Dock menu's items as `dock-menu:` lines.
struct SnapshotAppleScriptOptions {
    static let flags: Set<String> = ["--applescript", "--allow-applescript-javascript", "--print-dock-menu"]
    static let usage = """
                               [--applescript <file|text>]... [--allow-applescript-javascript] [--print-dock-menu]
    """

    enum Step {
        case script(String)
        case allowJavaScript
    }

    var steps: [Step] = []
    var printsDockMenu = false

    mutating func parse(_ flag: String, value: () throws -> String) throws {
        switch flag {
        case "--applescript":
            let text = try value()
            steps.append(.script((try? String(contentsOfFile: text, encoding: .utf8)) ?? text))
        case "--allow-applescript-javascript": steps.append(.allowJavaScript)
        default: printsDockMenu = true
        }
    }

    @MainActor
    func run(manager: BrowserWindowManager, wait: (TimeInterval) -> Void) {
        BrowserScripting.manager = manager
        for step in steps {
            switch step {
            case .allowJavaScript:
                manager.settingsStore.update { $0.allowsJavaScriptFromAppleEvents = true }
            case let .script(source):
                print("applescript: \(Self.execute(source))")
                wait(0.2)
            }
        }
        if printsDockMenu {
            // The harness has no app delegate: one made over its manager.
            let delegate = AppDelegate()
            delegate.adopt(manager)
            for item in delegate.applicationDockMenu(NSApp)?.items ?? [] {
                print("dock-menu: \(item.isSeparatorItem ? "—" : item.title)\(item.state == .on ? " ✓" : "")")
            }
        }
    }

    private static func execute(_ source: String) -> String {
        guard let script = NSAppleScript(source: source) else { return "error the script didn't compile" }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "?"
            return "error \(number) \(message)"
        }
        return text(result)
    }

    static func text(_ descriptor: NSAppleEventDescriptor) -> String {
        if descriptor.descriptorType == typeAEList {
            guard descriptor.numberOfItems > 0 else { return "{}" }
            return "{" + (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }.map(text).joined(separator: ", ") + "}"
        }
        return descriptor.stringValue ?? "(\(descriptor.descriptorType))"
    }
}
