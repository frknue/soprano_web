import AppKit
import WebKit

/// Snapshot harness flags for the page tools. Each writes its file or log
/// line before the PNG is captured:
/// `--print-to <pdf>` prints through the print operation into a PDF file,
/// `--page-print-to <pdf>` does the same for the page's own `window.print()`,
/// `--export-pdf <pdf>`, `--save-archive <webarchive>`, `--save-source <html>`
/// run Export as PDF and Save As without the save panel,
/// `--select <css>` selects an element's text and
/// `--context-menu <css>` right-clicks an element, logs WebKit's menu item
/// identifiers and the rewritten menu, then closes it;
/// `--context-menu-pick <title>` also chooses the item with that title.
@MainActor
enum SnapshotPageTools {
    struct Options {
        var printTo: URL?
        var pagePrintTo: URL?
        var exportPDF: URL?
        var saveArchive: URL?
        var saveSource: URL?
        var select: String?
        var contextMenu: String?
        var contextMenuPick: String?
    }

    nonisolated static let flags = [
        "--print-to", "--page-print-to", "--export-pdf", "--save-archive", "--save-source",
        "--select", "--context-menu", "--context-menu-pick",
    ]

    static let usage = """
                               [--print-to <pdf>] [--page-print-to <pdf>] [--export-pdf <pdf>]
                               [--save-archive <file>] [--save-source <file>] [--select <css>]
                               [--context-menu <css>] [--context-menu-pick <title>]
    """

    nonisolated static func parse(_ option: String, _ value: String, into options: inout Options) {
        switch option {
        case "--print-to": options.printTo = URL(fileURLWithPath: value)
        case "--page-print-to": options.pagePrintTo = URL(fileURLWithPath: value)
        case "--export-pdf": options.exportPDF = URL(fileURLWithPath: value)
        case "--save-archive": options.saveArchive = URL(fileURLWithPath: value)
        case "--save-source": options.saveSource = URL(fileURLWithPath: value)
        case "--select": options.select = value
        case "--context-menu": options.contextMenu = value
        case "--context-menu-pick": options.contextMenuPick = value
        default: break
        }
    }

    static func run(_ options: Options, controller: BrowserWindowController) {
        guard let tab = controller.selectedTab, let window = controller.window else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        let webView = tab.webView
        if let url = options.printTo {
            let operation = BrowserWindowController.printOperation(
                for: webView,
                title: tab.displayTitle,
                printInfo: nil
            )
            report("print-to", url, runToFile(operation, window: window, url: url))
        }
        if let url = options.pagePrintTo {
            var calls = 0
            var result: Error?
            BrowserWindowController.printPresenter = { operation, window in
                calls += 1
                result = runToFile(operation, window: window, url: url)
            }
            evaluate(webView, "window.print(); true")
            spin(until: { calls > 0 }, timeout: 5)
            BrowserWindowController.printPresenter = nil
            print("page-print: window.print() reached the print path \(calls) time(s)")
            report("page-print-to", url, calls > 0 ? result : CocoaError(.userCancelled))
        }
        if let url = options.exportPDF {
            report("export-pdf", url, waitFor { done in controller.writePDF(of: webView, to: url, completion: done) })
        }
        if let url = options.saveArchive {
            report("save-archive", url, waitFor { done in
                controller.save(webView, as: .webArchive, to: url, completion: done)
            })
        }
        if let url = options.saveSource {
            report("save-source", url, waitFor { done in
                controller.save(webView, as: .pageSource, to: url, completion: done)
            })
        }
        if let selector = options.select {
            evaluate(webView, """
            (() => { const e = document.querySelector(\(quoted(selector)));
              if (!e) { return false; } getSelection().selectAllChildren(e); return true; })()
            """)
        }
        if let selector = options.contextMenu {
            openContextMenu(on: selector, in: webView, window: window, pick: options.contextMenuPick)
            if options.contextMenuPick != nil {
                let tabs = controller.tabs.map { $0.webView.url?.absoluteString ?? $0.pendingURL ?? "start page" }
                print("  tabs: \(tabs), selected index \(controller.selectedIndex)")
                for record in controller.downloads.records {
                    print("  download \(record.filename) \(record.state) \(record.path ?? "-")")
                }
            }
        }
    }

    // MARK: Print

    private final class PrintCompletion: NSObject {
        var finished = false
        var success = false

