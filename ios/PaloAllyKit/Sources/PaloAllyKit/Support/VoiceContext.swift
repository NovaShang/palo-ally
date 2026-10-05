import Foundation

/// The background text voice input sends to Qwen as its context-biasing
/// corpus, so names and terms from the conversation come out right (bento
/// fed its recent on-screen text the same way). Built when a recording
/// starts, from what the owner can see: a quoted reply, the assistant's name,
/// goal and 成果 titles, and the recent conversation as plain prose (newest
/// wins). Terms from older messages are kept as a compact list. Kept SMALL:
/// a large or generic corpus makes Qwen echo it instead of listening.
public enum VoiceContext {
    public static let defaultMaxChars = 1200
    /// How many recent messages are read at all.
    static let messageWindow = 12
    /// A long message contributes its opening as prose and its terms after that.
    static let perMessageChars = 240
    static let maxTitles = 8
    static let maxTerms = 40

    public static func build(messages: [ChatMessage],
                             assistantName: String = "",
                             goalTitles: [String] = [],
                             artifactTitles: [String] = [],
                             quote: String? = nil,
                             maxChars: Int = defaultMaxChars) -> String {
        var lines: [String] = []
        var used = 0
        func fits(_ s: String) -> Bool { used + s.count + 1 <= maxChars }
        func add(_ s: String) {
            guard !s.isEmpty, fits(s) else { return }
            lines.append(s)
            used += s.count + 1
        }

        // 1. What the owner is replying to: the most relevant text there is.
        if let quote, !quote.isEmpty { add(String(plainText(quote).prefix(200))) }

        // 2. Names and titles: short, high-value proper nouns.
        var seen = Set<String>()
        var titles: [String] = []
        for t in [assistantName] + goalTitles.prefix(maxTitles) + artifactTitles.prefix(maxTitles) {
            let clean = plainText(t)
            if !clean.isEmpty, seen.insert(clean.lowercased()).inserted { titles.append(clean) }
        }
        add(titles.joined(separator: "、"))

        // 3. The recent conversation, newest first until the budget is spent;
        //    whatever doesn't fit as prose still lends its terms.
        let recent = messages.suffix(messageWindow).reversed().compactMap { m -> String? in
            guard m.role == .user || m.role == .assistant else { return nil }
            switch m.kind {
            case .text, .question, .task, .clipboard: break
            default: return nil
            }
            let text = plainText(m.text)
            return text.isEmpty ? nil : text
        }
        // Leave room for a line of terms.
        let termReserve = min(160, maxChars / 6)
        var prose: [String] = []
        var spill: [String] = []
        for text in recent {
            let head = text.count > perMessageChars ? String(text.prefix(perMessageChars)) : text
            if used + head.count + 1 <= maxChars - termReserve {
                prose.append(head)
                used += head.count + 1
                if text.count > perMessageChars { spill.append(String(text.dropFirst(perMessageChars))) }
            } else {
                spill.append(text)
            }
        }

        var termList: [String] = []
        let proseLower = prose.joined(separator: " ").lowercased()
        for chunk in spill {
            for term in terms(in: chunk) where termList.count < maxTerms {
                let key = term.lowercased()
                guard !proseLower.contains(key), seen.insert(key).inserted else { continue }
                termList.append(term)
            }
        }
        var termLine = ""
        for term in termList {
            let next = termLine.isEmpty ? term : termLine + " " + term
            if used + next.count + 1 > maxChars { break }
            termLine = next
        }
        if !termLine.isEmpty { lines.append(termLine); used += termLine.count + 1 }

        // Oldest → newest, the way the conversation reads.
        lines.append(contentsOf: prose.reversed())
        return lines.joined(separator: "\n")
    }

    // MARK: - Text cleanup

    /// Markdown → one line of plain prose: no code blocks, tables, images,
    /// URLs, emphasis markers or list bullets; link text stays.
    public static func plainText(_ markdown: String) -> String {
        var s = markdown
        s = replace(#"```[\s\S]*?```"#, in: s, with: " ")
        s = replace(#"```[\s\S]*$"#, in: s, with: " ")           // an unclosed fence (still streaming)
        s = replace(#"!\[[^\]]*\]\([^)]*\)"#, in: s, with: " ")  // images
        s = replace(#"\[([^\]]+)\]\([^)]*\)"#, in: s, with: "$1") // links keep their text
        s = replace(#"<[^>\n]+>"#, in: s, with: " ")              // html tags, autolinks
        s = replace(#"(?i)\b(?:https?://|www\.)\S+"#, in: s, with: " ")
        var kept: [String] = []
        for raw in s.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") { continue }                   // table rows and separators
            line = replace(#"^(?:#{1,6}\s+|>\s*|[-*+•]\s+|\d+[.)]\s+)"#, in: line, with: "")
            if !line.isEmpty { kept.append(line) }
        }
        s = kept.joined(separator: " ")
        s = replace(#"\*\*|__|~~|`"#, in: s, with: "")
        s = replace(#"\s+"#, in: s, with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Words worth biasing toward: names in 「」《》“” quotes, Latin words
    /// and identifiers, numbers with their units, mixed-script tokens.
    static func terms(in text: String) -> [String] {
        var out: [String] = []
        for m in matches(#"[「《“"]([^」》”"]{1,20})[」》”"]"#, in: text, group: 1) { out.append(m) }
        for m in matches(#"[A-Za-z0-9一-鿿]*[A-Za-z][A-Za-z0-9._+#/-]*[A-Za-z0-9+#][A-Za-z0-9一-鿿]*"#, in: text) {
            if m.count >= 2 { out.append(m) }
        }
        for m in matches(#"[¥$€£]?\d[\d,.:]*\s?(?:%|[A-Za-z]{1,4}|[元块号点月日年岁个件页天周])?"#, in: text) {
            let t = m.trimmingCharacters(in: .whitespaces)
            if t.count >= 2 { out.append(t) }
        }
        return out
    }

    private static func replace(_ pattern: String, in s: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private static func matches(_ pattern: String, in s: String, group: Int = 0) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: group), in: s).map { String(s[$0]) }
        }
    }
}
