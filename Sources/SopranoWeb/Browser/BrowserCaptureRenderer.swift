import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Turns a web view's page into a PNG: an area or the visible page through
/// `takeSnapshot` (view coordinates, inside the bounds), the full page
/// through `createPDF` with the rect set to the document, rasterized off the
/// main thread. Both render at `scale` pixels per point.
@MainActor
enum BrowserCaptureRenderer {
    /// `rect` (the web view's coordinates) or, nil, the visible page.
    static func snapshot(of webView: WKWebView, rect: CGRect?, scale: CGFloat) async throws -> BrowserCaptureImage {
        let configuration = WKSnapshotConfiguration()
        let area = rect ?? webView.bounds
        if let rect { configuration.rect = rect }
        let image: NSImage
        do {
            image = try await webView.takeSnapshot(configuration: configuration)
        } catch {
            throw BrowserCaptureError.snapshot(error.localizedDescription)
        }
        let pixels = BrowserCaptureGeometry.pixelSize(of: area.size, scale: scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels.width,
            pixelsHigh: pixels.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw BrowserCaptureError.snapshot("Couldn’t allocate the capture.") }
        rep.size = area.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: area.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = rep.cgImage, let png = encodePNG(cgImage) else {
            throw BrowserCaptureError.snapshot("Couldn’t encode the capture.")
        }
        return BrowserCaptureImage(png: png, pixelWidth: pixels.width, pixelHeight: pixels.height)
    }

    /// The document's size in CSS pixels, read in an isolated world so the
    /// page can't answer for it: scroll width and height, the layout
    /// viewport's width and the root's and body's `overflow-x`
    /// (`BrowserCaptureGeometry.documentWidth` picks the width).
    private static let documentSizeScript = """
    (function () {
      var d = document.documentElement, b = document.body;
      var overflow = function (e) { return e ? getComputedStyle(e).overflowX : 'visible'; };
      return [Math.max(d ? d.scrollWidth : 0, b ? b.scrollWidth : 0),
              Math.max(d ? d.scrollHeight : 0, b ? b.scrollHeight : 0),
              d ? d.clientWidth : 0, overflow(d), overflow(b)];
    })()
    """

    /// The document size `fullPage` captures (CSS pixels), nil when the
    /// page didn't answer.
    static func documentSize(of webView: WKWebView) async -> CGSize? {
        guard let values = try? await webView.evaluateJavaScript(documentSizeScript, contentWorld: .defaultClient) as? [Any],
              values.count == 5,
              let scrollWidth = (values[0] as? NSNumber)?.doubleValue,
              let scrollHeight = (values[1] as? NSNumber)?.doubleValue,
              let clientWidth = (values[2] as? NSNumber)?.doubleValue,
              scrollWidth > 0, scrollHeight > 0
        else { return nil }
        let width = BrowserCaptureGeometry.documentWidth(
            scrollWidth: scrollWidth,
            clientWidth: clientWidth,
            overflowX: [values[3], values[4]].compactMap { $0 as? String }
        )
        return CGSize(width: width, height: scrollHeight)
    }

    /// The whole document from its top, cut at
    /// `BrowserCaptureGeometry.maxPixelLength` and `maxPixelArea`.
    static func fullPage(of webView: WKWebView, scale: CGFloat) async throws -> BrowserCaptureImage {
        let contentSize = await documentSize(of: webView)
            ?? CGSize(width: webView.bounds.width / max(webView.pageZoom, 0.01), height: webView.bounds.height / max(webView.pageZoom, 0.01))
        let plan = BrowserCaptureGeometry.fullPage(contentSize: contentSize, pageZoom: webView.pageZoom, scale: scale)
        let configuration = WKPDFConfiguration()
        configuration.rect = plan.rect
        let pdf: Data
        do {
            pdf = try await webView.pdf(configuration: configuration)
        } catch {
            throw BrowserCaptureError.snapshot(error.localizedDescription)
        }
        let width = plan.pixelWidth, height = plan.pixelHeight
        let png = await Task.detached(priority: .userInitiated) {
            rasterize(pdf, pixelWidth: width, pixelHeight: height)
        }.value
        guard let png else { throw BrowserCaptureError.snapshot("Couldn’t render the page.") }
        return BrowserCaptureImage(png: png, pixelWidth: width, pixelHeight: height, isCut: plan.isCut)
    }

    /// Draws every page of `pdf` top to bottom into one opaque image of
    /// the given pixel size and encodes it as PNG.
    nonisolated static func rasterize(_ pdf: Data, pixelWidth: Int, pixelHeight: Int) -> Data? {
        guard let provider = CGDataProvider(data: pdf as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        let pages = (1...document.numberOfPages).compactMap { document.page(at: $0) }
        let boxes = pages.map { $0.getBoxRect(.mediaBox) }
        let totalHeight = boxes.reduce(0) { $0 + $1.height }
        guard let widest = boxes.map(\.width).max(), widest > 0, totalHeight > 0 else { return nil }
        let scaleX = CGFloat(pixelWidth) / widest
        let scaleY = CGFloat(pixelHeight) / totalHeight
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high
        var top: CGFloat = 0
        for (page, box) in zip(pages, boxes) {
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(pixelHeight) - (top + box.height) * scaleY)
            context.scaleBy(x: scaleX, y: scaleY)
            context.translateBy(x: -box.origin.x, y: -box.origin.y)
            context.drawPDFPage(page)
            context.restoreGState()
            top += box.height
        }
        return context.makeImage().flatMap(encodePNG)
    }

    nonisolated static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The pixels per point of `webView`'s window (2 on Retina).
    static func scale(of webView: WKWebView) -> CGFloat {
        webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}
