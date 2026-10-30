import AppKit

/// Snapshot flags for Reader and Translate, run on the page tab after the
/// wait (the page-info report first, up to 5 s):
/// - `--reader`: shows the page in Reader (the capture draws it) and prints
///   `reader:` lines (`browser reader`'s) and the Reader's DOM: root class,
///   title, paragraphs, images and links.
/// - `--translate <language>`: translates the page into it and prints
///   `translate:` lines: the page's text before and after (first 160
///   characters) and `browser translate`'s lines, or why it couldn't (a
///   pair not downloaded names System Settings' Translation Languages).
struct SnapshotReaderOptions {
    static let flags: Set<String> = ["--reader", "--translate"]
    static let usage = """
                               [--reader] [--translate <language>]
    """

    var showsReader = false
    var translateTo: String?

    mutating func parse(_ flag: String, value: () throws -> String) throws {
        switch flag {
        case "--reader": showsReader = true
        default: translateTo = try value()
        }
    }

    @MainActor
    func run(controller: BrowserWindowController, wait: (TimeInterval) -> Void) {
        guard showsReader || translateTo != nil, let tab = controller.pageTab else { return }
        let deadline = Date().addingTimeInterval(5)
        while !tab.reader.isReaderable, tab.translation.language == nil, Date() < deadline {
            wait(0.05)
        }
        if showsReader {
            var result: Result<BrowserReaderArticle?, Error>?
            if tab.reader.isAvailable {
                controller.setReader(true, in: tab) { result = $0 }
                let until = Date().addingTimeInterval(10)
                while result == nil, Date() < until {
                    wait(0.05)
                }
            }
            if case let .failure(error)? = result {
                print("reader: failed \(error.localizedDescription)")
            }
            controller.readerLines(for: tab).forEach { print("reader: \($0)") }
            let dom = evaluate(
                "[document.documentElement.className, (document.querySelector('.soprano-reader-title') || {}).textContent || '',"
                    + " String(document.querySelectorAll('.soprano-reader-content p').length),"
                    + " String(document.querySelectorAll('.soprano-reader-content img').length),"
                    + " String(document.querySelectorAll('.soprano-reader-content a[href]').length),"
                    + " getComputedStyle(document.body).backgroundColor, getComputedStyle(document.body).fontFamily].join(' | ')",
                in: tab,
                wait: wait
            )
            print("reader: dom \(dom)")
            wait(0.3)
        }
        if let translateTo {
            let sample = "(document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').trim().slice(0, 160)"
            print("translate: before \(evaluate(sample, in: tab, wait: wait))")
            var result: Result<Int, Error>?
            controller.translatePage(in: tab, to: translateTo) { result = $0 }
            let until = Date().addingTimeInterval(120)
            while result == nil, Date() < until {
                wait(0.05)
            }
            switch result {
            case let .success(nodes)?: print("translate: \(nodes) text nodes")
            case let .failure(error)?: print("translate: failed \(error.localizedDescription)")
            case nil: print("translate: timed out")
            }
            controller.translateLines(for: tab).forEach { print("translate: \($0)") }
            print("translate: after \(evaluate(sample, in: tab, wait: wait))")
        }
    }

    @MainActor
    private func evaluate(_ script: String, in tab: BrowserTab, wait: (TimeInterval) -> Void) -> String {
        var value: String?
        tab.webView.evaluateJavaScript(script) { result, _ in
            value = (result as? String) ?? "?"
        }
        let deadline = Date().addingTimeInterval(3)
        while value == nil, Date() < deadline {
            wait(0.05)
        }
        return value ?? "?"
    }
}
