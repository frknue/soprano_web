import AppKit
import WebKit

struct VimiumMark: Equatable, Sendable {
    let url: String
    let x: Double
    let y: Double
}

@MainActor
final class VimiumController: NSObject {
    private enum Mode {
        case normal
        case insert
        case hints(HintSession)
        case visual(line: Bool)
        case markSet
        case markJump
    }

    private struct HintSession {
        var hints: [String]
        var typed: String
        let action: VimiumHintMode
    }

    private weak var windowController: BrowserWindowController?
    private weak var tab: BrowserTab?
    private var mode: Mode = .normal
    private var keyMap = VimiumKeyMap()
    private var prefixTimer: Timer?
    private var isStartingHints = false
    private var localMarks: [String: VimiumMark] = [:]
    private var jumpHistory: [VimiumMark] = []
    private var pendingScroll: VimiumMark?
    private var lastFocusEditable = false
    private var hintGeneration = 0

    init(windowController: BrowserWindowController, tab: BrowserTab) {
        self.windowController = windowController
        self.tab = tab
        super.init()
    }

    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            return false
        }

        let characters = event.charactersIgnoringModifiers ?? ""
        let isEscape = event.keyCode == 53
            || characters == "\u{1b}"
            || (flags.contains(.control) && characters == "[")
        if isEscape {
            return handleEscape()
        }

        switch mode {
        case .insert:
            return false
        case .hints:
            return handleHintKey(characters: characters, event: event)
        case .visual:
            return handleVisualKey(characters: characters, event: event)
        case .markSet, .markJump:
            return handleMarkKey(characters: characters)
        case .normal:
            break
        }

        if isStartingHints {
            return true
        }

        if flags.contains(.control) {
            switch characters.lowercased() {
            case "e":
                evaluate(VimiumPageScripts.scroll(dx: 0, dy: 60))
                return true
            case "y":
                evaluate(VimiumPageScripts.scroll(dx: 0, dy: -60))
                return true
            default:
                return false
            }
        }
        if flags.contains(.option) {
            switch characters.lowercased() {
            case "f":
                startHints(.queue)
                return true
            case "p":
                toast("Pinned tabs are not available yet.")
                return true
            case "m":
                toggleMute()
                return true
            default:
                return false
            }
        }
        guard !flags.contains(.control), !flags.contains(.option) else {
            return false
        }

        guard characters.count == 1 else { return false }
        let wasPending = keyMap.hasPendingInput
        let result = keyMap.feed(characters)
        switch result {
        case .pending:
            schedulePrefixTimeout()
            return true
        case .handled:
            return true
        case let .execute(command, count):
            cancelPrefixTimer()
            execute(command, count: count)
            return true
        case .unknown:
            cancelPrefixTimer()
            if wasPending {
                NSSound.beep()
                return true
            }
            return false
        }
    }

    func pageFocusChanged(_ editable: Bool) {
        lastFocusEditable = editable
        switch mode {
        case .hints, .visual, .markSet, .markJump:
            return
        case .normal, .insert:
            keyMap.reset()
            cancelPrefixTimer()
            mode = editable ? .insert : .normal
        }
    }

    func pageDidStart() {
        hintGeneration += 1
        endHintsWithoutFocus()
        clearVisual()
        mode = .normal
        keyMap.reset()
        cancelPrefixTimer()
        isStartingHints = false
    }

    func pageDidFinish() {
        guard let mark = pendingScroll else { return }
        pendingScroll = nil
        evaluate(VimiumPageScripts.scrollTo(x: mark.x, y: mark.y))
    }

    func startHintsForSnapshot() {
        startHints(.currentTab)
    }

    func shutdown() {
        hintGeneration += 1
        isStartingHints = false
        cancelPrefixTimer()
        evaluate(VimiumPageScripts.endHints())
        evaluate(VimiumPageScripts.clearVisual())
        mode = .normal
        keyMap.reset()
    }

    // MARK: - Modes

    private func handleEscape() -> Bool {
        switch mode {
        case .insert, .normal:
            mode = .normal
            keyMap.reset()
            cancelPrefixTimer()
            if isStartingHints {
                isStartingHints = false
                hintGeneration += 1
                evaluate(VimiumPageScripts.endHints())
            }
            windowController?.endVimiumFind()
            focusPage()
        case .hints:
            endHints()
        case .visual:
            clearVisual()
            mode = .normal
            focusPage()
        case .markSet, .markJump:
            mode = .normal
            keyMap.reset()
            focusPage()
        }
        return true
    }

    private func schedulePrefixTimeout() {
        cancelPrefixTimer()
        let timer = Timer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(prefixTimedOut),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        prefixTimer = timer
    }

    private func cancelPrefixTimer() {
        prefixTimer?.invalidate()
        prefixTimer = nil
    }

    @objc private func prefixTimedOut() {
        prefixTimer = nil
        keyMap.reset()
    }

    private func focusPage() {
        guard let tab, tab.id == windowController?.selectedTab?.id else { return }
        tab.webView.window?.makeFirstResponder(tab.webView)
    }

    private func toast(_ message: String) {
        windowController?.showVimiumToast(message)
    }

    private var currentURL: String {
        guard let tab else { return "" }
        if tab.isStartPage { return "about:start" }
        return tab.failedURL ?? tab.webView.url?.absoluteString ?? ""
    }

    private func evaluate(_ script: String, completion: ((Any?) -> Void)? = nil) {
        tab?.webView.evaluateJavaScript(script) { value, _ in
            completion?(value)
        }
    }

    private func booleanValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }

    private func evaluateString(_ script: String, completion: @escaping (String) -> Void) {
        tab?.webView.evaluateJavaScript(script) { value, _ in
            completion(value as? String ?? "")
        }
    }

    // MARK: - Commands

    private func execute(_ command: VimiumCommand, count: Int) {
        switch command {
        case let .scroll(dx, dy):
            evaluate(VimiumPageScripts.scroll(dx: dx * Double(count), dy: dy * Double(count)))

        case let .scrollPage(direction):
            for _ in 0..<count {
                evaluate(VimiumPageScripts.scrollPage(direction: direction))
            }

        case .scrollToTop:
            rememberCurrentPosition()
            evaluate(VimiumPageScripts.scrollToTop())
        case .scrollToBottom:
            rememberCurrentPosition()
            evaluate(VimiumPageScripts.scrollToBottom())
        case .scrollToLeft:
            evaluate(VimiumPageScripts.scrollToLeft())
        case .scrollToRight:
            evaluate(VimiumPageScripts.scrollToRight())

        case let .reload(hard):
            if hard {
                tab?.webView.reloadFromOrigin()
            } else {
                tab?.webView.reload()
            }

        case .copyCurrentURL:
            let value = currentURL
            guard !value.isEmpty else {
                toast("No URL to copy.")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            toast("Copied \(value)")

        case let .openCopied(newTab):
            guard let value = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else {
                toast("Clipboard is empty.")
                return
            }
            if newTab {
                windowController?.newTab(url: value)
            } else {
                windowController?.navigateCurrent(to: value)
                focusPage()
            }

        case let .hints(mode):
            startHints(mode)

        case .find:
            windowController?.beginVimiumFind()

        case .findNext:
            windowController?.repeatVimiumFind(backwards: false)

        case .findPrevious:
            windowController?.repeatVimiumFind(backwards: true)

        case let .findSelected(forward):
            evaluateString(VimiumPageScripts.selectedText()) { [weak self] text in
                let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else {
                    self?.toast("Select some text first.")
                    return
                }
                self?.windowController?.setVimiumFindQuery(query, backwards: !forward)
            }

        case let .omnibar(newTab, edit):
            let initial = edit ? currentURL : ""
            windowController?.presentVimiumPrompt(initialText: initial, newTab: newTab)

        case let .bookmarks(newTab):
            windowController?.showVimiumBookmarks(newTab: newTab)

        case .tabSearch:
            windowController?.showVimiumTabs()

        case .commandPalette:
            windowController?.showCommandPalette()

        case .back:
            windowController?.goBack()
        case .forward:
            windowController?.goForward()

        case .nextTab:
            for _ in 0..<count { windowController?.selectNextTab() }
        case .previousTab:
            for _ in 0..<count { windowController?.selectPreviousTab() }
        case .firstTab:
            if count > 1 {
                windowController?.selectTab(number: count)
            } else {
                windowController?.selectTab(number: 1)
            }
        case .lastTab:
            windowController?.selectLastTab()
        case .previousVisitedTab:
            windowController?.selectPreviousVisitedTab()

        case .moveTabLeft:
            moveTab(by: -1)
        case .moveTabRight:
            moveTab(by: 1)

        case .createTab:
            for _ in 0..<count {
                windowController?.newTab(focusAddress: false)
            }
        case .duplicateTab:
            if let tab, windowController?.duplicateTab(id: tab.id) == nil {
                toast("Nothing to duplicate.")
            }
        case .closeTab:
            for _ in 0..<count {
                windowController?.closeSelectedTab()
            }
        case .restoreTab:
            windowController?.reopenClosedTab()
            windowController?.revealWindowIfNeeded()

        case .muteTab:
            toggleMute()

        case .zoomIn:
            windowController?.zoomIn()
        case .zoomOut:
            windowController?.zoomOut()
        case .zoomReset:
            windowController?.resetZoom()

        case .insertMode:
            mode = .insert
            keyMap.reset()
            cancelPrefixTimer()

        case let .visual(line):
            startVisual(line: line)

        case .markSet:
            mode = .markSet
            keyMap.reset()
            cancelPrefixTimer()
            toast("Set mark…")

        case .markJump:
            mode = .markJump
            keyMap.reset()
            cancelPrefixTimer()
            toast("Jump to mark…")

        case .help:
            windowController?.showVimiumHelp()

        case .source:
            showSource()

        case let .goUp(root):
            goUp(root: root)

        case .previousLink:
            clickLink(forward: false)
        case .nextLink:
            clickLink(forward: true)

        case .focusInput:
            evaluate(VimiumPageScripts.focusInput()) { [weak self] value in
                guard let self else { return }
                if self.booleanValue(value) {
                    self.mode = .insert
                    self.keyMap.reset()
                } else {
                    self.toast("No text input found.")
                }
            }

        case let .unsupported(message):
            toast(message)
        }
    }

    private func toggleMute() {
        guard let tab, let windowController else { return }
        windowController.toggleMute(tab)
        toast(tab.isMuted ? "Tab muted." : "Tab unmuted.")
    }

    private func moveTab(by offset: Int) {
        guard let tab, let windowController else { return }
        let tabs = windowController.tabs
        guard tabs.count > 1 else {
            toast("Only one tab is open.")
            return
        }
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }),
              tabs.indices.contains(index + offset)
        else {
            toast(offset < 0 ? "Already the first tab." : "Already the last tab.")
            return
        }
        windowController.moveTab(id: tab.id, toIndex: index + offset)
    }

    private func goUp(root: Bool) {
        guard let tab,
              let url = tab.webView.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme != "soprano-web"
        else {
            toast("Can’t go up from this page.")
            return
        }
        if root {
            components.path = "/"
        } else {
            var parts = components.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else {
                toast("Already at the site root.")
                return
            }
            parts.removeLast()
            components.path = parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
        }
        components.query = nil
        components.fragment = nil
        guard let next = components.url else {
            toast("Can’t go up from this page.")
            return
        }
        windowController?.navigate(tab, to: next)
        focusPage()
    }

    private func clickLink(forward: Bool) {
        evaluate(VimiumPageScripts.nextLink(forward: forward)) { [weak self] value in
            if self?.booleanValue(value) != true {
                self?.toast(forward ? "No next page link." : "No previous page link.")
            }
        }
    }

    private func showSource() {
        guard let tab else { return }
        tab.webView.evaluateJavaScript(VimiumPageScripts.source()) { [weak self] value, error in
            guard let self else { return }
            let source = value as? String ?? error?.localizedDescription ?? ""
            let host = tab.webView.url?.host ?? "Page"
            self.windowController?.showVimiumText(
                title: "View Source — \(host)",
                text: source
            )
        }
    }

    // MARK: - Hints

    private func startHints(_ action: VimiumHintMode) {
        guard let tab, tab.id == windowController?.selectedTab?.id else { return }
        hintGeneration += 1
        let generation = hintGeneration
        isStartingHints = true
        let hrefOnly = action != .currentTab
        tab.webView.evaluateJavaScript(VimiumPageScripts.hints(hrefOnly: hrefOnly)) { [weak self] value, _ in
            guard let self else { return }
            guard self.hintGeneration == generation, self.isStartingHints else {
                self.evaluate(VimiumPageScripts.endHints())
                return
            }
            self.isStartingHints = false
            let hints = value as? [String] ?? []
            guard !hints.isEmpty else {
                self.evaluate(VimiumPageScripts.endHints())
                self.toast("No visible links.")
                return
            }
            self.mode = .hints(HintSession(hints: hints, typed: "", action: action))
        }
    }

    private func handleHintKey(characters: String, event: NSEvent) -> Bool {
        guard case .hints(var session) = mode else { return false }
        if event.keyCode == 51 {
            if !session.typed.isEmpty {
                session.typed.removeLast()
                mode = .hints(session)
                evaluate(VimiumPageScripts.filterHints(session.typed))
            }
            return true
        }
        guard characters.count == 1,
              characters.rangeOfCharacter(from: CharacterSet.letters) != nil
        else {
            return true
        }
        session.typed += characters
        let matches = session.hints.filter { $0.hasPrefix(session.typed) }
        if matches.isEmpty {
            session.typed = ""
            mode = .hints(session)
            evaluate(VimiumPageScripts.filterHints(""))
            NSSound.beep()
            return true
        }
        mode = .hints(session)
        evaluate(VimiumPageScripts.filterHints(session.typed))
        if session.hints.contains(session.typed) {
            executeHint(session.typed, action: session.action)
        }
        return true
    }

    private func executeHint(_ hint: String, action: VimiumHintMode) {
        guard let tab else { return }
        switch action {
        case .currentTab:
            tab.webView.evaluateJavaScript(VimiumPageScripts.hintClick(hint)) { [weak self] _, _ in
                self?.endHints(focusInput: true)
            }
        case .newTab, .copyLink, .queue:
            tab.webView.evaluateJavaScript(VimiumPageScripts.hintHref(hint)) { [weak self] value, _ in
                guard let self else { return }
                let href = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !href.isEmpty else {
                    self.toast("That hint has no link.")
                    self.endHints()
                    return
                }
                switch action {
                case .newTab:
                    self.windowController?.newTab(url: href)
                    self.endHints()
                case .copyLink:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(href, forType: .string)
                    self.toast("Copied \(href)")
                    self.endHints()
                case .queue:
                    self.windowController?.newTab(url: href, select: false)
                    self.removeQueuedHint(hint)
                case .currentTab:
                    break
                }
            }
        }
    }

    private func removeQueuedHint(_ hint: String) {
        guard case .hints(var session) = mode else { return }
        session.hints.removeAll { $0 == hint }
        session.typed = ""
        if session.hints.isEmpty {
            mode = .hints(session)
            endHints()
            return
        }
        mode = .hints(session)
        evaluate(VimiumPageScripts.removeHint(hint))
        evaluate(VimiumPageScripts.filterHints(""))
    }

    private func endHints(focusInput: Bool = false) {
        hintGeneration += 1
        isStartingHints = false
        evaluate(VimiumPageScripts.endHints())
        mode = focusInput && lastFocusEditable ? .insert : .normal
        keyMap.reset()
        focusPage()
    }

    private func endHintsWithoutFocus() {
        hintGeneration += 1
        isStartingHints = false
        if case .hints = mode {
            evaluate(VimiumPageScripts.endHints())
            mode = .normal
        }
    }

    // MARK: - Visual mode

    private func startVisual(line: Bool) {
        evaluate(VimiumPageScripts.startVisual(line: line))
        mode = .visual(line: line)
        keyMap.reset()
        focusPage()
    }

    private func handleVisualKey(characters: String, event: NSEvent) -> Bool {
        guard case let .visual(line) = mode else { return false }
        switch characters {
        case "h":
            modifyVisual(alter: "extend", direction: "backward", granularity: "character")
        case "l":
            modifyVisual(alter: "extend", direction: "forward", granularity: "character")
        case "j":
            modifyVisual(alter: "extend", direction: "forward", granularity: "line")
        case "k":
            modifyVisual(alter: "extend", direction: "backward", granularity: "line")
        case "w":
            modifyVisual(alter: "extend", direction: "forward", granularity: "word")
        case "b":
            modifyVisual(alter: "extend", direction: "backward", granularity: "word")
        case "0", "^":
            modifyVisual(alter: "extend", direction: "backward", granularity: "lineboundary")
        case "$":
            modifyVisual(alter: "extend", direction: "forward", granularity: "lineboundary")
        case "y":
            evaluateString(VimiumPageScripts.visualText()) { [weak self] text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self?.toast("Yanked \(text.count) characters.")
            }
            clearVisual()
            mode = .normal
            focusPage()
        case "p", "P":
            toast("Paste-and-go is not available in visual mode.")
        case "v":
            clearVisual()
            mode = .normal
            focusPage()
        case "V":
            mode = .visual(line: !line)
        default:
            if event.keyCode == 53 {
                return handleEscape()
            }
        }
        return true
    }

    private func modifyVisual(alter: String, direction: String, granularity: String) {
        evaluate(VimiumPageScripts.modifyVisual(
            alter: alter,
            direction: direction,
            granularity: granularity
        ))
    }

    private func clearVisual() {
        evaluate(VimiumPageScripts.clearVisual())
    }

    // MARK: - Marks

    private func handleMarkKey(characters: String) -> Bool {
        guard characters.count == 1 else {
            mode = .normal
            keyMap.reset()
            return true
        }
        if characters == "`" {
            mode = .normal
            jumpBack()
            return true
        }
        guard characters.rangeOfCharacter(from: CharacterSet.letters) != nil else {
            mode = .normal
            return true
        }
        switch mode {
        case .markSet:
            mode = .normal
            setMark(characters)
        case .markJump:
            mode = .normal
            jumpToMark(characters)
        default:
            break
        }
        return true
    }

    private func setMark(_ letter: String) {
        guard let tab else { return }
        tab.webView.evaluateJavaScript(VimiumPageScripts.scrollPosition()) { [weak self] value, _ in
            guard let self,
                  let text = value as? String,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = object["url"] as? String,
                  let x = object["x"] as? Double,
                  let y = object["y"] as? Double
            else { return }
            let mark = VimiumMark(url: url, x: x, y: y)
            if letter == letter.uppercased(), letter != letter.lowercased() {
                self.windowController?.globalVimiumMarks[letter] = mark
            } else {
                self.localMarks[letter] = mark
            }
            self.toast("Mark \(letter) set.")
        }
    }

    private func jumpToMark(_ letter: String) {
        let mark: VimiumMark?
        if letter == letter.uppercased(), letter != letter.lowercased() {
            mark = windowController?.globalVimiumMarks[letter]
        } else {
            mark = localMarks[letter]
        }
        guard let mark else {
            toast("Mark \(letter) is not set.")
            return
        }
        jump(to: mark, record: true)
    }

    private func jumpBack() {
        guard let mark = jumpHistory.popLast() else {
            toast("No previous jump.")
            return
        }
        jump(to: mark, record: false)
    }

    private func jump(to mark: VimiumMark, record: Bool) {
        if record {
            rememberCurrentPosition()
        }
        guard let tab else { return }
        if currentURL == mark.url || tab.webView.url?.absoluteString == mark.url {
            evaluate(VimiumPageScripts.scrollTo(x: mark.x, y: mark.y))
        } else {
            pendingScroll = mark
            if let url = URL(string: mark.url) {
                windowController?.navigate(tab, to: url)
            }
        }
        focusPage()
    }

    private func rememberCurrentPosition() {
        guard let tab else { return }
        tab.webView.evaluateJavaScript(VimiumPageScripts.scrollPosition()) { [weak self] value, _ in
            guard let self,
                  let text = value as? String,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = object["url"] as? String,
                  let x = object["x"] as? Double,
                  let y = object["y"] as? Double
            else { return }
            self.jumpHistory.append(VimiumMark(url: url, x: x, y: y))
            if self.jumpHistory.count > 20 {
                self.jumpHistory.removeFirst(self.jumpHistory.count - 20)
            }
        }
    }
}
