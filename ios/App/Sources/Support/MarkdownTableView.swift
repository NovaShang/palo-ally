import PaloAllyKit
import SwiftUI
import UIKit

/// An assistant answer that may hold tables. Prose keeps the selectable text
/// view; each table becomes its own grid that scrolls sideways at a readable
/// column width, instead of every column being squeezed into the reply.
struct ReplyMarkdown: View {
    let source: String
    var streaming = false
    var onQuote: ((String) -> Void)? = nil
    /// Room the reply leaves on its trailing side; tables may use it.
    var trailingRoom: CGFloat = 0

    var body: some View {
        let segments = MarkdownSegments.split(source)
        if !segments.contains(where: { if case .table = $0 { true } else { false } }) {
            SelectableMarkdown(source: source, streaming: streaming, onQuote: onQuote)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(segments.enumerated()), id: \.offset) { i, segment in
                    switch segment {
                    case .text(let text):
                        // The streaming cursor belongs at the very end only.
                        SelectableMarkdown(source: text, streaming: streaming && i == segments.count - 1, onQuote: onQuote)
                    case .table(let table):
                        MarkdownTableView(table: table, trailingRoom: trailingRoom)
                    }
                }
            }
        }
    }
}

/// A table in a reply: columns sized to their content (72–240 pt, longer cells
/// wrap), header in semibold over a hairline, scrolling sideways edge to edge
/// of the conversation column, with a fade where more is hidden.
struct MarkdownTableView: View {
    let table: MarkdownTable
    var trailingRoom: CGFloat = 0
    @Environment(\.messageGutter) private var gutter
    @Environment(\.displayScale) private var displayScale
    @State private var hidden = HiddenEdges()
    /// Long tables show their first rows until 「展开全部」.
    @State private var showAll = false
    private static let rowLimit = 40

    private struct HiddenEdges: Equatable {
        var leading = false
        var trailing = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            scroller
            if table.rows.count > Self.rowLimit {
                Button(showAll ? "收起" : "展开全部 \(table.rows.count) 行") {
                    withAnimation(.snappy) { showAll.toggle() }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
            }
        }
    }

    private var scroller: some View {
        ScrollView(.horizontal) {
            grid.padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // At rest the table lines up with the text; scrolled, it slides to
        // the column's edges instead of being cut at the text margin.
        .contentMargins(.leading, gutter, for: .scrollContent)
        .contentMargins(.trailing, gutter + trailingRoom, for: .scrollContent)
        .onScrollGeometryChange(for: HiddenEdges.self) { g in
            HiddenEdges(leading: g.visibleRect.minX > 1, trailing: g.visibleRect.maxX < g.contentSize.width - 1)
        } action: { _, edges in
            hidden = edges
        }
        .mask(fade)
        .padding(.leading, -gutter)
        .padding(.trailing, -(gutter + trailingRoom))
        .contextMenu {
            Button("复制表格", systemImage: "doc.on.doc") { UIPasteboard.general.string = table.source }
        }
    }

    private var grid: some View {
        let n = table.columnCount
        return TableGrid(columns: n) {
            if let header = table.header {
                ForEach(0..<n, id: \.self) { c in cell(header[c], column: c, header: true) }
                rule(strong: true)
            }
            let rows = showAll ? table.rows : Array(table.rows.prefix(Self.rowLimit))
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                ForEach(0..<n, id: \.self) { c in cell(row[c], column: c, header: false) }
                if r < rows.count - 1 { rule(strong: false) }
            }
        }
    }

    private func cell(_ text: String, column c: Int, header: Bool) -> some View {
        let align = table.alignments[c]
        return Text(Self.inline(text))
            .font(header ? .subheadline.weight(.semibold) : .subheadline)
            .multilineTextAlignment(align == .center ? .center : align == .trailing ? .trailing : .leading)
            .padding(.vertical, 7)
            .padding(.leading, c == 0 ? 0 : 10)
            .padding(.trailing, c == table.columnCount - 1 ? 0 : 10)
            .frame(maxWidth: .infinity, alignment: align == .center ? .center : align == .trailing ? .trailing : .leading)
    }

