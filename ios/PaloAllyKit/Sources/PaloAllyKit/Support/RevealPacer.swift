import Foundation

/// Paces a reply's text onto the screen (design §3.2). What came off the
/// wire is `received`; what is on screen is `revealed`, a prefix of it. On
/// each tick (~70 ms) the revealed part grows to a cut point:
///
/// - between words (ICU's segmentation, so Chinese splits by dictionary into
///   words, not characters) or after a space or punctuation mark;
/// - never inside a character (an emoji sequence, a letter and its accent);
/// - never inside unfinished inline Markdown (`**…`, `` `…``, `[…](…)`,
///   `~~…`); a list marker, a heading's `#` or a quote's `>` comes with its
///   first word;
/// - table rows, and the lines of a code block and its fences, whole.
///
/// How much per tick follows the backlog: at least 30 characters a second,
/// and as fast as it takes for every piece to show within 0.4 s of arriving.
/// A burst (1000 characters at once after a reconnect) drains evenly over
/// those 0.4 s, by whole lines. Nothing waits past that: if the rules above
/// would hold a piece longer (a long bold run still open), the time limit
/// wins. The end of the text waits a moment for the rest of its word.
public struct RevealPacer: Sendable {
    public struct Timing: Sendable {
        /// Characters a second, at least.
        public var floorRate: Double = 30
        /// Every piece shows within this of arriving.
        public var horizon: TimeInterval = 0.4
        /// The end of what came waits this long for more of its word.
        public var settle: TimeInterval = 0.15
        /// From this pace on (characters a second), whole lines at a time.
        public var linePace: Double = 400
        public init() {}
    }

    public let timing: Timing
    public private(set) var received = ""
    /// Where the revealed part ends, in UTF-8 units of `received`.
    public private(set) var revealedLength = 0
    /// The longest any piece waited between arriving and being revealed.
    public private(set) var longestWait: TimeInterval = 0

    /// Received and not yet all revealed: where each piece ends, the
    /// characters received up to there, and when it came.
    private struct Piece: Sendable {
        var end: Int
        var chars: Int
        var at: TimeInterval
    }
    private var pieces: [Piece] = []
    private var receivedChars = 0
    private var revealedChars = 0
    private var lastArrival: TimeInterval = 0
    private var lastTick: TimeInterval?
    private var credit = 0.0
    /// The line the cut is on: where it starts, and whether a code block is
    /// open there.
    private var line = LineState(start: 0, inCode: false)

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    public var revealed: String { String(decoding: received.utf8.prefix(revealedLength), as: UTF8.self) }
    public var isCaughtUp: Bool { revealedLength >= received.utf8.count }
    /// Characters received and not yet revealed.
    public var backlog: Int { max(0, receivedChars - revealedChars) }

    // MARK: input

    public mutating func receive(_ more: String, at time: TimeInterval) {
        guard !more.isEmpty else { return }
        received += more
        receivedChars += more.count
        pieces.append(Piece(end: received.utf8.count, chars: receivedChars, at: time))
        lastArrival = time
    }

    /// The whole text so far, from elsewhere (a sync after a reconnect).
    /// Text that only grew goes on; text that changed under what is already
    /// shown is revealed again from the start of the line where it differs.
    public mutating func replace(with whole: String, at time: TimeInterval) {
        if whole.utf8.starts(with: received.utf8) {
            receive(String(decoding: whole.utf8.dropFirst(received.utf8.count), as: UTF8.self), at: time)
            return
        }
        var same = 0
        for (a, b) in zip(whole.utf8, received.utf8.prefix(revealedLength)) {
            guard a == b else { break }
            same += 1
        }
        if same < revealedLength {
            let prefix = whole.utf8.prefix(same)
            revealedLength = prefix.lastIndex(of: 10).map { prefix.distance(from: prefix.startIndex, to: $0) + 1 } ?? 0
            revealedChars = String(decoding: whole.utf8.prefix(revealedLength), as: UTF8.self).count
            line = LineState.at(revealedLength, in: whole)
        }
        received = whole
        receivedChars = revealedChars + String(decoding: whole.utf8.dropFirst(revealedLength), as: UTF8.self).count
        pieces = isCaughtUp ? [] : [Piece(end: whole.utf8.count, chars: receivedChars, at: time)]
        lastArrival = time
    }

