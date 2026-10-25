import AppKit
import WebKit

extension BrowserWindowController {
    func vimiumFocusChanged(tabID: UUID, editable: Bool) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tab.vimium?.pageFocusChanged(editable)
    }

    func showVimiumToast(_ text: String) {
        vimiumToastView?.removeFromSuperview()
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.colors.raised.cgColor
        container.layer?.cornerRadius = Chrome.Radius.card
        container.layer?.borderWidth = Chrome.hairline
        container.layer?.borderColor = theme.colors.borderStrong.cgColor

        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = ChromeFont.label
        label.textColor = theme.colors.textPrimary
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        container.addSubview(label)
        rootView.addSubview(container)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            container.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -28),
            container.heightAnchor.constraint(equalToConstant: 32),
            container.widthAnchor.constraint(lessThanOrEqualTo: rootView.widthAnchor, constant: -48),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        vimiumToastView = container
        Task { @MainActor [weak container] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            container?.removeFromSuperview()
        }
    }

    func presentVimiumPrompt(initialText: String, newTab: Bool) {
        guard let window else { return }
        if vimiumPromptPanel.isVisible {
            vimiumPromptPanel.dismiss()
        }
        vimiumPromptPanel.apply(theme: theme)
        vimiumPromptPanel.show(
            relativeTo: window,
            initialText: initialText,
            placeholder: "Open URL, bookmark, or search"
        ) { [weak self] value in
            guard let self else { return }
            if newTab {
                _ = self.newTab(url: value)
            } else {
                self.navigateCurrent(to: value)
            }
            self.focusPage()
        } onCancel: { [weak self] in
            self?.focusPage()
        }
    }

    /// `b` / `B`: every pin of the current Space in every folder; the
    /// description names the folder ("Work › Docs · https://…") so the
    /// palette matches it too.
    func showVimiumBookmarks(newTab: Bool) {
        guard let window else { return }
        let entries = currentSpaceID.map { spaces.pinEntries(inSpace: $0) } ?? []
        guard !entries.isEmpty else {
            showVimiumToast("No bookmarks yet.")
            return
        }
        let items = entries.map { entry in
            let pin = entry.pin
            return CommandItem(
                id: "vimium-bookmark-\(pin.id)",
                icon: "bookmark",
                label: pin.displayTitle,
                description: entry.detail
            ) { [weak self] in
                guard let self else { return }
                if newTab {
                    _ = self.newTab(url: pin.url)
                } else {
                    self.navigateCurrent(to: pin.url)
                }
                self.focusPage()
            }
        }
        palette.show(
            relativeTo: window,
            commands: items,
            placeholder: "Search bookmarks…"
        )
    }

    func showVimiumTabs() {
        guard let window else { return }
        let items = tabs.enumerated().map { index, tab in
            CommandItem(
                id: "vimium-tab-\(tab.id)",
                icon: "rectangle.on.rectangle",
                label: "\(index + 1). \(tab.displayTitle)",
                description: tab.isStartPage
                    ? "about:start"
                    : (tab.webView.url?.absoluteString ?? "")
            ) { [weak self] in
                self?.selectTab(id: tab.id, focus: true)
            }
        }
        palette.show(
            relativeTo: window,
            commands: items,
            placeholder: "Search tabs…"
        )
    }

    func showVimiumHelp() {
        showVimiumText(title: "Vimium Help", text: VimiumKeyMap.helpText)
    }

    func showVimiumText(title: String, text: String) {
        guard let window else { return }
        if vimiumTextPanel.isVisible {
            vimiumTextPanel.dismiss()
        }
        vimiumTextPanel.apply(theme: theme)
        vimiumTextPanel.show(
            relativeTo: window,
            title: title,
            text: text
        ) { [weak self] in
            self?.focusPage()
        }
    }
}