    private func rule(strong: Bool) -> some View {
        Rectangle()
            .fill(strong ? Color(uiColor: .separator) : Color.primary.opacity(0.07))
            .frame(height: 1 / max(displayScale, 1))
            .layoutValue(key: TableRule.self, value: true)
    }

    /// Fades the edge where more of the table is scrolled out of view.
    private var fade: some View {
        let w = max(gutter, 16) + 8
        return HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(hidden.leading ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: w)
            Rectangle()
            LinearGradient(colors: [.black, .black.opacity(hidden.trailing ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                .frame(width: w)
        }
        .animation(.easeOut(duration: 0.2), value: hidden)
    }

    /// Bold, italic, `code` and links inside a cell.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct TableRule: LayoutValueKey {
    static let defaultValue = false
}

/// Cells in row-major order, `columns` per row, with optional full-width rules
/// between rows. Each column is as wide as its widest cell's single line,
/// clamped to `minWidth…maxWidth`; cells wider than that wrap. The grid
/// doesn't depend on the proposed size, so it is measured once and cached
/// until the cells change (each layout pass used to measure every cell
/// twice over, for sizing and again for placing).
private struct TableGrid: Layout {
    var columns: Int
    var minWidth: CGFloat = 72
    var maxWidth: CGFloat = 240

    enum Line {
        case cells([Int], height: CGFloat)
        case rule(Int, height: CGFloat)
    }

    struct Measured {
        var widths: [CGFloat]
        var lines: [Line]
        var size: CGSize
    }

    func makeCache(subviews: Subviews) -> Measured? { nil }

    func updateCache(_ cache: inout Measured?, subviews: Subviews) { cache = nil }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Measured?) -> CGSize {
        measured(subviews, &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Measured?) {
        let m = measured(subviews, &cache)
        var y = bounds.minY
        for line in m.lines {
            switch line {
            case let .cells(indices, height):
                var x = bounds.minX
                for (c, i) in indices.enumerated() {
                    subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: m.widths[c], height: height))
                    x += m.widths[c]
                }
                y += height
            case let .rule(i, height):
                subviews[i].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: m.size.width, height: height))
                y += height
            }
        }
    }

    private func measured(_ subviews: Subviews, _ cache: inout Measured?) -> Measured {
        if let m = cache { return m }
        let m = measure(subviews)
        cache = m
        return m
    }

    private func measure(_ subviews: Subviews) -> Measured {
        let n = max(columns, 1)
        // Rows of cell indices and the rules between them.
        var rows: [[Int]] = []
        var order: [(isRule: Bool, index: Int)] = []
        var current: [Int] = []
        for i in subviews.indices {
            if subviews[i][TableRule.self] {
                if !current.isEmpty { rows.append(current); order.append((false, rows.count - 1)); current = [] }
                order.append((true, i))
            } else {
                current.append(i)
                if current.count == n { rows.append(current); order.append((false, rows.count - 1)); current = [] }
            }
        }
        if !current.isEmpty { rows.append(current); order.append((false, rows.count - 1)) }

        var widths = Array(repeating: minWidth, count: n)
        for row in rows {
            for (c, i) in row.enumerated() {
                widths[c] = max(widths[c], subviews[i].sizeThatFits(.unspecified).width)
            }
        }
        widths = widths.map { min(max(ceil($0), minWidth), maxWidth) }
        let total = widths.reduce(0, +)

        var lines: [Line] = []
        var height: CGFloat = 0
        for item in order {
            if item.isRule {
                let h = subviews[item.index].sizeThatFits(ProposedViewSize(width: total, height: nil)).height
                lines.append(.rule(item.index, height: h))
                height += h
            } else {
                let row = rows[item.index]
                var h: CGFloat = 0
                for (c, i) in row.enumerated() {
                    h = max(h, subviews[i].sizeThatFits(ProposedViewSize(width: widths[c], height: nil)).height)
                }
                lines.append(.cells(row, height: ceil(h)))
                height += ceil(h)
            }
        }
        return Measured(widths: widths, lines: lines, size: CGSize(width: total, height: height))
    }
}