    // MARK: output

    /// One tick: reveals what's due. True when `revealed` changed.
    public mutating func tick(at now: TimeInterval) -> Bool {
        let dt = min(max(now - (lastTick ?? (now - 0.07)), 0), 0.25)
        lastTick = now
        guard !isCaughtUp else { credit = 0; return false }
        // The pace: the floor, or what it takes for every piece to show by
        // its deadline, whichever is faster. A piece whose deadline comes
        // before the next tick must show now.
        var pace = timing.floorRate
        var due = revealedChars
        for p in pieces {
            let left = p.at + timing.horizon - now
            pace = max(pace, Double(p.chars - revealedChars) / max(left, dt, 0.001))
            if left < dt * 0.5 { due = max(due, p.chars) }
        }
        credit = min(credit + pace * dt, Double(backlog))
        let budget = revealedChars + Int(credit.rounded(.down))

        // Only as far as this tick may go, and a little past it.
        var scan = Scan(text: received, line: line, cut: revealedLength, revealedChars: revealedChars,
                        settled: now - lastArrival >= timing.settle, window: max(budget, due) - revealedChars + 48)
        var first: Cut?
        var best: Cut?
        var bestLine: Cut?
        var reachesDue: Cut?
        while let c = scan.next() {
            if first == nil { first = c }
            if c.chars <= budget {
                best = c
                if c.lineEnd { bestLine = c }
            }
            if reachesDue == nil, c.chars >= due { reachesDue = c }
            if c.chars > budget, reachesDue != nil { break }
        }
        // By whole lines when it's going fast; the first words of a reply
        // show at once, even if they may be half a word.
        var pick = (pace >= timing.linePace ? bestLine : nil) ?? best ?? (revealedLength == 0 ? first : nil)
        if pick == nil, revealedLength == 0 {
            var s = Scan(text: received, line: line, cut: 0, revealedChars: 0, settled: true)
            pick = s.next()
        }
        if due > revealedChars, (pick?.chars ?? 0) < due {
            // Overdue: the time limit beats the rules.
            pick = reachesDue ?? Scan.anyCut(in: received, from: revealedLength, line: line, revealedChars: revealedChars, atLeast: due)
        }
        guard let pick, pick.offset > revealedLength else { return false }
        advance(to: pick, now: now)
        return true
    }

    /// Everything now (the reply ended, the app is leaving the screen).
    @discardableResult
    public mutating func flush(at now: TimeInterval) -> Bool {
        guard !isCaughtUp else { return false }
        let end = received.utf8.count
        advance(to: Cut(offset: end, chars: receivedChars, lineEnd: false, line: LineState.at(end, in: received, from: line)), now: now)
        return true
    }

    private mutating func advance(to cut: Cut, now: TimeInterval) {
        credit = max(0, credit - Double(cut.chars - revealedChars))
        revealedLength = cut.offset
        revealedChars = cut.chars
        line = cut.line
        while let p = pieces.first, p.end <= revealedLength {
            longestWait = max(longestWait, now - p.at)
            pieces.removeFirst()
        }
        if isCaughtUp { credit = 0 }
    }
}

// MARK: - cut points

extension RevealPacer {
    struct LineState: Sendable, Equatable {
        /// UTF-8 offset where the line starts.
        var start: Int
        /// A code block is open at the start of the line.
        var inCode: Bool
        /// The cut on this line is a regular one, so no inline Markdown is
        /// open there: the next scan can start at the cut instead of at
        /// the start of the line.
        var clean = false

        /// The line `offset` is on, walking the text from `from` (a line
        /// state at or before it; the text's start by default).
        static func at(_ offset: Int, in text: String, from: LineState = LineState(start: 0, inCode: false)) -> LineState {
            var start = from.start
            var inCode = from.inCode
            let utf8 = text.utf8
            var i = utf8.index(utf8.startIndex, offsetBy: min(start, utf8.count))
            while let nl = utf8[i...].firstIndex(of: 10) {
                let end = utf8.distance(from: utf8.startIndex, to: nl)
                if offset <= end { break }
                if Scan.isFence(text[i..<nl]) { inCode.toggle() }
                start = end + 1
                i = utf8.index(after: nl)
            }
            return LineState(start: start, inCode: inCode)
        }
    }

