import AppKit
import WebKit

/// Snapshot steps for sheets and page buttons: fill and submit the HTTP
/// sign-in sheet, press a sheet button, click a page element through the
/// page's own handlers, and draw the attached sheet into the capture.
extension SnapshotCommand {
    /// Fills the sign-in sheet with `user:password` and presses Sign In.
    static func submitSignIn(_ credentials: String, controller: BrowserWindowController) {
        guard let sheet = controller.credentialPrompts.sheet else {
            FileHandle.standardError.write(Data("snapshot: no sign-in sheet to fill\n".utf8))
            return
        }
        let parts = credentials.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        sheet.userField.stringValue = parts.first.map(String.init) ?? ""
        sheet.passwordField.stringValue = parts.count > 1 ? String(parts[1]) : ""
        sheet.alert.buttons.first?.performClick(nil)
    }

    static func pressSheetButton(_ title: String, window: NSWindow) {
        guard let sheet = window.attachedSheet,
              let button = buttons(in: sheet.contentView).first(where: { $0.title == title })
        else {
            FileHandle.standardError.write(Data("snapshot: no sheet button “\(title)”\n".utf8))
            return
        }
        button.performClick(nil)
    }

    /// Clicks the first element matching `selector` in the selected tab's
    /// main frame, so its own handlers (and their page messages) run.
    static func click(_ selector: String, controller: BrowserWindowController) {
        guard let webView = controller.selectedTab?.webView else { return }
        let literal = String(data: try! JSONEncoder().encode(selector), encoding: .utf8)!
        webView.evaluateJavaScript(
            "(() => { const el = document.querySelector(\(literal)); if (!el) return false; el.click(); return true; })()"
        ) { result, _ in
            if result as? Bool != true {
                FileHandle.standardError.write(Data("snapshot: nothing to click for \(selector)\n".utf8))
            }
        }
    }

    /// Prints the attached sheet's texts and field values, then draws it at
    /// its place over the window capture (call inside `lockFocus`).
    static func drawAttachedSheet(of window: NSWindow, in content: NSView) {
        guard let sheet = window.attachedSheet,
              let sheetView = sheet.contentView?.superview ?? sheet.contentView
        else {
            print("sheet: none")
            return
        }
        for text in texts(in: sheet.contentView) {
            print("sheet: \(text)")
        }
        sheetView.layoutSubtreeIfNeeded()
        sheetView.displayIfNeeded()
        guard let rep = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds) else { return }
        sheetView.cacheDisplay(in: sheetView.bounds, to: rep)
        let image = NSImage(size: sheetView.bounds.size)
        image.addRepresentation(rep)
        let inWindow = sheet.convertToScreen(sheetView.convert(sheetView.bounds, to: nil))
        let frame = content.convert(window.convertFromScreen(inWindow), from: nil)
        image.draw(in: frame)
    }

    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }

    private static func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var result: [String] = []
        if let field = view as? NSSecureTextField {
            result.append("secure field (\(field.stringValue.count) characters)")
        } else if let field = view as? NSTextField, !field.stringValue.isEmpty {
            result.append(field.isEditable ? "field “\(field.stringValue)”" : field.stringValue)
        } else if let field = view as? NSTextField, field.isEditable {
            result.append("field “” (\(field.placeholderString ?? ""))")
        } else if let button = view as? NSButton, !button.title.isEmpty {
            result.append("button “\(button.title)”")
        }
        return result + view.subviews.flatMap { texts(in: $0) }
    }
}
