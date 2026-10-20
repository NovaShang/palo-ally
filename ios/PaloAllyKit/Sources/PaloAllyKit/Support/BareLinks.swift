import Foundation

/// Bare web addresses in Markdown, given an explicit end before a Markdown
/// parser sees them.
///
/// GitHub-flavored autolinks (MarkdownUI's cmark, and Foundation's
/// `AttributedString(markdown:)`) run a bare address on to the next space,
/// so in Chinese, where nothing separates it from the sentence,
/// `装：https://a.b/ota/，然后打开` linked `https://a.b/ota/，然后打开`.
/// An address is only ASCII (RFC 3986): the first character that isn't one
/// of its characters ends it, and so does sentence punctuation at its end
/// (a final `.` or `,`, a `)` that closes nothing). Each bare address is then
/// written as an autolink `<…>` (a `www.` one as `[…](<http://…>)`), which
/// every parser ends exactly there.
///
/// Addresses already in a link (`<…>`, `[…](…)`, the link's text), in a code
/// span or a fenced code block, or escaped, stay as they are.
public enum BareLinks {
    public static func marking(in markdown: String) -> String {
        guard markdown.contains("://") || markdown.range(of: "www.", options: .caseInsensitive) != nil else { return markdown }
        let s = Array(markdown.unicodeScalars)
        let n = s.count
        var out = String.UnicodeScalarView()
        out.reserveCapacity(n + 16)
        var i = 0
        var changed = false

        while i < n {
            let c = s[i]
            if i == 0 || s[i - 1] == "\n", let end = fencedBlockEnd(s, from: i) {
                out.append(contentsOf: s[i..<end]); i = end; continue
            }
            switch c {
            case "\\":
                let end = min(i + 2, n)
                out.append(contentsOf: s[i..<end]); i = end
            case "`":
                let run = runLength(s, at: i, of: "`")
                if let close = closingBackticks(s, from: i + run, count: run) {
                    out.append(contentsOf: s[i..<close]); i = close
                } else {
                    out.append(contentsOf: s[i..<i + run]); i += run
                }
            case "<":
                if let end = tagEnd(s, at: i) {
                    out.append(contentsOf: s[i..<end]); i = end
                } else {
                    out.append(c); i += 1
                }
            case "[":
                if let end = inlineLinkEnd(s, at: i) {
                    out.append(contentsOf: s[i..<end]); i = end
                } else {
                    out.append(c); i += 1
                }
            default:
                if let (end, web) = bareLink(s, at: i) {
                    let url = String(String.UnicodeScalarView(s[i..<end]))
                    if web {
                        out.append(contentsOf: "<\(url)>".unicodeScalars)
                    } else {
                        out.append(contentsOf: "[\(escaped(url))](<http://\(url)>)".unicodeScalars)
                    }
                    changed = true
                    i = end
                } else {
                    out.append(c); i += 1
                }
            }
        }
        return changed ? String(out) : markdown
    }

    // MARK: - The address

    private static let schemes = ["https://", "http://", "ftp://", "paloally://"]

    /// The end of a bare address starting at `i`, and whether it has a scheme
    /// (else it starts with `www.`).
    private static func bareLink(_ s: [Unicode.Scalar], at i: Int) -> (Int, Bool)? {
        let c = s[i]
        guard c == "h" || c == "H" || c == "f" || c == "F" || c == "p" || c == "P" || c == "w" || c == "W" else { return nil }
        // Not the middle of a word, a path or another address.
        if i > 0, isASCIIAlnum(s[i - 1]) || "/.@-".unicodeScalars.contains(s[i - 1]) { return nil }
        var start: Int?
        var web = true
        for scheme in schemes where hasPrefix(s, at: i, scheme) { start = i + scheme.unicodeScalars.count; break }
        if start == nil, hasPrefix(s, at: i, "www.") { start = i + 4; web = false }
        guard let hostStart = start else { return nil }
        var end = hostStart
        while end < s.count, isURLCharacter(s[end]) { end += 1 }
        end = trimmedEnd(s, from: i, to: end)
        // Something has to follow the scheme, beginning with the host.
        guard end > hostStart, isASCIIAlnum(s[hostStart]) || s[hostStart] == "[" else { return nil }
        return (end, web)
    }

    /// RFC 3986: unreserved, reserved, and `%` for percent-encoding. Nothing
    /// outside ASCII: CJK and full-width punctuation end an address.
    private static func isURLCharacter(_ c: Unicode.Scalar) -> Bool {
        isASCIIAlnum(c) || "-._~:/?#[]@!$&'()*+,;=%".unicodeScalars.contains(c)
    }