    struct Cut: Sendable {
        /// UTF-8 offset in the text.
        var offset: Int
        /// Characters revealed up to here.
        var chars: Int
        /// Right after a line break.
        var lineEnd: Bool
        /// The line the cut is on.
        var line: LineState
    }

    /// Walks the text from the cut (or the start of its line) and hands
    /// out the legal cuts after the cut, in order, a line at a time, up to
    /// `window` characters past the cut.
    struct Scan {
        private let text: String
        private let cut: Int
        private let settled: Bool
        private var line: LineState
        private var chars: Int
        private let limit: Int
        private var firstLine = true
        private var done = false
        private var found: [Cut] = []
        private var index = 0

        init(text: String, line: LineState, cut: Int, revealedChars: Int, settled: Bool, window: Int = .max / 2) {
            self.text = text
            self.line = line
            self.cut = cut
            self.settled = settled
            chars = revealedChars
            limit = revealedChars + max(window, 1)
        }

        mutating func next() -> Cut? {
            while index >= found.count {
                guard !done, line.start < text.utf8.count else { return nil }
                found = scanLine()
                index = 0
            }
            defer { index += 1 }
            return found[index]
        }

        /// The cuts on the current line, then on to the next.
        private mutating func scanLine() -> [Cut] {
            let utf8 = text.utf8
            let lineStart = utf8.index(utf8.startIndex, offsetBy: line.start)
            let newline = utf8[lineStart...].firstIndex(of: 10)
            let head = text[lineStart..<(newline ?? utf8.endIndex)]
            let length = head.utf8.count
            let complete = newline != nil
            let fence = Self.isFence(head)
            let next = LineState(start: line.start + length + 1, inCode: fence != line.inCode, clean: true)
            let whole = line.inCode || fence || head.drop { $0 == " " || $0 == "\t" }.first == "|"
            // After a regular cut nothing is open: start there.
            let from = firstLine && line.clean && cut > line.start ? cut : line.start
            firstLine = false
            var out: [Cut] = []
            if !whole {
                let (cuts, truncated) = proseCuts(from: from, to: line.start + length, complete: complete)
                out = cuts
                // The window ends inside this line: nothing past it.
                if truncated { done = true; return out }
            }
            if complete {
                // After the line break: the whole line.
                out.append(Cut(offset: next.start, chars: chars + count(from: max(cut, line.start), to: line.start + length) + 1,
                               lineEnd: true, line: next))
            } else if whole, line.inCode, !fence, settled, length > 0, line.start + length > cut {
                // A line of code that's been waiting: as far as it goes.
                out.append(Cut(offset: line.start + length,
                               chars: chars + count(from: max(cut, line.start), to: line.start + length),
                               lineEnd: false, line: line))
            }
            if complete, let last = out.last { chars = last.chars }
            line = next
            if chars > limit { done = true }
            return out
        }

        private func count(from a: Int, to b: Int) -> Int {
            guard b > a else { return 0 }
            let utf8 = text.utf8
            return text[utf8.index(utf8.startIndex, offsetBy: a)..<utf8.index(utf8.startIndex, offsetBy: b)].count
        }

        /// Cuts in a line of prose between two offsets: word boundaries past
        /// the line's marker, outside unfinished inline Markdown. True as
        /// well when the window ended before the line did.
        private func proseCuts(from: Int, to: Int, complete: Bool) -> ([Cut], Bool) {
            let utf8 = text.utf8
            let a = utf8.index(utf8.startIndex, offsetBy: from)
            var body = text[a..<utf8.index(utf8.startIndex, offsetBy: to)]
            // Characters already revealed at the start of `body`, then the window.
            let room = (from < cut ? count(from: from, to: cut) : 0) + (limit - chars)
            let full = body.utf8.count
            body = body.prefix(room)
            let truncated = body.utf8.count < full
            let chs = Array(body)
            guard !chs.isEmpty else { return ([], truncated) }
            // The end of a finished line, or of text that stopped coming, is
            // followed by a space as far as Markdown is concerned.
            let ended = !truncated && (complete || settled)
            let marker = from == line.start ? Self.markerEnd(chs) : 0
            let open = Self.openAt(chs, before: from == line.start ? nil : text[..<a].last, ended: ended)
            let inside = Self.insideWords(body, chs)
            var offset = from
            var count = chars
            var out: [Cut] = []
            let clean = LineState(start: line.start, inCode: line.inCode, clean: true)
            for k in 1...chs.count {
                offset += chs[k - 1].utf8.count
                guard offset > cut else { continue }
                count += 1
                guard k > marker, !open[k], !inside[k] else { continue }
                if k == chs.count {
                    // Where the window ends, the word may go on.
                    if truncated { continue }
                    if !complete, !settled {
                        // The end of what came so far: it may be half a word.
                        let last = chs[k - 1]
                        guard last.isWhitespace || (last.isPunctuation && !"*_~`[\\".contains(last)) else { continue }
                    }
                }
                out.append(Cut(offset: offset, chars: count, lineEnd: false, line: clean))
            }
            return (out, truncated)
        }

