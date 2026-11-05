import Foundation

/// The Markdown of the agent's answers, split into blocks by lines and
/// into spans within a line, for the Agent panel (`BrowserAgentRenderer`,
/// attributed text) and the chats page (`BrowserAgentChatsPage`, HTML), so
/// both show the same thing: paragraphs, `#` headings, bullet and numbered
/// lists (nested by indent), `>` quotes, fenced code, table rows; inline
/// bold, italic, code, strikethrough and web links. Text that isn't
/// Markdown stays as written.
enum BrowserAgentMarkdown {
    enum Kind: Equatable, Sendable {
        case text, heading, list, quote, code, table
    }

    struct Block: Equatable, Sendable {
        enum Content: Equatable, Sendable {
            case paragraph(String)
            case heading(level: Int, text: String)
            /// `number` is nil for a bullet; `depth` 0…3 by indent.
            case item(depth: Int, number: String?, text: String)
            case quote(String)
            /// A fence still streaming has the lines that came so far.
            case code([String])
            /// The row as written, pipes included.
            case tableRow(String)
        }

        var content: Content
        /// A blank line or a rule separates it from the block before.
        var afterGap: Bool

        var kind: Kind {
            switch content {
            case .paragraph: .text
            case .heading: .heading
            case .item: .list
            case .quote: .quote
            case .code: .code
            case .tableRow: .table
            }
        }
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var gap = false
        var code: [String]?
        var codeGap = false
        func add(_ content: Block.Content) {
            blocks.append(Block(content: content, afterGap: gap))
            gap = false
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") {
                    blocks.append(Block(content: .code(code ?? []), afterGap: codeGap))
                    code = nil
                    gap = false
                } else {
                    code?.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                code = []
                codeGap = gap
                continue
            }
            if trimmed.isEmpty || trimmed.wholeMatch(of: #/([-*_]\s*){3,}/#) != nil {
                gap = !blocks.isEmpty
                continue
            }
            if let match = trimmed.wholeMatch(of: #/(#{1,6})\s+(.*)/#) {
                add(.heading(level: match.1.count, text: String(match.2)))
            } else if let match = line.wholeMatch(of: #/(\s*)(?:([-*+•])|(\d{1,3})[.)])\s+(.*)/#) {
                add(.item(
                    depth: min(3, match.1.count / 2),
                    number: match.2 == nil ? String(match.3 ?? "") : nil,
                    text: String(match.4)
                ))
            } else if let match = trimmed.wholeMatch(of: #/>\s?(.*)/#) {
                add(.quote(String(match.1)))
            } else if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 1 {
                // A table's separator row only lines the columns up.
                if trimmed.wholeMatch(of: #/[|:\-\s]+/#) != nil { continue }
                add(.tableRow(trimmed))
            } else {
                add(.paragraph(trimmed))
            }
        }
        if let code {
            blocks.append(Block(content: .code(code), afterGap: codeGap))
        }
        return blocks
    }

    /// A run of one line's text with one set of inline styles.
    struct Span: Equatable, Sendable {
        var text: String
        var bold = false
        var italic = false
        var code = false
        var strikethrough = false
        /// Web and mail links only: a `file:` link would open (or launch)
        /// whatever it names.
        var link: URL?
    }

    static func spans(_ line: String) -> [Span] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: line, options: options) else {
            return [Span(text: line)]
        }
        return parsed.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            var span = Span(text: String(parsed[run.range].characters))
            span.bold = intent.contains(.stronglyEmphasized)
            span.italic = intent.contains(.emphasized)
            span.code = intent.contains(.code)
            span.strikethrough = intent.contains(.strikethrough)
            if let link = run.link, ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                span.link = link
            }
            return span
        }
    }
}
