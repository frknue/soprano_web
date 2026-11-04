import AppKit

extension BrowserWindowController {
    // MARK: - Agent panel

    /// Normal windows only: a private window's pages stay out of omp, and a
    /// pop-up or Little Arc has no room for it.
    var canShowAgent: Bool {
        role == .normal && !kind.isPrivate
    }

    /// The tab a message goes with: the page the user looks at (a Peek's),
    /// nil on a start page.
    var agentPage: BrowserAgentPage? {
        guard let tab = pageTab, !tab.isStartPage else { return nil }
        guard let url = tab.webView.url?.absoluteString ?? tab.state.url, !url.isEmpty else { return nil }
        return BrowserAgentPage(title: tab.displayTitle, url: url)
    }

    /// ⌘E: shows the panel and its composer; in a shown panel, the
    /// composer, or hides the panel when the composer has the keyboard.
    func toggleAgent() {
        guard isAgentVisible else {
            showAgent()
            return
        }
        if agentChat?.view.isComposerFocused == true {
            hideAgent()
        } else {
            agentChat?.view.focusComposer()
        }
    }

    func showAgent(focus: Bool = true) {
        guard canShowAgent else { return }
        if isSidebarVisible {
            hideSidebar()
        }
        let chat = agentChat ?? makeAgentChat()
        chat.updatePage()
        chat.view.isHidden = false
        isAgentVisible = true
        webTrailingToRoot.isActive = false
        webTrailingToSidebar.isActive = false
        webTrailingToAgent?.isActive = true
        updateWindowMinSize()
        viewNeedsLayout()
        if focus {
            chat.view.focusComposer()
        }
    }

    func hideAgent() {
        guard isAgentVisible, let chat = agentChat else { return }
        let hadKeyboard = chat.view.isComposerFocused
        isAgentVisible = false
        chat.view.isHidden = true
        webTrailingToAgent?.isActive = false
        webTrailingToRoot.isActive = true
        updateWindowMinSize()
        viewNeedsLayout()
        if hadKeyboard, let webView = pageTab?.webView {
            window?.makeFirstResponder(webView)
        }
    }

    /// ⇧⌘E: a new chat in a shown panel.
    func newAgentChat() {
        guard canShowAgent else { return }
        showAgent()
        agentChat?.newChat()
    }

    private func makeAgentChat() -> BrowserAgentChat {
        let chat = BrowserAgentChat(window: self, theme: theme)
        let view = chat.view
        view.isHidden = true
        rootView.addSubview(view)
        NSLayoutConstraint.activate([
            // The sidebar's slot: under the toolbar, at the right edge.
            view.topAnchor.constraint(equalTo: sidebar.topAnchor),
            view.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: BrowserAgentPanelView.width),
        ])
        webTrailingToAgent = webArea.trailingAnchor.constraint(equalTo: view.leadingAnchor)
        agentChat = chat
        return chat
    }

    /// `browser agent [show|hide|new|stop|send <message>]`.
    func performAgentCommand(_ arguments: [String]) -> Result<String, Error> {
        guard canShowAgent else {
            return .failure(BrowserAutomationError.unavailable("This window has no Agent panel."))
        }
        switch arguments.first {
        case "show":
            showAgent(focus: false)
        case "hide":
            hideAgent()
        case "new":
            showAgent(focus: false)
            agentChat?.newChat()
        case "stop":
            agentChat?.stop()
        case "send":
            showAgent(focus: false)
            agentChat?.send(arguments.dropFirst().joined(separator: " "))
            return .success("sent")
        default:
            break
        }
        let panel = isAgentVisible ? "shown" : "hidden"
        guard let chat = agentChat else { return .success("panel: \(panel)\nstate: idle") }
        let chatText = chat.transcript.plainText
        return .success("panel: \(panel)\nstate: \(chat.statusLine)" + (chatText.isEmpty ? "" : "\n\(chatText)"))
    }
}
