import SwiftUI
import UIKit

/// An assistant answer rendered as ONE attributed string in a non-editable
/// UITextView, so selection is the system's own: long-press a word, drag the
/// handles across paragraphs, Copy / Share / Look Up — like Notes or Safari.
/// MarkdownUI lays each block out as its own Text, and SwiftUI selection can't
/// cross blocks, which is why chat answers don't use it.
///
/// The look follows the `paloAlly` MarkdownUI theme (MarkdownText.swift):
/// body text with 0.2em line spacing, modest headings, monospaced code blocks
/// on a soft rounded background, a gray bar for quotes. Code blocks wrap
/// instead of scrolling sideways. Tables are split out before they get here
/// (ReplyMarkdown → MarkdownTableView); the tab-stop table below is a fallback.
struct SelectableMarkdown: UIViewRepresentable {
    let source: String
    var streaming: Bool = false
    /// 「引用回复」 in the selection menu: called with the selected text.
    var onQuote: ((String) -> Void)? = nil
    @Environment(\.appTheme) private var theme

    func makeUIView(context: Context) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.onQuote = onQuote
        view.render(source: source, streaming: streaming, linkColor: UIColor(theme.color))
        return view
    }

    func updateUIView(_ view: MarkdownTextView, context: Context) {
        view.onQuote = onQuote
        view.render(source: source, streaming: streaming, linkColor: UIColor(theme.color))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarkdownTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 10_000
        guard width > 0, width.isFinite else { return nil }
        let fit = uiView.fittingSize(width: width)
        return CGSize(width: proposal.width ?? ceil(fit.width), height: ceil(fit.height))
    }
}

final class MarkdownTextView: UITextView, UITextViewDelegate {
    var onQuote: ((String) -> Void)?
    private var lastSource: String?
    private var lastStreaming = false
    private var lastLinkColor: UIColor?
    /// Measured sizes for the current text, by proposed width. SwiftUI asks
    /// again on every layout pass, and each ask re-ran TextKit layout over the
    /// whole answer; a long chat full of long answers then pinned the main
    /// thread. Cleared whenever the text changes.
    private var measured: [CGFloat: CGSize] = [:]

    func fittingSize(width: CGFloat) -> CGSize {
        let key = (width * 2).rounded() / 2
        if let hit = measured[key] { return hit }
        let fit = sizeThatFits(CGSize(width: key, height: .greatestFiniteMagnitude))
        if measured.count > 8 { measured.removeAll() }
        measured[key] = fit
        return fit
    }

    /// TextKit 1, so the layout manager can draw block backgrounds.
    static func make() -> MarkdownTextView {
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = MarkdownTextView(frame: .zero, textContainer: container)
        view.delegate = view
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.adjustsFontForContentSizeCategory = false // re-rendered on size changes instead
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (v: MarkdownTextView, _) in
            v.lastSource = nil
            v.measured.removeAll()
            v.render(source: v.pendingSource, streaming: v.lastStreaming, linkColor: v.lastLinkColor ?? .link)
            v.invalidateIntrinsicContentSize()
        }
        return view
    }

    private var pendingSource = ""

    func render(source: String, streaming: Bool, linkColor: UIColor) {
        pendingSource = source
        guard source != lastSource || streaming != lastStreaming || linkColor != lastLinkColor else { return }
        lastSource = source
        lastStreaming = streaming
        lastLinkColor = linkColor
        measured.removeAll()
        let rendered = MarkdownRenderer.render(streaming ? source + " ▍" : source)
        // A code block / table background reaches 6 pt past its text; make
        // room when one is first or last so it isn't clipped.
        let pad = { (i: Int) -> CGFloat in
            guard rendered.length > 0, let kind = rendered.attribute(.paloBlock, at: i, effectiveRange: nil) as? String else { return 0 }
            return kind == "code" || kind == "table" ? 6 : 0
        }
        textContainerInset = UIEdgeInsets(top: pad(0), left: 0, bottom: rendered.length > 0 ? pad(rendered.length - 1) : 0, right: 0)
        attributedText = rendered
        linkTextAttributes = [.foregroundColor: linkColor]
        // Nothing to select mid-stream; links work once it's finished.
        isSelectable = !streaming
    }

    /// Code blocks and quotes use line separators (U+2028) to stay one
    /// paragraph; copied text gets ordinary newlines back.
    override func copy(_ sender: Any?) {
        guard let range = selectedTextRange, let text = text(in: range) else { return super.copy(sender) }
        UIPasteboard.general.string = text.replacingOccurrences(of: "\u{2028}", with: "\n")
    }

    /// Adds 「引用回复」 to the system selection menu: quotes just the selection.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard onQuote != nil, range.length > 0 else { return nil }
        let selected = (textView.text as NSString).substring(with: range)
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: " ▍", with: "")
        let quote = UIAction(title: "引用回复", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in
            self?.onQuote?(selected)
            textView.selectedTextRange = nil
        }
        return UIMenu(children: [quote] + suggestedActions)
    }
}

