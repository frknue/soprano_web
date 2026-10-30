import AppKit

/// AppleScript (`Support/SopranoWeb.sdef`): windows, their current Space's
/// tabs, and Spaces, with the commands the dictionary lists. Scripts see what
/// the `browser` CLI sees: private windows are never listed. Scripting
/// objects hold ids, never windows or tabs, and look them up on every use, so
/// a closed one reads as gone. Cocoa Scripting loads the dictionary from the
/// app bundle's `Info.plist` (`OSAScriptingDefinition`); a bare
/// `.build/debug/SopranoWeb` has none.
@MainActor
enum BrowserScripting {
    /// The app's window manager (the harness and tests set their own).
    static weak var manager: BrowserWindowManager?

    static let javaScriptDisabledMessage =
        "Turn on Settings ▸ “Allow JavaScript from Apple Events” to run JavaScript from scripts."

    /// The windows a script sees, the most recently active first.
    static var windows: [BrowserWindowController] {
        manager?.mostRecentlyActiveFirst { $0.kind.acceptsOutsideRequests } ?? []
    }

    static func window(id: UUID) -> BrowserWindowController? {
        windows.first { $0.id == id }
    }

    /// Where `new tab` without a window goes: the most recently active
    /// window that takes tabs.
    static var tabWindow: BrowserWindowController? {
        manager?.mostRecentlyActive { $0.kind.acceptsOutsideRequests && $0.role == .normal }
    }

    static func fail(_ command: NSScriptCommand, _ number: some BinaryInteger, _ message: String) {
        command.scriptErrorNumber = Int(number)
        command.scriptErrorString = message
    }

    /// A script's address: an address or a search, as the address field
    /// reads it.
    static func resolve(_ input: String, in manager: BrowserWindowManager) -> URL? {
        BrowserAddressResolver.resolve(input, searchEngines: manager.settingsStore.settings.searchEngines)
    }
}

// MARK: - Application

extension NSApplication {
    @objc(scriptVersion)
    var scriptVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    @objc(scriptWindows)
    var scriptWindows: [BrowserScriptWindow] {
        BrowserScripting.windows.map { BrowserScriptWindow(id: $0.id) }
    }

    @objc(valueInScriptWindowsWithUniqueID:)
    func valueInScriptWindows(uniqueID: String) -> BrowserScriptWindow? {
        guard let id = UUID(uuidString: uniqueID), BrowserScripting.window(id: id) != nil else { return nil }
        return BrowserScriptWindow(id: id)
    }

    @objc(scriptSpaces)
    var scriptSpaces: [BrowserScriptSpace] {
        (BrowserScripting.manager?.spaces.spaces ?? []).map { BrowserScriptSpace(id: $0.id) }
    }

    @objc(valueInScriptSpacesWithUniqueID:)
    func valueInScriptSpaces(uniqueID: String) -> BrowserScriptSpace? {
        guard let id = UUID(uuidString: uniqueID), BrowserScripting.manager?.spaces.space(id: id) != nil else { return nil }
        return BrowserScriptSpace(id: id)
    }

    /// `new window [URL text] [in space]`.
    @objc(handleNewWindowScriptCommand:)
    func handleNewWindowScriptCommand(_ command: NSScriptCommand) -> BrowserScriptWindow? {
        guard let manager = BrowserScripting.manager else { return nil }
        let arguments = command.evaluatedArguments ?? [:]
        let space = arguments["space"] as? BrowserScriptSpace
        if let space, manager.spaces.space(id: space.id) == nil {
            BrowserScripting.fail(command, errAENoSuchObject, "That Space no longer exists.")
            return nil
        }
        var address: String?
        if let text = arguments["url"] as? String {
            guard let url = BrowserScripting.resolve(text, in: manager) else {
                BrowserScripting.fail(command, errAEParamMissed, "“\(text)” is not an address.")
                return nil
            }
            address = url.absoluteString
        }
        let controller = manager.newWindow(url: address, spaceID: space?.id)
        return BrowserScriptWindow(id: controller.id)
    }

