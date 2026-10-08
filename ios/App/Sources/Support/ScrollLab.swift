#if DEBUG
import PaloAllyKit
import SwiftUI
import UIKit

/// `-demoScreen scrollLab -labRun <anchor|width|fling|sentinel>`: experiments
/// on SwiftUI's own scroll mechanisms, for the chat scroll redesign (step 0).
/// Each writes its findings to the debug log as `[lab]` lines (ScrollLabUITests
/// collects them; `fling` needs its swipe):
/// - anchor: does the bottom size-change anchor animate when the growth is
///   committed inside an animation? (Frame by frame, from the screen.)
/// - width: does an exactly laid-out stack keep the row being read in place
///   (scroll position by id) when the width changes, or rows come and go?
/// - fling: what `ScrollPosition.scrollTo(edge:)` does to a fling in flight,
///   or under a finger that is still dragging.
/// - sentinel: when a bottom sentinel counts as visible above a composer inset.
/// - touch: does the bottom anchor keep the end in view while a finger rests
///   on the list, or holds it after a short drag? (The test does the touching.)
struct ScrollLab: View {
    static var run: String { UserDefaults.standard.string(forKey: "labRun") ?? "anchor" }

    var body: some View {
        Group {
            switch Self.run {
            case "width": WidthLab()
            case "fling": FlingLab()
            case "sentinel": SentinelLab()
            case "touch": TouchLab()
            default: AnchorLab()
            }
        }
        .task { debugLog("[lab] run \(Self.run)") }
    }
}

// MARK: shared

