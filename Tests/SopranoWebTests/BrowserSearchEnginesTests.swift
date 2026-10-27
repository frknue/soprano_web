@testable import SopranoWeb
import AppKit
import Testing

struct BrowserSearchEnginesTests {
    private let wikipedia = BrowserSearchEngine(
        id: BrowserSearchEngineID(rawValue: "wiki"),
        name: "Wikipedia",
        keyword: "w",
        template: "https://en.wikipedia.org/w/index.php?title=Special:Search&search=%s"
    )

    /// Wikipedia `w`, and Google with the keyword the user gave it.
    private var engines: BrowserSearchEngines {
        BrowserSearchEngines(custom: [wikipedia], builtInKeywords: ["google": "g"])
    }

    // MARK: Templates

    @Test func templateTakesThePercentEncodedQuery() {
        #expect(wikipedia.searchURL(for: "c++ & rust?/é")?.absoluteString
            == "https://en.wikipedia.org/w/index.php?title=Special:Search&search=c%2B%2B%20%26%20rust%3F%2F%C3%A9")
        let path = BrowserSearchEngine(
            id: .makeCustom(),
            name: "Path",
            keyword: "p",
            template: "https://example.com/find/%s/all?again=%s"
        )
        #expect(path.searchURL(for: "a b#c")?.absoluteString
            == "https://example.com/find/a%20b%23c/all?again=a%20b%23c")
    }

    @Test func builtInsSearchWithTheirTemplates() {
        #expect(BrowserSearchEngine.duckDuckGo.searchURL(for: "cats")?.absoluteString == "https://duckduckgo.com/?q=cats")
        #expect(BrowserSearchEngine.google.searchURL(for: "cats")?.absoluteString
            == "https://www.google.com/search?q=cats")
        #expect(BrowserSearchEngine.bing.searchURL(for: "cats")?.absoluteString == "https://www.bing.com/search?q=cats")
        #expect(BrowserSearchEngine.builtIn.map(\.keyword) == ["", "", ""])
    }

    @Test func builtInsHaveNoKeywordByDefault() {
        // "b tree" and "g string" are ordinary searches, not Bing or Google.
        #expect(BrowserSearchEngines.default.resolve("b tree") == nil)
        #expect(BrowserSearchEngines.default.resolve("g string") == nil)
        #expect(BrowserAddressResolver.resolve("b tree")?.absoluteString == "https://duckduckgo.com/?q=b%20tree")
        let keywords = BrowserSearchEngines.default.all.map(\.keyword)
        #expect(keywords == ["", "", ""])
    }

    @Test func templatesMustBeHTTPWithAHostAndPercentS() {
        #expect(BrowserSearchEngine.isValidTemplate("https://example.com/?q=%s"))
        #expect(BrowserSearchEngine.isValidTemplate("http://intranet.local/search/%s"))
        #expect(!BrowserSearchEngine.isValidTemplate("https://example.com/?q="))
        #expect(!BrowserSearchEngine.isValidTemplate("ftp://example.com/%s"))
        #expect(!BrowserSearchEngine.isValidTemplate("javascript:alert('%s')"))
        #expect(!BrowserSearchEngine.isValidTemplate("example.com/?q=%s"))
        #expect(!BrowserSearchEngine.isValidTemplate("https://example.com/?q=%s and more"))
    }

    @Test func startPageFormFollowsTheTemplate() {
        #expect(BrowserSearchEngine.google.searchForm
            == BrowserSearchForm(action: "https://www.google.com/search", field: "q", hidden: []))
        #expect(wikipedia.searchForm == BrowserSearchForm(
            action: "https://en.wikipedia.org/w/index.php",
            field: "search",
            hidden: [BrowserSearchForm.Field(name: "title", value: "Special:Search")]
        ))
        let path = BrowserSearchEngine(id: .makeCustom(), name: "Path", keyword: "", template: "https://example.com/s/%s")
        #expect(path.searchForm == nil)
        let plain = BrowserSearchEngine(id: .makeCustom(), name: "Plain", keyword: "", template: "http://example.com/?q=%s")
        #expect(plain.searchForm == nil)
    }

    @Test func startPageUsesACustomDefaultsForm() {
        var settings = BrowserSettings()
        settings.customSearchEngines = [wikipedia]
        settings.searchEngine = wikipedia.id
        let html = BrowserStartPage.html(theme: .folioPaper, settings: settings, pins: BrowserPinTree(), history: [])
        #expect(html.contains("action=\"https://en.wikipedia.org/w/index.php\""))
        #expect(html.contains("name=\"search\" placeholder=\"Search with Wikipedia\""))
        #expect(html.contains("<input type=\"hidden\" name=\"title\" value=\"Special:Search\">"))
    }

    // MARK: Keywords

    @Test func keywordAndQuerySearchThatEngine() {
        #expect(engines.resolve("w cats") == BrowserKeywordSearch(engine: wikipedia, query: "cats"))
        #expect(engines.resolve("  W   big cats  ") == BrowserKeywordSearch(engine: wikipedia, query: "big cats"))
        #expect(engines.resolve("d cats") == nil)
        #expect(engines.resolve("G\tcats")?.engine.id == .google)
        #expect(engines.engine(forKeyword: "g")?.keyword == "g")
        #expect(engines.engine(forKeyword: " W ") == wikipedia)
        #expect(engines.engine(forKeyword: "") == nil)
    }

    @Test func bareKeywordOrOtherWordsAreNoKeywordSearch() {
        #expect(engines.resolve("w") == nil)
        #expect(engines.resolve("w   ") == nil)
        #expect(engines.resolve("wiki cats") == nil)
        #expect(engines.resolve("cats w") == nil)
        #expect(engines.resolve("") == nil)
    }

    @Test func addressesAreNotHijacked() {
        #expect(engines.resolve("d.com") == nil)
        #expect(engines.resolve("g:8080") == nil)
        #expect(engines.resolve("https://w cats") == nil)
        #expect(BrowserAddressResolver.resolve("d.com", searchEngines: engines)?.absoluteString == "https://d.com")
        #expect(BrowserAddressResolver.resolve("localhost:3000", searchEngines: engines)?.absoluteString
            == "http://localhost:3000")
        #expect(BrowserAddressResolver.resolve("w.example.com/cats", searchEngines: engines)?.absoluteString
            == "https://w.example.com/cats")
    }

    @Test func addressResolutionSearchesTheKeywordsEngine() {
        let engines = BrowserSearchEngines(
            custom: [wikipedia],
            builtInKeywords: ["duckDuckGo": "d"],
            defaultID: .google
        )
        #expect(BrowserAddressResolver.resolve("w cats", searchEngines: engines)?.absoluteString
            == "https://en.wikipedia.org/w/index.php?title=Special:Search&search=cats")
        #expect(BrowserAddressResolver.resolve("d cats", searchEngines: engines)?.absoluteString
            == "https://duckduckgo.com/?q=cats")
        // A bare keyword is an ordinary search with the default engine.
        #expect(BrowserAddressResolver.resolve("w", searchEngines: engines)?.absoluteString
            == "https://www.google.com/search?q=w")
        #expect(BrowserAddressResolver.resolve("swift tips", searchEngines: engines)?.absoluteString
            == "https://www.google.com/search?q=swift%20tips")
    }

    @Test func keywordGetsAFirstSuggestionRow() {
        let rows = AddressSuggestionEngine.suggestions(for: AddressSuggestionInput(
            query: "w big cats",
            searchEngines: engines
        )).rows
        #expect(rows.first == AddressSuggestion(
            kind: .search,
            title: "Search Wikipedia for “big cats”",
            detail: "",
            target: .keywordSearch(engine: wikipedia.id, query: "big cats"),
            fillText: "w big cats"
        ))
        // The default engine's search for the whole text stays offered.
        #expect(rows.contains { $0.target == .search("w big cats") })

        let bare = AddressSuggestionEngine.suggestions(for: AddressSuggestionInput(query: "w", searchEngines: engines))
        #expect(bare.rows.first?.target == .search("w"))
    }

    @Test func customEnginesHaveNoSuggestionService() {
        #expect(wikipedia.suggestionURL(for: "cats") == nil)
        #expect(BrowserSearchEngine.google.suggestionURL(for: "cats") != nil)
    }

    // MARK: Settings

    @Test func settingsDecodeEnginesEntryByEntry() throws {
        let json = Data("""
        {
          "searchEngine": "wiki",
          "homepage": "https://example.com",
          "searchEngineKeywords": { "google": " G ", "bing": "g", "nope": "n", "duckDuckGo": 5 },
          "customSearchEngines": [
            { "id": "wiki", "name": " Wikipedia ", "keyword": " W i ", "template": "https://en.wikipedia.org/w/index.php?search=%s" },
            { "id": "noname", "keyword": "n", "template": "https://example.com/?q=%s" },
            { "id": "ftp", "name": "FTP", "keyword": "f", "template": "ftp://example.com/%s" },
            { "id": "nopercent", "name": "No query", "keyword": "x", "template": "https://example.com/" },
            { "id": "taken", "name": "Not Google", "keyword": "G", "template": "https://example.com/?q=%s" },
            { "id": "wiki", "name": "Repeated id", "keyword": "r", "template": "https://example.com/?q=%s" },
            { "id": "google", "name": "Built-in id", "keyword": "bi", "template": "https://example.com/?q=%s" },
            { "id": "second", "name": "Repeated keyword", "keyword": "wi", "template": "https://example.com/?q=%s" },
            42,
            { "name": "No id", "template": "https://example.com/?q=%s" }
          ]
        }
        """.utf8)
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: json)
        // Bing's "g" is Google's already, "nope" is no built-in, 5 no string.
        #expect(settings.searchEngineKeywords == ["google": "g"])
        #expect(settings.searchEngines.engine(forKeyword: "g")?.id == .google)
        #expect(settings.customSearchEngines.map(\.name) == ["Wikipedia", "No id"])
        #expect(settings.customSearchEngines[0].keyword == "wi")
        #expect(settings.customSearchEngines[1].keyword == "")
        #expect(!settings.customSearchEngines[1].id.rawValue.isEmpty)
        #expect(settings.searchEngine == BrowserSearchEngineID(rawValue: "wiki"))
        #expect(settings.defaultSearchEngine.name == "Wikipedia")
        #expect(settings.homepage == "https://example.com")
    }

    @Test func unknownDefaultOrBadListFallsBack() throws {
        let json = Data("""
        {
          "searchEngine": "gone",
          "customSearchEngines": { "not": "a list" },
          "searchEngineKeywords": ["g"],
          "themeID": "folio-ink"
        }
        """.utf8)
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: json)
        #expect(settings.searchEngine == .duckDuckGo)
        #expect(settings.customSearchEngines.isEmpty)
        #expect(settings.searchEngineKeywords.isEmpty)
        #expect(settings.themeID == "folio-ink")
        #expect(BrowserSearchEngines(defaultID: BrowserSearchEngineID(rawValue: "gone")).defaultEngine == .duckDuckGo)
    }

    @Test func settingsRoundTrip() throws {
        var settings = BrowserSettings()
        settings.searchEngines.save(wikipedia)
        var google = BrowserSearchEngine.google
        google.keyword = "g"
        settings.searchEngines.save(google)
        settings.searchEngines.setDefault(wikipedia.id)
        let data = try JSONEncoder().encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"searchEngine\":\"wiki\""))
        #expect(text.contains("\"searchEngineKeywords\":{\"google\":\"g\"}"))
        #expect(try JSONDecoder().decode(BrowserSettings.self, from: data) == settings)
    }

    // MARK: Editing

    @Test func problemsNameWhatIsMissing() {
        #expect(engines.problem(name: " ", keyword: "x", template: "https://example.com/?q=%s") == .emptyName)
        #expect(engines.problem(name: "X", keyword: "x", template: "https://example.com/") == .invalidTemplate)
        #expect(engines.problem(name: "X", keyword: "G", template: "https://example.com/?q=%s")
            == .keywordInUse(by: "Google"))
        #expect(engines.problem(name: "X", keyword: "w", template: "https://example.com/?q=%s")
            == .keywordInUse(by: "Wikipedia"))
        #expect(engines.problem(name: "Wiki", keyword: "w", template: wikipedia.template, editing: wikipedia.id) == nil)
        #expect(engines.problem(name: "Google", keyword: "g", template: BrowserSearchEngine.google.template, editing: .google)
            == nil)
        #expect(engines.problem(name: "X", keyword: "", template: "https://example.com/?q=%s") == nil)
    }

    @Test func saveRemoveAndDefault() {
        var engines = self.engines
        var renamed = wikipedia
        renamed.name = "Wiki"
        renamed.keyword = "WK"
        let savedRenamed = engines.save(renamed)
        #expect(savedRenamed)
        #expect(engines.custom == [BrowserSearchEngine(id: wikipedia.id, name: "Wiki", keyword: "wk", template: wikipedia.template)])
        let savedDuplicate = engines.save(
            BrowserSearchEngine(id: .makeCustom(), name: "Dup", keyword: "wk", template: wikipedia.template)
        )
        #expect(!savedDuplicate)
        // Only a built-in's keyword changes: set, refused when taken, cleared.
        var bing = BrowserSearchEngine.bing
        bing.name = "Not Bing"
        bing.keyword = " B "
        let savedBing = engines.save(bing)
        #expect(savedBing)
        #expect(engines.engine(id: .bing) == BrowserSearchEngine(
            id: .bing,
            name: "Bing",
            keyword: "b",
            template: BrowserSearchEngine.bing.template
        ))
        bing.keyword = "wk"
        let savedTaken = engines.save(bing)
        #expect(!savedTaken)
        bing.keyword = ""
        let savedCleared = engines.save(bing)
        #expect(savedCleared)
        #expect(engines.builtInKeywords == ["google": "g"])

        engines.setDefault(wikipedia.id)
        #expect(engines.defaultEngine.name == "Wiki")
        engines.setDefault(BrowserSearchEngineID(rawValue: "missing"))
        #expect(engines.defaultID == wikipedia.id)
        engines.remove(id: .bing)
        #expect(engines.all.count == 4)
        // Removing the default falls back to DuckDuckGo.
        engines.remove(id: wikipedia.id)
        #expect(engines.custom.isEmpty)
        #expect(engines.defaultEngine == .duckDuckGo)
    }
}
