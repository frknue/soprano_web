@testable import SopranoWeb
import AppKit
import Testing

struct BrowserFaviconSelectionTests {
    private let page = URL(string: "https://www.example.com/articles/1?x=1#top")!

    private func candidate(_ href: String, rel: String = "icon", sizes: String? = nil, type: String? = nil)
        -> BrowserFaviconCandidate?
    {
        BrowserFaviconCandidate(href: href, rel: rel, sizes: sizes, type: type, base: page)
    }

    @Test func resolvesRelativeHrefsAgainstThePage() {
        #expect(candidate("/static/icon.png")?.url.absoluteString == "https://www.example.com/static/icon.png")
        #expect(candidate("icon.png")?.url.absoluteString == "https://www.example.com/articles/icon.png")
    }

    @Test func skipsMaskIconsNonIconRelsAndUnfetchableSchemes() {
        #expect(candidate("/mask.svg", rel: "mask-icon") == nil)
        #expect(candidate("/style.css", rel: "stylesheet") == nil)
        #expect(candidate("javascript:alert(1)") == nil)
        #expect(candidate("file:///etc/icon.png") == nil)
        #expect(candidate("data:image/png;base64,AAAA") != nil)
    }

    @Test func classifiesIcoSvgAndRasterByTypeOrExtension() {
        #expect(candidate("/favicon.ico")?.kind == .ico)
        #expect(candidate("/icon", type: "image/x-icon")?.kind == .ico)
        #expect(candidate("/icon.svg")?.kind == .svg)
        #expect(candidate("/icon", type: "image/svg+xml")?.kind == .svg)
        #expect(candidate("data:image/svg+xml,%3Csvg%3E%3C/svg%3E")?.kind == .svg)
        #expect(candidate("/icon.png")?.kind == .raster)
    }

    @Test func readsTheLargestDeclaredSize() {
        #expect(candidate("/a.png", sizes: "16x16 48x48 32x32")?.size == 48)
        #expect(candidate("/a.png", sizes: "any")?.size == nil)
        #expect(candidate("/a.png", sizes: "bogus")?.size == nil)
        #expect(candidate("/touch.png", rel: "apple-touch-icon")?.size == 180)
        #expect(candidate("/touch.png", rel: "apple-touch-icon-precomposed", sizes: "152x152")?.size == 152)
    }

    @Test func prefersTheSmallestRasterAtLeast32Pixels() {
        let icons = [
            candidate("/16.png", sizes: "16x16"),
            candidate("/192.png", sizes: "192x192"),
            candidate("/32.png", sizes: "32x32"),
            candidate("/touch.png", rel: "apple-touch-icon"),
        ].compactMap { $0 }
        let order = BrowserFaviconSelection.orderedSources(icons, pageURL: page).map(\.path)
        #expect(order == ["/32.png", "/touch.png", "/192.png", "/16.png", "/favicon.ico"])
    }

    @Test func ranksIcoThenUnsizedRasterThenSvgThenSmallRasters() {
        let icons = [
            candidate("/icon.svg"),
            candidate("/8.png", sizes: "8x8"),
            candidate("/16.png", sizes: "16x16"),
            candidate("/plain.png"),
            candidate("/site.ico"),
        ].compactMap { $0 }
        let order = BrowserFaviconSelection.orderedSources(icons, pageURL: page).map(\.path)
        #expect(order == ["/site.ico", "/plain.png", "/icon.svg", "/16.png", "/8.png", "/favicon.ico"])
    }

    @Test func fallsBackToFaviconIcoOnceWithoutDuplicates() {
        #expect(
            BrowserFaviconSelection.orderedSources([], pageURL: page).map(\.absoluteString)
                == ["https://www.example.com/favicon.ico"]
        )
        let declared = [candidate("/favicon.ico")].compactMap { $0 }
        #expect(BrowserFaviconSelection.orderedSources(declared, pageURL: page).count == 1)
        let port = URL(string: "http://127.0.0.1:8123/page")!
        #expect(BrowserFaviconSelection.fallbackURL(for: port)?.absoluteString == "http://127.0.0.1:8123/favicon.ico")
        #expect(BrowserFaviconSelection.fallbackURL(for: URL(string: "file:///tmp/a.html")!) == nil)
    }

    @Test func keysByHostWithNonDefaultPort() {
        #expect(BrowserFaviconSelection.key(for: URL(string: "https://WWW.Example.com./a")) == "www.example.com")
        #expect(BrowserFaviconSelection.key(for: URL(string: "https://example.com:443/")) == "example.com")
        #expect(BrowserFaviconSelection.key(for: URL(string: "http://127.0.0.1:8123/")) == "127.0.0.1:8123")
        #expect(BrowserFaviconSelection.key(for: URL(string: "soprano-web://start")) == nil)
        #expect(BrowserFaviconSelection.key(for: URL(string: "about:blank")) == nil)
        #expect(BrowserFaviconSelection.fileName(for: "127.0.0.1:8123") == "127.0.0.1_8123.png")
        #expect(BrowserFaviconSelection.fileName(for: "../evil/x") == ".._evil_x.png")
    }

    @MainActor
    @Test func rendersAnyDecodableImageTo32Pixels() throws {
        let source = NSImage(size: NSSize(width: 64, height: 40))
        source.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 40).fill()
        source.unlockFocus()
        let data = try #require(source.tiffRepresentation)
        let (image, png) = try #require(BrowserFaviconStore.render(data))
        #expect(image.size == NSSize(width: 16, height: 16))
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == 32 && rep.pixelsHigh == 32)
        #expect(BrowserFaviconStore.render(Data("<html></html>".utf8)) == nil)
    }
}