/// Deterministic rows of 1–9 lines.
private struct LabRow: View {
    let i: Int
    var body: some View {
        Text("第 \(i) 行 " + String(repeating: "用来撑出不同高度的一段文字，", count: (i * 7) % 9 * 3 + 1))
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pure colours the screen sampler looks for, in the left gutter (x 16–24).
private struct Marker: View {
    let color: Color
    var body: some View { Rectangle().fill(color).frame(width: 8, height: 4) }
}

/// Finds the UIScrollView a SwiftUI ScrollView is backed by (lab only).
@MainActor final class LabScrollRef {
    weak var scrollView: UIScrollView?
}

private struct ScrollFinder: UIViewRepresentable {
    let ref: LabScrollRef
    func makeUIView(context: Context) -> FinderView { FinderView(ref: ref) }
    func updateUIView(_ uiView: FinderView, context: Context) {}

    final class FinderView: UIView {
        let ref: LabScrollRef
        init(ref: LabScrollRef) {
            self.ref = ref
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var v: UIView? = superview
            while let s = v, !(s is UIScrollView) { v = s.superview }
            if let s = v as? UIScrollView { ref.scrollView = s }
        }
    }
}

/// One frame's worth of what the screen and the scroll view show.
struct LabSample {
    var t: Double
    var modelY: CGFloat
    var shownY: CGFloat
    var contentHeight: CGFloat
    /// Screen y of the blue marker (old content) and the red one (the end), from pixels.
    var blue: Int?
    var red: Int?
}

/// Samples every display frame for a while: the scroll view's offset (model
/// and on screen) and, from a capture of the window, where the markers are.
@MainActor final class LabSampler: NSObject {
    private var link: CADisplayLink?
    private var start = 0.0
    private var until = 0.0
    private(set) var samples: [LabSample] = []
    private var done: CheckedContinuation<[LabSample], Never>?
    let ref: LabScrollRef
    let pixels: Bool

    init(ref: LabScrollRef, pixels: Bool) {
        self.ref = ref
        self.pixels = pixels
    }

    func run(for seconds: Double, after action: () -> Void) async -> [LabSample] {
        samples = []
        start = CACurrentMediaTime()
        until = start + seconds
        take()
        action()
        return await withCheckedContinuation { c in
            done = c
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    @objc private func tick() {
        take()
        if CACurrentMediaTime() >= until {
            link?.invalidate()
            link = nil
            done?.resume(returning: samples)
            done = nil
        }
    }

    private func take() {
        guard let s = ref.scrollView else { return }
        var sample = LabSample(t: (CACurrentMediaTime() - start) * 1000, modelY: s.contentOffset.y,
                               shownY: s.layer.presentation()?.bounds.origin.y ?? s.contentOffset.y,
                               contentHeight: s.contentSize.height)
        if pixels, let w = s.window { (sample.blue, sample.red) = Self.markers(in: w) }
        samples.append(sample)
    }

    /// Captures the window at 1x and scans the gutter column (x = 20) for the markers.
    static func markers(in window: UIWindow) -> (Int?, Int?) {
        let w = Int(window.bounds.width), h = Int(window.bounds.height)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        var blue: Int?, red: Int?
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            window.drawHierarchy(in: CGRect(x: 0, y: 0, width: w, height: h), afterScreenUpdates: false)
            UIGraphicsPopContext()
        }
        let x = 20
        for y in 0..<h {
            let p = (y * w + x) * 4
            let r = buf[p], g = buf[p + 1], b = buf[p + 2]
            if blue == nil, b > 170, r < 90, g < 90 { blue = y }
            if red == nil, r > 170, g < 90, b < 90 { red = y }
        }
        return (blue, red)
    }
}

/// "12 steps over 233 ms, 0 → 40" for a series of values per frame.
private func motion(_ samples: [LabSample], _ value: (LabSample) -> CGFloat?) -> String {
    let pts = samples.compactMap { s in value(s).map { (s.t, $0) } }
    guard let first = pts.first, let last = pts.last else { return "not seen" }
    var steps = 0
    var firstMove: Double?
    var lastMove = 0.0
    var biggest: CGFloat = 0
    for (a, b) in zip(pts, pts.dropFirst()) where abs(b.1 - a.1) > 0.5 {
        steps += 1
        if firstMove == nil { firstMove = b.0 }
        lastMove = b.0
        biggest = max(biggest, abs(b.1 - a.1))
    }
    let span = firstMove.map { Int(lastMove - $0) } ?? 0
    return "\(Int(first.1)) → \(Int(last.1)) in \(steps) steps over \(span) ms (biggest \(Int(biggest)))"
}

// MARK: anchor (R1)

/// The last row grows by two lines; the bottom anchor (or a scroll command)
/// keeps the end in view. Is the old text's move up animated or a jump?
private struct AnchorLab: View {
    @State private var ref = LabScrollRef()
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var anchorBottom = true
    @State private var markdown = false
    @State private var extra = 0

    private var growing: String {
        "这是正在长的回复。" + (0..<extra).map { "第 \($0 + 1) 句新写出来的话，长到正好换一行还多一点点的样子。" }.joined()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<24, id: \.self) { LabRow(i: $0) }
                Marker(color: Color(red: 0, green: 0, blue: 1))
                if markdown {
                    ReplyMarkdown(source: growing, streaming: true)
                } else {
                    Text(growing).frame(maxWidth: .infinity, alignment: .leading)
                }
                Marker(color: Color(red: 1, green: 0, blue: 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(ScrollFinder(ref: ref))
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(anchorBottom ? .bottom : .top, for: .sizeChanges)
        .scrollPosition($position)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.gray.opacity(0.15).frame(height: 80).overlay { Text("composer") }
        }
        .task { await runAll() }
    }

    private func runAll() async {
        try? await Task.sleep(for: .seconds(1.5))
        let sampler = LabSampler(ref: ref, pixels: true)
        let anim = Animation.easeOut(duration: 0.25)
        typealias Case = (name: String, anchor: Bool, md: Bool, step: () -> Void)
        let cases: [Case] = [
            ("text, anchor .bottom, no animation", true, false, { extra += 2 }),
            ("text, anchor .bottom, withAnimation", true, false, { withAnimation(anim) { extra += 2 } }),
            ("markdown, anchor .bottom, no animation", true, true, { extra += 2 }),
            ("markdown, anchor .bottom, withAnimation", true, true, { withAnimation(anim) { extra += 2 } }),
            ("text, no anchor, scrollTo(edge:) plain", false, false, {
                extra += 2
                position.scrollTo(edge: .bottom)
            }),
            ("text, no anchor, scrollTo(edge:) withAnimation", false, false, {
                extra += 2
                withAnimation(anim) { position.scrollTo(edge: .bottom) }
            }),
            ("markdown, no anchor, scrollTo(edge:) withAnimation", false, true, {
                extra += 2
                withAnimation(anim) { position.scrollTo(edge: .bottom) }
            }),
        ]
        for c in cases {
            anchorBottom = c.anchor
            markdown = c.md
            extra = 0
            try? await Task.sleep(for: .milliseconds(300))
            position.scrollTo(edge: .bottom)
            try? await Task.sleep(for: .milliseconds(700))
            let s = await sampler.run(for: 0.7, after: c.step)
            report(c.name, s)
        }
        // A reply streaming: a growth every 70 ms, each inside an animation.
        for (name, md) in [("text", false), ("markdown", true)] {
            anchorBottom = true
            markdown = md
            extra = 0
            try? await Task.sleep(for: .milliseconds(300))
            position.scrollTo(edge: .bottom)
            try? await Task.sleep(for: .milliseconds(700))
            let s = await sampler.run(for: 2.0) {
                Task { @MainActor in
                    for _ in 0..<16 {
                        withAnimation(anim) { extra += 1 }
                        try? await Task.sleep(for: .milliseconds(70))
                    }
                }
            }
            report("\(name), anchor .bottom, a growth every 70 ms withAnimation", s)
        }
        debugLog("[lab] anchor done")
    }

    private func report(_ name: String, _ s: [LabSample]) {
        let reds = s.compactMap(\.red)
        let restRed = s.first?.red ?? -1
        let hidden = reds.map { $0 - restRed }.max() ?? 0
        debugLog("[lab] anchor | \(name) | old text on screen: \(motion(s) { $0.blue.map { CGFloat($0) } }) | end marker: \(motion(s) { $0.red.map { CGFloat($0) } }), lowest \(hidden) pt below its resting place | offset model: \(motion(s) { $0.modelY }) | offset shown: \(motion(s) { $0.shownY }) | frames \(s.count)")
    }
}

// MARK: width (exact stack + scroll position by id)

private struct WidthLab: View {
    enum Holder: String, CaseIterable {
        case idBinding = "scrollPosition(id:)", position = "ScrollPosition", none = "offset only"
        case manual = "the lab correcting by the row's move"
    }
    struct Variant: Hashable {
        var lazy = false
        var holder: Holder
        var bottomAnchor = false
        /// The rows straight inside the scroll view (no outer stack).
        var flat = false
        var name: String {
            "\(lazy ? "LazyVStack" : "VStack")\(flat ? " (flat)" : "") + \(holder.rawValue)\(bottomAnchor ? " + sizeChanges .bottom" : "")"
        }
    }
    static let variants: [Variant] = [
        Variant(holder: .idBinding),
        Variant(holder: .position),
        Variant(holder: .none),
        Variant(holder: .idBinding, flat: true),
        Variant(lazy: true, holder: .idBinding),
        Variant(lazy: true, holder: .none),
        Variant(holder: .idBinding, bottomAnchor: true),
        Variant(holder: .position, bottomAnchor: true),
        Variant(holder: .manual),
        Variant(holder: .manual, bottomAnchor: true),
    ]
    @State private var index = 0

    var body: some View {
        WidthCase(variant: Self.variants[index]) {
            if index + 1 < Self.variants.count { index += 1 } else { debugLog("[lab] width done") }
        }
        .id(index)
    }
}

private func fmt(_ v: CGFloat) -> String { v.isNaN ? "gone" : String(Int(v.rounded())) }

private struct WidthCase: View {
    let variant: WidthLab.Variant
    let next: () -> Void
    @State private var ref = LabScrollRef()
    @State private var narrow = false
    @State private var topID: String?
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var rowY: CGFloat = .nan
    @State private var offsetY: CGFloat = 0
    @State private var insetTop: CGFloat = 0
    /// `.manual`: where row 30 should stay.
    @State private var held: CGFloat?
    @State private var before = 0
    @State private var after = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if variant.flat {
                    VStack(alignment: .leading, spacing: 14) { pre; rows; post }
                        .scrollTargetLayout()
                        .padding(.horizontal, 16)
                        .background(ScrollFinder(ref: ref))
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        pre
                        if variant.lazy {
                            LazyVStack(alignment: .leading, spacing: 14) { rows }.scrollTargetLayout()
                        } else {
                            VStack(alignment: .leading, spacing: 14) { rows }.scrollTargetLayout()
                        }
                        post
                    }
                    .padding(.horizontal, 16)
                    .background(ScrollFinder(ref: ref))
                }
            }
            .frame(width: narrow ? 300 : nil)
            .frame(maxWidth: .infinity)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .modifier(SizeAnchor(bottom: variant.bottomAnchor))
            .modifier(Holding(holder: variant.holder, topID: $topID, position: $position))
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.y, $0.contentInsets.top] } action: { _, v in
                offsetY = v[0]
                insetTop = v[1]
            }
            .task { await run(proxy) }
        }
    }

    @ViewBuilder private var pre: some View {
        ForEach(0..<before, id: \.self) { i in
            Text("插在上面的第 \(i) 条，" + String(repeating: "有好几行字，", count: 12)).id("pre-\(i)")
        }
    }

    @ViewBuilder private var post: some View {
        ForEach(0..<after, id: \.self) { i in
            Text("在下面新来的第 \(i) 条，" + String(repeating: "有好几行字，", count: 30)).id("post-\(i)")
        }
    }

    @ViewBuilder private var rows: some View {
        ForEach(0..<60, id: \.self) { i in
            VStack(alignment: .leading, spacing: 0) {
                if i == 30 { Marker(color: Color(red: 0, green: 0, blue: 1)) }
                LabRow(i: i)
            }
            .id("row-\(i)")
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { y in
                guard i == 30 else { return }
                rowY = y
                // `scrollTo(y:)` counts from below the top inset; the geometry's offset includes it.
                if let held, abs(y - held) > 0.5 { position.scrollTo(y: offsetY + insetTop + (y - held)) }
            }
        }
    }

    private func run(_ proxy: ScrollViewProxy) async {
        try? await Task.sleep(for: .seconds(1))
        switch variant.holder {
        case .idBinding: topID = "row-30"
        case .position, .manual: position.scrollTo(id: "row-30", anchor: .top)
        case .none: proxy.scrollTo("row-30", anchor: .top)
        }
        try? await Task.sleep(for: .milliseconds(800))
        if variant.holder == .manual { held = rowY }
        let sampler = LabSampler(ref: ref, pixels: true)
        var steps: [String] = ["start y \(fmt(rowY))"]
        func change(_ what: String, _ action: () -> Void) async {
            let s = await sampler.run(for: 0.8, after: action)
            let ys = s.compactMap(\.blue)
            let base = ys.first ?? -1
            let worst = ys.map { abs($0 - base) }.max() ?? 0
            let missing = s.count - ys.count
            steps.append("\(what) → y \(fmt(rowY)) (on screen: worst frame \(worst) pt off\(missing > 0 ? ", off screen in \(missing) of \(s.count) frames" : ""))")
        }
        await change("width 300") { narrow = true }
        await change("width back") { narrow = false }
        await change("width 300 animated") { withAnimation(.smooth(duration: 0.3)) { narrow = true } }
        await change("width back animated") { withAnimation(.smooth(duration: 0.3)) { narrow = false } }
        await change("2 rows added below") { after += 2 }
        await change("3 rows inserted above") { before += 3 }
        debugLog("[lab] width | \(variant.name) | row 30 at the top: " + steps.joined(separator: "; ") + " | id now \(topID ?? position.viewID(type: String.self) ?? "nil")")
        next()
    }
}

