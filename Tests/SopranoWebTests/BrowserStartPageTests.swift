@testable import SopranoWeb
import AppKit
import Testing

struct BrowserStartPageTests {
    @Test func bookmarksAreEscaped() {
        let html = BrowserStartPage.html(
            theme: .folioPaper,
            settings: BrowserSettings(searchEngine: .google),
            bookmarks: BrowserBookmarkTree(children: [
                .bookmark(BrowserBookmark(
                    url: "https://example.com/?q=\"quoted\"",
                    title: "<script>alert(1)</script>"
                )),
            ]),
            history: []
        )
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(html.contains("https://www.google.com/search"))
        #expect(!html.contains("<script>alert(1)</script>"))
    }

    @Test func recentPagesAreShown() {
        let html = BrowserStartPage.html(
            theme: .folioInk,
            settings: .default,
            bookmarks: BrowserBookmarkTree(),
            history: [
                BrowserHistoryPage(
                    url: "https://example.com/products/x",
                    title: "Product",
                    lastVisit: Date(timeIntervalSince1970: 1_700_000_000)
                ),
            ]
        )
        #expect(html.contains("Product"))
        #expect(html.contains("example.com"))
        #expect(html.contains("No history yet") == false)
    }

    @Test func emptyStatesHaveCopy() {
        let html = BrowserStartPage.html(
            theme: .folioPaper,
            settings: .default,
            bookmarks: BrowserBookmarkTree(),
            history: []
        )
        #expect(html.contains("Bookmark a page with ⌘D"))
        #expect(html.contains("Pages you visit appear here."))
    }

    @Test func topLevelFoldersAreCardsListingTheirBookmarks() {
        let tree = BrowserBookmarkTree(children: [
            .folder(BrowserBookmarkFolder(name: "Work & <Play>", children: [
                .bookmark(BrowserBookmark(url: "https://a.example/", title: "A")),
                .folder(BrowserBookmarkFolder(name: "Docs", children: [
                    .bookmark(BrowserBookmark(url: "https://b.example/", title: "B")),
                ])),
            ])),
            .bookmark(BrowserBookmark(url: "https://top.example/", title: "Top")),
        ])
        let html = BrowserStartPage.html(theme: .folioPaper, settings: .default, bookmarks: tree, history: [])
        #expect(html.contains("<details class=\"card folder\">"))
        #expect(html.contains("Work &amp; &lt;Play&gt;"))
        #expect(html.contains("Folder · 2 bookmarks"))
        #expect(html.contains("Docs · b.example"))
        #expect(html.contains("href=\"https://top.example/\""))
        #expect(!html.contains("Bookmark a page with ⌘D"))
    }
}
