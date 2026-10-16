import Foundation

/// Finds file paths in a reply's text, so the ones that are real files can
/// become links (docs/files-prd.md, entry 2).
///
/// Ported from Bento Term's `PathDetector` (BentoFilePreviewKit): the same
/// patterns, priorities and token cleanup. Bento hit-tests one tapped
/// terminal cell; a reply is laid out text, so here every candidate in the
/// text is listed at once and the computer decides which are real files
/// (`files.resolve`). Nothing found here is shown as a link until it resolves.
public enum PathDetector {

    /// One recognized path token.
    public struct Candidate: Equatable, Sendable {
        /// The path itself: quotes stripped, trailing punctuation and any
        /// `:line[:col]` suffix removed, `\ ` unescaped.
        public let path: String
        /// `:12` / `:12:3` suffix if present (compiler-style references).
        public let line: Int?
        public let column: Int?
        /// True for tokens that are unambiguously path-shaped (`/…`, `~/…`,
        /// `./…`, `../…`, or quoted with a slash). False for bare relatives
        /// like `src/main.rs` and bare names like `README.md`.
        public let explicit: Bool
        /// The visible token in the text (trailing junk trimmed, `:line`
        /// suffix kept), UTF-16 based for attributed strings.
        public let range: NSRange
    }

    /// CJK / fullwidth punctuation that ends a path token ("…sample.txt、notes.md）。").
    /// CJK ideographs stay legal: `docs/渠道/说明文档.md` is a real path.
    private static let cjkPunct =
        #"\x{3000}-\x{303F}"# +
        #"\x{FF01}-\x{FF0F}\x{FF1A}-\x{FF20}\x{FF3B}-\x{FF40}\x{FF5B}-\x{FF65}"# +
        #"\x{2018}-\x{201D}\x{2026}\x{00B7}"#

    /// Pattern priority: when matches overlap, the lowest wins.
    private static let patterns: [(explicit: Bool, regex: NSRegularExpression)] = {
        func re(_ p: String) -> NSRegularExpression {
            guard let regex = try? NSRegularExpression(pattern: p) else {
                fatalError("PathDetector: invalid hardcoded pattern: \(p)")
            }
            return regex
        }
        return [
            // "quoted path with spaces": the inner part must contain a slash.
            (true, re(#""([^"\n]{1,512})""#)),
            (true, re(#"'([^'\n]{1,512})'"#)),
            // Absolute / home / dot-relative: `/…`, `~/…`, `./…`, `../…`. The
            // lookbehind rejects mid-token starts and URL slashes ("https://x").
            (true, re(#"(?<![\w:/.~-])(?:~|\.{1,2})?/(?:\\ |[^\s"'`"# + cjkPunct + #"])+"#)),
            // Bare relative with at least one slash, optionally `:line[:col]`: src/main.rs:42:7.
            (false, re(#"(?<![\w./~@:-])\.?[\w+@-][\w.+@-]*(?:/[\w.+@#%-]+)+/?(?::\d{1,6}(?::\d{1,6})?)?"#)),
            // Bare filename with an extension that has a letter: README.md, foo.tar.gz (not 1.2.3).
            (false, re(#"(?<![\w./~@:-])[\w+@-][\w.+@-]*\.[A-Za-z][A-Za-z0-9]{0,7}(?::\d{1,6}(?::\d{1,6})?)?(?![\w./~-])"#)),
            // Dotfile without a slash: .gitignore, .env.local.
            (false, re(#"(?<![\w./~@:-])\.[A-Za-z][\w.+-]{0,60}(?::\d{1,6}(?::\d{1,6})?)?(?![\w./~-])"#)),
        ]
    }()

    /// Every candidate in `text`, in order, none overlapping (where two
    /// patterns cover the same text, the higher-priority one wins).
    public static func candidates(in text: String) -> [Candidate] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [(priority: Int, explicit: Bool, range: NSRange, token: NSRange)] = []
        for (i, entry) in patterns.enumerated() {
            entry.regex.enumerateMatches(in: text, range: full) { m, _, _ in
                guard let m else { return }
                var token = m.range
                if m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound {
                    // Quoted: the payload is the inner group, and only with a slash.
                    guard ns.substring(with: m.range(at: 1)).contains("/") else { return }
                    token = m.range(at: 1)
                }
                found.append((i, entry.explicit, m.range, token))
            }
        }
        found.sort { ($0.priority, $0.range.location) < ($1.priority, $1.range.location) }
        var taken: [NSRange] = []
        var out: [Candidate] = []
        for f in found {
            guard !taken.contains(where: { NSIntersectionRange($0, f.range).length > 0 }) else { continue }
            guard let c = clean(ns, token: f.token, explicit: f.explicit) else { continue }
            // A slash right after an ellipsis: a cut-off path ("…/App/File.swift"), relative.
            var cand = c
            if f.explicit, cand.path.hasPrefix("/"), f.token.location > 0 {
                let before = ns.substring(with: NSRange(location: f.token.location - 1, length: 1))
                if before == "…" || before == "⋯" {
                    let suffix = String(cand.path.dropFirst())
                    guard suffix.count > 1 else { continue }
                    cand = Candidate(path: suffix, line: c.line, column: c.column, explicit: false, range: c.range)
                }
            }
            taken.append(f.range)
            out.append(cand)
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// A raw token after cleanup: junk-trimmed, `:line[:col]` split off.
    struct CleanedToken: Equatable {
        let path: String
        let line: Int?
        let column: Int?
        /// How many characters of the raw token stay visible.
        let keptCount: Int
    }

    /// Trim trailing junk, split off a `:line[:col]` suffix, unescape.
    static func cleanToken(_ raw: String) -> CleanedToken? {
        var token = raw
        // Prose and markup after a path, ASCII and CJK ("见 x.md。"). Closers
        // only come off while unbalanced against the token body.
        let junk = ".,;:!?'\"、。，；：！？…·’”"
        let closers: [Character: Character] = [
            ")": "(", "]": "[", "}": "{", ">": "<",
            "）": "（", "】": "【", "》": "《", "」": "「",
        ]
        while let last = token.last {
            if junk.contains(last) {
                token.removeLast()
            } else if let opener = closers[last],
                      token.filter({ $0 == opener }).count < token.filter({ $0 == last }).count {
                token.removeLast()
            } else {
                break
            }
        }
        let keptCount = token.count
        var lineNo: Int?
        var colNo: Int?
        var path = token
        if let m = token.range(of: #":(\d{1,6})(:(\d{1,6}))?$"#, options: .regularExpression) {
            let suffix = token[m].dropFirst().split(separator: ":")
            lineNo = suffix.first.flatMap { Int($0) }
            colNo = suffix.count > 1 ? Int(suffix[1]) : nil
            path = String(token[..<m.lowerBound])
        }
        path = path.replacingOccurrences(of: "\\ ", with: " ")
        // A lone "/" or "~" or "." isn't a useful target.
        guard path.count > 1, path != "~/", path != "./", path != "../" else { return nil }
        return CleanedToken(path: path, line: lineNo, column: colNo, keptCount: keptCount)
    }

    private static func clean(_ ns: NSString, token: NSRange, explicit: Bool) -> Candidate? {
        let raw = ns.substring(with: token)
        guard let ct = cleanToken(raw) else { return nil }
        let kept = (String(raw.prefix(ct.keptCount)) as NSString).length
        guard kept > 0 else { return nil }
        return Candidate(path: ct.path, line: ct.line, column: ct.column, explicit: explicit,
                         range: NSRange(location: token.location, length: kept))
    }
}
