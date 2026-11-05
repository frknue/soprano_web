import AppKit

/// A window's Agent panel: it shows one chat (`BrowserAgentConversation`)
/// at a time and sends what the user types to it with the tab they look
/// at, so the chat's `browser` commands act on this window. New Chat
/// (⇧⌘E) switches to a chat not saved yet (it becomes one with its first
/// message); the Chats menu switches to a saved chat (resuming it: its
/// next message continues its omp session), opens the shown one as a page
/// or shows every chat (`soprano-web://chats`). A chat the panel leaves
/// keeps working until its run ends; `BrowserAgentChats` then ends its omp
/// once nothing shows it.
@MainActor
final class BrowserAgentChat {
    let view: BrowserAgentPanelView
    private(set) var conversation: BrowserAgentConversation
    private let chats: BrowserAgentChats
    private weak var window: BrowserWindowController?
    private var observation: BrowserObservation?
    private var listObservation: BrowserObservation?

    /// How many chats the Chats menu lists.
    static let menuLimit = 15

    init(window: BrowserWindowController, theme: AppTheme) {
        self.window = window
        chats = window.manager.agentChats
        conversation = chats.newConversation()
        view = BrowserAgentPanelView(theme: theme)
        view.onSend = { [weak self] text in self?.send(text) }
        view.onStop = { [weak self] in self?.stop() }
        view.onNewChat = { [weak self] in self?.newChat() }
        view.onClose = { [weak window] in window?.hideAgent() }
        view.onSettings = { [weak window] in window?.manager.showSettings(section: "agent") }
        view.chatsMenu = { [weak self] in self?.makeChatsMenu() ?? NSMenu() }
        view.setIncludesPage(window.settingsStore.settings.agentIncludesPage)
        // A rename on the chats page retitles the panel.
        listObservation = chats.changes.observe { [weak self] id in
            guard let self, id == nil else { return }
            self.refresh()
        }
        bind()
        updatePage()
    }

    var transcript: BrowserAgentTranscript { conversation.transcript }

    /// One line on the panel's state (`browser agent`).
    var statusLine: String { conversation.statusLine }

    func send(_ text: String) {
        guard let window else { return }
        let page = view.includesPage ? window.agentPage : nil
        rememberIcon(of: page)
        conversation.send(text, page: page, from: window)
    }

    /// Aborts the run; omp's `prompt_result` ends it in the transcript.
    func stop() {
        conversation.stop()
    }

    /// A chat not saved yet; the one shown goes on until its run ends.
    func newChat() {
        show(chats.newConversation())
        view.setIncludesPage(window?.settingsStore.settings.agentIncludesPage ?? true)
    }

    /// Shows the saved chat `id`; false when there is no such chat.
    @discardableResult
    func open(_ id: UUID) -> Bool {
        guard let conversation = chats.conversation(for: id) else { return false }
        if conversation !== self.conversation {
            show(conversation)
        }
        return true
    }

    /// The window closed: a chat not saved yet ends with it.
    func shutdown() {
        observation = nil
        listObservation = nil
        if conversation.chatID == nil {
            conversation.shutdown()
        }
    }

    func updatePage() {
        view.pageTitle = window?.agentPage.map { $0.title.isEmpty ? $0.url : $0.title }
    }

    /// Redraws the panel (with the model omp runs or will start with).
    func refresh() {
        if let settings = window?.settingsStore.settings {
            conversation.syncLaunch(settings)
        }
        let title = conversation.chatID.flatMap { chats.store.record($0)?.title }
        view.update(conversation.transcript, model: Self.modelName(conversation.launch), title: title)
    }

    /// The model chip: the model's name without its provider, and the
    /// thinking level when Settings ▸ Agent sets one.
    nonisolated static func modelName(_ launch: BrowserAgentLaunch) -> String {
        let model = launch.model.split(separator: "/").last.map(String.init) ?? "Default model"
        return launch.thinking == .default ? model : "\(model) · \(launch.thinking.name)"
    }

    private func show(_ next: BrowserAgentConversation) {
        let previous = conversation
        conversation = next
        view.resetTranscript()
        bind()
        // A chat never sent has nothing to keep; a saved one ends once its
        // run settles and nothing shows it.
        if previous.chatID == nil {
            previous.shutdown()
        }
        chats.sweep()
    }

    private func bind() {
        observation = conversation.changes.observe { [weak self] in self?.refresh() }
        refresh()
    }

    /// The selected tab's icon, for the card of a message sent with it.
    private func rememberIcon(of page: BrowserAgentPage?) {
        guard let page else { return }
        view.setIcon(window?.selectedTab?.favicon, for: page)
    }

    // MARK: - The Chats menu

    /// Recent chats by group (Pinned, Today, Yesterday, …; the shown one
    /// checked), then Open Chat as Page and Show All Chats.
    private func makeChatsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let saved = chats.store.records
        let records = Array((saved.filter(\.pinned) + saved.filter { !$0.pinned }).prefix(Self.menuLimit))
        for group in BrowserAgentChatGroups.groups(records) {
            let header = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for record in group.records {
                let item = NSMenuItem(title: record.title, action: #selector(BrowserAgentChatMenuTarget.pick(_:)), keyEquivalent: "")
                item.target = menuTarget
                item.representedObject = record.id
                item.state = record.id == conversation.chatID ? .on : .off
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "No chats yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let page = NSMenuItem(title: "Open Chat as Page", action: #selector(BrowserAgentChatMenuTarget.openAsPage(_:)), keyEquivalent: "")
        page.target = menuTarget
        page.isEnabled = conversation.chatID != nil
        menu.addItem(page)
        let all = NSMenuItem(title: "Show All Chats", action: #selector(BrowserAgentChatMenuTarget.showAll(_:)), keyEquivalent: "e")
        all.keyEquivalentModifierMask = [.command, .option]
        all.target = menuTarget
        menu.addItem(all)
        return menu
    }

    private lazy var menuTarget = BrowserAgentChatMenuTarget(chat: self)

    fileprivate func pick(_ id: UUID) {
        open(id)
        view.focusComposer()
    }

    fileprivate func openAsPage() {
        guard let id = conversation.chatID else { return }
        window?.manager.showAgentChats(id: id)
    }

    fileprivate func showAll() {
        window?.manager.showAgentChats(id: conversation.chatID)
    }

    // MARK: - The harness

    /// Feeds `events` as if omp sent them (`--agent` seeds a chat).
    func replay(user text: String, page: BrowserAgentPage?, events: [BrowserAgentEvent]) {
        rememberIcon(of: page)
        conversation.replay(user: text, page: page, events: events)
    }
}

/// The Chats menu's items' target (menu actions need an Objective-C one).
@MainActor
final class BrowserAgentChatMenuTarget: NSObject {
    private weak var chat: BrowserAgentChat?

    init(chat: BrowserAgentChat) {
        self.chat = chat
    }

    @objc func pick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        chat?.pick(id)
    }

    @objc func openAsPage(_ sender: NSMenuItem) {
        chat?.openAsPage()
    }

    @objc func showAll(_ sender: NSMenuItem) {
        chat?.showAll()
    }
}
