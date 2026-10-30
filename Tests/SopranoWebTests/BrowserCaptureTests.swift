@testable import SopranoWeb
import AppKit
import Testing

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
}
