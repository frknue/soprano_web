import AppKit
import WebKit

enum BrowserTranslateError: LocalizedError, Equatable {
    case noLanguage
    case sameLanguage(String)
    case needsDownload(source: String, target: String)
    case unsupported(source: String, target: String)
    case noText
    case pageChanged

    var errorDescription: String? {
        let name = BrowserTranslationOffer.displayName
        switch self {
        case .noLanguage:
            return "The page's language isn't known."
        case let .sameLanguage(language):
            return "The page is already in \(name(language))."
        case let .needsDownload(source, target):
            return "\(name(source)) → \(name(target)) isn't downloaded on this Mac. Download it in "
                + "\(BrowserSystemTranslationService.settingsPath) (\(BrowserSystemTranslationService.settingsURL.absoluteString))."
        case let .unsupported(source, target):
            return "Translation from \(name(source)) to \(name(target)) isn't supported."
        case .noText:
            return "The page has no text to translate."
        case .pageChanged:
            return "The page changed while it was translated."
        }
    }
}

extension BrowserWindowController {
    // MARK: - Offer

    /// Languages never offered: Settings' list, plus this private window's
    /// own choices.
    var neverTranslateLanguages: Set<String> {
        Set(settingsStore.settings.neverTranslateLanguages).union(sessionNeverTranslate)
    }

    /// The language the address field offers to translate `tab` into.
    func translationOffer(for tab: BrowserTab) -> String? {
        BrowserTranslationOffer.target(
            detected: tab.translation.language,
            preferred: BrowserTranslationOffer.preferredLanguages,
            neverOffer: neverTranslateLanguages
        )
    }

    var canTranslatePage: Bool {
        guard canUsePageTools, let tab = pageTab else { return false }
        return tab.translation.language != nil && !tab.translation.isTranslating
    }

    /// The command: translates the page into the offered (or preferred)
    /// language, or shows the original of a translated page.
    func toggleTranslation() {
        guard let tab = pageTab else { return }
        if tab.translation.isTranslated {
            showOriginal(in: tab) { _ in }
            return
        }
        let target = translationOffer(for: tab) ?? BrowserTranslationOffer.defaultTarget()
        translatePage(in: tab, to: target) { [weak self] result in
            if case let .failure(error) = result, let error = error as? BrowserTranslateError {
                self?.presentTranslateError(error)
            }
        }
    }

