import AppKit

/// Drives the address field while the user types: asks the suggestion engine
/// for rows, applies inline completion, fetches search-engine suggestions,
/// and handles ↑/↓, Return, ⌘Return and Esc. The window controller supplies
/// the data and opens what is chosen.
@MainActor
final class BrowserAddressBarController {
    let dropdown: BrowserAddressDropdownView

    /// The engine input (history, bookmarks, other tabs, engine) for a query.
    var makeInput: ((String) -> AddressSuggestionInput)?
    var includesSearchSuggestions: (() -> Bool)?
    /// Opens a chosen row; true asks for a new tab.
    var onOpen: ((AddressSuggestion, Bool) -> Void)?
    var onFocusPage: (() -> Void)?

    private unowned let toolbar: BrowserToolbarView
    private let fetcher = BrowserSearchSuggestionFetcher()
    /// The text the user typed, without the inline-completed part.
    private var typedText = ""
    private var allowsCompletion = false
    private var remote: (query: String, phrases: [String])?
    private var result = AddressSuggestionResult.empty
    private var lastEditWasDeletion = false

    init(toolbar: BrowserToolbarView, theme: AppTheme) {
        self.toolbar = toolbar
        self.dropdown = BrowserAddressDropdownView(theme: theme)
        dropdown.onChoose = { [weak self] index, flags in
            guard let self, self.result.rows.indices.contains(index) else { return }
            self.choose(self.result.rows[index], newTab: flags.contains(.command))
        }
    }

    var isOpen: Bool {
        !dropdown.isHidden
    }

    var rows: [AddressSuggestion] {
        result.rows
    }

    func apply(theme: AppTheme) {
        dropdown.apply(theme: theme)
    }

    // MARK: Typing

    func textDidChange(_ text: String) {
        let editor = toolbar.addressEditor
        let length = (text as NSString).length
        let caretAtEnd = editor.map { $0.selectedRange() == NSRange(location: length, length: 0) } ?? true
        allowsCompletion = AddressInlineCompletion.isAllowed(
            lastEditWasDeletion: lastEditWasDeletion,
            caretAtEnd: caretAtEnd,
            hasMarkedText: editor?.hasMarkedText() ?? false
        )
        lastEditWasDeletion = false
        typedText = text
        if remote?.query != query {
            remote = nil
        }
        refresh(applyingCompletion: true, keepingSelection: false)
        requestRemoteSuggestions()
    }

    /// Key commands from the field editor. Returns true when handled.
    func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            guard isOpen else { return false }
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard isOpen else { return false }
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            return submit(newTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        case Selector(("noop:")):
            // ⌘Return has no text binding and arrives as `noop:`.
            guard let event = NSApp.currentEvent,
                  event.type == .keyDown,
                  event.modifierFlags.contains(.command),
                  event.keyCode == 36 || event.keyCode == 76
            else { return false }
            return submit(newTab: true)
        case #selector(NSResponder.cancelOperation(_:)):
            if isOpen || toolbar.isAddressEdited {
                close()
                toolbar.revertAddress()
            } else {
                onFocusPage?()
            }
            return true
        default:
            if NSStringFromSelector(selector).hasPrefix("delete") {
                // The text change, if any, follows synchronously.
                lastEditWasDeletion = true
                DispatchQueue.main.async { [weak self] in
                    self?.lastEditWasDeletion = false
                }
            }
            return false
        }
    }

    func close() {
        fetcher.cancel()
        remote = nil
        result = .empty
        dropdown.update(rows: [], selectedIndex: 0)
        dropdown.isHidden = true
    }

    // MARK: Snapshot harness

    /// Shows `phrases` as if the search engine had answered for the current
    /// query, so the offscreen harness renders suggestion rows offline.
    func showRemoteSuggestionsForSnapshot(_ phrases: [String]) {
        remote = (query, phrases)
        refresh(applyingCompletion: false, keepingSelection: true)
    }

    // MARK: Private

    private var query: String {
        typedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refresh(applyingCompletion: Bool, keepingSelection: Bool) {
        guard toolbar.addressEditor != nil, var input = makeInput?(typedText) else {
            close()
            return
        }
        input.allowsInlineCompletion = allowsCompletion
        input.remoteSuggestions = remote?.query == query ? remote?.phrases ?? [] : []
        let previousTarget = keepingSelection && dropdown.selectedIndex > 0
            ? result.rows[safe: dropdown.selectedIndex]?.target
            : nil
        result = AddressSuggestionEngine.suggestions(for: input)

        if applyingCompletion,
           let editor = toolbar.addressEditor,
           let suffix = AddressInlineCompletion.suffix(typed: typedText, completion: result.inlineCompletion)
        {
            editor.string = typedText + suffix
            editor.setSelectedRange(NSRange(
                location: (typedText as NSString).length,
                length: (suffix as NSString).length
            ))
        }

        guard !result.rows.isEmpty else {
            dropdown.update(rows: [], selectedIndex: 0)
            dropdown.isHidden = true
            return
        }
        let selection = previousTarget.flatMap { target in
            result.rows.firstIndex { $0.target == target }
        } ?? 0
        dropdown.update(rows: result.rows, selectedIndex: selection)
        dropdown.isHidden = false
    }

    private func requestRemoteSuggestions() {
        let query = query
        guard includesSearchSuggestions?() == true,
              !query.isEmpty,
              let engine = makeInput?(query).searchEngine,
              !AddressQueryMatcher.looksLikeAddress(query, engine: engine)
        else {
            fetcher.cancel()
            return
        }
        fetcher.request(query, engine: engine) { [weak self] phrases in
            guard let self, self.isOpen, self.query == query else { return }
            self.remote = (query, phrases)
            self.refresh(applyingCompletion: false, keepingSelection: true)
        }
    }

    private func moveSelection(by delta: Int) {
        guard !result.rows.isEmpty else { return }
        let index = min(max(0, dropdown.selectedIndex + delta), result.rows.count - 1)
        dropdown.select(index)
        guard let editor = toolbar.addressEditor else { return }
        if index == 0 {
            // Back on the first row: the typed text and its completion.
            let suffix = AddressInlineCompletion.suffix(typed: typedText, completion: result.inlineCompletion) ?? ""
            editor.string = typedText + suffix
            editor.setSelectedRange(NSRange(
                location: (typedText as NSString).length,
                length: (suffix as NSString).length
            ))
        } else {
            let text = result.rows[index].fillText
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    /// Return opens the selected row; with the list closed, the first row
    /// for the field's text. False lets the field submit an empty address.
    private func submit(newTab: Bool) -> Bool {
        let row: AddressSuggestion
        if isOpen, let selected = result.rows[safe: dropdown.selectedIndex] {
            row = selected
        } else {
            let text = toolbar.addressEditor?.string ?? toolbar.addressField.stringValue
            guard var input = makeInput?(text) else { return false }
            input.allowsInlineCompletion = false
            guard let first = AddressSuggestionEngine.suggestions(for: input).rows.first else { return false }
            row = first
        }
        choose(row, newTab: newTab)
        return true
    }

    private func choose(_ row: AddressSuggestion, newTab: Bool) {
        close()
        toolbar.revertAddress()
        onOpen?(row, newTab)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
