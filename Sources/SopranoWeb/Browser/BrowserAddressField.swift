import AppKit

/// The address text field. It reports focus as soon as editing starts, not on
/// the first keystroke as `controlTextDidBeginEditing` does, so the toolbar
/// knows the field is focused but not yet edited.
@MainActor
final class BrowserAddressField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocus?()
        }
        return accepted
    }
}
