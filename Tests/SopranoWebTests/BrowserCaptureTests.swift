@testable import SopranoWeb
import AppKit
import Testing
import WebKit

@MainActor
struct BrowserCaptureTests {
    // MARK: Area

    /// The drag is in the web view's own points (the overlay covers it
    /// exactly): normalized from any corner, clipped to the page, snapped
    /// outward to whole points. Nothing else enters: the page's scroll
    /// offset and zoom are already in what the view shows, which is what
    /// `takeSnapshot`'s rect takes.
    @Test func anAreaIsTheDragInViewPoints() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        typealias Geometry = BrowserCaptureGeometry
        #expect(Geometry.areaRect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 310, y: 220), in: bounds)
            == CGRect(x: 10, y: 20, width: 300, height: 200))
        // Dragged up and left.
        #expect(Geometry.areaRect(from: CGPoint(x: 310, y: 220), to: CGPoint(x: 10, y: 20), in: bounds)
            == CGRect(x: 10, y: 20, width: 300, height: 200))
        // Fractions snap outward.
        #expect(Geometry.areaRect(from: CGPoint(x: 10.4, y: 20.6), to: CGPoint(x: 99.2, y: 80.1), in: bounds)
            == CGRect(x: 10, y: 20, width: 90, height: 61))
        // Past the edge: clipped to the page.
        #expect(Geometry.areaRect(from: CGPoint(x: 1100, y: 700), to: CGPoint(x: 1500, y: 900), in: bounds)
            == CGRect(x: 1100, y: 700, width: 100, height: 100))
        // A click or a sliver is the visible page.
        #expect(Geometry.areaRect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 52, y: 51), in: bounds) == nil)
        #expect(Geometry.areaRect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 400, y: 52), in: bounds) == nil)
        // Wholly outside: nothing to clip to.
        #expect(Geometry.areaRect(from: CGPoint(x: 1300, y: 10), to: CGPoint(x: 1400, y: 90), in: bounds) == nil)
    }

    @Test func pixelsFollowTheDisplayScale() {
        let size = CGSize(width: 300, height: 200)
        #expect(BrowserCaptureGeometry.pixelSize(of: size, scale: 2) == (600, 400))
        #expect(BrowserCaptureGeometry.pixelSize(of: size, scale: 1) == (300, 200))
        #expect(BrowserCaptureGeometry.pixelSize(of: CGSize(width: 100.5, height: 0.2), scale: 2) == (201, 1))
    }

    // MARK: Full page

    /// The PDF rect is the document from its top in page coordinates (CSS
    /// pixels times the page zoom); the scroll position never enters.
    @Test func aFullPageIsTheDocumentAtItsZoom() {
        let plain = BrowserCaptureGeometry.fullPage(contentSize: CGSize(width: 1440, height: 5040), pageZoom: 1, scale: 2)
        #expect(plain == .init(rect: CGRect(x: 0, y: 0, width: 1440, height: 5040), scale: 2,
                               pixelWidth: 2880, pixelHeight: 10080, isCut: false))
        // At 125% the document is 1152 CSS px wide in a 1440 pt view.
        let zoomed = BrowserCaptureGeometry.fullPage(contentSize: CGSize(width: 1152, height: 5040), pageZoom: 1.25, scale: 2)
        #expect(zoomed.rect == CGRect(x: 0, y: 0, width: 1440, height: 6300))
        #expect((zoomed.pixelWidth, zoomed.pixelHeight) == (2880, 12600))
        #expect(BrowserCaptureGeometry.fullPage(contentSize: .zero, pageZoom: 0, scale: 0).rect
            == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// A page too tall for 2× renders at a lower scale (at least 1×); one
    /// too tall even at 1× is cut at the cap, never past it.
    @Test func aTallPageIsCappedNotUnbounded() {
        let cap = BrowserCaptureGeometry.maxPixelLength
        let tall = BrowserCaptureGeometry.fullPage(contentSize: CGSize(width: 1280, height: 10_000), pageZoom: 1, scale: 2)
        #expect(!tall.isCut)
        #expect(tall.rect.height == 10_000)
        #expect(tall.pixelHeight <= cap)
        #expect(abs(tall.scale - CGFloat(cap) / 10_000) < 0.0001)

        let huge = BrowserCaptureGeometry.fullPage(contentSize: CGSize(width: 1280, height: 30_000), pageZoom: 1, scale: 2)
        #expect(huge.isCut)
        #expect(huge.scale == 1)
        #expect(huge.rect == CGRect(x: 0, y: 0, width: 1280, height: CGFloat(cap)))
        #expect((huge.pixelWidth, huge.pixelHeight) == (1280, cap))
        // ~614 MB of RGBA uncapped; at most 4 bytes × 1280 × 16,384 now.
        #expect(huge.pixelWidth * huge.pixelHeight * 4 < 100_000_000)

        let small = BrowserCaptureGeometry.fullPage(contentSize: CGSize(width: 800, height: 600), pageZoom: 1, scale: 2,
                                                    maxPixelLength: 1000)
        #expect(small.scale == 1000.0 / 800.0)
        #expect(small.pixelWidth <= 1000 && small.pixelHeight <= 1000)
    }

    /// One PDF page and several stacked render into the planned pixels.
    @Test func aPDFRasterizesToThePlannedSize() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 50)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
        let png = try #require(BrowserCaptureRenderer.rasterize(data as Data, pixelWidth: 200, pixelHeight: 200))
        let image = try #require(NSBitmapImageRep(data: png))
        #expect((image.pixelsWide, image.pixelsHigh) == (200, 200))
        #expect(image.colorAt(x: 100, y: 190)?.redComponent ?? 0 > 0.9)
    }

    // MARK: File

    @Test func capturesGetUniqueNames() {
        let directory = URL(fileURLWithPath: "/tmp/captures", isDirectory: true)
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let utc = TimeZone(identifier: "UTC")!
        #expect(BrowserCaptureFile.name(for: date, timeZone: utc) == "Soprano Capture 2026-10-26 at 07.33.20")
        var taken: Set<String> = []
        var names: [String] = []
        for _ in 0..<3 {
            let url = BrowserCaptureFile.url(in: directory, date: date, timeZone: utc) { taken.contains($0.lastPathComponent) }
            taken.insert(url.lastPathComponent)
            names.append(url.lastPathComponent)
        }
        #expect(names == [
            "Soprano Capture 2026-10-26 at 07.33.20.png",
            "Soprano Capture 2026-10-26 at 07.33.20 (2).png",
            "Soprano Capture 2026-10-26 at 07.33.20 (3).png",
        ])
    }

    /// P8 review P3-5: the file appears whole (renamed from a hidden
    /// temporary file) and never replaces one; a name taken after the
    /// check moves on to the next number.
    @Test func aSaveNeverReplacesAFileAndRenumbersOnARace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebCaptureSave-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let utc = TimeZone(identifier: "UTC")!
        let first = try BrowserCaptureFile.save(Data("one".utf8), in: directory, date: date, timeZone: utc)
        #expect(first.lastPathComponent == "Soprano Capture 2026-10-26 at 07.33.20.png")
        // The check says the name is free, but the file is there by now.
        let raced = try BrowserCaptureFile.save(Data("two".utf8), in: directory, date: date, timeZone: utc) { _ in false }
        #expect(raced.lastPathComponent == "Soprano Capture 2026-10-26 at 07.33.20 (2).png")
        #expect(try Data(contentsOf: first) == Data("one".utf8))
        #expect(try Data(contentsOf: raced) == Data("two".utf8))
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left.sorted() == [first.lastPathComponent, raced.lastPathComponent].sorted())
    }

    /// P8 review P2-1: a full page never holds more than `maxPixelArea`
    /// pixels: the scale drops first, then the height is cut.
    @Test func aFullPageStaysWithinThePixelBudget() {
        let budget = BrowserCaptureGeometry.maxPixelArea
        let square = BrowserCaptureGeometry.fullPage(contentSize: CGSize(width: 16_384, height: 16_384), pageZoom: 1, scale: 2)
        #expect(square.pixelWidth * square.pixelHeight <= budget)
        #expect(square.isCut && square.scale == 1)
        let wide = BrowserCaptureGeometry.fullPage(contentSize: CGSize(width: 1440, height: 8000), pageZoom: 1, scale: 2)
        #expect(wide.pixelWidth * wide.pixelHeight <= budget)
        #expect(!wide.isCut && wide.scale < 2 && wide.rect.height == 8000)
        let tall = BrowserCaptureGeometry.fullPage(contentSize: CGSize(width: 2880, height: 16_000), pageZoom: 1, scale: 2)
        #expect(tall.pixelWidth * tall.pixelHeight <= budget)
        #expect(tall.isCut && tall.rect.height < 16_000)
    }

    /// P8 review P2-1: what an `overflow-x: hidden` root or body hides
    /// (an off-canvas drawer) is no part of the page's width.
    @Test func aFullPageIsAsWideAsWhatScrolls() {
        #expect(BrowserCaptureGeometry.documentWidth(scrollWidth: 2400, clientWidth: 1200, overflowX: ["visible", "hidden"]) == 1200)
        #expect(BrowserCaptureGeometry.documentWidth(scrollWidth: 2400, clientWidth: 1200, overflowX: ["clip", "visible"]) == 1200)
        #expect(BrowserCaptureGeometry.documentWidth(scrollWidth: 2400, clientWidth: 1200, overflowX: ["visible", "visible"]) == 2400)
        #expect(BrowserCaptureGeometry.documentWidth(scrollWidth: 1000, clientWidth: 1200, overflowX: ["auto"]) == 1200)
        #expect(BrowserCaptureGeometry.documentWidth(scrollWidth: 900, clientWidth: 0, overflowX: []) == 900)
    }

    @Test func anOffCanvasDrawerIsLeftOut() async throws {
        func size(_ body: String) async throws -> CGSize? {
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
            webView.loadHTMLString("<!doctype html><title>loaded</title>" + body, baseURL: URL(string: "https://capture.test/")!)
            for _ in 0..<200 {
                let state = try? await webView.evaluateJavaScript("document.readyState === 'complete' ? document.title : ''") as? String
                if state == "loaded" { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            return await BrowserCaptureRenderer.documentSize(of: webView)
        }
        let drawer = "<div style='position:absolute;left:100%;top:0;width:400px;height:10px'></div>"
        let hidden = try await size("<body style='margin:0;overflow-x:hidden'>\(drawer)<p>page</p></body>")
        #expect(hidden?.width == 400)
        let scrolling = try await size("<body style='margin:0'>\(drawer)<p>page</p></body>")
        #expect((scrolling?.width ?? 0) >= 800)
    }

    // MARK: CLI

    private func parse(_ words: [String]) throws -> BrowserCommandRequest? {
        try BrowserCommandRequest.parse(["soprano-web", "browser"] + words, environment: ["PWD": "/work"])
    }

    /// `--full` is an option, never the path; the path is made absolute
    /// against the CLI's directory.
    @Test func theScreenshotCommandParsesOptions() throws {
        #expect(try parse(["screenshot", "out.png"])?.arguments == ["/work/out.png"])
        #expect(try parse(["screenshot", "/tmp/x.png"])?.arguments == ["/tmp/x.png"])
        #expect(try parse(["screenshot", "--full", "/tmp/x.png"])?.arguments == ["--full", "/tmp/x.png"])
        #expect(try parse(["screenshot", "x.png", "--full"])?.arguments == ["--full", "/work/x.png"])
        #expect(try parse(["--tab", "2", "screenshot", "--full", "x.png"])?.tabIndex == 2)
        #expect(try parse(["screenshot", "--", "--full"])?.arguments == ["/work/--full"])
        #expect(try parse(["screenshot", "--full", "x.png"])?.timeout == BrowserCommandRequest.fullScreenshotTimeout)
        #expect(try parse(["screenshot", "x.png"])?.timeout == nil)
        for bad in [["screenshot"], ["screenshot", "--full"], ["screenshot", "--wide", "x.png"], ["screenshot", "a.png", "b.png"]] {
            #expect(throws: BrowserAutomationError.self) { try parse(bad) }
        }
    }

    /// P9 review P3-3: a write that fails part way leaves no hidden
    /// temporary file behind.
    @Test func aFailedSaveLeavesNoTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebCaptureSave-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        struct Failure: Error {}
        #expect(throws: Failure.self) {
            try BrowserCaptureFile.save(
                Data("one".utf8),
                in: directory,
                date: Date(timeIntervalSince1970: 1_793_000_000),
                write: { data, url in
                    try data.prefix(1).write(to: url)
                    throw Failure()
                }
            )
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!left.contains { $0.hasPrefix(".soprano-capture-") })
        #expect(left.isEmpty)
    }
}
