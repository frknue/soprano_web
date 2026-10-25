@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserFaviconStoreTests {
    @MainActor
    private final class Results {
        var first: NSImage??
        var second: NSImage??
    }

    /// A solid 32 px PNG in `color`, offered as a `data:` icon.
    private func icon(_ color: NSColor) -> BrowserFaviconCandidate {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
        let url = URL(string: "data:image/png;base64," + png.base64EncodedString())!
        return BrowserFaviconCandidate(url: url, kind: .raster, size: 32)
    }

    private func redComponent(of image: NSImage?) -> CGFloat? {
        guard let rep = image?.representations.first as? NSBitmapImageRep,
              let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB)
        else { return nil }
        return color.redComponent
    }

    @Test func twoPagesOnOneHostKeepTheirOwnIconsWhenResolvedTogether() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-favicons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserFaviconStore(directory: directory)
        let results = Results()

        // Both lookups are in flight at once, like two tabs loading pages of
        // one site that declare different icons (Docs and Sheets).
        store.resolve(
            pageURL: URL(string: "https://docs.example.com/document/1")!,
            candidates: [icon(.red)]
        ) { results.first = $0 }
        store.resolve(
            pageURL: URL(string: "https://docs.example.com/spreadsheets/2")!,
            candidates: [icon(.blue)]
        ) { results.second = $0 }

        for _ in 0..<150 where results.first == nil || results.second == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let first = try #require(results.first)
        let second = try #require(results.second)
        #expect((redComponent(of: first) ?? 0) > 0.9)
        #expect((redComponent(of: second) ?? 1) < 0.1)
    }

    @Test func inMemoryStoreWritesNoFilesAndKeepsItsIconsToItself() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-favicons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = BrowserFaviconStore(directory: directory)
        let results = Results()
        saved.resolve(pageURL: URL(string: "https://known.example/")!, candidates: [icon(.red)]) { results.first = $0 }
        for _ in 0..<150 where results.first == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(filesBefore.count == 1)

        let memory = BrowserFaviconStore(inMemoryOver: saved)
        // Saved icons still show.
        #expect(memory.image(for: URL(string: "https://known.example/page")) != nil)
        memory.resolve(pageURL: URL(string: "https://secret.example/")!, candidates: [icon(.blue)]) { results.second = $0 }
        for _ in 0..<150 where results.second == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((redComponent(of: try #require(results.second)) ?? 1) < 0.1)
        #expect(memory.image(for: URL(string: "https://secret.example/")) != nil)
        #expect(saved.image(for: URL(string: "https://secret.example/")) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == filesBefore)
    }
}