private struct SizeAnchor: ViewModifier {
    let bottom: Bool
    func body(content: Content) -> some View {
        if bottom { content.defaultScrollAnchor(.bottom, for: .sizeChanges) } else { content }
    }
}

private struct Holding: ViewModifier {
    let holder: WidthLab.Holder
    @Binding var topID: String?
    @Binding var position: ScrollPosition
    func body(content: Content) -> some View {
        switch holder {
        case .idBinding: content.scrollPosition(id: $topID, anchor: .top)
        case .position, .manual: content.scrollPosition($position, anchor: .top)
        case .none: content
        }
    }
}

// MARK: fling

/// At the end of 60 rows; the UI test flings toward older messages (or drags
/// and holds). `-labFlingMode`: what to do 150 ms into the fling (or 300 ms
/// into the drag): animated | instant | none | duringDrag.
private struct FlingLab: View {
    @State private var ref = LabScrollRef()
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var fired = false
    @State private var log: [String] = []
    @State private var phaseStart = CACurrentMediaTime()
    private let mode = UserDefaults.standard.string(forKey: "labFlingMode") ?? "animated"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<60, id: \.self) { LabRow(i: $0) }
            }
            .padding(.horizontal, 16)
            .background(ScrollFinder(ref: ref))
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollPosition($position)
        .onScrollPhaseChange { old, new, context in
            let v = context.velocity.map { "v (\(Int($0.dx)), \(Int($0.dy)))" } ?? "no v"
            debugLog("[lab] fling phase \(old) → \(new), \(v), y \(Int(context.geometry.contentOffset.y)), max \(Int(maxY(context.geometry)))")
            guard !fired else { return }
            if mode == "duringDrag", new == .interacting {
                fired = true
                Task { await command(after: 0.3, animated: true) }
            } else if mode != "duringDrag", new == .decelerating {
                fired = true
                Task { await command(after: 0.15, animated: mode == "animated") }
            }
        }
        .onScrollGeometryChange(for: Int.self) { Int(maxY($0) - $0.contentOffset.y) } action: { _, d in
            if fired { debugLog("[lab] fling distance from the end \(d)") }
        }
    }

    /// The bottom-most offset: content offsets include the insets (the visible rect is the whole bounds).
    private func maxY(_ g: ScrollGeometry) -> CGFloat {
        g.contentSize.height + g.contentInsets.bottom - g.visibleRect.height
    }

    private func command(after: Double, animated: Bool) async {
        try? await Task.sleep(for: .seconds(after))
        let y = ref.scrollView?.contentOffset.y ?? -1
        debugLog("[lab] fling mode \(mode): scrollTo(edge: .bottom)\(mode == "none" ? " skipped" : "") at y \(Int(y))")
        let sampler = LabSampler(ref: ref, pixels: false)
        let s = await sampler.run(for: 2.0) {
            guard mode != "none" else { return }
            if animated { withAnimation(.snappy) { position.scrollTo(edge: .bottom) } } else { position.scrollTo(edge: .bottom) }
        }
        let end = s.last.map { $0.contentHeight + (ref.scrollView?.adjustedContentInset.bottom ?? 0) - (ref.scrollView?.bounds.height ?? 0) - $0.modelY } ?? -1
        // Did the fling keep moving toward older text after the command?
        let after = s.dropFirst().prefix(10).map(\.modelY)
        let keptGoing = zip(after, after.dropFirst()).contains { $1 < $0 - 0.5 }
        debugLog("[lab] fling | mode \(mode) | offset model: \(motion(s) { $0.modelY }) | shown: \(motion(s) { $0.shownY }) | kept moving up after the command: \(keptGoing) | \(Int(end)) pt from the end after 2 s")
    }
}

