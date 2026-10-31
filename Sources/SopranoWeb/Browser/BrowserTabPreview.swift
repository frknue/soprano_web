import AppKit

/// ⌃Tab's picture of a tab's page: a JPEG of the visible page at the
/// widest card's width, taken while the page is on screen — as it leaves
/// the screen, and for the pages shown when the switcher opens
/// (`BrowserWindowController.captureTabPreview`). Kept in memory only; a
/// new document drops it.
struct BrowserTabPreview {
    /// The snapshot's width in points (WebKit renders it at the window's
    /// backing scale): the widest card's preview.
    static let pointWidth: CGFloat = 220

    let jpeg: Data

    var image: NSImage? {
        NSImage(data: jpeg)
    }

    /// A JPEG at the snapshot's own pixel size (tens of KB at 2×).
    static func jpeg(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
