import PaloAllyKit
import SwiftUI

/// The round session indicator (docs/workbench-design/indicator.html):
/// Bento's state glyph in the middle (working breathes), a 270 degree context
/// arc around it (the label color, orange from 80%, red from 95%, on a faint
/// track), and the effort label in the gap at the bottom, colored by model,
/// cool to warm (deeper on a light background). Glyph, arc and the glass
/// circle behind it share one center: everything is laid out in one square.
///
/// `size` is the indicator itself. With `glass` the Liquid Glass circle is
/// larger by `glassPadding` on each side, so the view's frame is
/// `size + 2 * glassPadding(size)` (use `outerSize(size:glass:)`). Below 26pt
/// only the glyph shows.
struct SessionIndicator: View {
    var state: StatusDotKind
    /// 0 to 100; nil draws an empty arc.
    var contextPct: Int?
    /// Raw effort ("low", "medium", "high", "xhigh", "max"); nil hides the label.
    var effort: String?
    /// A model id or name; picks the label's color.
    var model: String?
    var size: CGFloat = 38
    var glass = true
    /// Only the state glyph, at any size (the lists): no arc, no label.
    var glyphOnly = false
    /// Subagents and background tasks running: while it works, their count
    /// stands in the blue circle in place of the play glyph.
    var running = 0
    /// The conversation the owner may hold to talk to (nil: a single page,
    /// else a tile's session id): while they do, live level bars replace the
    /// glyph. Not set: never.
    var voiceOwner: String?? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var breathing = false

    init(state: StatusDotKind, contextPct: Int? = nil, effort: String? = nil, model: String? = nil,
         size: CGFloat = 38, glass: Bool = true, running: Int = 0, voiceOwner: String?? = nil) {
        self.state = state; self.contextPct = contextPct; self.effort = effort; self.model = model
        self.size = size; self.glass = glass; self.running = running; self.voiceOwner = voiceOwner
    }

    /// A session.
    init(_ pal: Pal, size: CGFloat = 38, glass: Bool = true, glyphOnly: Bool = false) {
        self.init(state: pal.dot, contextPct: pal.contextPct, effort: pal.effort, model: pal.model, size: size, glass: glass,
                  running: pal.tasksRunning)
        self.glyphOnly = glyphOnly
    }

    /// Palo: busy or not from the host's status, with its own context.
    init(palo status: HostStatus?, contextPct: Int?, size: CGFloat = 38, glass: Bool = true) {
        self.init(state: (status?.busy ?? false) ? .working : .idle, contextPct: contextPct,
                  effort: status?.effort, model: status?.model, size: size, glass: glass)
    }

    static func glassPadding(size: CGFloat) -> CGFloat { max(4, (size * 0.13).rounded()) }
    static func outerSize(size: CGFloat, glass: Bool) -> CGFloat { glass ? size + 2 * glassPadding(size: size) : size }

    var body: some View {
        indicator
            .frame(width: size, height: size)
            .padding(glass ? Self.glassPadding(size: size) : 0)
            .glassEffect(glass ? .regular : .identity, in: .circle)
            .animation(.snappy, value: state)
            .onAppear { startBreathing() }
            .onChange(of: state) { startBreathing() }
            .accessibilityElement()
            .accessibilityLabel(StatusDot.label(state))
            .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if state == .working, running > 0 { parts.append(String(localized: "\(running) 个任务在跑")) }
        if let contextPct { parts.append(String(localized: "上下文 \("\(contextPct)%")")) }
        return parts.joined(separator: "，")
    }

    private var showsRing: Bool { !glyphOnly && IndicatorRules.showsRing(size: Double(size)) }
    private var light: Bool { colorScheme == .light }

