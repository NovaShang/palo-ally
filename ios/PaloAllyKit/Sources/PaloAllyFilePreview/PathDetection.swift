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

    /// Chinese, Japanese and Korean letters: word characters, so they may be
    /// in a path, but in a sentence they are often right against one with no
    /// space between ("文件在/Users/x/a.md里"): where the path ends against
    /// them is a guess (`guesses` reads it both ways).
    static let cjkLetters = #"\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}"#
    /// A word character that isn't one of those: what may not follow a bare name.
    private static let latinWord = #"[\w--["# + cjkLetters + #"]]"#

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
            // Right after Chinese ("在~/notes/a.md") only `~/`, `./` and `../`
            // start one: a lone slash there is a folder's ("设计/列表页.md").
            (true, re(#"(?:(?<![\w:/.~-])|(?<=["# + cjkLetters + #"])(?=~/|\.{1,2}/))(?:~|\.{1,2})?/(?:\\ |[^\s"'`"# + cjkPunct + #"])+"#)),
            // Bare relative with at least one slash, optionally `:line[:col]`: src/main.rs:42:7.
            (false, re(#"(?<![\w./~@:-])\.?[\w+@-][\w.+@-]*(?:/[\w.+@#%-]+)+/?(?::\d{1,6}(?::\d{1,6})?)?"#)),
            // Bare filename with an extension that has a letter: README.md, foo.tar.gz (not 1.2.3).
            // Chinese right after one ends it ("README.md里").
            (false, re(#"(?<![\w./~@:-])[\w+@-][\w.+@-]*\.[A-Za-z][A-Za-z0-9]{0,7}(?::\d{1,6}(?::\d{1,6})?)?(?!"# + latinWord + #"|[./~-])"#)),
            // Dotfile without a slash: .gitignore, .env.local.
            (false, re(#"(?<![\w./~@:-])\.[A-Za-z][\w.+-]{0,60}(?::\d{1,6}(?::\d{1,6})?)?(?!"# + latinWord + #"|[./~-])"#)),
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

    private static func isExplicit(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~/") || path.hasPrefix("./") || path.hasPrefix("../")
    }

    // MARK: - Guesses: every way to read a stretch of a reply as a path

    /// One stretch of a reply that may name a file, read every way it can
    /// be, best first. The computer says which are files (`files.resolve`);
    /// the first reading that is one becomes the link, over its own range.
    public struct Guess: Equatable, Sendable {
        public let readings: [Candidate]
        /// All the readings' text.
        public var range: NSRange {
            readings.dropFirst().reduce(readings.first?.range ?? NSRange(location: 0, length: 0)) { NSUnionRange($0, $1.range) }
        }
        /// Each path once, in order: what to ask the computer about.
        public var paths: [String] {
            var seen = Set<String>()
            return readings.map(\.path).filter { seen.insert($0).inserted }
        }
    }

    /// The paths in a reply's laid-out text, with what the text knows besides
    /// its characters: its code spans (`` `…` ``, a path with spaces is
    /// whole there) and its links whose target is a path, not a web address
    /// (`[ListPage.tsx:12](src/pages/ListPage.tsx#L12)`, Claude Code's way
    /// of naming a file). A link's or a code span's whole text comes first,
    /// the paths found inside it after; a path written right against Chinese
    /// is read with and without the Chinese beside it.
    public static func guesses(in text: String, codeSpans: [NSRange] = [], links: [(range: NSRange, url: URL)] = []) -> [Guess] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var plain = candidates(in: text)
        var out: [Guess] = []
        var claimed: [NSRange] = []
        func inside(_ r: NSRange) -> [Candidate] {
            let hit = plain.filter { NSIntersectionRange($0.range, r).length > 0 }
            plain.removeAll { NSIntersectionRange($0.range, r).length > 0 }
            return hit.flatMap { variants(of: $0, in: ns) }
        }
        func add(_ first: Candidate, _ rest: [Candidate]) {
            let readings = [first] + rest.filter { $0 != first }
            out.append(Guess(readings: readings))
            claimed.append(Guess(readings: readings).range)
        }
        for link in links {
            let r = NSIntersectionRange(link.range, full)
            guard r.length > 0, !claimed.contains(where: { NSIntersectionRange($0, r).length > 0 }),
                  let target = linkedPath(link.url) else { continue }
            add(Candidate(path: target.path, line: target.line, column: nil, explicit: isExplicit(target.path), range: r), inside(r))
        }
        for span in codeSpans {
            let r = trimmed(NSIntersectionRange(span, full), in: ns)
            guard r.length > 1, !claimed.contains(where: { NSIntersectionRange($0, r).length > 0 }) else { continue }
            let raw = ns.substring(with: r)
            let found = inside(r)
            // A span that is a path as a whole: spaces allowed, one line, with
            // a slash or a name with an extension.
            if raw.count <= 1024, !raw.contains(where: \.isNewline), raw.contains("/") || raw.range(of: #"\.[A-Za-z][A-Za-z0-9]{0,7}(:\d+(:\d+)?)?$"#, options: .regularExpression) != nil,
               !raw.contains("://"), let ct = cleanToken(raw) {
                let kept = (String(raw.prefix(ct.keptCount)) as NSString).length
                let whole = Candidate(path: ct.path, line: ct.line, column: ct.column, explicit: isExplicit(ct.path),
                                      range: NSRange(location: r.location, length: kept))
                add(whole, found)
            } else {
                // Only what's inside, each on its own.
                let groups = regroup(found)
                out += groups
                claimed += groups.map(\.range)
            }
        }
        for c in plain { out.append(Guess(readings: variants(of: c, in: ns))) }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// Readings that overlap belong to one guess (a candidate and its variants).
    private static func regroup(_ readings: [Candidate]) -> [Guess] {
        var groups: [[Candidate]] = []
        for c in readings {
            if let i = groups.firstIndex(where: { g in g.contains { NSIntersectionRange($0.range, c.range).length > 0 } }) {
                groups[i].append(c)
            } else {
                groups.append([c])
            }
        }
        return groups.map { Guess(readings: $0) }
    }

    /// A candidate, then the same without the Chinese written against its
    /// end, its start, or both ("改了src/main.rs里" → "src/main.rs").
    static func variants(of c: Candidate, in ns: NSString) -> [Candidate] {
        let token = ns.substring(with: c.range) as NSString
        let lead = token.range(of: "^[" + cjkLetters + "]+", options: .regularExpression)
        let trail = token.range(of: "[" + cjkLetters + "]+$", options: .regularExpression)
        var out = [c]
        func add(drop front: Int, back: Int) {
            let length = token.length - front - back
            guard length > 1 else { return }
            let raw = token.substring(with: NSRange(location: front, length: length))
            guard let ct = cleanToken(raw) else { return }
            let kept = (String(raw.prefix(ct.keptCount)) as NSString).length
            let v = Candidate(path: ct.path, line: ct.line, column: ct.column, explicit: isExplicit(ct.path),
                              range: NSRange(location: c.range.location + front, length: kept))
            if !out.contains(where: { $0.path == v.path }) { out.append(v) }
        }
        let front = lead.location == NSNotFound ? 0 : lead.length
        let back = trail.location == NSNotFound || trail.length == token.length ? 0 : trail.length
        if back > 0 { add(drop: 0, back: back) }
        if front > 0 { add(drop: front, back: 0) }
        if front > 0, back > 0 { add(drop: front, back: back) }
        return out
    }

    private static func trimmed(_ r: NSRange, in ns: NSString) -> NSRange {
        var lo = r.location, hi = NSMaxRange(r)
        let space = CharacterSet.whitespacesAndNewlines
        func isSpace(_ i: Int) -> Bool { UnicodeScalar(ns.character(at: i)).map(space.contains) ?? false }
        while lo < hi, isSpace(lo) { lo += 1 }
        while hi > lo, isSpace(hi - 1) { hi -= 1 }
        return NSRange(location: lo, length: hi - lo)
    }

    /// The file a Markdown link points at, when it points at a path: no
    /// scheme (`src/a.ts`, `/Users/x/a.md`, `<My Docs/a.md>`) or `file:`,
    /// percent escapes undone, a `#L12` (or `#L12-L20`, `#L12C3`) or `:12`
    /// at the end taken as the line. Web addresses and `#section` links: nil.
    public static func linkedPath(_ url: URL) -> (path: String, line: Int?)? {
        let scheme = url.scheme?.lowercased()
        guard scheme == nil || scheme == "file" else { return nil }
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard c.host == nil || c.host == "" || c.host == "localhost" else { return nil }
        let path = c.percentEncodedPath.removingPercentEncoding ?? c.percentEncodedPath
        guard path.count > 1, !path.hasPrefix("//"), let ct = cleanToken(path) else { return nil }
        var line = ct.line
        if let fragment = c.fragment, let m = fragment.range(of: #"^L(\d{1,6})"#, options: .regularExpression) {
            line = Int(fragment[m].dropFirst())
        }
        return (ct.path, line)
    }
}
