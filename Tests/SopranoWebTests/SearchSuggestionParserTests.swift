@testable import SopranoWeb
import AppKit
import Testing

struct SearchSuggestionParserTests {
    @Test func parsesOpenSearchResponsesFromEachEngine() {
        // DuckDuckGo `type=list`, Bing osjson, and Google `client=firefox`
        // with its trailing metadata object.
        let duckDuckGo = #"["swift",["swift","swift codes","swiftui"]]"#
        let bing = #"["swift",["swift code","swift river"],[],[]]"#
        let google = #"["swift",["swift","taylor swift"],[],{"google:suggestsubtypes":[[512],[512]]}]"#
        #expect(SearchSuggestionParser.parse(Data(duckDuckGo.utf8)) == ["swift", "swift codes", "swiftui"])
        #expect(SearchSuggestionParser.parse(Data(bing.utf8)) == ["swift code", "swift river"])
        #expect(SearchSuggestionParser.parse(Data(google.utf8)) == ["swift", "taylor swift"])
    }

    @Test func acceptsDuckDuckGoPhraseObjectsAndLatin1() {
        let phrases = #"[{"phrase":"café"},{"phrase":"cafe near me"},{"other":1}]"#
        #expect(SearchSuggestionParser.parse(Data(phrases.utf8)) == ["café", "cafe near me"])

        let latin1 = "[\"caf\",[\"café\"]]".data(using: .isoLatin1)!
        #expect(SearchSuggestionParser.parse(latin1) == ["café"])
    }

    @Test func malformedResponsesYieldNothing() {
        for body in ["", "not json", "{}", "[]", #"["q"]"#, #"["q", "not a list"]"#, "<html>"] {
            #expect(SearchSuggestionParser.parse(Data(body.utf8)).isEmpty, "\(body)")
        }
        #expect(SearchSuggestionParser.parse(Data(#"["q",["a",2,null,"b"]]"#.utf8)) == ["a", "b"])
    }

    @Test func suggestionURLsEncodeTheQuery() {
        let query = "c++ & rust?"
        let encoded = "c%2B%2B%20%26%20rust?"
        #expect(BrowserSearchEngine.duckDuckGo.suggestionURL(for: query)?.absoluteString
            == "https://duckduckgo.com/ac/?q=\(encoded)&type=list")
        #expect(BrowserSearchEngine.google.suggestionURL(for: query)?.absoluteString
            == "https://suggestqueries.google.com/complete/search?client=firefox&q=\(encoded)")
        #expect(BrowserSearchEngine.bing.suggestionURL(for: query)?.absoluteString
            == "https://api.bing.com/osjson.aspx?query=\(encoded)")
    }
}
