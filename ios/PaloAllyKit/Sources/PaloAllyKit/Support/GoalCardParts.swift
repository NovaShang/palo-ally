import Foundation

/// What a scheduled run's card shows, in order: its top-level items (each with
/// 聊聊), and everything else (paragraphs, headings, tables, code, numbered
/// lists) as Markdown.
public enum GoalCardPart: Hashable, Sendable {
    /// One item's own line, and what is nested under it (Markdown; empty for none).
    case item(String, under: String)
    case markdown(String)

    public static func split(_ text: String) -> [GoalCardPart] {
        var parts: [GoalCardPart] = []
        var plain: [String] = []
        var item: (line: String, under: [String])?
        var fence: String?

        func flush() {
            let md = plain.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !md.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(.markdown(md)) }
            plain = []
        }
        func close() {
            guard let i = item else { return }
            parts.append(.item(i.line, under: dedented(i.under)))
            item = nil
        }
        func put(_ raw: String) {
            if item != nil { item?.under.append(raw) } else { plain.append(raw) }
        }

        for sub in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(sub)
            let s = raw.trimmingCharacters(in: .whitespaces)
            let indented = raw.first == " " || raw.first == "\t"
            if let f = fence {
                put(raw)
                if s.hasPrefix(f) { fence = nil }
                continue
            }
            // Text that isn't under the item ends it.
            if item != nil, !s.isEmpty, !indented { close() }
            if s.hasPrefix("```") || s.hasPrefix("~~~") {
                fence = String(s.prefix(3))
                put(raw)
            } else if !indented, let words = bullet(s) {
                flush()
                close()
                item = (words, [])
            } else {
                put(raw)
            }
        }
        close()
        flush()
        return parts
    }

    private static func bullet(_ s: String) -> String? {
        // (a rule is `* * *` or `- - -`)
        if s.filter({ !$0.isWhitespace }).allSatisfy({ $0 == "-" || $0 == "*" }) { return nil }
        for marker in ["- ", "* ", "+ ", "• ", "· "] where s.hasPrefix(marker) {
            let words = s.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return words.isEmpty ? nil : words
        }
        return nil
    }

    /// Nested lines without the indent they share.
    private static func dedented(_ lines: [String]) -> String {
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " || $0 == "\t" }.count))) }
            .joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}
