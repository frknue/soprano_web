import AppKit

extension NSAttributedString.Key {
    /// A `BrowserAgentBox` drawn under the text it covers.
    static let agentBox = NSAttributedString.Key("SopranoWebAgentBox")
}

/// A rounded surface under a stretch of the Agent chat: the user's bubble,
/// the tab card over it, a code block. Its horizontal extent is fixed in
/// text container coordinates; its height follows the lines it covers.
/// Two boxes never merge: attribute runs compare by identity.
final class BrowserAgentBox: NSObject {
    let minX: CGFloat
    let maxX: CGFloat
    /// Above the first line and under the last.
    let padding: CGFloat
    let radius: CGFloat
    let fill: NSColor
    let edge: NSColor?
    /// A card's icon, on a tile at the box's leading edge.
    let icon: NSImage?
    let tile: NSColor?

    static let tileSide: CGFloat = 28
    static let tileInset: CGFloat = 8

    init(
        minX: CGFloat,
        maxX: CGFloat,
        padding: CGFloat,
        radius: CGFloat,
        fill: NSColor,
        edge: NSColor? = nil,
        icon: NSImage? = nil,
        tile: NSColor? = nil
    ) {
        self.minX = minX
        self.maxX = maxX
        self.padding = padding
        self.radius = radius
        self.fill = fill
        self.edge = edge
        self.icon = icon
        self.tile = tile
    }

    func draw(in rect: NSRect) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        shape.fill()
        if let edge {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            ring.lineWidth = Chrome.hairline
            edge.setStroke()
            ring.stroke()
        }
        guard let icon else { return }
        let side = Self.tileSide
        let tileRect = NSRect(x: rect.minX + Self.tileInset, y: floor(rect.midY - side / 2), width: side, height: side)
        if let tile {
            tile.setFill()
            NSBezierPath(roundedRect: tileRect, xRadius: Chrome.Radius.control, yRadius: Chrome.Radius.control).fill()
        }
        let glyph: CGFloat = 16
        icon.draw(
            in: NSRect(x: tileRect.midX - glyph / 2, y: tileRect.midY - glyph / 2, width: glyph, height: glyph),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }
}

/// The Agent chat's layout manager: draws each `BrowserAgentBox` under
/// its text, as tall as the lines it covers plus its padding.
final class BrowserAgentLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let whole = NSRange(location: 0, length: storage.length)
        var drawn = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.agentBox, in: characters) { value, range, _ in
            guard let box = value as? BrowserAgentBox, drawn.insert(ObjectIdentifier(box)).inserted else { return }
            var full = NSRange()
            _ = storage.attribute(.agentBox, at: range.location, longestEffectiveRange: &full, in: whole)
            let glyphs = glyphRange(forCharacterRange: full, actualCharacterRange: nil)
            let lines = boundingRect(forGlyphRange: glyphs, in: container)
            box.draw(in: NSRect(
                x: origin.x + box.minX,
                y: origin.y + lines.minY - box.padding,
                width: box.maxX - box.minX,
                height: lines.height + box.padding * 2
            ))
        }
    }
}

/// The Agent chat as styled text, against the transcript view's width:
/// a centered time over a message after a pause, the tab a message went
/// with as a card, the user's message in a bubble at the trailing edge,
/// the agent's run as a "Worked for 16s ›" row (its tool calls under it
/// when expanded) over the answer's Markdown, and a footer with Copy and
/// the time.
@MainActor
struct BrowserAgentRenderer {
    let colors: ThemeColors
    /// The text container's width (no line fragment padding).
    let width: CGFloat

    /// Links the panel handles itself: `steps/<run>` and `copy/<run>`.
    static let actionScheme = "soprano-agent"

    static func actionURL(_ action: String, _ id: Int) -> URL {
        URL(string: "\(actionScheme)://\(action)/\(id)")!
    }

    static var body: NSFont { ChromeFont.sans(size: 14) }
    private static var small: NSFont { ChromeFont.sans(size: 13) }
    private static let bubblePadding = NSSize(width: 12, height: 8)
    private static let cardPadding = NSSize(width: 12, height: 8)
    /// The widest a bubble or card gets, as a share of the chat's width.
    private static let maxShare: CGFloat = 0.84
    /// A line break inside one paragraph (a tool call's lines keep its
    /// indent and spacing).
    private static let lineBreak = "\u{2028}"

