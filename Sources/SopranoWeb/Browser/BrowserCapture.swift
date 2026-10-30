import AppKit
import WebKit

/// Capture (⇧⌘2, `/capture`, `browser screenshot [--full]`): what part of
/// the page becomes a PNG, at which pixel size.
enum BrowserCaptureGeometry {
    /// A drag shorter than this (points) in either direction is a click:
    /// the visible page.
    static let minimumDrag: CGFloat = 4
    /// The tallest (and widest) full-page PNG in pixels: inside every image
    /// API's limit.
    static let maxPixelLength = 16_384
    /// The most pixels a full page may have, whatever its shape: 2560 ×
    /// 16,384 px, ~168 MB of RGBA while it is drawn (a 1440 pt page 8000 pt
    /// tall at 2× would already be 184 MB without it).
    static let maxPixelArea = 2560 * 16_384

    /// The area a drag from `start` to `end` selects, in the web view's own
    /// coordinates (the overlay covers it exactly, so its points are the web
    /// view's): normalized, clipped to `bounds` and snapped outward to whole
    /// points. Nil for a click or a drag outside the page: the visible page.
    /// It stays in view coordinates, which is what `takeSnapshot`'s `rect`
    /// takes, so the page's scroll offset and zoom never enter it.
    static func areaRect(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect? {
        let drag = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        guard drag.width >= minimumDrag, drag.height >= minimumDrag else { return nil }
        let clipped = drag.intersection(bounds)
        guard !clipped.isNull, clipped.width >= minimumDrag, clipped.height >= minimumDrag else { return nil }
        return clipped.integral.intersection(bounds)
    }

    /// The PNG's pixel size for `size` points at `scale` (2 on Retina).
    static func pixelSize(of size: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    /// A full-page capture: the PDF rect, the scale it is rendered at and
    /// whether the page was cut at `maxPixelLength` or `maxPixelArea`.
    struct FullPage: Equatable {
        /// `WKPDFConfiguration.rect`: the document from its top, in page
        /// coordinates (CSS pixels times the page zoom).
        var rect: CGRect
        var scale: CGFloat
        var pixelWidth: Int
        var pixelHeight: Int
        var isCut: Bool
    }

    /// The full page of a document `contentSize` CSS pixels big, shown at
    /// `pageZoom`, rendered at `scale`. The scroll position plays no part:
    /// the rect starts at the document's top. A page too big for the
    /// display scale first drops toward 1× (for the longest side, then for
    /// the pixel budget), then is cut: each side at `maxPixelLength`, then
    /// the height so the whole stays within `maxPixelArea`.
    static func fullPage(
        contentSize: CGSize,
        pageZoom: CGFloat,
        scale: CGFloat,
        maxPixelLength: Int = maxPixelLength,
        maxPixelArea: Int = maxPixelArea
    ) -> FullPage {
        let zoom = pageZoom > 0 ? pageZoom : 1
        let limit = CGFloat(maxPixelLength)
        let budget = CGFloat(maxPixelArea)
        var width = max(1, (contentSize.width * zoom).rounded(.up))
        var height = max(1, (contentSize.height * zoom).rounded(.up))
        var scale = max(1, scale)
        let longest = max(width, height)
        if longest * scale > limit {
            scale = max(1, limit / longest)
        }
        let area = width * height * scale * scale
        if area > budget {
            scale = max(1, scale / (area / budget).squareRoot())
            // Whole pixels round up; step down until they fit.
            while scale > 1 {
                let pixels = pixelSize(of: CGSize(width: width, height: height), scale: scale)
                if pixels.width * pixels.height <= maxPixelArea { break }
                scale = max(1, scale - 0.001)
            }
        }
        var isCut = height * scale > limit || width * scale > limit
        if isCut {
            width = min(width, (limit / scale).rounded(.down))
            height = min(height, (limit / scale).rounded(.down))
        }
        var pixels = pixelSize(of: CGSize(width: width, height: height), scale: scale)
        pixels = (min(pixels.width, maxPixelLength), min(pixels.height, maxPixelLength))
        if pixels.width * pixels.height > maxPixelArea {
            pixels.height = max(1, maxPixelArea / pixels.width)
            height = max(1, (CGFloat(pixels.height) / scale).rounded(.down))
            isCut = true
        }
        return FullPage(
            rect: CGRect(x: 0, y: 0, width: width, height: height),
            scale: scale,
            pixelWidth: pixels.width,
            pixelHeight: pixels.height,
            isCut: isCut
        )
    }

    /// The document's width for a full page, in CSS pixels: the layout
    /// viewport's (`clientWidth`) unless the page really scrolls sideways.
    /// `scrollWidth` also counts what an `overflow-x: hidden` (or `clip`)
    /// root or body hides — an off-canvas drawer — which no one can see.
    static func documentWidth(scrollWidth: CGFloat, clientWidth: CGFloat, overflowX: [String]) -> CGFloat {
        guard clientWidth > 0 else { return scrollWidth }
        let clipped = overflowX.contains { $0 == "hidden" || $0 == "clip" }
        return clipped ? clientWidth : max(clientWidth, scrollWidth)
    }
}

/// Where a capture is saved: `Soprano Capture <date> at <time>.png` in the
/// download folder, made unique with ` (2)`, ` (3)`… as Finder does.
enum BrowserCaptureFile {
    static func name(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Soprano Capture \(formatter.string(from: date))"
    }

    static func url(
        in directory: URL,
        date: Date,
        timeZone: TimeZone = .current,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = name(for: date, timeZone: timeZone)
        var candidate = directory.appendingPathComponent("\(base).png")
        var number = 2
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(base) (\(number)).png")
            number += 1
        }
        return candidate
    }

    /// Writes `data` under the first free name (`url(in:)`'s order) and
    /// never replaces a file: into a hidden temporary file in the same
    /// folder, then renamed with `RENAME_EXCL`, so the capture appears
    /// whole or not at all, and a name taken between the check and the
    /// rename moves on to the next number. Called off the main actor.
    static func save(
        _ data: Data,
        in directory: URL,
        date: Date,
        timeZone: TimeZone = .current,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        write: (Data, URL) throws -> Void = { try $0.write(to: $1) }
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".soprano-capture-\(UUID().uuidString).png")
        // Before the write: a write that fails part way leaves nothing.
        defer { try? FileManager.default.removeItem(at: temporary) }
        try write(data, temporary)
        var taken: Set<String> = []
        for _ in 0..<1000 {
            let candidate = url(in: directory, date: date, timeZone: timeZone) { url in
                exists(url) || taken.contains(url.lastPathComponent)
            }
            if renamex_np(temporary.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                return candidate
            }
            let code = errno
            guard code == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            taken.insert(candidate.lastPathComponent)
        }
        throw POSIXError(.EEXIST)
    }
}

/// A finished capture: the PNG and its pixel size.
struct BrowserCaptureImage: Sendable {
    var png: Data
    var pixelWidth: Int
    var pixelHeight: Int
    /// The full page was taller than `maxPixelLength` and was cut.
    var isCut = false
}

enum BrowserCaptureError: LocalizedError {
    case snapshot(String)

    var errorDescription: String? {
        switch self {
        case .snapshot(let message): message
        }
    }
}
