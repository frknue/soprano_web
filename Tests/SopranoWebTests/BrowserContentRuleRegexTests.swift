@testable import SopranoWeb
import AppKit
import Testing

/// The `url-filter` checker mirrors what WebKit's `URLFilterParser`
/// accepted and rejected when compiled on this Mac (one rejected pattern
/// fails a whole list).
struct BrowserContentRuleRegexTests {
    @Test func acceptsWhatWebKitCompiles() {
        let accepted = [
            "ads",
            ".*",
            "^https://ads\\.example\\.com/",
            "^[^:/?#]+://([^/?#]*\\.)?example\\.com[^-a-zA-Z0-9_.%]",
            "/banner/.*/img([^-a-zA-Z0-9_.%].*)?$",
            "(ab)+c",
            "((a)b)?c",
            "(?:ab)c",
            "a()b",
            "[^a]",
            "[a^]",
            "[a\\-z]",
            "[.a-z]+",
            "a\\{2\\}",
            "\\/ads\\/",
            "\\x41",
            "a*?b",
            "a.*.*b",
            "$",
            "^.*",
        ]
        for pattern in accepted {
            #expect(BrowserContentRuleRegex.problem(in: pattern) == nil, "\(pattern)")
        }
    }

    @Test func rejectsWhatWebKitRejects() {
        let rejected: [(String, BrowserContentRuleRegex.Problem)] = [
            ("", .empty),
            ("é", .nonASCII),
            ("a|b", .disjunction),
            ("(ads|banners)/", .disjunction),
            ("a{2}", .countedRepetition),
            ("a{2,3}", .countedRepetition),
            ("a\\d", .characterClass),
            ("\\w+", .characterClass),
            ("[\\w]", .characterClass),
            ("\\bab", .wordBoundary),
            ("(a)\\1", .backReference),
            ("a^b", .misplacedStart),
            ("(^a)", .misplacedStart),
            ("a$b", .misplacedEnd),
            ("a(b$)?", .misplacedEnd),
            ("a(?=b)", .lookaround),
            ("a(?!b)", .lookaround),
            ("*ab", .misplacedQuantifier),
            ("^?a", .misplacedQuantifier),
            ("a**", .misplacedQuantifier),
            ("(*a)", .misplacedQuantifier),
            ("(ab", .unbalanced),
            ("ab)", .unbalanced),
            ("[ab", .unbalanced),
            ("[]", .unbalanced),
            ("a\\", .badEscape),
            ("\\u00e9", .badEscape),
        ]
        for (pattern, problem) in rejected {
            #expect(BrowserContentRuleRegex.problem(in: pattern) == problem, "\(pattern)")
        }
    }
}