    /// `new tab [URL text] [in window]`.
    @objc(handleNewTabScriptCommand:)
    func handleNewTabScriptCommand(_ command: NSScriptCommand) -> BrowserScriptTab? {
        guard let manager = BrowserScripting.manager else { return nil }
        let arguments = command.evaluatedArguments ?? [:]
        let controller: BrowserWindowController
        if let target = arguments["window"] as? BrowserScriptWindow {
            guard let found = target.controller else {
                BrowserScripting.fail(command, errAENoSuchObject, "That window is closed.")
                return nil
            }
            guard found.role == .normal else {
                BrowserScripting.fail(command, errAEEventFailed, "A \(target.kind) window has no tabs to add to.")
                return nil
            }
            controller = found
        } else {
            controller = BrowserScripting.tabWindow ?? manager.newWindow()
        }
        var address: String?
        if let text = arguments["url"] as? String {
            guard let url = BrowserScripting.resolve(text, in: manager) else {
                BrowserScripting.fail(command, errAEParamMissed, "“\(text)” is not an address.")
                return nil
            }
            address = url.absoluteString
        }
        let tab = controller.newTab(url: address)
        return BrowserScriptTab(windowID: controller.id, tabID: tab.id)
    }
}

// MARK: - Window

@MainActor
@objc(SopranoWebScriptWindow)
final class BrowserScriptWindow: NSObject {
    let id: UUID

    init(id: UUID) {
        self.id = id
    }

    var controller: BrowserWindowController? {
        BrowserScripting.window(id: id)
    }

    @objc(uniqueID)
    var uniqueID: String { id.uuidString }

    @objc(scriptName)
    var scriptName: String {
        guard let controller else { return "" }
        let title = controller.window?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? (controller.selectedTab?.displayTitle ?? "") : title
    }

    @objc(scriptIndex)
    var scriptIndex: Int {
        (BrowserScripting.windows.firstIndex { $0.id == id } ?? -1) + 1
    }

    @objc(kind)
    var kind: String {
        controller?.role.rawValue ?? ""
    }

    @objc(currentSpace)
    var currentSpace: BrowserScriptSpace? {
        guard let controller, controller.role != .popup,
              let space = BrowserScripting.manager?.space(of: controller)
        else { return nil }
        return BrowserScriptSpace(id: space.id)
    }

    @objc(activeTab)
    var activeTab: BrowserScriptTab? {
        controller?.selectedTab.map { BrowserScriptTab(windowID: id, tabID: $0.id) }
    }

    @objc(tabs)
    var tabs: [BrowserScriptTab] {
        (controller?.visibleTabs ?? []).map { BrowserScriptTab(windowID: id, tabID: $0.id) }
    }

    @objc(valueInTabsWithUniqueID:)
    func valueInTabs(uniqueID: String) -> BrowserScriptTab? {
        guard let tabID = UUID(uuidString: uniqueID),
              controller?.visibleTabs.contains(where: { $0.id == tabID }) == true
        else { return nil }
        return BrowserScriptTab(windowID: id, tabID: tabID)
    }

    @objc(handleCloseScriptCommand:)
    func handleCloseScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard let controller, let manager = BrowserScripting.manager else {
            BrowserScripting.fail(command, errAENoSuchObject, "That window is closed.")
            return nil
        }
        manager.closeWindow(controller)
        return nil
    }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        BrowserScriptSpecifiers.window(id)
    }
}

// MARK: - Tab

@MainActor
@objc(SopranoWebScriptTab)
final class BrowserScriptTab: NSObject {
    let windowID: UUID
    let tabID: UUID

    init(windowID: UUID, tabID: UUID) {
        self.windowID = windowID
        self.tabID = tabID
    }

    var controller: BrowserWindowController? {
        BrowserScripting.window(id: windowID)
    }

    /// The tab while it is one of its window's current Space's tabs.
    var tab: BrowserTab? {
        controller?.visibleTabs.first { $0.id == tabID }
    }

