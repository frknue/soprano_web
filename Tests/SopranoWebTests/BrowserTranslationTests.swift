@testable import SopranoWeb
import AppKit
import Testing
import WebKit

/// Translates by wrapping each text in brackets, upper-cased; records its
/// batches.
final class BracketTranslator: BrowserTextTranslator, @unchecked Sendable {
    var batches: [[String]] = []

    func translate(_ texts: [String]) async throws -> [String] {
        batches.append(texts)
        return texts.map { "[\($0.uppercased())]" }
    }
}

@MainActor
final class FakeTranslationService: BrowserTranslationService {
    var availability: BrowserTranslationAvailability = .installed
    var pairs: [String] = []
    let translator = BracketTranslator()

    func availability(source: String, target: String) async -> BrowserTranslationAvailability {
        pairs.append("\(source)>\(target)")
        return availability
    }

    func translator(source: String, target: String) throws -> any BrowserTextTranslator {
        translator
    }
}

@MainActor
struct BrowserTranslationTests {
    // MARK: Language and offer

    @Test func detectsThePagesLanguage() {
        let german = "Am frühen Morgen verlassen die Fischerboote den Hafen, und die Möwen folgen ihnen hinaus aufs Meer."
        let english = "Early in the morning the fishing boats leave the harbour, and the gulls follow them out to sea."
        #expect(BrowserLanguageDetector.detect(sample: german, hint: "") == "de")
        #expect(BrowserLanguageDetector.detect(sample: english, hint: "de") == "en")
        // Too little text: `<html lang>` decides, else nothing.
        #expect(BrowserLanguageDetector.detect(sample: "Bonjour", hint: "fr-FR") == "fr")
        #expect(BrowserLanguageDetector.detect(sample: "OK", hint: "") == nil)
    }

    @Test func offersOnlyLanguagesTheUserDoesntRead() {
        let offer = BrowserTranslationOffer.target
        #expect(offer("de", ["en-US"], []) == "en-US")
        #expect(offer("de", ["en-US", "de-CH"], []) == nil)
        #expect(offer("en", ["en-GB"], []) == nil)
        #expect(offer("de", ["en-US"], ["de"]) == nil)
        #expect(offer("fr", ["en-US"], ["de"]) == "en-US")
        #expect(offer("zh-Hans", ["zh-Hant-TW"], []) == nil)
        #expect(offer(nil, ["en-US"], []) == nil)
        #expect(BrowserTranslationOffer.languageCode("de-CH") == "de")
        #expect(BrowserTranslationOffer.languageCode("zh-Hans") == "zh")
        #expect(BrowserTranslationOffer.displayName("de") == "German")
        #expect(BrowserTranslationOffer.defaultTarget(preferred: []) == "en")
    }

