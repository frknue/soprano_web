import AppKit
import UniformTypeIdentifiers
import WebKit

extension BrowserWindowController {
    // MARK: - Page tools

    /// Print, Export as PDF and Save As act on a loaded web page, not the
    /// start page or an error page.
    var canUsePageTools: Bool {
        guard let tab = selectedTab else { return false }
        return !tab.isStartPage && !tab.isShowingErrorPage && tab.webView.url != nil
    }

    var isSelectedTabLoading: Bool {
        selectedTab?.webView.isLoading ?? false
    }

    func stopLoading() {
        selectedTab?.webView.stopLoading()
    }

    // MARK: Print

    func printSelectedPage() {
        guard canUsePageTools, let tab = selectedTab else { return }
        printPage(tab)
    }

    /// The page called `window.print()`. Page input: only the visible tab's
    /// main frame may ask, and only while no sheet is up.
    func printPageRequested(by tab: BrowserTab, frame: WKFrameInfo) {
        guard frame.isMainFrame, tab.id == selectedTab?.id else { return }
        printPage(tab)
    }

    private func printPage(_ tab: BrowserTab) {
        guard let window, window.isVisible, window.attachedSheet == nil else { return }
        let operation = Self.printOperation(for: tab.webView, title: tab.displayTitle, printInfo: nil)
        if let presenter = Self.printPresenter {
            presenter(operation, window)
            return
        }
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Replaces the print sheet; set only by the snapshot harness to print
    /// a page's `window.print()` into a file without panels.
    static var printPresenter: ((NSPrintOperation, NSWindow) -> Void)?

    /// The known blank-page pitfalls of `printOperation(with:)`: its view
    /// starts with a zero frame, and a synchronous `run()` gives WebKit no
    /// chance to lay out the pages. Size the view to the web view and always
    /// run the operation with `runModal(for:…)`.
    static func printOperation(
        for webView: WKWebView,
        title: String,
        printInfo: NSPrintInfo?
    ) -> NSPrintOperation {
        let info = printInfo ?? (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        operation.jobTitle = title
        return operation
    }

    // MARK: Export as PDF

    func exportSelectedPageAsPDF() {
        guard canUsePageTools, let tab = selectedTab, let window, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = BrowserPageSaveFormat.suggestedName(
            title: tab.webView.title,
            url: tab.webView.url
        ) + ".pdf"
        panel.beginSheetModal(for: window) { [weak self, weak tab] response in
            guard response == .OK, let url = panel.url, let self, let tab else { return }
            self.writePDF(of: tab.webView, to: url) { error in
                if let error { self.presentPageToolsError("Couldn’t export the page as PDF.", error) }
            }
        }
    }

    func writePDF(of webView: WKWebView, to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        webView.createPDF(configuration: WKPDFConfiguration()) { result in
            MainActor.assumeIsolated {
                completion(Self.write(result, to: url))
            }
        }
    }

    // MARK: Save As

    func saveSelectedPageAs() {
        guard canUsePageTools, let tab = selectedTab, let window, window.attachedSheet == nil else { return }
        let formats = BrowserPageSaveFormat.available(for: tab.webView.url)
        guard let first = formats.first else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = BrowserPageSaveFormat.suggestedName(
            title: tab.webView.title,
            url: tab.webView.url
        )
        let accessory = BrowserSaveFormatAccessory(panel: panel, formats: formats, selected: first)
        panel.accessoryView = accessory.view
        panel.beginSheetModal(for: window) { [weak self, weak tab] response in
            let format = accessory.format
            guard response == .OK, let url = panel.url, let self, let tab else { return }
            self.save(tab.webView, as: format, to: url) { error in
                if let error { self.presentPageToolsError("Couldn’t save the page.", error) }
            }
        }
    }

    func save(
        _ webView: WKWebView,
        as format: BrowserPageSaveFormat,
        to url: URL,
        completion: @escaping @MainActor (Error?) -> Void
    ) {
        switch format {
        case .webArchive:
            webView.createWebArchiveData { result in
                MainActor.assumeIsolated {
                    completion(Self.write(result, to: url))
                }
            }
        case .pageSource:
            guard let pageURL = webView.url else {
                completion(BrowserPageSource.FetchError.unsupportedScheme)
                return
            }
            BrowserPageSource.fetch(pageURL, from: webView) { result in
                completion(Self.write(result, to: url))
            }
        }
    }

    private static func write(_ result: Result<Data, Error>, to url: URL) -> Error? {
        do {
            try result.get().write(to: url, options: .atomic)
            return nil
        } catch {
            return error
        }
    }

    private func presentPageToolsError(_ title: String, _ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: Share

    /// The selected page for File ▸ Share; empty on the start page.
    var shareItems: [Any] {
        guard canUsePageTools, let tab = selectedTab, let url = tab.webView.url else { return [] }
        return [NSPreviewRepresentingActivityItem(
            item: url as NSURL,
            title: tab.displayTitle,
            image: nil,
            icon: tab.favicon
        )]
    }

    // MARK: Context menu

    /// Observes every rewritten context menu: WebKit's identifiers and
    /// titles, the captured target and the final menu. Set only by the
    /// snapshot harness to log real menus.
    static var contextMenuObserver: (
        (_ identifiers: [String?], _ titles: [String], _ target: BrowserContextMenuTarget?, _ menu: NSMenu) -> Void
    )?

    func prepareContextMenu(_ menu: NSMenu, target: BrowserContextMenuTarget?, in webView: BrowserWebView) {
        let items = menu.items
        let identifiers = items.map { $0.isSeparatorItem ? nil : $0.identifier?.rawValue }
        let titles = items.map(\.title)
        let entries = BrowserContextMenu.transform(
            identifiers: identifiers,
            titles: titles,
            target: target,
            searchEngine: settingsStore.settings.defaultSearchEngine
        )
        menu.removeAllItems()
        for entry in entries {
            switch entry {
            case let .keep(index):
                menu.addItem(items[index])
            case let .retitle(index, title):
                items[index].title = title
                menu.addItem(items[index])
            case let .action(action, title):
                let item = NSMenuItem(title: title, action: #selector(performContextMenuAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = BrowserContextMenuCommand(action: action, webView: webView)
                menu.addItem(item)
            }
        }
        Self.contextMenuObserver?(identifiers, titles, target, menu)
    }

    @objc func performContextMenuAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? BrowserContextMenuCommand else { return }
        let opener = command.webView.flatMap { tab(for: $0) }
        switch command.action {
        case let .openInNewTab(url), let .openImageInNewTab(url), let .search(_, url):
            if let opener {
                openLinkTab(url, opener: opener, select: true)
            } else {
                newTab(url: url.absoluteString)
            }
        case let .openInBackgroundTab(url):
            if let opener {
                openLinkTab(url, opener: opener, select: false)
            } else {
                newTab(url: url.absoluteString, select: false)
            }
        case let .download(url):
            if let webView = command.webView ?? selectedTab?.webView {
                downloadManager.start(URLRequest(url: url), in: webView, privateContextID: dataContext.downloadContextID)
            }
        }
    }
}

/// A context menu item's command and the web view the menu belongs to.
@MainActor
final class BrowserContextMenuCommand: NSObject {
    let action: BrowserContextMenuAction
    weak var webView: WKWebView?

    init(action: BrowserContextMenuAction, webView: WKWebView) {
        self.action = action
        self.webView = webView
    }
}

/// The Format pop-up in the Save As panel; switching it changes the
/// file type the panel writes.
@MainActor
final class BrowserSaveFormatAccessory: NSObject {
    let view: NSView
    private(set) var format: BrowserPageSaveFormat
    private let formats: [BrowserPageSaveFormat]
    private weak var panel: NSSavePanel?
    private let popUp: NSPopUpButton

    init(panel: NSSavePanel, formats: [BrowserPageSaveFormat], selected: BrowserPageSaveFormat) {
        self.panel = panel
        self.formats = formats
        self.format = selected
        let label = NSTextField(labelWithString: "Format:")
        popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: formats.map(\.title))
        let stack = NSStackView(views: [label, popUp])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        view = stack
        super.init()
        popUp.target = self
        popUp.action = #selector(formatChanged)
        popUp.selectItem(at: formats.firstIndex(of: selected) ?? 0)
        panel.allowedContentTypes = [selected.contentType]
    }

    @objc private func formatChanged() {
        guard formats.indices.contains(popUp.indexOfSelectedItem) else { return }
        format = formats[popUp.indexOfSelectedItem]
        panel?.allowedContentTypes = [format.contentType]
    }
}