// MARK: - Block backgrounds

extension NSAttributedString.Key {
    /// "code" | "quote" | "table" | "rule": drawn by MarkdownLayoutManager.
    static let paloBlock = NSAttributedString.Key("paloBlock")
}

final class MarkdownLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first,
              let ctx = UIGraphicsGetCurrentContext() else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let all = NSRange(location: 0, length: storage.length)
        var seen = Set<Int>()
        storage.enumerateAttribute(.paloBlock, in: visible) { value, range, _ in
            guard let kind = value as? String else { return }
            // The whole block, not just the part being redrawn.
            var full = NSRange()
            _ = storage.attribute(.paloBlock, at: range.location, longestEffectiveRange: &full, in: all)
            guard seen.insert(full.location).inserted else { return }
            var rect = CGRect.null
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: full, actualCharacterRange: nil)) { frag, _, _, _, _ in
                rect = rect.union(frag)
            }
            guard !rect.isNull else { return }
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            ctx.saveGState()
            defer { ctx.restoreGState() }
            switch kind {
            case "code", "table":
                let box = CGRect(x: origin.x, y: rect.minY - 6, width: container.size.width, height: rect.height + 12)
                UIColor.secondaryLabel.withAlphaComponent(0.1).setFill()
                UIBezierPath(roundedRect: box, cornerRadius: 10).fill()
            case "quote":
                UIColor.secondaryLabel.withAlphaComponent(0.4).setFill()
                UIBezierPath(roundedRect: CGRect(x: origin.x, y: rect.minY, width: 3, height: rect.height), cornerRadius: 1.5).fill()
            case "rule":
                UIColor.separator.setFill()
                UIRectFill(CGRect(x: origin.x, y: rect.midY, width: container.size.width, height: 1 / max(UITraitCollection.current.displayScale, 1)))
            default:
                break
            }
        }
    }
}

// MARK: - Markdown → NSAttributedString

enum MarkdownRenderer {
    private enum Block {
        case heading(Int, String)
        case paragraph(String)
        case item(level: Int, marker: String, String)
        case quote([String])
        case code([String])
        case table([[String]])
        case rule
    }

