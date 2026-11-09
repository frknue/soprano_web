import AppKit

/// The address text field. It reports focus as soon as editing starts, not on
/// the first keystroke as `controlTextDidBeginEditing` does, so the toolbar
/// knows the field is focused but not yet edited. The first click into it
/// selects the whole address, as in other browsers: unfocused, the toolbar
/// shows the site and title over it, so a caret at the click point would
/// land somewhere in text the user never saw.
@MainActor
final class BrowserAddressField: NSTextField {
    var onFocus: (() -> Void)?
    /// The mouse-down that focused the field: the window makes a clicked
    /// view first responder before it sends it `mouseDown`.
    private var focusingClick: TimeInterval?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            let event = NSApp.currentEvent
            focusingClick = event?.type == .leftMouseDown ? event?.timestamp : nil
            onFocus?()
        }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        let focusedByThisClick = focusingClick == event.timestamp
        focusingClick = nil
        if focusedByThisClick {
            currentEditor()?.selectAll(nil)
        } else if currentEditor() == nil, let window {
            if window.makeFirstResponder(self) {
                currentEditor()?.selectAll(nil)
            }
        } else {
            super.mouseDown(with: event)
        }
    }
}
