@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserAddressSummaryTests {
    @Test func webPagesShowTheSiteThenTheTitle() {
        let summary = BrowserAddressSummary.make(address: "https://www.github.com/features?x=1", title: "  GitHub · Features ")
        #expect(summary == BrowserAddressSummary(site: "github.com", title: "GitHub · Features"))
        #expect(BrowserAddressSummary.make(address: "http://localhost:3000/a", title: "Dev")?.site == "localhost:3000")
    }

    @Test func aTitleRepeatingTheSiteOrAddressIsDropped() {
        #expect(BrowserAddressSummary.make(address: "https://www.example.com/", title: "www.example.com")?.title == "")
        #expect(BrowserAddressSummary.make(address: "https://example.com/", title: "Example.com")?.title == "")
        #expect(BrowserAddressSummary.make(address: "file:///tmp/a.txt", title: "file:///tmp/a.txt")?.title == "")
    }

    @Test func otherSchemesShowTheWholeAddress() {
        let summary = BrowserAddressSummary.make(address: "soprano-web://settings", title: "Settings")
        #expect(summary == BrowserAddressSummary(site: "soprano-web://settings", title: "Settings"))
        #expect(BrowserAddressSummary.make(address: "", title: "New Tab") == nil)
    }

    @Test func theUnfocusedToolbarShowsTheSummaryUnlessTheFieldHoldsOtherText() {
        let toolbar = BrowserToolbarView(theme: .folioPaper)
        toolbar.setAddress("https://github.com/", title: "GitHub", security: .secure)
        #expect(toolbar.shownAddressSummary == BrowserAddressSummary(site: "github.com", title: "GitHub"))
        #expect(toolbar.addressField.stringValue == "https://github.com/")

        toolbar.setAddress("", title: "", security: .local)
        #expect(toolbar.shownAddressSummary == nil)

        // Text the user typed and left stays visible instead.
        toolbar.setAddress("https://github.com/", title: "GitHub", security: .secure)
        toolbar.addressField.stringValue = "half typed"
        toolbar.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(toolbar.shownAddressSummary == nil)
    }
}
