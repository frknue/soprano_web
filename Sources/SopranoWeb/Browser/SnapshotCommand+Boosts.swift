import AppKit

/// Snapshot flags for Boosts:
/// - `--boost-css <css>`, `--boost-js <js>`, `--boost-zap <selector>`
///   (repeatable): a Boost for the `--url` page's host, saved before the
///   page loads.
/// - `--boost-editor`: the Boost editor for the page, opened after the
///   wait (`--sheet` draws it). Prints `boost:` lines with the page's Boost
///   `<style>` and `document.title`.
struct SnapshotBoostOptions {
    static let flags: Set<String> = ["--boost-css", "--boost-js", "--boost-zap", "--boost-editor"]
    static let usage = """
                               [--boost-css <css>] [--boost-js <js>] [--boost-zap <selector>]... [--boost-editor]
    """

    var css: String?
    var js: String?
    var zaps: [String] = []
    var showsEditor = false

    var seeds: Bool { css != nil || js != nil || !zaps.isEmpty }

    mutating func parse(_ flag: String, value: () throws -> String) throws {
        switch flag {
        case "--boost-css": css = try value()
        case "--boost-js": js = try value()
        case "--boost-zap": zaps.append(try value())
        default: showsEditor = true
        }
    }

    /// Saves the Boost for `url`'s host.
    @MainActor
    func seed(_ store: BrowserBoostStore, url: String?) {
        guard seeds else { return }
        guard let host = BrowserBoost.key(for: url.flatMap(URL.init(string:))) else {
            print("boost: --url is not an http(s) page")
            return
        }
        store.update(host: host) { boost in
            if let css { boost.css = css }
            if let js { boost.js = js }
            boost.zaps += zaps
        }
        print("boost: seeded \(host)")
    }

    /// Prints the page's Boost state, then opens the editor when asked.
    @MainActor
    func run(controller: BrowserWindowController, wait: (TimeInterval) -> Void) {
        guard seeds || showsEditor, let tab = controller.pageTab else { return }
        var done = false
        tab.webView.evaluateJavaScript(
            "(function () { var s = document.querySelector('style[\(BrowserBoostScripts.styleAttribute)]');"
                + " return [s ? s.textContent : '', document.title, getComputedStyle(document.body).backgroundColor]; })()"
        ) { result, _ in
            let values = result as? [String] ?? []
            print("boost: style \(values.first.map { $0.isEmpty ? "none" : "\($0.utf8.count) bytes" } ?? "?")")
            print("boost: title \(values.count > 1 ? values[1] : "?")")
            print("boost: body background \(values.count > 2 ? values[2] : "?")")
            done = true
        }
        let deadline = Date().addingTimeInterval(3)
        while !done, Date() < deadline {
            wait(0.05)
        }
        if showsEditor {
            controller.showBoostEditor()
            wait(0.35)
            print("boost: editor \(controller.boostEditor == nil ? "not shown" : "shown for \(controller.boostEditor!.host)")")
        }
    }
}
