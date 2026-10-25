import Foundation

/// The regular expressions WebKit accepts in a content rule's `url-filter`
/// and `if-top-url` (WebKit's `URLFilterParser`): ASCII only; `.`,
/// character sets, groups and the `*`, `+`, `?` quantifiers; `^` only as
/// the first term and `$` only as the last. No alternation (`|`), counted
/// repetition (`{n,m}`), built-in classes (`\d`, `\w`, `\s`), word
/// boundaries, back-references or look-arounds. One unsupported pattern
/// fails the whole list, so the converter checks every pattern it emits.
enum BrowserContentRuleRegex {
    enum Problem: String, Equatable, Sendable {
        case empty
        case nonASCII
        case disjunction
        case countedRepetition
        case characterClass
        case wordBoundary
        case backReference
        case misplacedStart
        case misplacedEnd
        case lookaround
        case misplacedQuantifier
        case unbalanced
        case badEscape
    }

    static func isSupported(_ pattern: String) -> Bool {
        problem(in: pattern) == nil
    }

    /// The first construct WebKit would reject, or nil.
    static func problem(in pattern: String) -> Problem? {
        let chars = Array(pattern.utf8)
        guard !chars.isEmpty else { return .empty }
        guard chars.allSatisfy({ $0 < 0x80 }) else { return .nonASCII }

        var index = 0
        var depth = 0
        /// Whether the previous term can take a quantifier (an atom or a
        /// closed group), and whether it already has one.
        var canQuantify = false
        var quantified = false
        while index < chars.count {
            let char = chars[index]
            switch char {
            case UInt8(ascii: "^"):
                guard index == 0 else { return .misplacedStart }
                canQuantify = false
            case UInt8(ascii: "$"):
                guard index == chars.count - 1, depth == 0 else { return .misplacedEnd }
                canQuantify = false
            case UInt8(ascii: "|"):
                return .disjunction
            case UInt8(ascii: "{"), UInt8(ascii: "}"):
                return .countedRepetition
            case UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "?"):
                if quantified, char == UInt8(ascii: "?"), chars[index - 1] != UInt8(ascii: "?") {
                    // A lazy quantifier (`*?`); WebKit's DFA treats it as
                    // the greedy one.
                    quantified = false
                    canQuantify = false
                    index += 1
                    continue
                }
                guard canQuantify, !quantified else { return .misplacedQuantifier }
                quantified = true
                index += 1
                continue
            case UInt8(ascii: "("):
                if index + 1 < chars.count, chars[index + 1] == UInt8(ascii: "?") {
                    guard index + 2 < chars.count, chars[index + 2] == UInt8(ascii: ":") else {
                        return .lookaround
                    }
                    index += 2
                }
                depth += 1
                canQuantify = false
            case UInt8(ascii: ")"):
                guard depth > 0 else { return .unbalanced }
                depth -= 1
                canQuantify = true
            case UInt8(ascii: "["):
                guard let end = classEnd(chars, from: index) else { return .unbalanced }
                if let problem = classProblem(chars, from: index + 1, to: end) {
                    return problem
                }
                index = end
                canQuantify = true
            case UInt8(ascii: "]"):
                return .unbalanced
            case UInt8(ascii: "\\"):
                guard index + 1 < chars.count else { return .badEscape }
                if let problem = escapeProblem(chars, at: index + 1, inClass: false) {
                    return problem
                }
                index += escapeLength(chars, at: index + 1)
                canQuantify = true
            default:
                canQuantify = true
            }
            quantified = false
            index += 1
        }
        return depth == 0 ? nil : .unbalanced
    }

    /// The index of the `]` closing the set opened at `start`.
    private static func classEnd(_ chars: [UInt8], from start: Int) -> Int? {
        var index = start + 1
        if index < chars.count, chars[index] == UInt8(ascii: "^") {
            index += 1
        }
        // An empty set (`[]`, `[^]`) is rejected below; a `]` first is
        // still the end.
        while index < chars.count {
            switch chars[index] {
            case UInt8(ascii: "\\"):
                index += 2
                continue
            case UInt8(ascii: "]"):
                return index
            default:
                index += 1
            }
        }
        return nil
    }

    private static func classProblem(_ chars: [UInt8], from start: Int, to end: Int) -> Problem? {
        var index = start
        if index < end, chars[index] == UInt8(ascii: "^") {
            index += 1
        }
        guard index < end else { return .unbalanced }
        while index < end {
            if chars[index] == UInt8(ascii: "\\") {
                if let problem = escapeProblem(chars, at: index + 1, inClass: true) {
                    return problem
                }
                index += escapeLength(chars, at: index + 1) + 1
                continue
            }
            index += 1
        }
        return nil
    }

    /// Escapes WebKit takes: punctuation and `\xHH`. Letters and digits
    /// are classes, boundaries, back-references or code points it rejects.
    private static func escapeProblem(_ chars: [UInt8], at index: Int, inClass: Bool) -> Problem? {
        guard index < chars.count else { return .badEscape }
        let char = chars[index]
        switch char {
        case UInt8(ascii: "d"), UInt8(ascii: "D"), UInt8(ascii: "w"), UInt8(ascii: "W"),
             UInt8(ascii: "s"), UInt8(ascii: "S"):
            return .characterClass
        case UInt8(ascii: "b"), UInt8(ascii: "B"):
            return inClass ? .badEscape : .wordBoundary
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .backReference
        case UInt8(ascii: "x"):
            guard index + 2 < chars.count,
                  isHex(chars[index + 1]), isHex(chars[index + 2])
            else { return .badEscape }
            return nil
        default:
            let isLetter = (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(char)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(char)
            return isLetter ? .badEscape : nil
        }
    }

    /// Characters after the backslash an accepted escape spans.
    private static func escapeLength(_ chars: [UInt8], at index: Int) -> Int {
        chars[index] == UInt8(ascii: "x") ? 3 : 1
    }

    private static func isHex(_ char: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(char)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(char)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(char)
    }
}