        /// How many characters at the start of a line are its marker(s): `#`,
        /// `-`, `1.`, `>`, a task box, and the spaces after. All of them
        /// while the line is nothing but marker so far (or a rule, `---`).
        static func markerEnd(_ chs: [Character]) -> Int {
            if chs.allSatisfy({ "-*_ ".contains($0) }) { return chs.count }
            var i = 0
            func spaces() -> Int {
                let s = i
                while i < chs.count, chs[i] == " " || chs[i] == "\t" { i += 1 }
                return i - s
            }
            _ = spaces()
            while i < chs.count {
                let start = i
                if chs[i] == "#" {
                    while i < chs.count, chs[i] == "#" { i += 1 }
                } else if "-*+•>".contains(chs[i]) {
                    i += 1
                } else if chs[i].isASCII, chs[i].isNumber {
                    while i < chs.count, chs[i].isASCII, chs[i].isNumber { i += 1 }
                    if i < chs.count {
                        guard chs[i] == "." || chs[i] == ")" else { return start }
                        i += 1
                    }
                } else if chs[i] == "[", i + 2 < chs.count, " xX".contains(chs[i + 1]), chs[i + 2] == "]" {
                    i += 3
                } else {
                    return start
                }
                if i >= chs.count { return chs.count }
                // A marker is followed by a space ('>' needn't be).
                if spaces() == 0, chs[start] != ">" { return start }
            }
            return chs.count
        }

        /// For each character boundary of a line: is inline Markdown open
        /// there, or a delimiter run unfinished? `ended`: nothing follows the
        /// last character (the line is over, or the text stopped coming).
        static func openAt(_ chs: [Character], before: Character? = nil, ended: Bool) -> [Bool] {
            var open = Array(repeating: false, count: chs.count + 1)
            var stack: [Character] = []
            var code = 0 // backticks of the open code span
            var link = 0 // 1: inside [...]; 2: inside the (...) after it
            var parens = 0
            func space(_ c: Character?) -> Bool { c.map(\.isWhitespace) ?? true }
            func punct(_ c: Character?) -> Bool { c.map { $0.isPunctuation || $0.isSymbol } ?? false }
            var i = 0
            while i < chs.count {
                let c = chs[i]
                var j = i + 1
                var unknown = false
                if code > 0 {
                    if c == "`" {
                        while j < chs.count, chs[j] == "`" { j += 1 }
                        if j - i == code { code = 0 }
                    }
                } else if c == "\\" {
                    j = min(i + 2, chs.count)
                } else if c == "`" {
                    while j < chs.count, chs[j] == "`" { j += 1 }
                    code = j - i
                } else if c == "*" || c == "_" || c == "~" {
                    while j < chs.count, chs[j] == c { j += 1 }
                    let prev: Character? = i > 0 ? chs[i - 1] : before
                    let next: Character? = j < chs.count ? chs[j] : (ended ? " " : nil)
                    if next == nil {
                        // Can't tell yet what this run does.
                        unknown = true
                    } else if c == "~", j - i < 2 {
                        // One tilde is just a tilde.
                    } else {
                        // CommonMark's flanking rules, roughly.
                        let left = !space(next) && (!punct(next) || space(prev) || punct(prev))
                        let right = !space(prev) && (!punct(prev) || space(next) || punct(next))
                        let canOpen = c == "_" ? left && (!right || punct(prev)) : left
                        let canClose = c == "_" ? right && (!left || punct(next)) : right
                        if canClose, stack.last == c {
                            stack.removeLast()
                        } else if canOpen {
                            stack.append(c)
                        }
                    }
                } else if link == 0, c == "[" {
                    link = 1
                } else if link == 1, c == "]" {
                    if j < chs.count {
                        if chs[j] == "(" { link = 2; parens = 1; j += 1 } else { link = 0 }
                    } else if ended {
                        link = 0
                    } else {
                        // A link if "(" comes next: can't tell yet.
                        link = 0
                        unknown = true
                    }
                } else if link == 2 {
                    if c == "(" { parens += 1 }
                    if c == ")" { parens -= 1; if parens == 0 { link = 0 } }
                }
                // Never inside a run of one delimiter.
                if j > i + 1 { for k in (i + 1)..<j { open[k] = true } }
                open[j] = unknown || code > 0 || !stack.isEmpty || link > 0
                i = j
            }
            return open
        }

