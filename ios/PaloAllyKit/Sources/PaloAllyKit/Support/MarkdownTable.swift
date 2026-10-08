import Foundation

/// A GitHub-flavored table taken out of an assistant reply, so the app can lay
/// it out as a real grid that scrolls sideways at a readable column width
/// instead of squeezing every column into the reply's width.
public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }

    /// The first row, when a `|---|` separator follows it; otherwise nil.
    public var header: [String]?
    /// Body rows, each padded to `columnCount` cells.
    public var rows: [[String]]
    /// One per column, from the separator row (`:--`, `:-:`, `--:`).
    public var alignments: [Alignment]
    /// The table as written, for copying.
    public var source: String

    public var columnCount: Int { alignments.count }
}

/// A reply split into prose and tables, in order.
public enum MarkdownSegment: Equatable, Sendable {
    case text(String)
    case table(MarkdownTable)
}

public enum MarkdownSegments {
    /// Runs of lines starting with `|` (outside fenced code) become tables;
    /// everything else stays prose, untouched.
    public static func split(_ source: String) -> [MarkdownSegment] {
        splitWithLines(source).map(\.segment)
    }

    /// The segments, each with the line it starts on. Line by line, forward
    /// only, and every segment starts outside a fence: once the next segment
    /// has begun, a segment never changes (what `MarkdownSegmentCache` uses).
    static func splitWithLines(_ source: String) -> [(segment: MarkdownSegment, line: Int)] {
        var segments: [(segment: MarkdownSegment, line: Int)] = []
        var prose: [String] = []
        var proseStart = 0
        var rows: [String] = []
        var rowsStart = 0
        var inFence = false

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { segments.append((.text(text), proseStart)) }
            prose = []
        }
        func flushTable() {
            if !rows.isEmpty { segments.append((.table(table(rows)), rowsStart)) }
            rows = []
        }

        for (n, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle() }
            if !inFence, line.hasPrefix("|") {
                if rows.isEmpty { flushProse(); rowsStart = n }
                rows.append(line)
                continue
            }
            flushTable()
            if prose.isEmpty { proseStart = n }
            prose.append(raw)
        }
        flushTable()
        flushProse()
        return segments
    }

    static func table(_ lines: [String]) -> MarkdownTable {
        var rows = lines.map(cells)
        var header: [String]?
        var aligns: [MarkdownTable.Alignment] = []
        if rows.count >= 2, isSeparator(rows[1]) {
            header = rows[0]
            aligns = rows[1].map(alignment)
            rows.removeFirst(2)
        }
        rows.removeAll(where: isSeparator)
        let columns = max(header?.count ?? 0, rows.map(\.count).max() ?? 0, 1)
        let pad = { (row: [String]) in row + Array(repeating: "", count: max(0, columns - row.count)) }
        return MarkdownTable(header: header.map(pad), rows: rows.map(pad),
                             alignments: Array(aligns.prefix(columns)) + Array(repeating: .leading, count: max(0, columns - aligns.count)),
                             source: lines.joined(separator: "\n"))
    }

    /// `| a | b \| c |` → ["a", "b | c"]: outer pipes dropped, `\|` kept as text.
    static func cells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var out: [String] = []
        var cell = ""
        var escaped = false
        for ch in body {
            if escaped {
                cell.append(ch == "|" ? "|" : "\\\(ch)")
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                out.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(ch)
            }
        }
        if escaped { cell.append("\\") }
        out.append(cell.trimmingCharacters(in: .whitespaces))
        return out
    }

    static func isSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { c in
            !c.isEmpty && c.contains("-") && c.allSatisfy { ":-".contains($0) }
        }
    }

    static func alignment(_ cell: String) -> MarkdownTable.Alignment {
        switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
        case (true, true): .center
        case (false, true): .trailing
        default: .leading
        }
    }
}

/// `MarkdownSegments.split` for a reply being written: the segments before
/// the last are kept as they are, and only the text from where the last one
/// starts is split again (a growing reply re-split every bit of itself on
/// every piece). Gives exactly what `split` gives for the whole text.
extension String {
    /// `hasPrefix`, comparing UTF-8 bytes (memcmp) instead of characters:
    /// for a reply checked against what it was a moment ago, on each piece.
    public func hasBytePrefix(_ prefix: String) -> Bool {
        var text = self
        var prefix = prefix
        return text.withUTF8 { t in
            prefix.withUTF8 { p in
                guard p.count <= t.count else { return false }
                guard let pb = p.baseAddress, p.count > 0 else { return true }
                return memcmp(t.baseAddress!, pb, p.count) == 0
            }
        }
    }
}

public final class MarkdownSegmentCache {
    private var source = ""
    private var frozen: [MarkdownSegment] = []
    /// Where the last (still open) segment's lines begin, in UTF-16 units.
    private var openStart = 0
    private var last: [MarkdownSegment] = []

    public init() {}

    public func split(_ text: String) -> [MarkdownSegment] {
        // Byte-wise: called with the whole reply on each of its pieces.
        if text.utf8.count == source.utf8.count, text.hasBytePrefix(source) { return last }
        if source.isEmpty || !text.hasBytePrefix(source) {
            frozen = []
            openStart = 0
        }
        let tail = (text as NSString).substring(from: openStart)
        let parts = MarkdownSegments.splitWithLines(tail)
        if parts.count > 1 { frozen += parts.dropLast().map(\.segment) }
        if let open = parts.last { openStart += Self.utf16Offset(ofLine: open.line, in: tail) }
        source = text
        last = frozen + (parts.last.map { [$0.segment] } ?? [])
        return last
    }

    private static func utf16Offset(ofLine n: Int, in text: String) -> Int {
        guard n > 0 else { return 0 }
        var offset = 0
        var line = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 {
                line += 1
                if line == n { return offset }
            }
        }
        return offset
    }
}
