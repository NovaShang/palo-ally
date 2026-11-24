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
        .accessibilityElement(children: .contain)
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
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

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
                        line
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
                        .font(.system(size: 9, weight: .bold))
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
        .padding(.vertical, 11)
        .contentShape(.rect)
        .onHover { hovered = $0 }
    }

    /// 「2 分 3 秒 · 已跑 40 个」; with nothing said yet, 「子 agent · 1 分钟」.
    private var line: RunningLine {
        let said = task.summary?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = !said.isEmpty ? said : task.needsYou ? String(localized: "需要你") : AgentTaskRow.kindWord(task)
        return RunningLine(since: task.startedAt > 0 ? task.startedAt.msDate : nil, words: words, timeFirst: !said.isEmpty,
                           size: metrics.line, textScale: scale)
    }
}

/// How long it has run and some words, a second at a time. The label ticks
/// by itself: as a `Text` each second laid the whole page out again.
private struct RunningLine: UIViewRepresentable {
    let since: Date?
    let words: String
    let timeFirst: Bool
    let size: CGFloat
    let textScale: CGFloat

    private var font: UIFont { .systemFont(ofSize: size * textScale) }

    func makeUIView(context: Context) -> Ticking { Ticking() }

    func updateUIView(_ view: Ticking, context: Context) {
        view.label.font = font
        view.line = { [since, words, timeFirst] in
            guard let since else { return words }
            let time = Self.time(since)
            return timeFirst ? "\(time) · \(words)" : "\(words) · \(time)"
        }
        view.tick()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Ticking, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: ceil(font.lineHeight))
    }

    static func time(_ since: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        let units: Set<Duration.UnitsFormatStyle.Unit> = s >= 3600 ? [.hours, .minutes] : [.minutes, .seconds]
        return Duration.seconds(s).formatted(.units(allowed: units, width: .abbreviated, zeroValueUnits: .hide))
    }

    final class Ticking: UIView {
        let label = UILabel()
        var line: () -> String = { "" }
        private var timer: Timer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            label.textColor = .secondaryLabel
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            label.frame = bounds
        }

        func tick() {
            let s = line()
            if s != label.text { label.text = s }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            timer?.invalidate()
            timer = nil
            guard window != nil else { return }
            tick()
            timer = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }
}

/// A turning arc in the working color, turned by Core Animation: nothing of
/// the page is drawn again for it.
struct TaskSpinner: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> SpinnerView { SpinnerView() }
    func updateUIView(_ view: SpinnerView, context: Context) { view.still = reduceMotion }

    final class SpinnerView: UIView {
        private let turning = CALayer()
        var still = false { didSet { if still != oldValue { turn() } } }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.addSublayer(turning)
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: SpinnerView, _: UITraitCollection) in v.draw() }
        }

        required init?(coder: NSCoder) { fatalError() }

        /// The ring and its arc, a picture that turns.
        private func draw() {
            let side = min(bounds.width, bounds.height)
            guard side > 0 else { return }
            turning.contents = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
                let c = CGPoint(x: side / 2, y: side / 2)
                func arc(to end: CGFloat, _ color: Color) {
                    let p = UIBezierPath(arcCenter: c, radius: side * 0.375, startAngle: -.pi / 2, endAngle: end, clockwise: true)
                    p.lineWidth = side * 0.125
                    p.lineCapStyle = .round
                    UIColor(color).resolvedColor(with: traitCollection).setStroke()
                    p.stroke()
                }
                arc(to: 1.5 * .pi, DetailColors.track)
                arc(to: 0, StatusDot.color(.working))
            }.cgImage
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard turning.frame.size != bounds.size || turning.contents == nil else { return }
            turning.bounds = CGRect(origin: .zero, size: bounds.size)
            turning.position = CGPoint(x: bounds.midX, y: bounds.midY)
            draw()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            turn()
        }

        private func turn() {
            turning.removeAnimation(forKey: "turn")
            guard window != nil, !still else { return }
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = 2 * Double.pi
            a.duration = 1.6
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 24)
            turning.add(a, forKey: "turn")
        }
    }
}