        /// For each character boundary: is it strictly inside a word? By
        /// the system's word segmentation (ICU; Chinese and Japanese by
        /// dictionary), with one tokenizer kept per thread: making one per
        /// call loads the Chinese model each time (~0.3 ms a line on iOS).
        static func insideWords(_ body: Substring, _ chs: [Character]) -> [Bool] {
            let string = String(body) as CFString
            let length = CFStringGetLength(string)
            // The character boundary at each UTF-16 offset (-1: none).
            var index = [Int](repeating: -1, count: length + 1)
            index[0] = 0
            var u = 0
            for (k, c) in chs.enumerated() {
                u += c.utf16.count
                if u < index.count { index[u] = k + 1 }
            }
            var inside = [Bool](repeating: false, count: chs.count + 1)
            let words = WordTokenizer.current.tokenizer(for: string, length: length)
            while CFStringTokenizerAdvanceToNextToken(words) != [] {
                let r = CFStringTokenizerGetCurrentTokenRange(words)
                let end = r.location + r.length
                guard r.location >= 0, end < index.count else { continue }
                let a = index[r.location], b = index[end]
                guard a >= 0, b - a > 1 else { continue }
                for k in (a + 1)..<b { inside[k] = true }
            }
            return inside
        }

        /// A line that opens or closes a code block.
        static func isFence<S: StringProtocol>(_ line: S) -> Bool {
            let t = line.drop { $0 == " " }
            return t.hasPrefix("```") || t.hasPrefix("~~~")
        }

        /// Overdue: the first character boundary with at least `atLeast`
        /// characters revealed, moved on to the end of its word if that's
        /// close, whatever the Markdown.
        static func anyCut(in text: String, from offset: Int, line: LineState, revealedChars: Int, atLeast: Int) -> Cut? {
            let utf8 = text.utf8
            guard offset < utf8.count else { return nil }
            var chars = revealedChars
            var pos = offset
            var reached: (offset: Int, chars: Int)?
            var looked = 0
            for c in text[utf8.index(utf8.startIndex, offsetBy: offset)...] {
                pos += c.utf8.count
                chars += 1
                guard chars >= atLeast else { continue }
                if reached == nil { reached = (pos, chars) }
                if c.isWhitespace || c.isPunctuation {
                    reached = (pos, chars)
                    break
                }
                looked += 1
                if looked > 8 { break }
            }
            guard let r = reached else { return nil }
            return Cut(offset: r.offset, chars: r.chars, lineEnd: false, line: LineState.at(r.offset, in: text, from: line))
        }
    }
}

/// A word tokenizer kept for the thread it was made on.
private final class WordTokenizer {
    private var words: CFStringTokenizer?

    static var current: WordTokenizer {
        let key = "com.novashang.paloally.words"
        if let t = Thread.current.threadDictionary[key] as? WordTokenizer { return t }
        let t = WordTokenizer()
        Thread.current.threadDictionary[key] = t
        return t
    }

    func tokenizer(for string: CFString, length: CFIndex) -> CFStringTokenizer {
        let range = CFRange(location: 0, length: length)
        if let words {
            CFStringTokenizerSetString(words, string, range)
            return words
        }
        let made = CFStringTokenizerCreate(nil, string, range, kCFStringTokenizerUnitWord, nil)!
        words = made
        return made
    }
}