    @ViewBuilder private var indicator: some View {
        let s = size / 100
        ZStack {
            if showsRing { ring(s) }
            let glyph = glyph(radius: showsRing ? 21 * s : 40 * s)
                .scaleEffect(state == .working && breathing ? 0.86 : 1)
                .opacity(state == .working && breathing ? 0.8 : 1)
            if let owner = voiceOwner {
                IndicatorVoiceCenter(owner: owner, side: 38 * s) { glyph }
            } else {
                glyph
            }
            if showsRing, let label = IndicatorRules.effortLabel(effort) {
                Text(label)
                    .font(.system(size: 21 * s, weight: .bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(Color(rgb: light ? IndicatorModelClass(modelId: model).lightRGB
                                                      : IndicatorModelClass(modelId: model).rgb))
                    .lineLimit(1)
                    .fixedSize()
                    // Centered on the label's own height, low in the arc's gap: the mock's baseline at y 96.
                    .position(x: size / 2, y: 86 * s)
            }
        }
        .frame(width: size, height: size)
    }

    private func ring(_ s: CGFloat) -> some View {
        let fraction = IndicatorRules.fraction(pct: contextPct)
        let stroke = StrokeStyle(lineWidth: 7 * s, lineCap: .round)
        let tone: Color = switch IndicatorRules.arcTone(fraction: fraction) {
        case .normal: light ? Color(rgb: 0x1C1C1E) : .white.opacity(0.9)
        case .warn: Color(rgb: light ? 0xFF9500 : 0xFF9F0A)
        case .danger: Color(rgb: light ? 0xFF3B30 : 0xFF453A)
        }
        let track: Color = light ? .black.opacity(0.12) : .white.opacity(0.16)
        // A trim runs from 3 o'clock, clockwise; 135 degrees turns the 270 degree
        // sweep so its gap is at the bottom, like the mock's SVG.
        return ZStack {
            Circle().trim(from: 0, to: 0.75).stroke(track, style: stroke)
            Circle().trim(from: 0, to: max(0.001, fraction) * 0.75).stroke(tone, style: stroke)
        }
        .rotationEffect(.degrees(135))
        .frame(width: 80 * s, height: 80 * s)
        .animation(.snappy, value: fraction)
    }

    private func glyph(radius r: CGFloat) -> some View {
        let color = StatusDot.color(state)
        return ZStack {
            switch state {
            case .idle:
                // Nothing going on: a gray ring with a dot in it, quiet.
                Circle().strokeBorder(color, lineWidth: r * 0.2).frame(width: r * 2, height: r * 2)
                Circle().fill(color).frame(width: r * 0.8, height: r * 0.8)
            case .working where running > 0:
                // How many subagents and background tasks run, in place of the play glyph.
                Circle().fill(color).frame(width: r * 2, height: r * 2)
                Text(running > 99 ? "99+" : "\(running)")
                    .font(.system(size: r * (running > 9 ? 0.95 : 1.15), weight: .heavy))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .frame(width: r * 1.7)
            case .working:
                Circle().fill(color).frame(width: r * 2, height: r * 2)
                Path { p in
                    p.move(to: CGPoint(x: r * 0.72, y: r * 0.58))
                    p.addLine(to: CGPoint(x: r * 1.48, y: r))
                    p.addLine(to: CGPoint(x: r * 0.72, y: r * 1.42))
                    p.closeSubpath()
                }
                .fill(.white)
                .frame(width: r * 2, height: r * 2)
            case .waiting:
                Circle().fill(color).frame(width: r * 2, height: r * 2)
                Text("?").font(.system(size: r * 1.15, weight: .heavy)).fontDesign(.rounded).foregroundStyle(.white)
                    .offset(y: r * 0.02)
            case .done:
                Circle().fill(color).frame(width: r * 2, height: r * 2)
                Path { p in
                    p.move(to: CGPoint(x: r * 0.58, y: r * 1.02))
                    p.addLine(to: CGPoint(x: r * 0.9, y: r * 1.34))
                    p.addLine(to: CGPoint(x: r * 1.46, y: r * 0.68))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: r * 0.2, lineCap: .round, lineJoin: .round))
                .frame(width: r * 2, height: r * 2)
            }
        }
        .frame(width: r * 2, height: r * 2)
    }

    private func startBreathing() {
        guard state == .working, !reduceMotion else { breathing = false; return }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathing = true }
    }
}

/// The indicator's middle while the owner holds to talk to its conversation:
/// live level bars in place of the glyph (workbench-prd §11). A view of its
/// own so only it follows the level.
private struct IndicatorVoiceCenter<Glyph: View>: View {
    let owner: String?
    let side: CGFloat
    @ViewBuilder let glyph: () -> Glyph
    @Environment(VoiceInputController.self) private var voice

    var body: some View {
        if voice.isActive && voice.owner == owner {
            LevelBars(level: voice.dictation.level, bars: 3, barWidth: max(2, side * 0.08), tallest: side * 0.6)
                .tint(.primary)
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        } else {
            glyph()
        }
    }
}

#if DEBUG
#Preview("Session indicator") {
    let states: [StatusDotKind] = [.working, .waiting, .done, .idle]
    let models = ["claude-haiku-4-5", "claude-sonnet-5", "claude-opus-5-5", "claude-fable-1", "default"]
    let efforts = ["low", "medium", "high", "xhigh", "max"]
    return ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text("States").font(.caption)
            HStack(spacing: 20) { ForEach(states, id: \.self) { SessionIndicator(state: $0, contextPct: 41, effort: "high", model: "opus", size: 64) } }
            Text("Context 12 / 41 / 83 / 97").font(.caption)
            HStack(spacing: 20) { ForEach([12, 41, 83, 97], id: \.self) { SessionIndicator(state: .idle, contextPct: $0, effort: "high", model: "opus", size: 64) } }
            Text("Effort and model").font(.caption)
            HStack(spacing: 20) { ForEach(0..<5, id: \.self) { SessionIndicator(state: .idle, contextPct: 50, effort: efforts[$0], model: models[$0], size: 64) } }
            Text("Sizes 16 / 24 / 26 / 32 / 38 / 150, glass and flat").font(.caption)
            HStack(spacing: 14) { ForEach([16, 24, 26, 32, 38, 150] as [CGFloat], id: \.self) { SessionIndicator(state: .waiting, contextPct: 62, effort: "xhigh", model: "fable", size: $0) } }
            HStack(spacing: 14) { ForEach([16, 24, 26, 32, 38] as [CGFloat], id: \.self) { SessionIndicator(state: .done, contextPct: 62, effort: "xhigh", model: "fable", size: $0, glass: false) } }
        }
        .padding()
    }
    .background(Color.black)
    .preferredColorScheme(.dark)
}
#endif
