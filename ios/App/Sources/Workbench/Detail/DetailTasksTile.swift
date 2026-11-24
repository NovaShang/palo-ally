import PaloAllyKit
import SwiftUI

/// What runs now: at most three, 还有 N 个 opens the rest in place. A task is
/// stopped by its button (under the pointer; always on a phone) or a swipe;
/// the assistant's open their page.
struct DetailTasksTile: View {
    let tasks: [AgentTask]
    @Binding var all: Bool
    var canStop = true
    var open: ((AgentTask) -> Void)?
    let stop: (AgentTask) -> Void

    static let shown = 3
    @Environment(\.detailMetrics) private var metrics
    @State private var height: CGFloat = 0

    private var visible: [AgentTask] { all || tasks.count <= Self.shown ? tasks : Array(tasks.prefix(Self.shown)) }
    private var hidden: Int { tasks.count - visible.count }

    var body: some View {
        // A list for the system's swipe, as high as what's in it.
        List {
            ForEach(Array(visible.enumerated()), id: \.element.id) { i, t in
                DetailTaskRow(task: t, canStop: canStop, open: open, stop: stop)
                    .overlay(alignment: .top) { if i > 0 { separator } }
                    .modifier(PlainRow())
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if canStop {
                            Button("停", role: .destructive) { stop(t) }
                        }
                    }
            }
            if hidden > 0 {
                Button { withAnimation(.snappy) { all = true } } label: {
                    Text("还有 \(hidden) 个")
                        .detailFont(metrics.line)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 44)
                        .padding(.trailing, 13)
                        .padding(.top, 9)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(TileInnerButtonStyle())
                .overlay(alignment: .top) { separator }
                .modifier(PlainRow())
                .accessibilityIdentifier("detail-more-tasks")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .environment(\.defaultMinListRowHeight, 1)
        .contentMargins(.all, 0, for: .scrollContent)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, h in
            if h > 0, abs(h - height) > 0.5 { height = h }
        }
        .frame(height: height > 0 ? height : CGFloat(visible.count) * 54 + (hidden > 0 ? 36 : 0))
        .clipShape(.rect(cornerRadius: DetailMetrics.radius, style: .continuous))
        .detailTile()
        .accessibilityIdentifier("detail-tasks")
    }

    private var separator: some View { DetailColors.line.frame(height: 1) }

    private struct PlainRow: ViewModifier {
        func body(content: Content) -> some View {
            content
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }
}

private struct DetailTaskRow: View {
    let task: AgentTask
    let canStop: Bool
    let open: ((AgentTask) -> Void)?
    let stop: (AgentTask) -> Void
    @Environment(\.detailMetrics) private var metrics
    @State private var hovered = false

    private var title: String { task.title.isEmpty ? String(localized: "一件事") : task.title }

    var body: some View {
        HStack(spacing: 11) {
            Button { open?(task) } label: {
                HStack(spacing: 11) {
                    Group {
                        if task.needsYou {
                            SessionIndicator(glyph: .waiting, size: 20)
                        } else {
                            TaskSpinner().frame(width: 20, height: 20)
                        }
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).detailFont(metrics.row, .semibold).lineLimit(1)
                        line.detailFont(metrics.line).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(TileInnerButtonStyle())
            .allowsHitTesting(open != nil)
            .accessibilityIdentifier("detail-task-\(task.id)")
            if canStop {
                Button { stop(task) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .background(DetailColors.track, in: .circle)
                        // A finger's worth, without making the row taller.
                        .padding(8)
                        .contentShape(.circle)
                        .padding(-8)
                }
                .buttonStyle(TileInnerButtonStyle())
                .opacity(metrics.phone || hovered ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .accessibilityLabel("停下「\(title)」")
                .accessibilityIdentifier("detail-stop-\(task.id)")
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onHover { hovered = $0 }
    }

    /// 「2 分 3 秒 · 已跑 40 个」; with nothing said yet, 「子 agent · 1 分钟」.
    private var line: Text {
        let since = task.startedAt > 0 ? Text(task.startedAt.msDate, style: .relative) : Text(verbatim: "")
        if task.needsYou, task.summary?.isEmpty != false { return Text("需要你") }
        if let s = task.summary?.split(whereSeparator: \.isNewline).first.map(String.init), !s.isEmpty {
            return task.startedAt > 0 ? Text("\(since) · \(Text(verbatim: s))") : Text(verbatim: s)
        }
        return task.startedAt > 0 ? Text("\(Text(verbatim: AgentTaskRow.kindWord(task))) · \(since)") : Text(verbatim: AgentTaskRow.kindWord(task))
    }
}

/// A turning arc in the working color, turned by Core Animation: nothing of
/// the page is drawn again for it.
struct TaskSpinner: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> SpinnerView { SpinnerView() }
    func updateUIView(_ view: SpinnerView, context: Context) { view.still = reduceMotion }

    final class SpinnerView: UIView {
        private let track = CAShapeLayer()
        private let arc = CAShapeLayer()
        var still = false { didSet { if still != oldValue { turn() } } }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            for l in [track, arc] {
                l.fillColor = nil
                l.lineWidth = 2.5
                layer.addSublayer(l)
            }
            arc.lineCap = .round
            color()
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: SpinnerView, _: UITraitCollection) in v.color() }
        }

        required init?(coder: NSCoder) { fatalError() }

        private func color() {
            track.strokeColor = UIColor(DetailColors.track).resolvedColor(with: traitCollection).cgColor
            arc.strokeColor = UIColor(StatusDot.color(.working)).resolvedColor(with: traitCollection).cgColor
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let r = min(bounds.width, bounds.height) * 0.375
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            for l in [track, arc] { l.frame = bounds }
            track.path = UIBezierPath(arcCenter: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
            arc.path = UIBezierPath(arcCenter: c, radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: true).cgPath
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            turn()
        }

        private func turn() {
            arc.removeAnimation(forKey: "turn")
            guard window != nil, !still else { return }
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = 2 * Double.pi
            a.duration = 1.6
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            arc.add(a, forKey: "turn")
        }
    }
}
