import Foundation

/// The Netscape bookmark file format every browser imports and exports
/// (`<DL>` lists of `<DT><H3>` folders and `<DT><A HREF>` links).
enum BrowserNetscapeBookmarks {
    /// Parses `data` as UTF-8, falling back to Latin-1.
    static func parse(data: Data) -> [BrowserImportedNode] {
        parse(String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "")
    }

    /// The top-level nodes of a bookmark file. Tolerant: tag names in any
    /// case, missing `</A>`, `</H3>` or `</DL>`, a folder without its `<DL>`
    /// (an empty folder), stray `</DL>`, comments and unknown tags. Links
    /// without an `HREF` are skipped; names and URLs are entity-decoded.
    static func parse(_ html: String) -> [BrowserImportedNode] {
        struct Frame {
            /// `nil` for a `<DL>` that belongs to no folder: its children
            /// join the enclosing list.
            var folder: BrowserImportedFolder?
            var children: [BrowserImportedNode] = []
        }

        var stack = [Frame(folder: nil)]
        // A folder's `<H3>`, waiting for the `<DL>` with its children.
        var pending: BrowserImportedFolder?
        func flushPending() {
            guard let folder = pending else { return }
            stack[stack.count - 1].children.append(.folder(folder))
            pending = nil
        }
        func closeFrame() {
            let frame = stack.removeLast()
            if var folder = frame.folder {
                folder.children = frame.children
                stack[stack.count - 1].children.append(.folder(folder))
            } else {
                stack[stack.count - 1].children.append(contentsOf: frame.children)
            }
        }

        var index = html.startIndex
        while let open = html[index...].firstIndex(of: "<") {
            if html[open...].hasPrefix("<!--") {
                guard let end = html.range(of: "-->", range: open..<html.endIndex) else { break }
                index = end.upperBound
                continue
            }
            guard let close = tagEnd(in: html, from: open) else { break }
            let tag = html[html.index(after: open)..<close]
            index = html.index(after: close)
            let (name, isClosing) = tagName(tag)
            switch name {
            case "DL" where !isClosing:
                stack.append(Frame(folder: pending))
                pending = nil
            case "DL":
                flushPending()
                if stack.count > 1 { closeFrame() }
            case "H3" where !isClosing:
                flushPending()
                let (text, next) = elementText(in: html, from: index, name: name)
                index = next
                let values = attributes(of: tag)
                pending = BrowserImportedFolder(name: text, addedAt: date(values["add_date"]))
            case "A" where !isClosing:
                flushPending()
                let (text, next) = elementText(in: html, from: index, name: name)
                index = next
                let values = attributes(of: tag)
                guard let href = values["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !href.isEmpty
                else { continue }
                stack[stack.count - 1].children.append(.link(BrowserImportedLink(
                    url: href,
                    title: text,
                    addedAt: date(values["add_date"])
                )))
            default:
                break
            }
        }
        flushPending()
        while stack.count > 1 { closeFrame() }
        return stack[0].children
    }

    /// A standard Netscape bookmark file for `nodes` (what Chrome, Firefox
    /// and Safari import).
    static func html(for nodes: [BrowserImportedNode], title: String = "Bookmarks") -> String {
        var lines = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<!-- This is an automatically generated file.",
            "     It will be read and overwritten.",
            "     DO NOT EDIT! -->",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>\(escape(title))</TITLE>",
            "<H1>\(escape(title))</H1>",
            "<DL><p>",
        ]
        func dateAttribute(_ date: Date?) -> String {
            guard let date else { return "" }
            return " ADD_DATE=\"\(Int64(date.timeIntervalSince1970))\""
        }
        func write(_ nodes: [BrowserImportedNode], depth: Int) {
            let indent = String(repeating: "    ", count: depth)
            for node in nodes {
                switch node {
                case let .link(link):
                    lines.append("\(indent)<DT><A HREF=\"\(escape(link.url))\"\(dateAttribute(link.addedAt))>\(escape(link.title))</A>")
                case let .folder(folder):
                    lines.append("\(indent)<DT><H3\(dateAttribute(folder.addedAt))>\(escape(folder.name))</H3>")
                    lines.append("\(indent)<DL><p>")
                    write(folder.children, depth: depth + 1)
                    lines.append("\(indent)</DL><p>")
                }
            }
        }
        write(nodes, depth: 1)
        lines.append("</DL><p>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Decodes `&amp;`-style named entities (the common ones) and numeric
    /// `&#NN;` / `&#xNN;` references; anything else stays as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while let ampersand = text[index...].firstIndex(of: "&") {
            result += text[index..<ampersand]
            let start = text.index(after: ampersand)
            if let semicolon = text[start...].prefix(12).firstIndex(of: ";"),
               let decoded = entity(text[start..<semicolon]) {
                result += decoded
                index = text.index(after: semicolon)
            } else {
                result += "&"
                index = start
            }
        }
        result += text[index...]
        return result
    }

