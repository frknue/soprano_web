import AppKit

/// `snapshot --address <text>`: seeds the volatile stores with history (visit
/// and typed counts), bookmarks and two open tabs, then types `text` into the
/// address field key by key so inline completion and the dropdown run as
/// they do for a user. Search-engine suggestions are canned; nothing leaves
/// the machine.
@MainActor
enum AddressBarSnapshot {
    static func type(
        _ text: String,
        into controller: BrowserWindowController,
        history: BrowserHistoryStore,
        bookmarks: BrowserBookmarkStore
    ) {
        let tabs = [
            ("https://github.com/frknue/soprano_web/pulls", "Pull requests · frknue/soprano_web"),
            ("https://webkit.org/blog/", "Blog | WebKit"),
        ]
        for (address, title) in tabs {
            let tab = controller.newTab(url: nil, focusAddress: false, select: false)
            tab.suppressNextHistoryRecord = true
            tab.webView.loadHTMLString("<title>\(title)</title>", baseURL: URL(string: address))
        }
        settle(0.6)

        let now = Date()
        let visits: [(String, String, Int, Int, Double)] = [
            // url, title, visits, typed visits, hours since the last visit
            ("https://news.ycombinator.com/", "Hacker News", 6, 4, 30),
            ("https://github.com/", "GitHub", 4, 3, 5),
            ("https://github.com/frknue/soprano_web", "frknue/soprano_web: Soprano Web", 5, 2, 1),
            ("https://gist.github.com/", "Gists", 1, 0, 200),
            ("https://developer.apple.com/documentation/webkit", "WebKit | Apple Developer Documentation", 3, 0, 48),
            ("https://webkit.org/", "WebKit", 2, 1, 72),
            ("https://webkit.org/blog/", "Blog | WebKit", 1, 0, 90),
            ("https://www.swift.org/documentation/", "Documentation | Swift.org", 2, 0, 120),
            ("https://docs.github.com/en", "GitHub Docs", 2, 0, 20),
        ]
        var stamp = 0.0
        for (address, title, count, typed, hours) in visits {
            for visit in 0..<count {
                stamp += 1
                // Spaced apart so the store does not merge repeat visits.
                let date = now.addingTimeInterval(-hours * 3_600 - Double(visit) * 900 - stamp)
                history.record(url: address, title: title, at: date, typed: visit < typed)
            }
        }
        bookmarks.toggle(url: "https://github.com/frknue/soprano_web", title: "Soprano Web")
        bookmarks.toggle(url: "https://developer.apple.com/documentation/webkit", title: "WebKit Documentation")

        controller.focusAddressBar()
        settle(0.1)
        guard let editor = controller.toolbar.addressEditor else {
            FileHandle.standardError.write(Data("Snapshot could not focus the address field.\n".utf8))
            return
        }
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
        controller.addressBar.showRemoteSuggestionsForSnapshot([
            "\(text) tutorial",
            "\(text) documentation",
            "\(text) news",
        ])
        print("address-field: \(editor.string)")
        print("address-rows: \(controller.addressBar.rows.map(\.title).joined(separator: " | "))")
    }

    private static func settle(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }
}
