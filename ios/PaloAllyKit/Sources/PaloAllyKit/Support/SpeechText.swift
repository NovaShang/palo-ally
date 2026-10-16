import Foundation
import NaturalLanguage

/// What a reply sounds like read aloud (朗读): its Markdown reduced to the
/// words, and the language those words are in.
public enum SpeechText {
    /// The spoken language of a text.
    public enum Language: Equatable, Sendable {
        case chinese, english
        /// Anything else the recognizer is sure of, by BCP 47 prefix (ja, fr…).
        case other(String)
    }

    public static func language(of text: String) -> Language {
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let top = r.dominantLanguage else { return .english }
        switch top {
        case .simplifiedChinese, .traditionalChinese: return .chinese
        case .english: return .english
        default: return .other(top.rawValue)
        }
    }

    /// Plain words from Markdown: headings and list marks dropped, emphasis
    /// and inline code unwrapped, links read as their text, images as their
    /// description, bare addresses skipped, tables as comma-separated cells,
    /// and each code block replaced by `codeOmitted`.
    public static func plain(_ markdown: String, codeOmitted: String) -> String {
        var out: [String] = []
        var fence: Character?
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let t = line.trimmingCharacters(in: .whitespaces)
            if let f = fence {
                if t.hasPrefix(String(repeating: f, count: 3)) { fence = nil }
                continue
            }
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                fence = t.first
                out.append(codeOmitted)
                continue
            }
            // Rules and table separators say nothing.
            if t.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil { continue }
            if t.range(of: #"^\|?[\s:|-]+\|?$"#, options: .regularExpression) != nil, t.contains("-"), t.contains("|") { continue }
            var s = t
            s = s.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: #"^(>\s?)+"#, with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: #"^[-*+•]\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
            if s.hasPrefix("|") || s.hasSuffix("|") {
                s = s.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
            }
            out.append(inline(s))
        }
        // Blank runs collapse to one.
        var lines: [String] = []
        for l in out {
            if l.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(l)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inline(_ line: String) -> String {
        var s = line
        s = s.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>\s]+>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*\*|__|~~)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`+"#, with: "", options: .regularExpression)
        // Single emphasis marks around words; a lone * or _ inside one stays.
        s = s.replacingOccurrences(of: #"(^|\s)[*_](\S[^*_]*?)[*_](?=\s|$|[.,;:!?，。；：！？])"#, with: "$1$2", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}