    /// Escapes text and attribute values.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: Private

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "middot": "\u{00B7}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}", "bull": "\u{2022}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "euro": "\u{20AC}",
    ]

    private static func entity(_ name: Substring) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32? = if digits.first == "x" || digits.first == "X" {
                UInt32(digits.dropFirst(), radix: 16)
            } else {
                UInt32(digits, radix: 10)
            }
            guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[String(name)] ?? namedEntities[name.lowercased()]
    }

    /// The `>` that ends the tag opened at `open`, skipping quoted attribute
    /// values; falls back to the first `>` when a quote never closes.
    private static func tagEnd(in html: String, from open: String.Index) -> String.Index? {
        var quote: Character?
        var index = html.index(after: open)
        while index < html.endIndex {
            let character = html[index]
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return html[open...].firstIndex(of: ">")
    }

    /// The tag's upper-cased name and whether it is a closing tag.
    private static func tagName(_ tag: Substring) -> (String, Bool) {
        let trimmed = tag.drop { $0.isWhitespace }
        let isClosing = trimmed.first == "/"
        let body = isClosing ? trimmed.dropFirst().drop { $0.isWhitespace } : trimmed
        return (String(body.prefix { $0.isLetter || $0.isNumber }).uppercased(), isClosing)
    }

    /// The text after an opening tag up to the next tag, entity-decoded and
    /// whitespace-collapsed, and the index after the element's closing tag
    /// when it comes next (else at the next tag).
    private static func elementText(in html: String, from start: String.Index, name: String) -> (String, String.Index) {
        let end = html[start...].firstIndex(of: "<") ?? html.endIndex
        let text = decodeEntities(String(html[start..<end]))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        var next = end
        if end < html.endIndex, let close = tagEnd(in: html, from: end) {
            let (closeName, isClosing) = tagName(html[html.index(after: end)..<close])
            if isClosing, closeName == name { next = html.index(after: close) }
        }
        return (text, next)
    }

    /// Attribute names lower-cased, values entity-decoded.
    private static func attributes(of tag: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var index = tag.startIndex
        // Skip the tag name.
        while index < tag.endIndex, !tag[index].isWhitespace { index = tag.index(after: index) }
        while index < tag.endIndex {
            while index < tag.endIndex, tag[index].isWhitespace || tag[index] == "/" {
                index = tag.index(after: index)
            }
            let nameStart = index
            while index < tag.endIndex, !tag[index].isWhitespace, tag[index] != "=" {
                index = tag.index(after: index)
            }
            let name = tag[nameStart..<index].lowercased()
            while index < tag.endIndex, tag[index].isWhitespace { index = tag.index(after: index) }
            var value = ""
            if index < tag.endIndex, tag[index] == "=" {
                index = tag.index(after: index)
                while index < tag.endIndex, tag[index].isWhitespace { index = tag.index(after: index) }
                if index < tag.endIndex, tag[index] == "\"" || tag[index] == "'" {
                    let quote = tag[index]
                    let valueStart = tag.index(after: index)
                    let valueEnd = tag[valueStart...].firstIndex(of: quote) ?? tag.endIndex
                    value = String(tag[valueStart..<valueEnd])
                    index = valueEnd < tag.endIndex ? tag.index(after: valueEnd) : valueEnd
                } else {
                    let valueStart = index
                    while index < tag.endIndex, !tag[index].isWhitespace { index = tag.index(after: index) }
                    value = String(tag[valueStart..<index])
                }
            }
            if !name.isEmpty, result[name] == nil { result[name] = decodeEntities(value) }
        }
        return result
    }

    /// `ADD_DATE` in seconds since 1970; milliseconds and microseconds (some
    /// exporters) are recognised by their size.
    private static func date(_ value: String?) -> Date? {
        guard let value, let number = Double(value.trimmingCharacters(in: .whitespaces)), number > 0 else {
            return nil
        }
        let seconds = number > 1e14 ? number / 1e6 : number > 1e11 ? number / 1e3 : number
        return Date(timeIntervalSince1970: seconds)
    }
}