    /// Translates `tab`'s text nodes into `target` in batches; the result
    /// is how many nodes changed. Works the same in a private window and
    /// saves nothing.
    func translatePage(in tab: BrowserTab, to requested: String, completion: @escaping (Result<Int, Error>) -> Void) {
        guard let source = tab.translation.language else {
            completion(.failure(BrowserTranslateError.noLanguage))
            return
        }
        let target = requested
        guard BrowserTranslationOffer.languageCode(source) != BrowserTranslationOffer.languageCode(target) else {
            completion(.failure(BrowserTranslateError.sameLanguage(source)))
            return
        }
        tabWasUsed(tab)
        let generation = tab.translation.generation
        let previous = tab.translation.phase
        tab.translation.phase = .translating(target: target)
        translationStateChanged(tab)
        let service = translationService
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            let webView = tab.webView
            @MainActor func finish(_ result: Result<Int, Error>) {
                if tab.translation.generation == generation {
                    if case let .success(nodes) = result {
                        tab.translation.phase = .translated(target: target, nodes: nodes)
                    } else if tab.translation.isTranslating {
                        tab.translation.phase = .original
                    }
                    self.translationStateChanged(tab)
                }
                completion(result)
            }
            switch await service.availability(source: source, target: target) {
            case .installed:
                break
            case .needsDownload:
                tab.translation.phase = previous
                return finish(.failure(BrowserTranslateError.needsDownload(source: source, target: target)))
            case .unsupported:
                tab.translation.phase = previous
                return finish(.failure(BrowserTranslateError.unsupported(source: source, target: target)))
            }
            do {
                let translator = try service.translator(source: source, target: target)
                if case .translated = previous {
                    try await BrowserTranslationScripts.restore(in: webView)
                }
                let (start, texts) = try await BrowserTranslationScripts.collect(in: webView)
                guard tab.translation.generation == generation else { return finish(.failure(BrowserTranslateError.pageChanged)) }
                guard !texts.isEmpty else { return finish(.failure(BrowserTranslateError.noText)) }
                var applied = 0
                for batch in BrowserTranslationBatches.make(texts) {
                    let translated = try await translator.translate(Array(texts[batch]))
                    guard tab.translation.generation == generation else {
                        return finish(.failure(BrowserTranslateError.pageChanged))
                    }
                    applied += try await BrowserTranslationScripts.apply(translated, from: start + batch.lowerBound, in: webView)
                }
                finish(.success(applied))
            } catch {
                // A batch that failed leaves no half-translated page.
                if tab.translation.generation == generation {
                    _ = try? await BrowserTranslationScripts.restore(in: webView)
                }
                finish(.failure(error))
            }
        }
    }

    /// "Show Original": every translated node gets its text back.
    func showOriginal(in tab: BrowserTab, completion: @escaping (Result<Int, Error>) -> Void) {
        let generation = tab.translation.generation
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            do {
                let restored = try await BrowserTranslationScripts.restore(in: tab.webView)
                if tab.translation.generation == generation {
                    tab.translation.phase = .original
                    self.translationStateChanged(tab)
                }
                completion(.success(restored))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// "Never Offer for <language>": saved in Settings, or kept by a
    /// private window while it is open.
    func neverOfferTranslation(for language: String) {
        let code = BrowserTranslationOffer.languageCode(language)
        if kind.savesTranslationChoices {
            settingsStore.update { settings in
                if !settings.neverTranslateLanguages.contains(code) {
                    settings.neverTranslateLanguages.append(code)
                }
            }
        } else {
            sessionNeverTranslate.insert(code)
        }
        updateTranslateChip()
    }

    private func translationStateChanged(_ tab: BrowserTab) {
        if tab === pageTab {
            updateTranslateChip()
        }
    }

    /// A missing language pair offers System Settings' Translation
    /// Languages (downloading in the app needs SwiftUI); other failures
    /// show as a toast.
    func presentTranslateError(_ error: BrowserTranslateError) {
        guard !manager.placement.isOffscreen, let window else { return }
        guard case let .needsDownload(source, target) = error else {
            showVimiumToast(error.localizedDescription)
            return
        }
        let name = BrowserTranslationOffer.displayName
        let alert = NSAlert()
        alert.messageText = "Download \(name(source)) and \(name(target))?"
        alert.informativeText = "Translating this page needs both languages on this Mac. Download them in "
            + "\(BrowserSystemTranslationService.settingsPath), then translate again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(BrowserSystemTranslationService.settingsURL)
        }
    }

    // MARK: - Address field chip

    /// The "Translate" chip while the page's language isn't one of the
    /// user's (and isn't on the Never Offer list), and "Translated" (filled)
    /// while the page shows a translation. It opens the Translate menu.
    func updateTranslateChip() {
        guard canUsePageTools, let tab = pageTab,
              tab.translation.target != nil || translationOffer(for: tab) != nil
        else {
            translateChip?.isHidden = true
            return
        }
        let chip: ChromeButton
        if let existing = translateChip {
            chip = existing
        } else {
            chip = ChromeButton(title: "Translate", theme: theme, kind: .standard, target: self, action: #selector(translateChipPressed(_:)))
            chip.heightAnchor.constraint(equalToConstant: 20).isActive = true
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            toolbar.addressAccessories.addArrangedSubview(chip)
            translateChip = chip
        }
        let source = tab.translation.language.map(BrowserTranslationOffer.displayName) ?? "this language"
        chip.kind = tab.translation.target == nil ? .standard : .ink
        chip.apply(theme: theme)
        switch tab.translation.phase {
        case .original:
            chip.title = "Translate"
            chip.toolTip = "This page is in \(source). Translate it"
        case let .translating(target):
            chip.title = "Translating…"
            chip.toolTip = "Translating into \(BrowserTranslationOffer.displayName(target))"
        case let .translated(target, _):
            chip.title = "Translated"
            chip.toolTip = "Translated from \(source) into \(BrowserTranslationOffer.displayName(target))"
        }
        chip.setAccessibilityLabel(chip.toolTip)
        chip.isHidden = false
    }

    /// The chip's menu items for `tab` (titles and what they do), also
    /// read by tests.
    func translateMenuItems(for tab: BrowserTab) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: Selector, _ value: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            items.append(item)
        }
        if tab.translation.target != nil {
            add("Show Original", #selector(showOriginalFromMenu(_:)))
        } else {
            let target = translationOffer(for: tab) ?? BrowserTranslationOffer.defaultTarget()
            add("Translate to \(BrowserTranslationOffer.displayName(target))", #selector(translateFromMenu(_:)), target)
        }
        if let language = tab.translation.language {
            items.append(.separator())
            add("Never Offer for \(BrowserTranslationOffer.displayName(language))", #selector(neverOfferFromMenu(_:)), language)
        }
        return items
    }

    @objc func translateChipPressed(_ sender: NSButton) {
        guard let tab = pageTab else { return }
        let menu = NSMenu()
        translateMenuItems(for: tab).forEach(menu.addItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func translateFromMenu(_ sender: NSMenuItem) {
        guard let tab = pageTab, let target = sender.representedObject as? String else { return }
        translatePage(in: tab, to: target) { [weak self] result in
            if case let .failure(error) = result, let error = error as? BrowserTranslateError {
                self?.presentTranslateError(error)
            }
        }
    }

    @objc func showOriginalFromMenu(_ sender: NSMenuItem) {
        guard let tab = pageTab else { return }
        showOriginal(in: tab) { _ in }
    }

    @objc func neverOfferFromMenu(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? String else { return }
        neverOfferTranslation(for: language)
    }

    // MARK: - CLI

    /// `browser translate [to <lang>|off]`: the page's language and
    /// translation, or translates it / shows the original.
    func performTranslateCommand(_ arguments: [String], tab: BrowserTab, completion: @escaping (Result<String, Error>) -> Void) {
        let report: (Result<Int, Error>) -> Void = { [weak self, weak tab] result in
            guard let self, let tab else { return }
            switch result {
            case .success:
                completion(.success(self.translateLines(for: tab).joined(separator: "\n")))
            case let .failure(error):
                completion(.failure(BrowserAutomationError.unavailable(error.localizedDescription)))
            }
        }
        switch arguments {
        case []:
            completion(.success(translateLines(for: tab).joined(separator: "\n")))
        case ["off"]:
            showOriginal(in: tab, completion: report)
        case let words where words.count == 2 && words[0] == "to":
            translatePage(in: tab, to: words[1], completion: report)
        default:
            completion(.failure(BrowserAutomationError.invalidArguments(BrowserCommandRequest.translateUsage)))
        }
    }

    func translateLines(for tab: BrowserTab) -> [String] {
        let translation = tab.translation
        var lines = [
            "url: \(tab.webView.url?.absoluteString ?? "")",
            "language: \(translation.language ?? "unknown")",
            "offer: \(translationOffer(for: tab) ?? "none")",
        ]
        switch translation.phase {
        case .original: lines.append("translation: off")
        case let .translating(target): lines.append("translation: translating to \(target)")
        case let .translated(target, nodes): lines.append("translation: \(target) (\(nodes) text nodes)")
        }
        let never = neverTranslateLanguages.sorted()
        lines.append("never offer: \(never.isEmpty ? "none" : never.joined(separator: ", "))")
        return lines
    }
}
