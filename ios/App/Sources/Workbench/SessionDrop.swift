import PaloAllyKit
import simd
import SwiftUI

/// A session's liquid-glass drop: the assistant's avatar engine (TwoDropsState
/// + GlassDropsView) with one drop instead of the pair, in the session's state
/// color. Its motion is its state: calm when idle, churning while it works,
/// leaning out while it waits, trembling with the owner's voice.
///
/// A prototype for now (SessionDropPreview), to decide where it goes.
struct SessionDrop: View {
    var state: StatusDotKind
    /// 0…1 while the owner speaks to it; nil: not listening.
    var voiceLevel: Float?
    /// The glass in a neutral gray whatever the state (the drop as a
    /// container, the state shown by what's on it); its motion still follows the state.
    var neutral = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @State private var engine = SoloEngine()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { ctx in
            let u = engine.frame(now: ctx.date.timeIntervalSinceReferenceDate, state: state, neutral: neutral, voiceLevel: voiceLevel,
                                 reduceMotion: reduceMotion, dark: scheme == .dark, scale: Float(displayScale))
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                // The drawing needs room past the drop (shadow, motion).
                GlassDropsView(uniforms: u, canvas: side / 0.75)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// The state's color, for the glass (sRGB 0…1).
    static func color(_ state: StatusDotKind) -> SIMD3<Float> {
        let hex: UInt32 = switch state {
        case .working: 0x0A85FF
        case .waiting: 0xFF9F0A
        case .done: 0x30D158
        case .idle: 0x9A9AA0
        }
        return SIMD3(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255)
    }
}

@MainActor
private final class SoloEngine {
    private var drops: TwoDropsState?
    private var shown: StatusDotKind?
    private var last: Double?

    func frame(now: Double, state: StatusDotKind, neutral: Bool, voiceLevel: Float?, reduceMotion: Bool, dark: Bool, scale: Float) -> [Float] {
        let c = SessionDrop.color(neutral ? .idle : state)
        // The inner drop a lighter shade of the same color: one drop, not two.
        let partner = c + (SIMD3<Float>(repeating: 1) - c) * 0.35
        let d: TwoDropsState
        if let drops { d = drops } else {
            d = TwoDropsState(primary: c, partner: partner, seed: UInt64.random(in: 1...UInt64.max))
            d.solo = true
            drops = d
            shown = state
        }
        if shown != state, !neutral {
            d.send(.colorChange(primary: c, partner: partner))
            shown = state
        }
        d.reduceMotion = reduceMotion
        var i = TwoDropsState.Inputs()
        switch state {
        case .working: i.thinking = true; i.busyness = 0.6
        case .waiting: i.approval = true
        case .done, .idle: break
        }
        if let voiceLevel { i.speaking = true; i.voiceLevel = voiceLevel }
        d.inputs = i
        let dt = Float(min(max(now - (last ?? now), 0), 0.1))
        last = now
        d.advance(by: dt)
        return d.uniforms(dark: dark, scale: scale)
    }
}

#if DEBUG
/// Settings → 会话水滴（试验）: the drop in each state, in the title
/// indicator's middle and on its own, and listening to a voice, for the
/// owner to judge on the phone.
struct SessionDropPreview: View {
    @State private var listening = false
    @State private var level: Float = 0
    /// The indicator without its glass circle, laid on a drop a little
    /// larger than it: the drop is the container.
    private func containerRow(neutral: Bool) -> some View {
        HStack {
            ForEach(states, id: \.1) { st, name in
                VStack(spacing: 6) {
                    ZStack {
                        SessionDrop(state: st, voiceLevel: nil, neutral: neutral)
                            .frame(width: 66, height: 66)
                        SessionIndicator(state: st, contextPct: 46, effort: "high", model: "claude-opus-5-5",
                                         size: 50, glass: false)
                    }
                    .frame(width: 70, height: 70)
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
    }

    private let states: [(StatusDotKind, String)] = [(.working, "在干"), (.waiting, "等你"), (.done, "做完了"), (.idle, "闲着")]

    var body: some View {
        List {
            Section("A. 放在指示器中间（外圈照旧）") {
                HStack {
                    ForEach(states, id: \.1) { st, name in
                        VStack(spacing: 6) {
                            SessionIndicator(state: st, contextPct: 46, effort: "high", model: "claude-opus-5-5", size: 58)
                                .modifiedCenter(SessionDrop(state: st, voiceLevel: nil))
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 8)
            }
            Section("B. 只有水滴（上下文、深度在详情里）") {
                HStack {
                    ForEach(states, id: \.1) { st, name in
                        VStack(spacing: 6) {
                            SessionDrop(state: st, voiceLevel: nil).frame(width: 44, height: 44)
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 8)
            }
            Section("C. 水滴当容器，代替外面的玻璃圆（染状态色）") {
                containerRow(neutral: false)
            }
            Section("C2. 水滴当容器（灰色水滴，状态看里面的图标）") {
                containerRow(neutral: true)
            }
            Section("按住说话时：从标题落下来，变大，跟着声音抖") {
                VStack(spacing: 16) {
                    SessionDrop(state: .working, voiceLevel: listening ? level : nil)
                        .frame(width: listening ? 150 : 44, height: listening ? 150 : 44)
                        .frame(height: 170)
                        .animation(.spring(response: 0.42, dampingFraction: 0.58), value: listening)
                    Button(listening ? "松开" : "按住说话（模拟）") { listening.toggle() }
                        .buttonStyle(.bordered)
                        .tint(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                Text("这是试验页，用的就是 Palo 球的引擎，只是一滴水、染状态色。看完告诉我选 A、B、C 还是 C2，或者要怎么改。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("会话水滴（试验）")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: listening) {
            // A voice: a level that rises and falls like speech.
            var t = 0.0
            while listening, !Task.isCancelled {
                t += 0.05
                level = Float(max(0, sin(t * 7) * 0.5 + sin(t * 2.3) * 0.4 + 0.2))
                try? await Task.sleep(for: .milliseconds(50))
            }
            level = 0
        }
    }
}

private extension SessionIndicator {
    func modifiedCenter<V: View>(_ v: V) -> SessionIndicator {
        var copy = self
        copy.center = AnyView(v)
        return copy
    }
}
#endif
