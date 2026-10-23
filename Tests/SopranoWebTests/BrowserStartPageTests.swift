@testable import SopranoWeb
import AppKit
import Testing

struct BrowserStartPageTests {
    @Test func bookmarksAreEscaped() {
        let html = BrowserStartPage.html(
            theme: .folioPaper,
            settings: BrowserSettings(searchEngine: .google),
            bookmarks: [
                BrowserBookmark(
                    url: "https://example.com/?q=\"quoted\"",
                    title: "<script>alert(1)</script>"
                ),
            ],
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
            bookmarks: [],
            history: [
                BrowserHistoryEntry(
                    url: "https://example.com/products/x",
                    title: "Product",
                    visitedAt: Date(timeIntervalSince1970: 1_700_000_000)
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
            bookmarks: [],
            history: []
        )
        #expect(html.contains("Bookmark a page with ⌘D"))
        #expect(html.contains("Pages you visit appear here."))
    }
}
