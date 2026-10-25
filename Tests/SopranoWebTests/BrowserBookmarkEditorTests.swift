@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserBookmarkEditorTests {
    @Test func editedAddressesGetASchemeWhenTheyNameNone() {
        #expect(BrowserBookmarkEditorContent.address(from: "  example.com/a ") == "https://example.com/a")
        #expect(BrowserBookmarkEditorContent.address(from: "localhost:8080") == "https://localhost:8080")
        #expect(BrowserBookmarkEditorContent.address(from: "http://example.com") == "http://example.com")
        #expect(BrowserBookmarkEditorContent.address(from: "mailto:a@example.com") == "mailto:a@example.com")
        #expect(BrowserBookmarkEditorContent.address(from: "   ") == nil)
    }

    @Test func thePopoverHangsUnderTheStarInsideTheWindow() {
        let size = NSSize(width: 300, height: 150)
        let window = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let star = NSRect(x: 1100, y: 760, width: 24, height: 24)
        let frame = BrowserBookmarkEditorView.frame(size: size, below: star, within: window)
        #expect(frame.maxX == star.maxX + 6)
        #expect(frame.maxY == star.minY - 4)
        // Near the left edge it stays inside.
        let left = BrowserBookmarkEditorView.frame(size: size, below: NSRect(x: 10, y: 400, width: 24, height: 24), within: window)
        #expect(left.minX == 8)
    }
}
