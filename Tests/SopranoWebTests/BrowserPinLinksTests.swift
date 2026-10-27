@testable import SopranoWeb
import AppKit
import Testing

struct BrowserPinLinksTests {
    private let pin = UUID()
    private let otherPin = UUID()
    private let favorite = UUID()

    @Test func aLinkLastsWhileItsPinOrFavoriteExists() {
        let targets = BrowserPinLinks.Targets(pins: [pin], favorites: [favorite])
        #expect(BrowserPinLinks.validated(.pinned(pin), in: targets) == .pinned(pin))
        #expect(BrowserPinLinks.validated(.favorite(favorite), in: targets) == .favorite(favorite))
        // A deleted pin or favorite leaves a Today tab.
        #expect(BrowserPinLinks.validated(.pinned(otherPin), in: targets) == .today)
        #expect(BrowserPinLinks.validated(.favorite(pin), in: targets) == .today)
        #expect(BrowserPinLinks.validated(.today, in: targets) == .today)
    }

    @Test func aMovedTabKeepsItsLinkOnlyWhereItsPinHasNoLiveTab() {
        let targets = BrowserPinLinks.Targets(pins: [pin, otherPin], favorites: [favorite])
        #expect(BrowserPinLinks.originAfterMove(.pinned(pin), into: targets, live: [.today, .pinned(otherPin)]) == .pinned(pin))
        // The target window already has the pin's live tab.
        #expect(BrowserPinLinks.originAfterMove(.pinned(pin), into: targets, live: [.pinned(pin)]) == .today)
        #expect(BrowserPinLinks.originAfterMove(.favorite(favorite), into: targets, live: [.favorite(favorite)]) == .today)
        #expect(BrowserPinLinks.originAfterMove(.favorite(favorite), into: targets, live: []) == .favorite(favorite))
        // The pin isn't in the Space the tab lands in.
        let elsewhere = BrowserPinLinks.Targets(pins: [otherPin], favorites: [])
        #expect(BrowserPinLinks.originAfterMove(.pinned(pin), into: elsewhere, live: []) == .today)
        #expect(BrowserPinLinks.originAfterMove(.favorite(favorite), into: elsewhere, live: []) == .today)
        #expect(BrowserPinLinks.originAfterMove(.today, into: targets, live: []) == .today)
    }

    @Test func aTabIsAwayOnlyWhenItsPageLeftThePinsAddress() {
        let pinURL = "https://example.com/docs"
        #expect(!BrowserPinLinks.isAway("https://example.com/docs", from: pinURL))
        #expect(!BrowserPinLinks.isAway("HTTPS://Example.COM:443/docs#intro", from: pinURL))
        #expect(!BrowserPinLinks.isAway("http://example.com", from: "http://example.com/"))
        #expect(!BrowserPinLinks.isAway("https://example.com/docs/", from: pinURL))
        #expect(!BrowserPinLinks.isAway(nil, from: pinURL))
        #expect(BrowserPinLinks.isAway("https://example.com/docs/page", from: pinURL))
        #expect(BrowserPinLinks.isAway("https://example.com/docs?tab=2", from: pinURL))
        #expect(BrowserPinLinks.isAway("https://example.com/", from: pinURL))
    }

    @Test func whereThePinsLoadLandedIsHomeToo() {
        // http://mail.example.com redirects to https://mail.example.com/u/0/.
        let pinURL = "http://mail.example.com"
        let landing = "https://mail.example.com/u/0/"
        #expect(!BrowserPinLinks.isAway(landing, from: pinURL, landing: landing))
        #expect(!BrowserPinLinks.isAway("https://mail.example.com/u/0", from: pinURL, landing: landing))
        #expect(!BrowserPinLinks.isAway(pinURL, from: pinURL, landing: landing))
        #expect(BrowserPinLinks.isAway("https://mail.example.com/u/0/inbox/42", from: pinURL, landing: landing))
        // Without a landing address, the redirect target is away.
        #expect(BrowserPinLinks.isAway(landing, from: pinURL))
    }

    @Test func favoritesThenPinsThenTodayTabsInWindowOrder() {
        let favorites = [UUID(), UUID()]
        let pins = [UUID(), UUID(), UUID()]
        let tabs: [(id: String, origin: BrowserTabOrigin)] = [
            ("today 1", .today),
            ("pin 3", .pinned(pins[2])),
            ("favorite 2", .favorite(favorites[1])),
            ("today 2", .today),
            ("pin 1", .pinned(pins[0])),
            ("favorite 1", .favorite(favorites[0])),
            ("gone", .pinned(UUID())),
        ]
        #expect(BrowserPinLinks.order(tabs, favorites: favorites, pins: pins) == [
            "favorite 1", "favorite 2", "pin 1", "pin 3", "today 1", "today 2", "gone",
        ])
    }

    @Test func theIconFieldTakesASymbolNameOrAnEmoji() {
        let symbols: Set<String> = ["briefcase", "house.fill"]
        let isSymbol = { symbols.contains($0) }
        #expect(BrowserSpaceIcon.parse("  ", isSymbol: isSymbol) == .none)
        #expect(BrowserSpaceIcon.parse("briefcase", isSymbol: isSymbol) == .symbol("briefcase"))
        #expect(BrowserSpaceIcon.parse(" house.fill ", isSymbol: isSymbol) == .symbol("house.fill"))
        #expect(BrowserSpaceIcon.parse("🏠", isSymbol: isSymbol) == .emoji("🏠"))
        #expect(BrowserSpaceIcon.parse("👩‍💻 work", isSymbol: isSymbol) == .emoji("👩‍💻"))
        #expect(BrowserSpaceIcon.parse("W", isSymbol: isSymbol) == .emoji("W"))
        #expect(BrowserSpaceIcon.symbol("briefcase").fieldText == "briefcase")
    }
}
