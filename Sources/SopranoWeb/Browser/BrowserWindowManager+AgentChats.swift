import AppKit
import WebKit

/// The chats page in a tab (`BrowserAgentChatsPage`): opening it, its
/// messages, the state every open chats page shows and which chats the
/// panels and pages show (`BrowserAgentChats.isShown`).
extension BrowserWindowManager {
    /// Selects the chats tab of the current Space of the most recently
    /// active normal window (never a private one) at chat `id` (nil: as it
    /// is, or a new chat), else opens one there or in a new window (⌥⌘E,
    /// the Agent panel's Chats menu).
    func showAgentChats(id: UUID?) {
        let address = BrowserAgentChatsPage.url(for: id)
        guard let target = outsideTabbedController else {
            newWindow(url: address.absoluteString)
            return
        }
        if let tab = target.visibleTabs.first(where: Self.isAgentChatsTab) {
            target.selectTab(id: tab.id, focus: true)
            if id != nil, tab.webView.url != address {
                target.navigate(tab, to: address)
            }
        } else {
            target.newTab(url: address.absoluteString)
        }
        present(target)
    }

    /// A tab showing the chats page, loaded or still to load.
    static func isAgentChatsTab(_ tab: BrowserTab) -> Bool {
        let address = tab.webView.url?.absoluteString ?? tab.pendingURL ?? tab.lifecycle.pendingRestore?.url
        return BrowserAgentChatsPage.isChats(address.flatMap(URL.init(string:)))
    }

    // MARK: Messages

    /// One message from a chats page; anything not from its own main frame
    /// is dropped. The page gets the whole state back.
    func handleAgentChatsMessage(
        _ body: [String: Any],
        tab: BrowserTab,
        frame: WKFrameInfo,
        in controller: BrowserWindowController
    ) {
        guard BrowserAgentChatsPage.acceptsMessage(frameURL: frame.request.url, isMainFrame: frame.isMainFrame),
              frame.securityOrigin.protocol.lowercased() == BrowserStartPageSchemeHandler.scheme,
              frame.securityOrigin.host.lowercased() == BrowserAgentChatsPage.host,
              BrowserAgentChatsPage.isChats(tab.webView.url),
              let message = BrowserAgentChatsPage.Message(body)
        else { return }
        var selected = BrowserAgentChatsPage.chatID(in: tab.webView.url)
        // A private window shows the page but sends nothing to omp.
        guard controller.canShowAgent else {
            pushAgentChatsState(to: tab, in: controller, selected: selected)
            return
        }
        var extra: [String: Any] = [:]
        switch message {
        case let .ready(id), let .select(id):
            selected = id
        case let .send(chat, text):
            let conversation = chat.flatMap(agentChats.conversation(for:)) ?? agentChats.newConversation()
            conversation.send(text, page: nil, from: controller)
            selected = conversation.chatID
            // A new chat whose message never reached omp saved nothing: the
            // page shows why and gets the text back.
            if selected == nil {
                extra["notice"] = conversation.transcript.entries.last { $0.kind == .note }?.text ?? "omp didn’t start."
                extra["draft"] = text
            }
        case let .stop(id):
            agentChats.openConversation(id)?.stop()
        case let .rename(id, title):
            agentChats.store.rename(id, to: title)
        case let .pin(id, pinned):
            agentChats.store.setPinned(id, pinned)
        case let .delete(id):
            // Panels showing it start a new chat.
            for other in controllers where other.agentChat?.conversation.chatID == id {
                other.agentChat?.newChat()
            }
            agentChats.delete(id)
            if selected == id { selected = nil }
        case let .copy(chat, run):
            guard let transcript = agentChats.conversation(for: chat)?.transcript,
                  let answer = BrowserAgentChatsPage.answer(of: run, in: transcript)
            else { break }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer, forType: .string)
        case let .openInPanel(id):
            controller.showAgent()
            controller.agentChat?.open(id)
        }
        pushAgentChatsState(to: tab, in: controller, selected: selected, extra: extra)
        scheduleAgentChatsSweep()
    }

    // MARK: State

    /// What a chats page in `tab` shows with chat `selected`; a private
    /// window's in Folio Ink, without the Agent.
    func agentChatsPageState(for tab: BrowserTab?, selected: UUID?) -> [String: Any] {
        let isPrivate = tab?.dataContext.kind.isPrivate == true
        let conversation = isPrivate ? nil : selected.flatMap(agentChats.conversation(for:))
        // Settings ▸ Agent applies to a chat whose omp isn't running.
        conversation?.syncLaunch(settingsStore.settings)
        let launch = conversation?.launch ?? BrowserAgentLaunch(settings: settingsStore.settings)
        return BrowserAgentChatsPage.state(
            records: agentChats.store.records,
            working: agentChats.workingChats,
            selected: conversation,
            model: BrowserAgentChat.modelName(launch),
            theme: isPrivate ? .folioInk : themeManager.currentTheme,
            available: !isPrivate
        )
    }

    /// `extra` adds one-off keys (`notice`, `draft`) to this push.
    func pushAgentChatsState(to tab: BrowserTab, in controller: BrowserWindowController, selected: UUID?, extra: [String: Any] = [:]) {
        guard BrowserAgentChatsPage.isChats(tab.webView.url) else { return }
        var state = agentChatsPageState(for: tab, selected: selected)
        state["available"] = controller.canShowAgent
        state.merge(extra) { $1 }
        tab.webView.evaluateJavaScript(BrowserAgentChatsPage.applyScript(state), in: nil, in: .page) { _ in }
    }

    /// Every open chats page shows the current state (each its own chat).
    func refreshAgentChatsPages() {
        for controller in controllers {
            for tab in controller.tabsWithPeek where BrowserAgentChatsPage.isChats(tab.webView.url) {
                pushAgentChatsState(to: tab, in: controller, selected: BrowserAgentChatsPage.chatID(in: tab.webView.url))
            }
        }
    }

    /// One refresh per turn of the run loop, however many deltas arrived.
    func scheduleAgentChatsRefresh() {
        guard !agentChatsRefreshScheduled else { return }
        agentChatsRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.agentChatsRefreshScheduled = false
                self.refreshAgentChatsPages()
            }
        }
    }

    /// After a chats page closed or showed another chat: chats nothing
    /// shows any more end once settled.
    func scheduleAgentChatsSweep() {
        guard !agentChatsSweepScheduled else { return }
        agentChatsSweepScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.agentChatsSweepScheduled = false
                self.agentChats.sweep()
            }
        }
    }

    /// A window's Agent panel or a chats page shows `conversation`.
    func isShowingAgentConversation(_ conversation: BrowserAgentConversation) -> Bool {
        controllers.contains { controller in
            if controller.agentChat?.conversation === conversation { return true }
            guard let id = conversation.chatID else { return false }
            return controller.tabsWithPeek.contains { BrowserAgentChatsPage.chatID(in: $0.webView.url) == id }
        }
    }
}
