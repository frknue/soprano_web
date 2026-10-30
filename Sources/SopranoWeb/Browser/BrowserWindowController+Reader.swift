import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Page info

    /// The page-info report (main frame): whether the page has an article
    /// and what language it's in.
    func receivePageInfo(_ body: [String: Any], tab: BrowserTab, frame: WKFrameInfo) {
        guard frame.isMainFrame else { return }
        if !tab.reader.isActive {
            tab.reader.isReaderable = body["readerable"] as? Bool ?? false
        }
        tab.translation.language = BrowserLanguageDetector.detect(
            sample: body["sample"] as? String ?? "",
            hint: body["lang"] as? String ?? ""
        )
        if tab === pageTab {
            updateReaderChip()
            updateTranslateChip()
        }
    }

    /// Main-frame commit: a new document starts without Reader or
    /// translation (a page from the back-forward cache is put back as it
    /// was and reports again).
    func readerPageCommitted(_ tab: BrowserTab) {
        tab.reader.pageCommitted()
        tab.translation.pageCommitted()
        tab.webView.evaluateJavaScript(BrowserReaderScripts.commitSource, in: nil, in: BrowserPageScripts.isolatedWorld)
    }

    // MARK: - Reader

    var canToggleReader: Bool {
        guard canUsePageTools, let tab = pageTab else { return false }
        return tab.reader.isAvailable
    }

    /// ⇧⌘R on the page (the Peek's when one is open).
    func toggleReader() {
        guard let tab = pageTab else { return }
        setReader(!tab.reader.isActive, in: tab) { _ in }
    }

    enum ReaderError: LocalizedError {
        case noArticle
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noArticle: "No article on this page."
            case let .failed(reason): "Reader failed: \(reason)"
            }
        }
    }

    /// Shows (`on`) or leaves the Reader in `tab`. A translated page is
    /// restored first and translated again in the new view.
    func setReader(_ on: Bool, in tab: BrowserTab, completion: @escaping (Result<BrowserReaderArticle?, Error>) -> Void) {
        guard on != tab.reader.isActive else {
            completion(.success(tab.reader.article))
            return
        }
        tabWasUsed(tab)
        let generation = tab.translation.generation
        let translationTarget = tab.translation.target
        let css = BrowserReaderScripts.css(theme: theme)
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            let webView = tab.webView
            do {
                if translationTarget != nil {
                    try await BrowserTranslationScripts.restore(in: webView)
                    tab.translation.phase = .original
                }
                if on {
                    if try await webView.callAsyncJavaScript(
                        "return typeof Readability === 'function';", arguments: [:], in: nil,
                        contentWorld: BrowserPageScripts.isolatedWorld
                    ) as? Bool != true {
                        guard let source = BrowserReaderScripts.readability else {
                            throw ReaderError.failed("Readability.js is missing from the app's resources")
                        }
                        _ = try await webView.evaluateJavaScript(source, in: nil, contentWorld: BrowserPageScripts.isolatedWorld)
                    }
                    let result = try await webView.callAsyncJavaScript(
                        BrowserReaderScripts.enterSource, arguments: ["css": css], in: nil,
                        contentWorld: BrowserPageScripts.isolatedWorld
                    )
                    guard tab.translation.generation == generation else { return completion(.success(nil)) }
                    guard let article = BrowserReaderArticle(result: result) else {
                        let reason = (result as? [String: Any])?["reason"] as? String ?? "noArticle"
                        if reason == "noArticle" {
                            tab.reader.isReaderable = false
                            self.readerStateChanged(tab)
                            throw ReaderError.noArticle
                        }
                        throw ReaderError.failed(reason)
                    }
                    tab.reader.entered(article)
                } else {
                    _ = try await webView.callAsyncJavaScript(
                        BrowserReaderScripts.leaveSource, arguments: [:], in: nil,
                        contentWorld: BrowserPageScripts.isolatedWorld
                    )
                    guard tab.translation.generation == generation else { return completion(.success(nil)) }
                    tab.reader.left()
                }
                self.readerStateChanged(tab)
                completion(.success(tab.reader.article))
                if let translationTarget {
                    self.translatePage(in: tab, to: translationTarget) { _ in }
                }
            } catch {
                self.readerStateChanged(tab)
                completion(.failure(error))
            }
        }
    }

    private func readerStateChanged(_ tab: BrowserTab) {
        if tab === pageTab {
            updateReaderChip()
            updateTranslateChip()
        }
    }

    /// Restyles every showing Reader in the window's theme.
    func applyReaderTheme() {
        let css = BrowserReaderScripts.css(theme: theme)
        for tab in tabsWithPeek where tab.reader.isActive {
            tab.webView.callAsyncJavaScript(
                BrowserReaderScripts.themeSource, arguments: ["css": css], in: nil,
                in: BrowserPageScripts.isolatedWorld
            )
        }
    }

    /// The address field's "Reader" chip while the page has an article;
    /// filled while the Reader shows. Clicking it is ⇧⌘R.
    func updateReaderChip() {
        guard canToggleReader, let tab = pageTab else {
            readerChip?.isHidden = true
            return
        }
        let chip: ChromeButton
        if let existing = readerChip {
            chip = existing
        } else {
            chip = ChromeButton(title: "Reader", theme: theme, kind: .standard, target: self, action: #selector(readerChipPressed(_:)))
            chip.heightAnchor.constraint(equalToConstant: 20).isActive = true
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            toolbar.addressAccessories.addArrangedSubview(chip)
            readerChip = chip
        }
        let active = tab.reader.isActive
        chip.kind = active ? .ink : .standard
        chip.apply(theme: theme)
        chip.title = "Reader"
        chip.toolTip = active ? "Show the original page (⇧⌘R)" : "Show the article in Reader (⇧⌘R)"
        chip.setAccessibilityLabel(active ? "Reader on, show the original page" : "Show in Reader")
        chip.isHidden = false
    }

    @objc func readerChipPressed(_ sender: NSButton) {
        toggleReader()
    }

    // MARK: - CLI

    /// `browser reader [on|off]`: the Reader's state, or shows/leaves it.
    func performReaderCommand(_ arguments: [String], tab: BrowserTab, completion: @escaping (Result<String, Error>) -> Void) {
        switch arguments.first {
        case nil:
            completion(.success(readerLines(for: tab).joined(separator: "\n")))
        case let word? where word == "on" || word == "off":
            if word == "on", !tab.reader.isAvailable {
                completion(.failure(BrowserAutomationError.unavailable("No article on this page.")))
                return
            }
            setReader(word == "on", in: tab) { [weak self, weak tab] result in
                guard let self, let tab else { return }
                switch result {
                case .success: completion(.success(self.readerLines(for: tab).joined(separator: "\n")))
                case let .failure(error): completion(.failure(BrowserAutomationError.unavailable(error.localizedDescription)))
                }
            }
        default:
            completion(.failure(BrowserAutomationError.invalidArguments(BrowserCommandRequest.readerUsage)))
        }
    }

    func readerLines(for tab: BrowserTab) -> [String] {
        var lines = [
            "url: \(tab.webView.url?.absoluteString ?? "")",
            "article: \(tab.reader.isAvailable ? "yes" : "no")",
            "reader: \(tab.reader.isActive ? "on" : "off")",
        ]
        if let article = tab.reader.article {
            lines.append("title: \(article.title)")
            if !article.byline.isEmpty { lines.append("byline: \(article.byline)") }
            if !article.siteName.isEmpty { lines.append("site: \(article.siteName)") }
            lines.append("length: \(article.length)")
        }
        return lines
    }
}
