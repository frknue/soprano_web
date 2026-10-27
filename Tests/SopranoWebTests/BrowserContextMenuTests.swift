@testable import SopranoWeb
import AppKit
import Testing

struct BrowserContextMenuTests {
    private let link = URL(string: "https://example.com/article?id=7")!
    private let image = URL(string: "https://example.com/photo.jpg")!

    private func transform(
        _ identifiers: [String?],
        titles: [String]? = nil,
        target: BrowserContextMenuTarget?,
        engine: BrowserSearchEngine = .duckDuckGo
    ) -> [BrowserContextMenuEntry] {
        BrowserContextMenu.transform(
            identifiers: identifiers,
            titles: titles ?? identifiers.map { $0 ?? "" },
            target: target,
            searchEngine: engine
        )
    }

    @Test func linkMenuOpensInNewAndBackgroundTabsAndKeepsDownloadAndCopy() {
        let entries = transform(
            [WebKitMenuItem.openLink, WebKitMenuItem.openLinkInNewWindow, WebKitMenuItem.downloadLinkedFile,
             nil, WebKitMenuItem.copyLink],
            titles: ["Open Link", "Open Link in New Window", "Download Linked File", "", "Copy Link"],
            target: BrowserContextMenuTarget(link: link)
        )
        #expect(entries == [
            .keep(0),
            .action(.openInNewTab(link), title: "Open Link in New Tab"),
            .action(.openInBackgroundTab(link), title: "Open Link in Background Tab"),
            .action(.download(link), title: "Download Linked File"),
            .keep(3),
            .keep(4),
        ])
    }

    @Test func linkMenuWithoutCapturedTargetRetitlesWebKitsItem() {
        let entries = transform(
            [WebKitMenuItem.openLinkInNewWindow, WebKitMenuItem.downloadLinkedFile],
            target: nil
        )
        #expect(entries == [.retitle(0, "Open Link in New Tab"), .keep(1)])
    }

    @Test func imageMenuOpensImageInNewTab() {
        let entries = transform(
            [WebKitMenuItem.openImageInNewWindow, WebKitMenuItem.downloadImage, WebKitMenuItem.copyImage],
            titles: ["Open Image in New Window", "Download Image", "Copy Image"],
            target: BrowserContextMenuTarget(image: image)
        )
        #expect(entries == [
            .action(.openImageInNewTab(image), title: "Open Image in New Tab"),
            .action(.download(image), title: "Download Image"),
            .keep(2),
        ])
    }

    @Test func otherNewWindowItemsSayNewTab() {
        let entries = transform(
            [WebKitMenuItem.openMediaInNewWindow, WebKitMenuItem.openFrameInNewWindow],
            titles: ["Open Video in New Window", "Open Frame in New Window"],
            target: nil
        )
        #expect(entries == [.retitle(0, "Open Video in New Tab"), .retitle(1, "Open Frame in New Tab")])
    }

    @Test func selectionSearchesWithTheConfiguredEngine() throws {
        let entries = transform(
            ["WKMenuItemIdentifierLookUp", WebKitMenuItem.searchWeb, nil, "WKMenuItemIdentifierCopy"],
            target: BrowserContextMenuTarget(selection: "  Soprano   web\nbrowser "),
            engine: .google
        )
        let url = try #require(BrowserSearchEngine.google.searchURL(for: "Soprano web browser"))
        #expect(entries == [
            .keep(0),
            .action(.search(query: "Soprano web browser", url: url),
                    title: "Search with Google for “Soprano web browser”"),
            .keep(2),
            .keep(3),
        ])
    }

    @Test func blankSelectionKeepsWebKitsSearchItem() {
        let entries = transform([WebKitMenuItem.searchWeb], target: BrowserContextMenuTarget(selection: " \n "))
        #expect(entries == [.keep(0)])
    }

    @Test func searchTitleShortensLongSelections() {
        let query = "the quick brown fox jumps over the lazy dog"
        #expect(BrowserContextMenu.searchTitle(query: query, engine: .duckDuckGo)
            == "Search with DuckDuckGo for “the quick brown fox jumps over…”")
        #expect(BrowserContextMenu.searchTitle(query: "fox", engine: .bing) == "Search with Bing for “fox”")
    }

    @Test func searchURLEncodesTheSelection() throws {
        let url = try #require(BrowserSearchEngine.duckDuckGo.searchURL(for: BrowserContextMenu.searchQuery("a&b = c?")))
        #expect(url.absoluteString == "https://duckduckgo.com/?q=a%26b%20%3D%20c%3F")
    }

    @Test func targetParsesThePageMessageAndExpires() {
        let now = Date()
        let target = BrowserContextMenuTarget(
            body: ["type": "contextMenu", "link": link.absoluteString, "image": "", "selection": "word"],
            now: now
        )
        #expect(target?.link == link)
        #expect(target?.image == nil)
        #expect(target?.selection == "word")
        #expect(target?.isFresh(at: now.addingTimeInterval(0.5)) == true)
        #expect(target?.isFresh(at: now.addingTimeInterval(5)) == false)
        #expect(BrowserContextMenuTarget(body: ["link": "not a url"])?.link == nil)
    }
}
