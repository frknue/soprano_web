@testable import SopranoWeb
import AppKit
import Testing

/// Extension notifications' button sets registered as categories: capped,
/// the least recently used dropped first, a set registered again only when
/// it changed.
struct BrowserExtensionNotificationCategoriesTests {
    @Test func theLeastRecentlyUsedIsDroppedBeyondTheCap() {
        var categories = BrowserExtensionNotificationCategories<String>(capacity: 3)
        var made: [String] = []
        for identifier in ["a", "b", "c"] {
            #expect(categories.use(identifier) {
                made.append(identifier)
                return identifier.uppercased()
            })
        }
        #expect(!categories.use("a") {
            made.append("a")
            return "A"
        })
        #expect(categories.use("d") {
            made.append("d")
            return "D"
        })
        #expect(made == ["a", "b", "c", "d"])
        #expect(categories.identifiers == ["c", "a", "d"])
        #expect(categories.categories == ["C", "A", "D"])
    }

    @Test func theAppKeepsAtMostThirtyTwo() {
        var categories = BrowserExtensionNotificationCategories<Int>(capacity: BrowserNotificationCenter.maximumExtensionCategories)
        for index in 0...32 {
            _ = categories.use("\(index)") { index }
        }
        #expect(BrowserNotificationCenter.maximumExtensionCategories == 32)
        #expect(categories.categories == Array(1...32))
    }
}
