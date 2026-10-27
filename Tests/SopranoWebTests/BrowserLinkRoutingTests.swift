@testable import SopranoWeb
import AppKit
import Testing

/// Links from other apps: rule matching, the first rule winning, the file
/// and the store's dedupe.
@MainActor
struct BrowserLinkRoutingTests {
    private let space = UUID()

    private func rule(_ match: BrowserLinkRoutingRule.Match, _ value: String, to destination: BrowserLinkRoutingRule.Destination = .mostRecentSpace) -> BrowserLinkRoutingRule {
        BrowserLinkRoutingRule(match: match, value: value, destination: destination)
    }

    @Test func containsMatchesAnywhereIgnoringCase() {
        let meet = rule(.contains, "Meet.Google.com")
        #expect(meet.matches("https://meet.google.com/abc-defg-hij"))
        #expect(meet.matches("HTTPS://MEET.GOOGLE.COM/"))
        #expect(!meet.matches("https://google.com/meet"))
        #expect(!rule(.contains, "  ").matches("https://example.com/"))
    }

    @Test func equalsMatchesTheWholeAddressWithOrWithoutSchemeAndSlash() {
        let exact = rule(.equals, "https://x.example/")
        #expect(exact.matches("https://x.example/"))
        #expect(exact.matches("https://x.example"))
        #expect(!exact.matches("https://x.example/page"))
        let bare = rule(.equals, "x.example/page")
        #expect(bare.matches("http://x.example/page"))
        #expect(!bare.matches("http://x.example/page/more"))
    }

    @Test func prefixMatchesTheStartWithOrWithoutScheme() {
        #expect(rule(.prefix, "https://docs.").matches("https://docs.example/a"))
        #expect(!rule(.prefix, "https://docs.").matches("http://docs.example/a"))
        #expect(rule(.prefix, "docs.example/a").matches("https://docs.example/a/b"))
        #expect(!rule(.prefix, "example").matches("https://docs.example/"))
    }

    @Test func theFirstMatchingRuleWins() {
        let rules = [rule(.contains, "zoom.us", to: .space(space)), rule(.contains, "zoom", to: .mostRecentSpace)]
        #expect(BrowserLinkRouting.rule(for: "https://us02web.zoom.us/j/1", in: rules)?.destination == .space(space))
        #expect(BrowserLinkRouting.rule(for: "https://zoom.example/", in: rules)?.destination == .mostRecentSpace)
        #expect(BrowserLinkRouting.rule(for: "https://example.com/", in: rules) == nil)
    }

    @Test func theStoreSavesSkipsRepeatsAndDeletes() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebRouting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("link-routing.json")
        let store = BrowserLinkRoutingStore(url: url)
        let meet = rule(.contains, "meet.google.com")
        #expect(store.add([meet, rule(.equals, "https://x.example/", to: .space(space))]) == 2)
        // The same rule with another id or case is a repeat.
        #expect(store.add([rule(.contains, "MEET.google.com")]) == 0)

        let reopened = BrowserLinkRoutingStore(url: url)
        #expect(reopened.rules == store.rules)
        #expect(reopened.rules.map(\.destination) == [.mostRecentSpace, .space(space)])
        reopened.remove(id: meet.id)
        #expect(BrowserLinkRoutingStore(url: url).rules.map(\.value) == ["https://x.example/"])
    }

    @Test func theFileSkipsBadRulesAndRepeatedIDs() throws {
        let id = UUID()
        let json = """
        {"version":1,"rules":[
          {"id":"\(id.uuidString)","match":"contains","value":"a.example"},
          {"id":"\(id.uuidString)","match":"contains","value":"b.example"},
          {"id":"\(UUID().uuidString)","match":"regex","value":"x"},
          {"id":"\(UUID().uuidString)","match":"prefix","value":" "},
          {"match":"contains","value":"no id"},
          {"id":"\(UUID().uuidString)","match":"equals","value":"c.example","space":"\(space.uuidString)"}
        ]}
        """
        let file = try JSONDecoder().decode(BrowserLinkRoutingFile.self, from: Data(json.utf8))
        #expect(file.rules.map(\.value) == ["a.example", "c.example"])
        #expect(file.rules.map(\.destination) == [.mostRecentSpace, .space(space)])
    }
}
