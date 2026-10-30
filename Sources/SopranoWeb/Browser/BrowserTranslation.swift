import AppKit
import NaturalLanguage
import Translation

/// One tab's page language and translation. A new document starts over
/// (`pageCommitted`); `generation` tells a translation in flight that its
/// page is gone.
struct BrowserTabTranslation: Equatable {
    enum Phase: Equatable {
        case original
        case translating(target: String)
        case translated(target: String, nodes: Int)
    }

    /// The page's language (`BrowserLanguageDetector`), a BCP 47 code.
    var language: String?
    var phase: Phase = .original
    private(set) var generation = 0

    var target: String? {
        switch phase {
        case .original: nil
        case let .translating(target), let .translated(target, _): target
        }
    }

    var isTranslated: Bool {
        if case .translated = phase { return true }
        return false
    }

    var isTranslating: Bool {
        if case .translating = phase { return true }
        return false
    }

    mutating func pageCommitted() {
        language = nil
        phase = .original
        generation += 1
    }
}

/// Guesses a page's language from its text (`NLLanguageRecognizer`), with
/// `<html lang>` as the fallback for pages with little text.
enum BrowserLanguageDetector {
    /// Letters below which the text alone doesn't decide.
    static let minimumLetters = 40
    /// The recognizer's confidence below which the guess isn't used.
    static let minimumConfidence = 0.5

    static func detect(sample: String, hint: String) -> String? {
        let hinted = hint.isEmpty ? nil : BrowserTranslationOffer.languageCode(hint)
        let letters = sample.unicodeScalars.lazy.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= minimumLetters else { return hinted }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              language != .undetermined, confidence >= minimumConfidence
        else { return hinted }
        return language.rawValue
    }
}

/// When the address field offers a translation, and into what.
enum BrowserTranslationOffer {
    /// The language part of a BCP 47 identifier ("de-CH" → "de",
    /// "zh-Hans" → "zh").
    static func languageCode(_ identifier: String) -> String {
        let language = Locale.Language(identifier: identifier)
        if let code = language.languageCode?.identifier, !code.isEmpty { return code.lowercased() }
        return identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? identifier
    }

    /// The user's languages, most preferred first (System Settings ▸
    /// Language & Region).
    static var preferredLanguages: [String] { Locale.preferredLanguages }

    /// The language a page is translated into: the first preferred one.
    static func defaultTarget(preferred: [String] = preferredLanguages) -> String {
        preferred.first ?? "en"
    }

    /// The target the address field offers for a page in `detected`, or
    /// nil: no language guessed, one of the user's languages, or a
    /// language the user never wants offered.
    static func target(detected: String?, preferred: [String], neverOffer: Set<String>) -> String? {
        guard let detected else { return nil }
        let code = languageCode(detected)
        let userCodes = Set(preferred.map(languageCode))
        guard !userCodes.contains(code), !neverOffer.contains(code) else { return nil }
        return defaultTarget(preferred: preferred)
    }

    /// "German", "English" (the app's UI is English).
    static func displayName(_ identifier: String) -> String {
        let code = languageCode(identifier)
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? identifier
    }
}

/// Splits text nodes into translation requests: at most `maxCount`
/// strings and `maxCharacters` characters per batch (a longer string goes
/// alone), in page order.
enum BrowserTranslationBatches {
    static let maxCount = 40
    static let maxCharacters = 4000

    static func make(_ texts: [String], maxCount: Int = maxCount, maxCharacters: Int = maxCharacters) -> [Range<Int>] {
        var batches: [Range<Int>] = []
        var start = 0
        var characters = 0
        for (index, text) in texts.enumerated() {
            let length = text.count
            let isFull = index - start >= maxCount || (index > start && characters + length > maxCharacters)
            if isFull {
                batches.append(start..<index)
                start = index
                characters = 0
            }
            characters += length
        }
        if start < texts.count {
            batches.append(start..<texts.count)
        }
        return batches
    }
}

enum BrowserTranslationAvailability: Equatable, Sendable {
    case installed
    /// Supported but not downloaded on this Mac.
    case needsDownload
    case unsupported
}

/// Translates strings in one language pair; the result keeps the order.
protocol BrowserTextTranslator: AnyObject, Sendable {
    func translate(_ texts: [String]) async throws -> [String]
}

/// Language availability and translators: the Translation framework, or a
/// test's stand-in.
@MainActor
protocol BrowserTranslationService: AnyObject {
    func availability(source: String, target: String) async -> BrowserTranslationAvailability
    func translator(source: String, target: String) throws -> any BrowserTextTranslator
}

/// The Translation framework without SwiftUI: only installed pairs
/// (`TranslationSession(installedSource:target:)`); a missing pair is
/// downloaded in System Settings (`openTranslationLanguages`).
@MainActor
final class BrowserSystemTranslationService: BrowserTranslationService {
    /// System Settings ▸ General ▸ Language & Region, whose Translation
    /// Languages… button lists and downloads the languages.
    nonisolated static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
    nonisolated static let settingsPath = "System Settings ▸ General ▸ Language & Region ▸ Translation Languages"

    func availability(source: String, target: String) async -> BrowserTranslationAvailability {
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target)
        )
        switch status {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    func translator(source: String, target: String) throws -> any BrowserTextTranslator {
        BrowserSystemTranslator(session: TranslationSession(
            installedSource: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        ))
    }
}

/// One `TranslationSession`, used for one page's batches one after the
/// other (hence `@unchecked Sendable`).
final class BrowserSystemTranslator: BrowserTextTranslator, @unchecked Sendable {
    private let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }

    func translate(_ texts: [String]) async throws -> [String] {
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        let responses = try await session.translations(from: requests)
        var result = texts
        for response in responses {
            if let index = response.clientIdentifier.flatMap(Int.init), result.indices.contains(index) {
                result[index] = response.targetText
            }
        }
        return result
    }
}
