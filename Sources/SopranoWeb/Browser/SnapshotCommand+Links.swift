import AppKit
import WebKit

/// Snapshot harness steps for link behavior: real mouse clicks into the
/// selected page (WebKit treats them as user gestures) and a tab listing.
extension SnapshotCommand {
    /// `--click [cmd-|shift-cmd-|middle-]X,Y`: X,Y in page points from the
    /// web view's top-left corner.
    struct Click: Equatable {
        enum Kind: String {
            case plain
            case cmd
            case shiftCmd = "shift-cmd"
            case middle
        }

        var kind: Kind
        var point: NSPoint

        nonisolated static func parse(_ value: String) -> Click? {
            var kind = Kind.plain
            var rest = Substring(value)
            for candidate in [Kind.shiftCmd, .cmd, .middle] where rest.hasPrefix(candidate.rawValue + "-") {
                kind = candidate
                rest = rest.dropFirst(candidate.rawValue.count + 1)
                break
            }
            let parts = rest.split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
            return Click(kind: kind, point: NSPoint(x: x, y: y))
        }
    }

    static func perform(_ click: Click, in webView: WKWebView) {
        guard let window = webView.window else { return }
        let local = NSPoint(
            x: click.point.x,
            y: webView.isFlipped ? click.point.y : webView.bounds.height - click.point.y
        )
        let location = webView.convert(local, to: nil)
        let flags: NSEvent.ModifierFlags = switch click.kind {
        case .plain, .middle: []
        case .cmd: .command
        case .shiftCmd: [.shift, .command]
        }
        let isMiddle = click.kind == .middle
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseUp || type == .otherMouseUp ? 0 : 1
            ) else { return nil }
            guard isMiddle, let cgEvent = event.cgEvent else { return event }
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
            return NSEvent(cgEvent: cgEvent)
        }
        if isMiddle {
            if let down = event(.otherMouseDown) { webView.otherMouseDown(with: down) }
            if let up = event(.otherMouseUp) { webView.otherMouseUp(with: up) }
        } else {
            if let down = event(.leftMouseDown) { webView.mouseDown(with: down) }
            if let up = event(.leftMouseUp) { webView.mouseUp(with: up) }
        }
    }

    /// `--print-tabs`: one line per tab, `* ` marks the selected tab.
    static func printTabs(_ controller: BrowserWindowController) {
        for (index, tab) in controller.tabs.enumerated() {
            let mark = tab.id == controller.selectedTab?.id ? "*" : " "
            let url = tab.webView.url?.absoluteString ?? tab.pendingURL ?? ""
            let opener = tab.links.openerID.flatMap { id in controller.tabs.firstIndex { $0.id == id } }
            let blocked = tab.links.blockedPopups.map(\.absoluteString).joined(separator: " ")
            print("\(mark) \(index) \(tab.displayTitle) | \(url)"
                + (opener.map { " | opener \($0)" } ?? "")
                + (blocked.isEmpty ? "" : " | blocked \(blocked)"))
        }
        for sheet in controller.window?.sheets ?? [] {
            print("sheet: \(texts(in: sheet.contentView).joined(separator: " | "))")
        }
        if let toast = controller.vimiumToastView, toast.superview != nil {
            print("toast: \(texts(in: toast).joined(separator: " | "))")
        }
    }

    /// The labels, buttons and checkboxes of a sheet, in view order.
    private static func texts(in view: NSView?) -> [String] {
        guard let view, !view.isHidden else { return [] }
        var result: [String] = []
        if let button = view as? NSButton, !button.title.isEmpty {
            result.append("(\(button.title)\(button.state == .on ? " ✓" : ""))")
        } else if let field = view as? NSTextField, !field.stringValue.isEmpty {
            result.append(field.stringValue)
        }
        return result + view.subviews.flatMap { texts(in: $0) }
    }
}