    @objc(uniqueID)
    var uniqueID: String { tabID.uuidString }

    @objc(scriptName)
    var scriptName: String {
        guard let tab else { return "" }
        return tab.lifecycle.pendingRestore != nil ? tab.state.title : tab.displayTitle
    }

    /// What the CLI's `url` prints: the address (a restored tab's saved
    /// one), `about:start` on the start page.
    @objc(scriptURL)
    var scriptURL: String {
        get {
            guard let tab else { return "" }
            if tab.lifecycle.pendingRestore != nil { return tab.state.url ?? "about:start" }
            if tab.isStartPage { return "about:start" }
            return tab.failedURL ?? tab.webView.url?.absoluteString ?? tab.pendingURL ?? ""
        }
        set {
            guard let controller, let tab else {
                NSScriptCommand.current()?.scriptErrorNumber = errAENoSuchObject
                NSScriptCommand.current()?.scriptErrorString = "That tab is closed."
                return
            }
            guard let manager = BrowserScripting.manager, let url = BrowserScripting.resolve(newValue, in: manager) else {
                NSScriptCommand.current()?.scriptErrorNumber = errAEParamMissed
                NSScriptCommand.current()?.scriptErrorString = "“\(newValue)” is not an address."
                return
            }
            controller.tabWasUsed(tab)
            controller.navigate(tab, to: url)
        }
    }

    @objc(loading)
    var loading: Bool {
        guard let tab, tab.lifecycle.pendingRestore == nil else { return false }
        return tab.webView.isLoading
    }

    @objc(scriptIndex)
    var scriptIndex: Int {
        (controller?.visibleTabs.firstIndex { $0.id == tabID } ?? -1) + 1
    }

    @objc(selected)
    var selected: Bool {
        controller?.selectedTab?.id == tabID
    }

    @objc(handleSelectScriptCommand:)
    func handleSelectScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard let controller, tab != nil else {
            BrowserScripting.fail(command, errAENoSuchObject, "That tab is closed.")
            return nil
        }
        controller.selectTab(id: tabID, focus: true)
        return nil
    }

    @objc(handleCloseScriptCommand:)
    func handleCloseScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard let controller, tab != nil else {
            BrowserScripting.fail(command, errAENoSuchObject, "That tab is closed.")
            return nil
        }
        controller.closeTab(id: tabID, archive: true)
        return nil
    }

    @objc(handleReloadScriptCommand:)
    func handleReloadScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard let controller, let tab else {
            BrowserScripting.fail(command, errAENoSuchObject, "That tab is closed.")
            return nil
        }
        controller.tabWasUsed(tab)
        controller.loadRestoredTabIfNeeded(tab)
        controller.reload(tab)
        return nil
    }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let container = BrowserScriptSpecifiers.window(windowID),
              let description = NSScriptClassDescription(for: BrowserScriptWindow.self)
        else { return nil }
        return NSUniqueIDSpecifier(
            containerClassDescription: description,
            containerSpecifier: container,
            key: "tabs",
            uniqueID: tabID.uuidString
        )
    }
}

// MARK: - Space

@MainActor
@objc(SopranoWebScriptSpace)
final class BrowserScriptSpace: NSObject {
    let id: UUID

    init(id: UUID) {
        self.id = id
    }

    private var space: BrowserSpace? {
        BrowserScripting.manager?.spaces.space(id: id)
    }

    @objc(uniqueID)
    var uniqueID: String { id.uuidString }

    @objc(scriptName)
    var scriptName: String { space?.displayName ?? "" }

    @objc(scriptIndex)
    var scriptIndex: Int {
        (BrowserScripting.manager?.spaces.spaces.firstIndex { $0.id == id } ?? -1) + 1
    }

