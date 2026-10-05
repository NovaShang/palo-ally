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
        var segments: [MarkdownSegment] = []
        var prose: [String] = []
        var rows: [String] = []
        var inFence = false

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { segments.append(.text(text)) }
            prose = []
        }
        func flushTable() {
            if !rows.isEmpty { segments.append(.table(table(rows))) }
            rows = []
        }

        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle() }
            if !inFence, line.hasPrefix("|") {
                if rows.isEmpty { flushProse() }
                rows.append(line)
                continue
            }
            flushTable()
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