// MARK: touch

/// The end grows every 120 ms (inside an animation, bottom anchor) for 8 s;
/// the UI test rests a finger, then drags 30 pt and holds. Per scroll phase:
/// how far below the view the end got, and how much the offset moved.
private struct TouchLab: View {
    @State private var extra = 0
    @State private var phase: ScrollPhase = .idle
    @State private var since = CACurrentMediaTime()
    @State private var worst: CGFloat = 0
    @State private var grew = 0
    @State private var firstY: CGFloat?
    @State private var lastY: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<30, id: \.self) { LabRow(i: $0) }
                Text("这是正在长的回复。" + (0..<extra).map { "第 \($0 + 1) 句。" }.joined())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onScrollPhaseChange { old, new in
            summarize(old)
            phase = new
        }
        .onScrollGeometryChange(for: [CGFloat].self) { g in
            [g.contentSize.height + g.contentInsets.bottom - g.visibleRect.maxY, g.contentOffset.y]
        } action: { _, v in
            worst = max(worst, v[0])
            if firstY == nil { firstY = v[1] }
            lastY = v[1]
        }
        .task {
            try? await Task.sleep(for: .seconds(1))
            debugLog("[lab] touch growing")
            for _ in 0..<70 {
                withAnimation(.easeOut(duration: 0.25)) { extra += 1 }
                grew += 1
                try? await Task.sleep(for: .milliseconds(120))
            }
            summarize(phase)
            debugLog("[lab] touch done")
        }
    }

    private func summarize(_ p: ScrollPhase) {
        let ms = Int((CACurrentMediaTime() - since) * 1000)
        debugLog("[lab] touch | \(p) for \(ms) ms: grew \(grew) times, the end up to \(Int(worst)) pt below the view, offset moved \(Int(lastY - (firstY ?? lastY)))")
        since = CACurrentMediaTime()
        worst = 0
        grew = 0
        firstY = nil
    }
}

