@testable import SopranoWeb
import AppKit
import Testing
import WebKit

/// Fixture pages for Reader and Translate tests.
enum ReaderFixtures {
    static let article = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>The Quiet Harbour — Coast Weekly</title>
        <meta property="og:site_name" content="Coast Weekly">
        <style>body { background: rgb(1, 2, 3); } .ad { width: 300px; }</style></head>
        <body>
        <nav id="nav"><a href="/">Home</a> <a href="/news">News</a> <a href="/sports">Sports</a></nav>
        <aside class="ad">Buy a boat today! <a href="https://ads.example/">Ad</a></aside>
        <article>
          <h1>The Quiet Harbour</h1>
          <p class="byline">By Mara Lind</p>
          \(paragraphs)
          <figure><img src="harbour.png" alt="The harbour at dawn" width="600" height="400"><figcaption>The harbour at dawn.</figcaption></figure>
          <p>Read more in <a href="https://coast.example/archive" onclick="window.__clicked = true">the archive</a>, where every
          season of the harbour's long history is kept for the town's readers, fishermen and visitors alike.</p>
          <script>window.__articleScript = true;</script>
        </article>
        <footer>© Coast Weekly</footer>
        </body></html>
        """

    static let paragraphs = (1...8).map { index in
        "<p>Paragraph \(index): the harbour wakes slowly. Fishing boats leave before dawn, gulls follow them out past the "
            + "breakwater, and the café on the quay sets out its chairs while the tide turns, as it has for a hundred years, "
            + "and the town counts on the sea for its living and its weather and its stories.</p>"
    }.joined(separator: "\n")

    static let short = """
        <!doctype html><html lang="en"><head><title>Links</title></head>
        <body><ul><li><a href="/a">A</a></li><li><a href="/b">B</a></li></ul><p>Short.</p></body></html>
        """

    static let german = """
        <!doctype html>
        <html lang="de"><head><meta charset="utf-8"><title>Der stille Hafen</title></head>
        <body>
        <h1>Der stille Hafen</h1>
        <p id="first">  Am frühen Morgen verlassen die Fischerboote den Hafen, und die Möwen folgen ihnen hinaus.  </p>
        <p id="second">Das Café am Kai stellt seine Stühle auf, während sich die <b>Gezeiten</b> wenden.</p>
        <p id="third">Die Stadt lebt seit hundert Jahren vom Meer, von seinem Wetter und von seinen Geschichten.</p>
        <pre id="code">let hafen = "nicht übersetzen"</pre>
        <p id="keep" translate="no">Markenname Hafenblick</p>
        <p class="notranslate" id="keep2">Kapitän Lind</p>
        <div id="hidden" style="display:none">Versteckter Text bleibt so</div>
        <textarea id="field">Eingabe bleibt</textarea>
        </body></html>
        """

    /// Writes `html` to `name` in `directory`.
    static func write(_ html: String, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(html.utf8).write(to: url)
        return url
    }
}

@MainActor
struct BrowserReaderTests {
    /// Readability.js ships with its Apache-2.0 LICENSE and NOTICE.
    @Test func readabilityShipsWithItsLicenseAndNotice() throws {
        let bundle = AppResources.bundle
        for (name, ext) in [("Readability", "js"), ("Readability-readerable", "js"), ("LICENSE", nil), ("NOTICE", nil)] {
            let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Readability")
            #expect(url != nil, "\(name) missing")
        }
        let notice = try String(contentsOf: #require(bundle.url(forResource: "NOTICE", withExtension: nil, subdirectory: "Readability")), encoding: .utf8)
        #expect(notice.contains("Arc90"))
        #expect(notice.contains("Mozilla"))
        #expect(BrowserReaderScripts.readability?.contains("function Readability(doc, options)") == true)
        #expect(BrowserReaderScripts.pageInfo.source.contains("function isProbablyReaderable"))
    }

    @Test func toggleStateFollowsThePage() {
        var reader = BrowserTabReader()
        #expect(!reader.isAvailable)
        reader.isReaderable = true
        #expect(reader.isAvailable && !reader.isActive)
        reader.entered(BrowserReaderArticle(title: "T", byline: "B", siteName: "S", length: 10))
        #expect(reader.isActive)
        #expect(reader.article?.title == "T")
        reader.left()
        #expect(!reader.isActive && reader.isAvailable)
        reader.entered(BrowserReaderArticle(title: "T"))
        reader.pageCommitted()
        #expect(reader == BrowserTabReader())
        #expect(BrowserReaderArticle(result: ["active": false, "reason": "noArticle"]) == nil)
        #expect(BrowserReaderArticle(result: ["active": true, "title": "A", "length": 12])?.length == 12)
    }

    /// Readability finds the article (title, byline, site, the image and
    /// the link) and leaves the nav, the ad and the scripts out; the page
    /// comes back as it was, without a reload.
    @Test func extractsTheArticleAndRestoresThePage() async throws {
        let webView = try await Self.load(ReaderFixtures.article)
        _ = try await webView.evaluateJavaScript("window.__marker = 7", in: nil, contentWorld: .page)
        _ = try await webView.evaluateJavaScript(
            try #require(BrowserReaderScripts.readability), in: nil, contentWorld: BrowserPageScripts.isolatedWorld
        )
        let css = BrowserReaderScripts.css(theme: .folioPaper)
        let result = try await webView.callAsyncJavaScript(
            BrowserReaderScripts.enterSource, arguments: ["css": css], in: nil, contentWorld: BrowserPageScripts.isolatedWorld
        )
        let article = try #require(BrowserReaderArticle(result: result))
        #expect(article.title.hasPrefix("The Quiet Harbour"))
        #expect(article.byline == "By Mara Lind")
        #expect(article.siteName == "Coast Weekly")
        #expect(article.length > 1000)

        let dom = try await Self.run("""
            [document.documentElement.className, document.querySelector('.soprano-reader-title').textContent,
             String(document.querySelectorAll('.soprano-reader-content p').length),
             document.querySelector('.soprano-reader-content img') ? document.querySelector('.soprano-reader-content img').src : '',
             document.querySelector('.soprano-reader-content a[href="https://coast.example/archive"]') ? 'link' : '',
             String(document.querySelectorAll('[onclick], script, nav, .ad').length),
             document.title, getComputedStyle(document.body).backgroundColor].join('|')
            """, in: webView)
        let parts = dom.components(separatedBy: "|")
        #expect(parts[0] == "soprano-reader")
        #expect(parts[1] == article.title)
        #expect(Int(parts[2]) ?? 0 >= 8)
        #expect(parts[3] == "https://coast.example/news/harbour.png")
        #expect(parts[4] == "link")
        #expect(parts[5] == "0")
        #expect(parts[6] == "The Quiet Harbour — Coast Weekly")
        // Folio Paper's page color, not the page's own.
        #expect(parts[7] == "rgb(246, 242, 234)")

        // Restyled for Folio Ink in place.
        _ = try await webView.callAsyncJavaScript(
            BrowserReaderScripts.themeSource, arguments: ["css": BrowserReaderScripts.css(theme: .folioInk)], in: nil,
            contentWorld: BrowserPageScripts.isolatedWorld
        )
        #expect(try await Self.run("getComputedStyle(document.body).backgroundColor", in: webView) == "rgb(29, 27, 24)")

        let left = try await webView.callAsyncJavaScript(
            BrowserReaderScripts.leaveSource, arguments: [:], in: nil, contentWorld: BrowserPageScripts.isolatedWorld
        )
        #expect(left as? Bool == true)
        let restored = try await Self.run("""
            [document.documentElement.className, String(!!document.getElementById('nav')), String(window.__marker),
             getComputedStyle(document.body).backgroundColor, String(document.adoptedStyleSheets.length)].join('|')
            """, in: webView)
        #expect(restored == "|true|7|rgb(1, 2, 3)|0")
    }

    /// A page of links has no article: the readerable check says no and
    /// Readability returns nothing to show.
    @Test func aPageWithoutAnArticleHasNoReader() async throws {
        let webView = try await Self.load(ReaderFixtures.short)
        let readerable = try await webView.callAsyncJavaScript(
            "\(try #require(BrowserReaderScripts.readerable))\nreturn isProbablyReaderable(document);",
            arguments: [:], in: nil, contentWorld: BrowserPageScripts.isolatedWorld
        )
        #expect(readerable as? Bool == false)
        _ = try await webView.evaluateJavaScript(
            try #require(BrowserReaderScripts.readability), in: nil, contentWorld: BrowserPageScripts.isolatedWorld
        )
        let result = try await webView.callAsyncJavaScript(
            BrowserReaderScripts.enterSource, arguments: ["css": ""], in: nil, contentWorld: BrowserPageScripts.isolatedWorld
        )
        #expect(BrowserReaderArticle(result: result) == nil)
        #expect(try await Self.run("document.documentElement.className", in: webView) == "")
    }

    // MARK: - Helpers

    static func load(_ html: String, baseURL: String = "https://coast.example/news/story.html") async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        webView.loadHTMLString(html, baseURL: URL(string: baseURL)!)
        // The initial empty document is "complete" too: wait for this one.
        let deadline = Date().addingTimeInterval(10)
        while (try? await run("document.readyState + ' ' + location.href", in: webView)) != "complete \(baseURL)",
              Date() < deadline
        {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(webView.url?.absoluteString == baseURL)
        return webView
    }

    static func run(_ script: String, in webView: WKWebView, world: WKContentWorld = .page) async throws -> String {
        let value = try await webView.evaluateJavaScript(script, in: nil, contentWorld: world)
        return value.map { "\($0)" } ?? ""
    }
}
