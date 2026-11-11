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
    /// A reply being written splits again only from its last segment.
    @State private var segmentCache = MarkdownSegmentCache()

    var body: some View {
        let segments = segmentCache.split(source)
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
                        MarkdownTableView(table: table, trailingRoom: trailingRoom, onQuote: onQuote)
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
    /// 「引用回复」 in a cell's selection menu.
    var onQuote: ((String) -> Void)? = nil
    @Environment(\.messageGutter) private var gutter
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.legibilityWeight) private var legibility
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
                Button(showAll ? String(localized: "收起") : String(localized: "展开全部 \(table.rows.count) 行")) {
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
        // What the cells' sizes depend on: their text and its size. Not
        // their color, so a change of appearance keeps the measurement.
        var sizes = Hasher()
        sizes.combine(table.source)
        sizes.combine(showAll)
        sizes.combine(typeSize)
        sizes.combine(legibility)
        sizes.combine(displayScale)
        return TableGrid(columns: n, sizes: sizes.finalize()) {
            if let header = table.header {
                TableRowCells(cells: header, alignments: table.alignments, header: true, source: table.source, onQuote: onQuote)
                rule(strong: true)
            }
            let rows = showAll ? table.rows : Array(table.rows.prefix(Self.rowLimit))
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                TableRowCells(cells: row, alignments: table.alignments, header: false, source: table.source, onQuote: onQuote)
                if r < rows.count - 1 { rule(strong: false) }
            }
        }
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
}

/// One row's cells, laid out by the grid. Its own view, so a row that
/// hasn't changed isn't built again when one is added below it.
private struct TableRowCells: View {
    let cells: [String]
    let alignments: [MarkdownTable.Alignment]
    let header: Bool
    let source: String
    let onQuote: ((String) -> Void)?

    var body: some View {
        ForEach(cells.indices, id: \.self) { c in
            let align = alignments[c]
            CellText(text: cells[c], header: header,
                     alignment: align == .center ? .center : align == .trailing ? .right : .left,
                     source: source, onQuote: onQuote)
                .padding(.vertical, 7)
                .padding(.leading, c == 0 ? 0 : 10)
                .padding(.trailing, c == cells.count - 1 ? 0 : 10)
                .frame(maxWidth: .infinity, alignment: align == .center ? .center : align == .trailing ? .trailing : .leading)
        }
    }
}

/// A cell's text, selected and copied as the prose around it is (a drag, a
/// double click, ⌘C, the selection menu with 引用回复 and 复制表格), its
/// paths links to the files on the computer, found the same way (FileLinks).
/// As wide as its text on one line when asked for its own size (the grid's
/// column widths), wrapping at the width it's given.
private struct CellText: UIViewRepresentable {
    let text: String
    let header: Bool
    let alignment: NSTextAlignment
    /// The table as written, for 复制表格.
    let source: String
    let onQuote: ((String) -> Void)?
    @Environment(\.appTheme) private var theme
    @Environment(\.wholeReply) private var wholeReply
    @Environment(\.fileLinks) private var fileLinks

    func makeUIView(context: Context) -> TableCellView {
        let view = TableCellView()
        update(view)
        return view
    }

    func updateUIView(_ view: TableCellView, context: Context) {
        update(view)
    }

    private func update(_ view: TableCellView) {
        view.onQuote = onQuote
        view.wholeReply = wholeReply
        view.table = source
        view.show(text, header: header, alignment: alignment, linkColor: theme.uiColor, links: fileLinks)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TableCellView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else {
            let fit = uiView.fittingSize(width: 10_000)
            return CGSize(width: ceil(fit.width), height: ceil(fit.height))
        }
        guard width > 0 else { return nil }
        return CGSize(width: width, height: ceil(uiView.fittingSize(width: width).height))
    }
}