    static func render(_ source: String) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let size = body.pointSize
        let out = NSMutableAttributedString()
        let blocks = parse(source)
        for (i, block) in blocks.enumerated() {
            let last = i == blocks.count - 1
            let piece: NSAttributedString
            switch block {
            case let .heading(level, text):
                let scale: CGFloat = [1.3, 1.15, 1.05][min(level, 3) - 1]
                let weight: UIFont.Weight = level <= 2 ? .bold : .semibold
                let style = paragraph(size: size, before: level <= 2 ? 8 : 6, after: level <= 2 ? 4 : 2)
                piece = inline(text, font: .systemFont(ofSize: size * scale, weight: weight), style: style)
            case let .paragraph(text):
                piece = inline(text, font: body, style: paragraph(size: size, after: 8))
            case let .item(level, marker, text):
                let indent = CGFloat(level) * 18 + (marker.count > 2 ? 26 : 18)
                let style = paragraph(size: size, after: 4)
                style.headIndent = indent
                style.firstLineHeadIndent = CGFloat(level) * 18
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                let line = NSMutableAttributedString(string: marker + "\t", attributes: [.font: body, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: style])
                line.append(inline(text, font: body, style: style))
                piece = line
            case let .quote(lines):
                let style = paragraph(size: size, after: 8)
                style.headIndent = 13
                style.firstLineHeadIndent = 13
                let q = NSMutableAttributedString(attributedString: inline(lines.joined(separator: "\u{2028}"), font: body, style: style, color: .secondaryLabel))
                q.addAttribute(.paloBlock, value: "quote", range: NSRange(location: 0, length: q.length))
                piece = q
            case let .code(lines):
                let mono = UIFont.monospacedSystemFont(ofSize: size * 0.85, weight: .regular)
                let style = paragraph(size: size * 0.85, before: 10, after: 16)
                style.headIndent = 10
                style.firstLineHeadIndent = 10
                style.tailIndent = -10
                style.lineBreakMode = .byCharWrapping
                let c = NSMutableAttributedString(string: lines.joined(separator: "\u{2028}"), attributes: [.font: mono, .foregroundColor: UIColor.label, .paragraphStyle: style])
                c.addAttribute(.paloBlock, value: "code", range: NSRange(location: 0, length: c.length))
                piece = c
            case let .table(rows):
                piece = table(rows, body: body)
            case .rule:
                let style = paragraph(size: size, before: 4, after: 8)
                piece = NSAttributedString(string: "\u{00A0}", attributes: [.font: body, .paragraphStyle: style, .paloBlock: "rule"])
            }
            out.append(piece)
            if !last { out.append(NSAttributedString(string: "\n", attributes: [.font: body])) }
        }
        return out
    }

    private static func paragraph(size: CGFloat, before: CGFloat = 0, after: CGFloat = 0) -> NSMutableParagraphStyle {
        let s = NSMutableParagraphStyle()
        s.lineSpacing = size * 0.2
        s.paragraphSpacingBefore = before
        s.paragraphSpacing = after
        return s
    }

    /// Inline markdown (bold, italic, `code`, ~~strike~~, links) via Foundation.
    private static func inline(_ text: String, font: UIFont, style: NSParagraphStyle, color: UIColor = .label) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            let intent = run.inlinePresentationIntent ?? []
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if !traits.isEmpty, let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) {
                attrs[.font] = UIFont(descriptor: d, size: font.pointSize)
            }
            if intent.contains(.code) {
                attrs[.font] = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                attrs[.backgroundColor] = UIColor.secondaryLabel.withAlphaComponent(0.12)
            }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }

    /// Tables: cells separated by tabs, column stops sized to the widest cell
    /// (capped, so a long cell wraps instead of pushing the rest away).
    private static func table(_ rows: [[String]], body: UIFont) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: body.pointSize * 0.9)
        let bold = UIFont.systemFont(ofSize: body.pointSize * 0.9, weight: .semibold)
        let columns = rows.map(\.count).max() ?? 0
        var widths = Array(repeating: CGFloat(0), count: columns)
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() {
                let w = NSAttributedString(string: plain(cell), attributes: [.font: r == 0 ? bold : font]).size().width
                widths[c] = min(max(widths[c], w + 16), 180)
            }
        }
        var stops: [NSTextTab] = []
        var x: CGFloat = 10
        for w in widths.dropLast() { x += w; stops.append(NSTextTab(textAlignment: .left, location: x)) }
        let out = NSMutableAttributedString()
        for (r, row) in rows.enumerated() {
            let style = paragraph(size: font.pointSize, before: r == 0 ? 10 : 0, after: r == rows.count - 1 ? 16 : 4)
            style.firstLineHeadIndent = 10
            style.headIndent = 10
            style.tabStops = stops
            for (c, cell) in row.enumerated() {
                if c > 0 { out.append(NSAttributedString(string: "\t", attributes: [.font: font, .paragraphStyle: style])) }
                out.append(inline(cell, font: r == 0 ? bold : font, style: style))
            }
            if r < rows.count - 1 { out.append(NSAttributedString(string: "\u{2028}", attributes: [.font: font, .paragraphStyle: style])) }
        }
        out.addAttribute(.paloBlock, value: "table", range: NSRange(location: 0, length: out.length))
        return out
    }

    private static func plain(_ s: String) -> String {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? s
    }

    // MARK: parsing (line-based, GitHub-flavored enough for chat)

    private static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var quote: [String] = []
        var table: [[String]] = []
        var code: [String]? = nil

        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\u{2028}"))); para = [] }
            if !quote.isEmpty { blocks.append(.quote(quote)); quote = [] }
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }

        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var c = code {
                if line.hasPrefix("```") { blocks.append(.code(c)); code = nil } else { c.append(raw); code = c }
                continue
            }
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("|") {
                if table.isEmpty { flush() }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|:--:| separator row carries no text.
                if !cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { table.append(cells) }
                continue
            }
            if !table.isEmpty { flush() }
            if line == "---" || line == "***" || line == "___" { flush(); blocks.append(.rule); continue }
            if let h = heading(line) { flush(); blocks.append(.heading(h.0, h.1)); continue }
            let level = min(leadingSpaces(raw) / 2, 4)
            if let b = bullet(line) { flush(); blocks.append(.item(level: level, marker: b.0, b.1)); continue }
            if let n = numbered(line) { flush(); blocks.append(.item(level: level, marker: "\(n.0).", n.1)); continue }
            if line.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
            }
            if !quote.isEmpty { flush() }
            para.append(line)
        }
        if let c = code { blocks.append(.code(c)) } // still streaming a code block
        flush()
        return blocks
    }

    private static func leadingSpaces(_ s: String) -> Int {
        s.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func bullet(_ line: String) -> (String, String)? {
        for p in ["- ", "* ", "+ ", "• "] where line.hasPrefix(p) {
            let rest = String(line.dropFirst(p.count))
            if rest.hasPrefix("[ ] ") { return ("☐", String(rest.dropFirst(4))) }
            if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { return ("☑︎", String(rest.dropFirst(4))) }
            return ("•", rest)
        }
        return nil
    }

    private static func numbered(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let n = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (n, String(rest.dropFirst(2)))
    }
}