    // MARK: Messages

    /// "Today at 11:54 PM", centered.
    func stamp(_ date: Date, before: CGFloat) -> NSAttributedString {
        paragraph(
            ChromeText.attributed(Self.stampFormatter.string(from: date), font: ChromeFont.meta, color: colors.textMuted),
            before: before,
            alignment: .center,
            lineBreak: .byTruncatingTail
        )
    }

    /// The tab a message went with: its icon on a tile, its title over its
    /// host, at the trailing edge.
    func card(_ page: BrowserAgentPage, icon: NSImage?, before: CGFloat) -> NSAttributedString {
        let title = page.title.isEmpty ? page.url : page.title
        let host = URL(string: page.url)?.host() ?? page.url
        let titleFont = ChromeFont.sans(size: 13, weight: .medium)
        let hostFont = ChromeFont.label
        let pad = Self.cardPadding
        let lead = BrowserAgentBox.tileInset + BrowserAgentBox.tileSide + 10
        let maxText = floor(width * Self.maxShare) - lead - pad.width
        let textWidth = ceil(min(maxText, max(
            Self.measure(title, font: titleFont, width: maxText),
            Self.measure(host, font: hostFont, width: maxText)
        ))) + 2
        let minX = max(0, width - textWidth - lead - pad.width)
        let output = NSMutableAttributedString()
        output.append(paragraph(
            ChromeText.attributed(title, font: titleFont, color: colors.textPrimary),
            before: before + pad.height,
            head: minX + lead,
            tail: -pad.width,
            lineBreak: .byTruncatingTail
        ))
        output.append(paragraph(
            ChromeText.attributed(host, font: hostFont, color: colors.textMuted),
            before: 1,
            head: minX + lead,
            tail: -pad.width,
            lineBreak: .byTruncatingTail
        ))
        return boxed(output, BrowserAgentBox(
            minX: minX,
            maxX: width,
            padding: pad.height,
            radius: Chrome.Radius.panel,
            fill: colors.raised,
            edge: colors.borderSubtle,
            icon: icon ?? Self.symbol("globe", size: 13, color: colors.textMuted),
            tile: colors.glyphTile
        ))
    }

