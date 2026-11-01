@testable import SopranoWeb
import AppKit
import Testing

/// The Settings page's boundary: which address is Settings, which frame
/// may change settings, which messages and values are accepted, and that
/// stored text can't break out of the page's state script.
struct BrowserSettingsWebPageTests {
    @Test func settingsIsItsOwnPageNotTheStartPage() {
        let settings = URL(string: "soprano-web://settings")
        #expect(BrowserSettingsWebPage.isSettings(settings))
        #expect(BrowserSettingsWebPage.isSettings(URL(string: "SOPRANO-WEB://Settings#privacy")))
        #expect(!BrowserAddressResolver.isStartPage(settings))
        #expect(BrowserAddressResolver.isStartPage(URL(string: "soprano-web://start")))
        #expect(!BrowserSettingsWebPage.isSettings(URL(string: "soprano-web://start")))
        #expect(!BrowserSettingsWebPage.isSettings(URL(string: "https://settings/")))
        #expect(!BrowserSettingsWebPage.isSettings(nil))
    }

    @Test func onlyTheSettingsMainFrameMayPost() {
        let settings = URL(string: "soprano-web://settings")
        #expect(BrowserSettingsWebPage.acceptsMessage(frameURL: settings, isMainFrame: true))
        #expect(!BrowserSettingsWebPage.acceptsMessage(frameURL: settings, isMainFrame: false))
        #expect(!BrowserSettingsWebPage.acceptsMessage(frameURL: URL(string: "https://example.com/"), isMainFrame: true))
        #expect(!BrowserSettingsWebPage.acceptsMessage(frameURL: URL(string: "soprano-web://start"), isMainFrame: true))
    }

    @Test func messagesParseOnlyTheirOwnShape() {
        typealias Message = BrowserSettingsWebPage.Message
        #expect(Message(["action": "set", "key": "restoreSession", "value": true]) == .set(key: "restoreSession", value: .bool(true)))
        #expect(Message(["action": "set", "key": "themeID", "value": "folio"]) == .set(key: "themeID", value: .text("folio")))
        // A number is no switch value.
        #expect(Message(["action": "set", "key": "restoreSession", "value": 1]) == nil)
        #expect(Message(["action": "set", "key": "restoreSession"]) == nil)
        #expect(Message(["action": "open", "sheet": "extensions"]) == .open(.extensions))
        #expect(Message(["action": "open", "sheet": "terminal"]) == nil)
        #expect(Message(["action": "allowTranslation", "code": "de"]) == .allowTranslation("de"))
        #expect(Message(["action": "eval"]) == nil)
        #expect(Message([:]) == nil)
    }

    @Test func valuesTheSettingDoesNotOfferAreRefused() {
        var settings = BrowserSettings.default
        let before = settings
        let refused: [(String, BrowserSettingsWebPage.SettingValue)] = [
            ("themeID", .text("no-such-theme")),
            ("defaultZoom", .text("1.3")),
            ("defaultZoom", .text("big")),
            ("searchEngine", .text("no-such-engine")),
            ("appearance", .text("sepia")),
            ("tabSleep", .text("forever")),
            ("historyRetention", .text("")),
            ("autoplay", .text("always")),
            ("restoreSession", .text("true")),
            ("homepage", .bool(true)),
            ("homepage", .text(String(repeating: "a", count: BrowserSettingsWebPage.homepageLimit + 1))),
            ("downloadDirectory", .text("/")),
            ("customSearchEngines", .text("[]")),
        ]
        for (key, value) in refused {
            #expect(!BrowserSettingsWebPage.apply(key: key, value: value, to: &settings), "\(key)")
        }
        #expect(settings == before)
    }

    @Test func offeredValuesApply() {
        var settings = BrowserSettings.default
        let google = settings.searchEngines.all.first { $0.name == "Google" }!.id.rawValue
        let theme = AppTheme.options.last!.id
        let accepted: [(String, BrowserSettingsWebPage.SettingValue)] = [
            ("restoreSession", .bool(false)),
            ("verticalTabs", .bool(false)),
            ("searchEngine", .text(google)),
            ("themeID", .text(theme)),
            ("appearance", .text("dark")),
            ("defaultZoom", .text("1.25")),
            ("tabSleep", .text(BrowserTabSleepAfter.fourHours.rawValue)),
            ("homepage", .text("  https://example.com  ")),
        ]
        for (key, value) in accepted {
            #expect(BrowserSettingsWebPage.apply(key: key, value: value, to: &settings), "\(key)")
        }
        #expect(!settings.restoreSession)
        #expect(!settings.usesVerticalTabs)
        #expect(settings.searchEngines.defaultID.rawValue == google)
        #expect(settings.themeID == theme)
        #expect(settings.appearance == .dark)
        #expect(settings.defaultZoom == 1.25)
        #expect(settings.tabSleep == .fourHours)
        #expect(settings.homepage == "https://example.com")
        // The menu's value for that zoom is what the page posts back.
        #expect(BrowserSettingsWebPage.zoomValue(1.25) == "1.25")
        #expect(BrowserSettingsWebPage.zoomValue(1) == "1")
    }

    @Test func storedTextCannotLeaveThePageStateScript() {
        var settings = BrowserSettings.default
        settings.homepage = "</script><script>alert(1)</script>"
        let environment = BrowserSettingsWebPage.Environment(
            theme: .folioInk,
            blockerStatus: "<img src=x onerror=alert(1)>",
            canUpdateLists: true,
            defaultBrowser: "Safari",
            isDefaultBrowser: false,
            canBecomeDefault: true,
            globalShortcut: "⌥⌘N",
            isRecordingShortcut: false,
            shortcutUnavailable: false,
            settingsFile: "~/.config/soprano-web/settings.json",
            version: "1.0"
        )
        let html = BrowserSettingsWebPage.html(state: BrowserSettingsWebPage.state(settings: settings, environment: environment))
        #expect(!html.contains("</script><script>alert"))
        #expect(!html.contains("<img src=x"))
        #expect(html.contains("\\u003c\\/script>\\u003cscript>alert(1)"))
    }
}