    @Test func neverOfferDecodesTolerantly() throws {
        let json = #"{"neverTranslateLanguages": ["de-CH", "de", "fr"]}"#
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: Data(json.utf8))
        #expect(settings.neverTranslateLanguages == ["de", "fr"])
        let bad = try JSONDecoder().decode(BrowserSettings.self, from: Data(#"{"neverTranslateLanguages": 3}"#.utf8))
        #expect(bad.neverTranslateLanguages == [])
    }

    // MARK: Batches

    @Test func batchesByCountAndCharacters() {
        #expect(BrowserTranslationBatches.make([]) == [])
        let ten = Array(repeating: "abc", count: 10)
        #expect(BrowserTranslationBatches.make(ten, maxCount: 4, maxCharacters: 100) == [0..<4, 4..<8, 8..<10])
        #expect(BrowserTranslationBatches.make(ten, maxCount: 40, maxCharacters: 7) == [0..<2, 2..<4, 4..<6, 6..<8, 8..<10])
        // A string longer than the limit goes alone.
        let long = ["a", String(repeating: "x", count: 50), "b"]
        #expect(BrowserTranslationBatches.make(long, maxCount: 40, maxCharacters: 10) == [0..<1, 1..<2, 2..<3])
        let batches = BrowserTranslationBatches.make(Array(repeating: "word", count: 95))
        #expect(batches.map(\.count) == [40, 40, 15])
    }

    // MARK: Page script

    /// Rendered text nodes go out in order without their edge white space;
    /// code, form fields, `translate="no"`, `.notranslate` and hidden text
    /// stay; applying keeps the elements and the white space; restoring
    /// gives back the exact page.
    @Test func translatesTextNodesAndRestoresThem() async throws {
        let webView = try await BrowserReaderTests.load(ReaderFixtures.german, baseURL: "https://hafen.example/")
        let before = try await BrowserReaderTests.run("document.body.innerHTML", in: webView)
        let elements = try await BrowserReaderTests.run("String(document.body.querySelectorAll('*').length)", in: webView)

        let (start, texts) = try await BrowserTranslationScripts.collect(in: webView)
        #expect(start == 0)
        #expect(texts.first == "Der stille Hafen")
        #expect(texts.contains("Am frühen Morgen verlassen die Fischerboote den Hafen, und die Möwen folgen ihnen hinaus."))
        #expect(texts.contains("Gezeiten"))
        for kept in ["nicht übersetzen", "Markenname", "Kapitän", "Versteckter", "Eingabe"] {
            #expect(!texts.contains { $0.contains(kept) }, "\(kept) collected")
        }
        // Nothing new to collect a second time.
        #expect(try await BrowserTranslationScripts.collect(in: webView).texts.isEmpty)

        let translated = texts.map { "[\($0.uppercased())]" }
        let applied = try await BrowserTranslationScripts.apply(Array(translated[1...]), from: 1, in: webView)
        #expect(applied == texts.count - 1)
        #expect(try await BrowserReaderTests.run("document.getElementById('first').textContent", in: webView)
            == "  [AM FRÜHEN MORGEN VERLASSEN DIE FISCHERBOOTE DEN HAFEN, UND DIE MÖWEN FOLGEN IHNEN HINAUS.]  ")
        #expect(try await BrowserReaderTests.run("document.querySelector('h1').textContent", in: webView) == "Der stille Hafen")
        #expect(try await BrowserReaderTests.run("document.querySelector('#second b').textContent", in: webView) == "[GEZEITEN]")
        #expect(try await BrowserReaderTests.run("document.getElementById('code').textContent", in: webView)
            == "let hafen = \"nicht übersetzen\"")
        #expect(try await BrowserReaderTests.run("String(document.body.querySelectorAll('*').length)", in: webView) == elements)

        // The page changed one node itself: restoring leaves it alone.
        _ = try await webView.evaluateJavaScript(
            "document.getElementById('third').firstChild.nodeValue = 'Seite'", in: nil, contentWorld: .page
        )
        let restored = try await BrowserTranslationScripts.restore(in: webView)
        #expect(restored == texts.count - 2)
        _ = try await webView.evaluateJavaScript(
            "document.getElementById('third').firstChild.nodeValue = 'Die Stadt lebt seit hundert Jahren vom Meer, von seinem Wetter und von seinen Geschichten.'",
            in: nil, contentWorld: .page
        )
        #expect(try await BrowserReaderTests.run("document.body.innerHTML", in: webView) == before)
        // Restoring twice does nothing.
        #expect(try await BrowserTranslationScripts.restore(in: webView) == 0)
    }

    /// A node the page rewrote between collecting and applying keeps the
    /// page's text.
    @Test func applyingSkipsNodesThePageChanged() async throws {
        let webView = try await BrowserReaderTests.load(ReaderFixtures.german, baseURL: "https://hafen.example/")
        let (_, texts) = try await BrowserTranslationScripts.collect(in: webView)
        _ = try await webView.evaluateJavaScript("document.querySelector('h1').firstChild.nodeValue = 'Neu'", in: nil, contentWorld: .page)
        let applied = try await BrowserTranslationScripts.apply(texts.map { "x\($0)" }, from: 0, in: webView)
        #expect(applied == texts.count - 1)
        #expect(try await BrowserReaderTests.run("document.querySelector('h1').textContent", in: webView) == "Neu")
    }
}
