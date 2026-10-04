@preconcurrency import MarkdownUI
import SwiftUI

/// Chat and library markdown, rendered by MarkdownUI (GitHub-flavored:
/// headings, nested lists, tables, code blocks, quotes, task lists, links).
/// Sized for chat bubbles; tables and code scroll sideways instead of wrapping.
struct MarkdownText: View {
    let source: String
    var streaming: Bool = false
    var compact: Bool = true

    var body: some View {
        Markdown(streaming ? source + " ▍" : source)
            .markdownTheme(compact ? .paloAlly : .paloAllyDocument)
            .markdownCodeSyntaxHighlighter(.plainText)
            .textSelection(.enabled)
    }
}

extension Theme {
    /// Chat: body-sized text, modest headings.
    @MainActor static var paloAlly: Theme { Theme.gitHub
        .text { FontSize(.em(1.0)); BackgroundColor(nil) }
        .heading1 { configuration in
            configuration.label.markdownMargin(top: 8, bottom: 4).markdownTextStyle { FontWeight(.bold); FontSize(.em(1.3)) }
        }
        .heading2 { configuration in
            configuration.label.markdownMargin(top: 8, bottom: 4).markdownTextStyle { FontWeight(.bold); FontSize(.em(1.15)) }
        }
        .heading3 { configuration in
            configuration.label.markdownMargin(top: 6, bottom: 2).markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.05)) }
        }
        .paragraph { configuration in
            configuration.label.relativeLineSpacing(.em(0.2)).markdownMargin(top: 0, bottom: 8)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle { FontFamilyVariant(.monospaced); FontSize(.em(0.85)) }
                    .padding(10)
            }
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .markdownMargin(top: 0, bottom: 8)
        }
        .table { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: .secondary.opacity(0.3)))
                    .markdownTableBackgroundStyle(.alternatingRows(Color.clear, Color.secondary.opacity(0.06)))
            }
            .markdownMargin(top: 0, bottom: 8)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.5)).frame(width: 3)
                configuration.label.markdownTextStyle { ForegroundColor(.secondary) }.padding(.leading, 10)
            }
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: 0, bottom: 8)
        }
    }

    /// Library documents: a little roomier.
    @MainActor static var paloAllyDocument: Theme { Theme.gitHub
        .text { BackgroundColor(nil) }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label.markdownTextStyle { FontFamilyVariant(.monospaced); FontSize(.em(0.85)) }.padding(12)
            }
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .markdownMargin(top: 0, bottom: 12)
        }
        .table { configuration in
            ScrollView(.horizontal, showsIndicators: false) { configuration.label }
                .markdownMargin(top: 0, bottom: 12)
        }
    }
}

enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case bullet([String])
    case numbered([(Int, String)])
    case quote(String)
    case code(String)
    case rule

    static func == (a: MarkdownBlock, b: MarkdownBlock) -> Bool {
        switch (a, b) {
        case let (.heading(l1, t1), .heading(l2, t2)): l1 == l2 && t1 == t2
        case let (.paragraph(x), .paragraph(y)), let (.quote(x), .quote(y)), let (.code(x), .code(y)): x == y
        case let (.bullet(x), .bullet(y)): x == y
        case let (.numbered(x), .numbered(y)): x.map(\.0) == y.map(\.0) && x.map(\.1) == y.map(\.1)
        case (.rule, .rule): true
        default: false
        }
    }

    static func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var para: [String] = []
        var bullets: [String] = []
        var numbers: [(Int, String)] = []
        var quote: [String] = []
        var code: [String]? = nil

        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] }
            if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if var c = code {
                if line.hasPrefix("```") { blocks.append(.code(c.joined(separator: "\n"))); code = nil } else { c.append(rawLine); code = c }
                continue
            }
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }
            if line == "---" || line == "***" || line == "___" { flush(); blocks.append(.rule); continue }
            if let h = heading(line) { flush(); blocks.append(.heading(h.0, h.1)); continue }
            if let b = bullet(line) {
                if bullets.isEmpty { flush() }
                bullets.append(b); continue
            }
            if let n = numbered(line) {
                if numbers.isEmpty { flush() }
                numbers.append(n); continue
            }
            if line.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
            }
            if !bullets.isEmpty || !numbers.isEmpty || !quote.isEmpty { flush() }
            para.append(line)
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func bullet(_ line: String) -> String? {
        for p in ["- ", "* ", "+ ", "• "] where line.hasPrefix(p) {
            var rest = String(line.dropFirst(p.count))
            if rest.hasPrefix("[ ] ") { rest = "☐ " + rest.dropFirst(4) }
            if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { rest = "☑︎ " + rest.dropFirst(4) }
            return rest
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

#Preview {
    ScrollView {
        MarkdownText(source: """
        # 今日晨报
        早上好，**今天**有 3 件事：
        1. 周四的会
        2. 报销单
        - 记得 `带伞`
        > 今天也辛苦啦
        ```
        let x = 1
        ```
        """, streaming: true)
        .padding()
    }
}