        @objc func printOperationDidRun(
            _ operation: NSPrintOperation,
            success: Bool,
            contextInfo: UnsafeMutableRawPointer?
        ) {
            self.success = success
            finished = true
        }
    }

    /// Saves the operation's output to `url` without print or progress
    /// panels, the way the print sheet runs it.
    private static func runToFile(_ operation: NSPrintOperation, window: NSWindow, url: URL) -> Error? {
        operation.printInfo.jobDisposition = .save
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        let completion = PrintCompletion()
        operation.runModal(
            for: window,
            delegate: completion,
            didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)),
            contextInfo: nil
        )
        spin(until: { completion.finished }, timeout: 30)
        guard completion.finished else { return CocoaError(.userCancelled) }
        return completion.success ? nil : CocoaError(.fileWriteUnknown)
    }

    // MARK: Context menu

    private static func openContextMenu(on selector: String, in webView: BrowserWebView, window: NSWindow, pick: String?) {
        let point = evaluate(webView, """
        (() => { const e = document.querySelector(\(quoted(selector)));
          if (!e) { return ""; } e.scrollIntoView({block: "center"});
          const r = e.getBoundingClientRect(); return (r.left + r.width / 2) + "," + (r.top + r.height / 2); })()
        """) as? String ?? ""
        let parts = point.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else {
            print("context-menu: no element matches \(selector)")
            return
        }
        let local = NSPoint(x: parts[0], y: webView.isFlipped ? parts[1] : webView.bounds.height - parts[1])
        let location = webView.convert(local, to: nil)

        var sawMenu = false
        let previousObserver = BrowserWindowController.contextMenuObserver
        BrowserWindowController.contextMenuObserver = { identifiers, titles, target, menu in
            sawMenu = true
            if let target {
                let milliseconds = Int(Date().timeIntervalSince(target.capturedAt) * 1000)
                print("  contextMenu message arrived \(milliseconds) ms before willOpenMenu")
                print("  target link=\(target.link?.absoluteString ?? "-") image=\(target.image?.absoluteString ?? "-") selection=\(target.selection.map { "\"\($0)\"" } ?? "-")")
            } else {
                print("  willOpenMenu without a captured target")
            }
            for (identifier, title) in zip(identifiers, titles) {
                print("  webkit  \(identifier ?? "-")  \"\(title)\"")
            }
            for item in menu.items {
                let name = item.isSeparatorItem ? "-"
                    : item.target is BrowserWindowController ? "(browser)"
                    : item.identifier?.rawValue ?? "?"
                print("  final   \(name)  \"\(item.title)\"")
            }
            if let pick, let index = menu.items.firstIndex(where: { $0.title == pick }) {
                print("  pick \"\(pick)\"")
                menu.performActionForItem(at: index)
            }
            // Empty the menu so nothing appears, then end the tracking loop
            // AppKit starts after this callback.
            menu.removeAllItems()
            menu.perform(
                #selector(NSMenu.cancelTrackingWithoutAnimation),
                with: nil,
                afterDelay: 0.05,
                inModes: [.common, .eventTracking]
            )
        }
        defer { BrowserWindowController.contextMenuObserver = previousObserver }

        print("context-menu \(selector): right-click at \(Int(location.x)),\(Int(location.y))")
        webView.contextMenuTarget = nil
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else { continue }
            window.sendEvent(event)
        }
        spin(until: { sawMenu }, timeout: 5)
        spin(until: { false }, timeout: 1.5)
        print("context-menu \(selector): \(sawMenu ? "done" : "no menu opened")")
    }

    // MARK: Helpers

    private static func waitFor(_ start: (@escaping @MainActor (Error?) -> Void) -> Void) -> Error? {
        var finished = false
        var result: Error?
        start { error in
            result = error
            finished = true
        }
        spin(until: { finished }, timeout: 30)
        return finished ? result : CocoaError(.userCancelled)
    }

    private static func report(_ name: String, _ url: URL, _ error: Error?) {
        if let error {
            print("\(name): failed: \(error.localizedDescription)")
        } else {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("\(name): wrote \(url.path) (\(size) bytes)")
        }
    }

    @discardableResult
    private static func evaluate(_ webView: WKWebView, _ script: String) -> Any? {
        var finished = false
        var value: Any?
        webView.evaluateJavaScript(script) { result, _ in
            value = result
            finished = true
        }
        spin(until: { finished }, timeout: 5)
        return value
    }

    private static func quoted(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private static func spin(until done: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }
}