    /// The user's message in a bubble at the trailing edge, its lines
    /// starting at the bubble's leading edge.
    func user(_ text: String, before: CGFloat) -> NSAttributedString {
        let font = Self.body
        let pad = Self.bubblePadding
        let maxText = floor(width * Self.maxShare) - pad.width * 2
        let lines = text.components(separatedBy: "\n")
        let textWidth = ceil(min(maxText, lines.map { Self.measure($0, font: font, width: maxText) }.max() ?? 0)) + 2
        let minX = max(0, width - textWidth - pad.width * 2)
        let output = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            output.append(paragraph(
                ChromeText.attributed(line.isEmpty ? " " : line, font: font, color: colors.textPrimary, lineBreakMode: .byWordWrapping),
                before: index == 0 ? before + pad.height : 2,
                head: minX + pad.width,
                tail: -pad.width
            ))
        }
        return boxed(output, BrowserAgentBox(
            minX: minX,
            maxX: width,
            padding: pad.height,
            radius: Chrome.Radius.panel,
            fill: colors.bgOverlay
        ))
    }

    /// A note (an error, a stop) in italics.
    func note(_ text: String, before: CGFloat) -> NSAttributedString {
        paragraph(
            ChromeText.attributed(text, font: Self.italic(ChromeFont.sans(size: 13)), color: colors.textMuted, lineBreakMode: .byWordWrapping),
            before: before
        )
    }

    // MARK: The agent's run

    /// "Worked for 16s ›": a link that shows or hides the run's steps
    /// when `run` is set; a plain line ("Reading the page…") otherwise.
    func runRow(_ label: String, run: Int?, expanded: Bool, before: CGFloat) -> NSAttributedString {
        let font = Self.small
        let row = NSMutableAttributedString(attributedString: ChromeText.attributed(label, font: font, color: colors.textMuted))
        if let run {
            row.append(ChromeText.attributed(" ", font: font, color: colors.textMuted))
            row.append(Self.attachment(expanded ? "chevron.down" : "chevron.right", size: 10, color: colors.textMuted, font: font))
            row.addAttribute(.link, value: Self.actionURL("steps", run), range: NSRange(location: 0, length: row.length))
        }
        return paragraph(row, before: before, lineBreak: .byTruncatingTail)
    }

    /// A tool call under an expanded run: its mark and intent over its
    /// command, a failure's first lines in red.
    func tool(_ entry: BrowserAgentTranscript.Entry, before: CGFloat) -> NSAttributedString {
        let mark: String
        let markColor: NSColor
        switch entry.toolState {
        case .running: mark = "◦"; markColor = colors.textMuted
        case .done: mark = "✓"; markColor = colors.success
        case .failed: mark = "✕"; markColor = colors.danger
        }
        let line = NSMutableAttributedString(attributedString: ChromeText.attributed("\(mark) ", font: ChromeFont.label, color: markColor))
        if let intent = entry.detail {
            line.append(ChromeText.attributed(intent, font: ChromeFont.label, color: colors.textMuted))
            line.append(ChromeText.attributed(Self.lineBreak, font: ChromeFont.label, color: colors.textMuted))
        }
        line.append(ChromeText.attributed(entry.text, font: ChromeFont.monoSmall, color: colors.textMuted, lineBreakMode: .byCharWrapping))
        if entry.toolState == .failed, let failure = entry.failure {
            line.append(ChromeText.attributed(
                Self.lineBreak + failure.replacingOccurrences(of: "\n", with: Self.lineBreak),
                font: ChromeFont.monoSmall,
                color: colors.danger,
                lineBreakMode: .byCharWrapping
            ))
        }
        return paragraph(line, before: before, head: 14, firstHead: 0, lineSpacing: 2)
    }

    /// Copy (a check once copied) and the time the run ended.
    func footer(run: Int, copied: Bool, end: Date, before: CGFloat) -> NSAttributedString {
        let font = ChromeFont.label
        let copy = NSMutableAttributedString(attributedString: Self.attachment(
            copied ? "checkmark" : "square.on.square",
            size: 12,
            color: colors.textMuted,
            font: font
        ))
        copy.addAttributes([
            .link: Self.actionURL("copy", run),
            .toolTip: copied ? "Copied" : "Copy",
        ], range: NSRange(location: 0, length: copy.length))
        copy.append(ChromeText.attributed("    " + Self.timeFormatter.string(from: end), font: font, color: colors.textMuted))
        return paragraph(copy, before: before, lineBreak: .byTruncatingTail)
    }

    // MARK: Markdown

    /// Markdown (`BrowserAgentMarkdown`): paragraphs, `#` headings, bullet
    /// and numbered lists (nested by indent), `>` quotes, fenced code in a
    /// box, table rows in mono; inline bold, italic, code, strikethrough
    /// and web links. Text that isn't Markdown shows as written.
    func markdown(_ text: String, size: CGFloat, color: NSColor, before first: CGFloat) -> NSAttributedString {
        typealias Kind = BrowserAgentMarkdown.Kind
        let output = NSMutableAttributedString()
        var previous: Kind?
        var gap = false
        let font = ChromeFont.sans(size: size)

        func spacing(_ kind: Kind) -> CGFloat {
            guard let previous else { return first }
            if kind == .heading { return 16 }
            if gap || previous != kind { return 10 }
            switch kind {
            case .list: return 5
            case .table: return 0
            default: return 2
            }
        }

        for block in BrowserAgentMarkdown.blocks(text) {
            gap = block.afterGap
            let piece: NSAttributedString
            switch block.content {
            case let .paragraph(line):
                piece = paragraph(inline(line, font: font, color: color), before: spacing(.text))
            case let .heading(level, line):
                let headingFont = ChromeFont.sans(size: level <= 2 ? size + 2 : size, weight: .semibold)
                piece = paragraph(inline(line, font: headingFont, color: color), before: spacing(.heading))
            case let .item(depth, number, line):
                let indent = CGFloat(depth) * 18
                let marker = number.map { "\($0)." } ?? "•"
                let hang: CGFloat = number == nil ? 16 : 22
                let item = NSMutableAttributedString(attributedString: ChromeText.attributed(
                    marker + "\t",
                    font: font,
                    color: colors.textMuted
                ))
                item.append(inline(line, font: font, color: color))
                piece = paragraph(
                    item,
                    before: spacing(.list),
                    head: indent + hang,
                    firstHead: indent + 2,
                    tabs: [NSTextTab(textAlignment: .left, location: indent + hang)]
                )
            case let .quote(line):
                piece = paragraph(
                    inline(line, font: Self.italic(font), color: colors.textMuted),
                    before: spacing(.quote),
                    head: 12,
                    firstHead: 12
                )
            case let .tableRow(row):
                piece = paragraph(
                    ChromeText.attributed(row, font: ChromeFont.monospaced(size: size - 2), color: color, lineBreakMode: .byCharWrapping),
                    before: spacing(.table)
                )
            case let .code(lines):
                let pad: CGFloat = 10
                let body = ChromeText.attributed(
                    lines.joined(separator: Self.lineBreak),
                    font: ChromeFont.monospaced(size: size - 2),
                    color: color,
                    lineBreakMode: .byCharWrapping
                )
                piece = boxed(
                    NSMutableAttributedString(attributedString: paragraph(
                        body,
                        before: spacing(.code) + pad,
                        after: pad,
                        head: pad,
                        tail: -pad,
                        lineSpacing: 2
                    )),
                    BrowserAgentBox(
                        minX: 0,
                        maxX: width,
                        padding: pad,
                        radius: Chrome.Radius.card,
                        fill: colors.raised,
                        edge: colors.borderSubtle
                    )
                )
            }
            output.append(piece)
            previous = block.kind
        }
        return output
    }

    /// One line's inline Markdown in `font` and `color`.
    func inline(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let size = font.pointSize
        let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
        let output = NSMutableAttributedString()
        for span in BrowserAgentMarkdown.spans(text) {
            var runFont = font
            if span.code {
                runFont = ChromeFont.monospaced(size: size - 1)
            } else if span.bold || bold {
                runFont = ChromeFont.sans(size: size, weight: .semibold)
                if span.italic { runFont = Self.italic(runFont) }
            } else if span.italic {
                runFont = Self.italic(font)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color]
            if span.strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = span.link {
                attributes[.link] = link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            output.append(NSAttributedString(string: span.text, attributes: attributes))
        }
        return output
    }

    // MARK: Building blocks

    /// `text` (no newline inside; U+2028 breaks a line) as one paragraph.
    /// A negative `tail` is measured from the trailing edge.
    private func paragraph(
        _ text: NSAttributedString,
        before: CGFloat,
        after: CGFloat = 0,
        alignment: NSTextAlignment = .natural,
        head: CGFloat = 0,
        firstHead: CGFloat? = nil,
        tail: CGFloat = 0,
        lineBreak: NSLineBreakMode = .byWordWrapping,
        tabs: [NSTextTab] = [],
        lineSpacing: CGFloat = 3
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: text)
        output.append(NSAttributedString(string: "\n", attributes: text.length > 0
            ? text.attributes(at: text.length - 1, effectiveRange: nil).filter { $0.key != .link && $0.key != .attachment }
            : [:]))
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.alignment = alignment
        style.headIndent = head
        style.firstLineHeadIndent = firstHead ?? head
        style.tailIndent = tail
        style.lineBreakMode = lineBreak
        style.lineSpacing = lineSpacing
        style.tabStops = tabs
        output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: output.length))
        return output
    }

    /// `text` with `box` under all of it but its closing newline.
    private func boxed(_ text: NSAttributedString, _ box: BrowserAgentBox) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: text)
        output.addAttribute(.agentBox, value: box, range: NSRange(location: 0, length: max(0, output.length - 1)))
        return output
    }

    private static func measure(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        (text as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).width
    }

    /// An SF Symbol in `color`.
    static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    /// An SF Symbol inline, centered on `font`'s capitals.
    private static func attachment(_ name: String, size: CGFloat, color: NSColor, font: NSFont) -> NSAttributedString {
        guard let image = symbol(name, size: size, color: color) else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(
            x: 0,
            y: round((font.capHeight - image.size.height) / 2),
            width: image.size.width,
            height: image.size.height
        )
        let output = NSMutableAttributedString(attachment: attachment)
        output.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: output.length))
        return output
    }

    private static func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    /// "16s", "2m 5s", "1h 3m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }

    static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
