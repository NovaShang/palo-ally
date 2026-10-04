import SwiftUI

/// Lightweight block-level markdown renderer. Inline styling (bold, italic,
/// code, links) comes from `AttributedString(markdown:)`; blocks (headings,
/// lists, quotes, code fences, rules) are laid out natively.
struct MarkdownText: View {
    let source: String
    var streaming: Bool = false

    var body: some View {
        let blocks = MarkdownBlock.parse(source)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isLast: index == blocks.count - 1)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, isLast: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text, cursor: isLast)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 4 : 0)
        case .paragraph(let text):
            inline(text, cursor: isLast)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(item, cursor: isLast && i == items.count - 1)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(item.0).").monospacedDigit().foregroundStyle(.secondary)
                        inline(item.1, cursor: isLast && i == items.count - 1)
                    }
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                Capsule().fill(.tint.opacity(0.5)).frame(width: 3)
                inline(text, cursor: isLast).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
            }
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String, cursor: Bool) -> Text {
        let t = Text(MarkdownBlock.attributed(text))
        if cursor && streaming {
            return Text("\(t)\(Text(" ▍").foregroundStyle(.tint))")
        }
        return t
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