    /// Sentence punctuation at the end isn't the address's (GitHub's rules).
    private static func trimmedEnd(_ s: [Unicode.Scalar], from start: Int, to end: Int) -> Int {
        var end = end
        while end > start {
            let last = s[end - 1]
            if "?!.,:*_~'\"".unicodeScalars.contains(last) {
                end -= 1
            } else if last == ")" || last == "]" {
                let open: Unicode.Scalar = last == ")" ? "(" : "["
                let opens = s[start..<end].filter { $0 == open }.count
                let closes = s[start..<end].filter { $0 == last }.count
                guard closes > opens else { break }
                end -= 1
            } else if last == ";" {
                // An entity like `&amp;` at the end goes with it.
                var j = end - 2
                while j > start, isASCIIAlnum(s[j]) { j -= 1 }
                end = (j > start && s[j] == "&" && j < end - 2) ? j : end - 1
            } else {
                break
            }
        }
        return end
    }

    // MARK: - What to leave alone

    /// A fenced code block opening at line start `i` (``` or ~~~ after at
    /// most three spaces): where it ends, after its closing fence's line or at
    /// the end of the text.
    private static func fencedBlockEnd(_ s: [Unicode.Scalar], from i: Int) -> Int? {
        guard let (char, length) = fence(s, at: i) else { return nil }
        var line = lineEnd(s, from: i)
        while line < s.count {
            let next = line + 1
            if let (c, l) = fence(s, at: next), c == char, l >= length { return min(lineEnd(s, from: next) + 1, s.count) }
            line = lineEnd(s, from: next)
        }
        return s.count
    }

    private static func fence(_ s: [Unicode.Scalar], at i: Int) -> (Unicode.Scalar, Int)? {
        var j = i
        while j < s.count, j - i < 3, s[j] == " " { j += 1 }
        guard j < s.count, s[j] == "`" || s[j] == "~" else { return nil }
        let length = runLength(s, at: j, of: s[j])
        return length >= 3 ? (s[j], length) : nil
    }

    /// The index of the newline ending the line `i` is on (or the text's end).
    private static func lineEnd(_ s: [Unicode.Scalar], from i: Int) -> Int {
        var j = i
        while j < s.count, s[j] != "\n" { j += 1 }
        return j
    }

    /// After the run of exactly `count` backticks closing a code span.
    private static func closingBackticks(_ s: [Unicode.Scalar], from i: Int, count: Int) -> Int? {
        var j = i
        while j < s.count {
            if s[j] == "`" {
                let run = runLength(s, at: j, of: "`")
                if run == count { return j + run }
                j += run
            } else {
                j += 1
            }
        }
        return nil
    }

    /// After an autolink `<scheme:…>` or an HTML tag on one line.
    private static func tagEnd(_ s: [Unicode.Scalar], at i: Int) -> Int? {
        guard i + 1 < s.count, isASCIIAlnum(s[i + 1]) || "/!?".unicodeScalars.contains(s[i + 1]) else { return nil }
        var j = i + 1
        while j < s.count, s[j] != "\n", s[j] != "<" {
            if s[j] == ">" { return j + 1 }
            j += 1
        }
        return nil
    }

    /// After an inline link or image `[text](destination)`, its text and
    /// destination both left as written.
    private static func inlineLinkEnd(_ s: [Unicode.Scalar], at i: Int) -> Int? {
        guard let close = matching(s, from: i, open: "[", close: "]"),
              close + 1 < s.count, s[close + 1] == "(",
              let end = matching(s, from: close + 1, open: "(", close: ")") else { return nil }
        return end + 1
    }

    /// The index of the bracket closing the one at `i`, within the paragraph.
    private static func matching(_ s: [Unicode.Scalar], from i: Int, open: Unicode.Scalar, close: Unicode.Scalar) -> Int? {
        var depth = 0
        var j = i
        while j < s.count {
            let c = s[j]
            if c == "\\" { j += 2; continue }
            if c == "\n", j + 1 < s.count, s[j + 1] == "\n" { return nil }
            if c == open { depth += 1 }
            if c == close { depth -= 1; if depth == 0 { return j } }
            j += 1
        }
        return nil
    }

    // MARK: - Helpers

    private static func runLength(_ s: [Unicode.Scalar], at i: Int, of c: Unicode.Scalar) -> Int {
        var j = i
        while j < s.count, s[j] == c { j += 1 }
        return j - i
    }

    private static func hasPrefix(_ s: [Unicode.Scalar], at i: Int, _ prefix: String) -> Bool {
        var j = i
        for p in prefix.unicodeScalars {
            guard j < s.count else { return false }
            let c = s[j]
            let lower = c >= "A" && c <= "Z" ? Unicode.Scalar(c.value + 32)! : c
            guard lower == p else { return false }
            j += 1
        }
        return true
    }

    private static func isASCIIAlnum(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
    }

    /// A `www.` address as a link's text: its Markdown punctuation escaped.
    private static func escaped(_ url: String) -> String {
        var out = ""
        for c in url.unicodeScalars {
            if "\\`*_[]<>!".unicodeScalars.contains(c) { out.append("\\") }
            out.unicodeScalars.append(c)
        }
        return out
    }
}