/// A table cell's text. Drawn by TextKit as the reply's text view lays it
/// out (the same storage, container and fonts) until it's used: the pointer
/// over it, or a long press, puts the reply's own text view
/// (`MarkdownTextView`) in its place, laid out the same to the point, for
/// selecting and copying. A text view for every cell from the start cost a
/// table of 40 rows about half a second (most of it the text views'
/// selection gestures being set up), for the few cells ever selected. A
/// click on a link before then (a touch, no pointer) opens it here.
final class TableCellView: UIView {
    var onQuote: ((String) -> Void)? { didSet { live?.onQuote = onQuote } }
    var wholeReply: WholeReplyActions? { didSet { live?.wholeReply = wholeReply } }
    /// The table as written, for 复制表格.
    var table = ""

    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private var shown: (text: String, header: Bool, alignment: NSTextAlignment)?
    private var linkColor: UIColor = .link
    private var links: FileLinkContext?
    private var measured: [CGFloat: CGSize] = [:]
    /// The text view in use, once the cell has been.
    private var live: MarkdownTextView?
    /// The cell's own tap and long press, until the text view takes over.
    private var gestures: [UIGestureRecognizer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        storage.addLayoutManager(layout)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        gestures = [UITapGestureRecognizer(target: self, action: #selector(tapped(_:))),
                    UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))]
        for g in gestures { addGestureRecognizer(g) }
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (v: TableCellView, _) in
            guard let s = v.shown else { return }
            v.shown = nil
            v.show(s.text, header: s.header, alignment: s.alignment, linkColor: v.linkColor, links: v.links)
            v.invalidateIntrinsicContentSize()
        }
        // Drawn again in the colors of the new appearance.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: TableCellView, _) in v.setNeedsDisplay() }
    }

    required init?(coder: NSCoder) { fatalError("not from a coder") }

    func show(_ text: String, header: Bool, alignment: NSTextAlignment, linkColor: UIColor, links: FileLinkContext?) {
        let same = shown.map { $0.text == text && $0.header == header && $0.alignment == alignment } == true
        let newLinks = links != self.links
        self.links = links
        // Dynamic colors compare by what they look like.
        let sameColor = linkColor.resolvedColor(with: traitCollection) == self.linkColor.resolvedColor(with: traitCollection)
        guard !same || !sameColor else {
            if newLinks {
                linkFiles()
                live?.fileLinks = links
                setNeedsDisplay()
            }
            return
        }
        shown = (text, header, alignment)
        self.linkColor = linkColor
        measured.removeAll()
        storage.setAttributedString(MarkdownRenderer.cell(text, header: header, alignment: alignment))
        linkFiles()
        live?.fileLinks = links
        live?.renderCell(text, header: header, alignment: alignment, linkColor: linkColor)
        setNeedsDisplay()
    }

    /// The paths that are files become links, drawn in the link color (the
    /// text view draws its links so itself); again once the computer answers.
    private func linkFiles() {
        if let links {
            FileLinks.apply(links, to: storage) { [weak self] in
                guard let self, self.live == nil else { return }
                self.linkFiles()
                self.setNeedsDisplay()
            }
        }
        let all = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.link, in: all) { value, range, _ in
            if value != nil { storage.addAttribute(.foregroundColor, value: linkColor, range: range) }
        }
    }

    /// As MarkdownTextView measures: TextKit at that width, the used rect.
    func fittingSize(width: CGFloat) -> CGSize {
        let exact = (width * 2).rounded(.down) / 2
        if let hit = measured[exact] { return hit }
        container.size = CGSize(width: exact, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let fit = CGSize(width: ceil(used.width), height: ceil(used.height))
        if measured.count > 8 { measured.removeAll() }
        measured[exact] = fit
        return fit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let exact = (bounds.width * 2).rounded(.down) / 2
        if container.size.width != exact {
            container.size = CGSize(width: exact, height: .greatestFiniteMagnitude)
            setNeedsDisplay()
        }
        if let live, live.frame != bounds { live.frame = bounds }
    }

    override func draw(_ rect: CGRect) {
        guard live == nil, storage.length > 0 else { return }
        let glyphs = layout.glyphRange(for: container)
        layout.drawBackground(forGlyphRange: glyphs, at: .zero)
        layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    /// The reply's text view in the cell's place, the same text in it.
    /// The cell's text, as written.
    var text: String { shown?.text ?? "" }

    @discardableResult
    func goLive() -> MarkdownTextView? {
        if let live { return live }
        guard let shown else { return nil }
        #if DEBUG
        debugLog("[table] cell in use: \(shown.text.prefix(30))")
        #endif
        let view = MarkdownTextView.make()
        view.onQuote = onQuote
        view.wholeReply = wholeReply
        view.fileLinks = links
        let table = table
        view.moreMenu = [UIAction(title: String(localized: "复制表格"), image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = table
        }]
        view.renderCell(shown.text, header: shown.header, alignment: shown.alignment, linkColor: linkColor)
        view.frame = bounds
        addSubview(view)
        live = view
        // Its own taps, presses and links from now on.
        for g in gestures { removeGestureRecognizer(g) }
        gestures = []
        setNeedsDisplay()
        return view
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        if g.state == .began { goLive() }
    }

    /// A long press (a touch): the word under it selected, as in the prose.
    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, live == nil, let view = goLive() else { return }
        let p = g.location(in: view)
        guard let at = view.closestPosition(to: p),
              let word = view.tokenizer.rangeEnclosingPosition(at, with: .word, inDirection: .storage(.forward)) else { return }
        _ = view.becomeFirstResponder()
        view.selectedTextRange = word
    }

    /// A link clicked before the text view is here.
    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard live == nil, storage.length > 0 else { return }
        let p = g.location(in: self)
        var fraction: CGFloat = 0
        let i = layout.characterIndex(for: p, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard i < storage.length else { return }
        let glyph = layout.glyphIndexForCharacter(at: i)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -2, dy: -2).contains(p),
              let value = storage.attribute(.link, at: i, effectiveRange: nil),
              let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return }
        FileLinks.open(url)
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
    /// Changes whenever the cells' sizes may have (see `grid`).
    var sizes: Int
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
        var sizes: Int
        var count: Int
    }

    func makeCache(subviews: Subviews) -> Measured? { nil }

    /// Measured again only when the cells' sizes may have changed: not for
    /// a change of appearance (dark mode, the system's app-switcher
    /// snapshots, which switch it twice each time the app leaves).
    func updateCache(_ cache: inout Measured?, subviews: Subviews) {
        if cache?.sizes != sizes || cache?.count != subviews.count { cache = nil }
    }

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
        return Measured(widths: widths, lines: lines, size: CGSize(width: total, height: height), sizes: sizes, count: subviews.count)
    }
}