// MARK: sentinel

/// When does a bottom sentinel count as visible, above an 80 pt composer?
private struct SentinelLab: View {
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var thin = false
    @State private var tall = false
    @State private var geo: ScrollGeometry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<40, id: \.self) { LabRow(i: $0) }
                Color.clear.frame(height: 1)
                    .onScrollVisibilityChange(threshold: 0.01) { thin = $0 }
                    .background(alignment: .bottom) {
                        Color.clear.frame(height: 56)
                            .onScrollVisibilityChange(threshold: 0.01) { tall = $0 }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, g in geo = g }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.gray.opacity(0.15).frame(height: 80).overlay { Text("composer") }
        }
        .task { await run() }
    }

    private func run() async {
        try? await Task.sleep(for: .seconds(1.5))
        guard let g0 = geo else { return }
        // Content offsets include the insets: the visible rect is the whole bounds.
        let maxY = g0.contentSize.height + g0.contentInsets.bottom - g0.visibleRect.height
        debugLog("[lab] sentinel geometry: content \(Int(g0.contentSize.height)), container \(Int(g0.containerSize.height)), insets \(Int(g0.contentInsets.top)),\(Int(g0.contentInsets.bottom)), visibleRect \(Int(g0.visibleRect.minY))–\(Int(g0.visibleRect.maxY)), offset \(Int(g0.contentOffset.y)), bottom-most offset \(Int(maxY))")
        var rows: [String] = []
        for d in [0, 5, 12, 20, 40, 55, 60, 80, 100, 140, 200] {
            position.scrollTo(y: maxY - CGFloat(d))
            try? await Task.sleep(for: .milliseconds(400))
            rows.append("\(d) pt up: 1 pt sentinel \(thin ? "visible" : "hidden"), 56 pt sentinel \(tall ? "visible" : "hidden")")
        }
        debugLog("[lab] sentinel | " + rows.joined(separator: "; "))
        debugLog("[lab] sentinel done")
    }
}
#endif