    /// `select space "Work"`: the most recently active window with Spaces
    /// shows it (a new window on it when there is none).
    @objc(handleSelectScriptCommand:)
    func handleSelectScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard let manager = BrowserScripting.manager, space != nil else {
            BrowserScripting.fail(command, errAENoSuchObject, "That Space no longer exists.")
            return nil
        }
        if let controller = manager.mostRecentlyActive(where: { $0.kind.acceptsOutsideRequests && $0.hasSpaces }) {
            controller.switchToSpace(id)
        } else {
            manager.newWindow(spaceID: id)
        }
        return nil
    }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        BrowserScriptSpecifiers.application(key: "scriptSpaces", id: id)
    }
}

/// Object specifiers (AppKit asks for them off the main actor's view):
/// built from ids only.
enum BrowserScriptSpecifiers {
    static func application(key: String, id: UUID) -> NSScriptObjectSpecifier? {
        guard let application = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(
            containerClassDescription: application,
            containerSpecifier: nil,
            key: key,
            uniqueID: id.uuidString
        )
    }

    static func window(_ id: UUID) -> NSScriptObjectSpecifier? {
        application(key: "scriptWindows", id: id)
    }
}

// MARK: - execute javascript

/// Why a scripting command failed: its Apple event error number and text.
struct BrowserScriptFailure: Error, Equatable {
    let number: Int
    let message: String
}

extension BrowserScripting {
    /// `execute javascript`'s work: the CLI's `eval` (an expression or an
    /// async function body, the result as JSON text) in `target` (the most
    /// recently active window's selected tab without one), only while
    /// Settings ▸ "Allow JavaScript from Apple Events" is on. Failures
    /// before the page runs anything answer at once; the page's answer
    /// comes later.
    static func executeJavaScript(
        _ source: String?,
        in target: BrowserScriptTab?,
        completion: @escaping (Result<String, BrowserScriptFailure>) -> Void
    ) {
        guard let manager, manager.settingsStore.settings.allowsJavaScriptFromAppleEvents else {
            completion(.failure(BrowserScriptFailure(number: Int(errAEEventNotPermitted), message: javaScriptDisabledMessage)))
            return
        }
        guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(BrowserScriptFailure(number: Int(errAEParamMissed), message: "Give the JavaScript to run.")))
            return
        }
        let target = target ?? windows.first.flatMap { BrowserScriptWindow(id: $0.id).activeTab }
        guard let target, let controller = target.controller, let tab = target.tab else {
            completion(.failure(BrowserScriptFailure(number: Int(errAENoSuchObject), message: "No tab to run it in.")))
            return
        }
        controller.tabWasUsed(tab)
        controller.loadRestoredTabIfNeeded(tab)
        controller.evaluateAsync(source, in: tab.webView) { (result: Result<String, Error>) in
            completion(result.mapError { BrowserScriptFailure(number: Int(errAEEventFailed), message: $0.localizedDescription) })
        }
    }
}

/// `execute javascript "<code>" [in tab]`: `BrowserScripting.executeJavaScript`.
/// The command waits for the page (`suspendExecution`) without blocking the
/// app, so a script in the app's own process can't wait for it.
@objc(SopranoWebExecuteJavaScriptCommand)
final class BrowserExecuteJavaScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Cocoa Scripting runs commands on the main thread.
        nonisolated(unsafe) let command = self
        return MainActor.assumeIsolated { command.run() }
    }

    /// Nil: the command suspended (the page answers later) or failed.
    @MainActor
    private func run() -> String? {
        var immediate: Result<String, BrowserScriptFailure>?
        var isSuspended = false
        BrowserScripting.executeJavaScript(
            directParameter as? String,
            in: evaluatedArguments?["tab"] as? BrowserScriptTab
        ) { [self] result in
            guard isSuspended else {
                immediate = result
                return
            }
            resumeExecution(withResult: answer(result))
        }
        if let immediate {
            return answer(immediate)
        }
        isSuspended = true
        suspendExecution()
        return nil
    }

    @MainActor
    private func answer(_ result: Result<String, BrowserScriptFailure>) -> String? {
        switch result {
        case let .success(json):
            return json
        case let .failure(failure):
            BrowserScripting.fail(self, failure.number, failure.message)
            return nil
        }
    }
}
