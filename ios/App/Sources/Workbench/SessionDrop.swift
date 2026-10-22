import PaloAllyKit
import simd
import SwiftUI

/// A session's liquid-glass drop: the assistant's avatar engine (TwoDropsState
/// + GlassDropsView) with one drop instead of the pair, in the session's state
/// color. Its motion is its state: calm when idle, churning while it works,
/// leaning out while it waits, trembling with the owner's voice.
///
/// In the middle of the session indicator (SessionIndicator); the debug
/// builds' Settings keep the prototype page it was chosen from.
struct SessionDrop: View {
    var state: StatusDotKind
    /// 0…1 while the owner speaks to it; nil: not listening.
    var voiceLevel: Float?
    /// The glass in a neutral gray whatever the state (the drop as a
    /// container, the state shown by what's on it); its motion still follows the state.
    var neutral = false
    /// While the owner talks to it: the theme color instead of the state's.
    var listenColor: SIMD3<Float>? = nil

    var body: some View {
        // Drawn in place: hosted apart (IsolatedHost) its glass lost the page
        // behind it and its colors went wrong.
        SessionDropCanvas(state: state, voiceLevel: voiceLevel, neutral: neutral, listenColor: listenColor)
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

/// SessionDrop's drawing: 30 frames a second while it works, waits or
/// listens; at rest 10, then still once its color change is over (pausing
/// at once froze a change halfway).
struct SessionDropCanvas: View {
    var state: StatusDotKind
    /// 0…1 while the owner speaks to it; nil: not listening.
    var voiceLevel: Float?
    /// The glass in a neutral gray whatever the state (the drop as a
    /// container, the state shown by what's on it); its motion still follows the state.
    var neutral = false
    var listenColor: SIMD3<Float>? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @State private var engine = SoloEngine()
    /// Idle or done for a while (its color change long over): it holds still.
    @State private var resting = false
    @Environment(\.scenePhase) private var scenePhase

    /// Moving now: working, waiting, or listening to the owner.
    private var lively: Bool { voiceLevel != nil || state == .working || state == .waiting }

    var body: some View {
        // Each frame costs about a fifth of a core whatever its size (the
        // system glass half of it), so it only ticks when it has to: never
        // once settled at rest, never while no window shows it; a calmer
        // rate while another app is in front (as Palo's orb does).
        var paused = (resting && !lively) || scenePhase == .background
        var interval = lively ? 1.0 / 30 : 1.0 / 10
        #if targetEnvironment(macCatalyst)
        if !MacAppActivity.shared.visible { paused = true }
        if !MacAppActivity.shared.frontmost { interval = 1.0 / 10 }
        #endif
        return TimelineView(.animation(minimumInterval: interval, paused: paused)) { ctx in
            let u = engine.frame(now: ctx.date.timeIntervalSinceReferenceDate, state: state, neutral: neutral, color: listenColor, voiceLevel: voiceLevel,
                                 reduceMotion: reduceMotion, dark: scheme == .dark, scale: Float(displayScale))
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                // The drawing needs room past the drop (shadow, motion).
                GlassDropsView(uniforms: u, canvas: side / 0.75)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        // At rest: a few seconds to finish any color change and settle, then still.
        .task(id: "\(state)-\(voiceLevel == nil)") {
            resting = false
            guard !lively else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { resting = true }
        }
    }
}

@MainActor
private final class SoloEngine {
    private var drops: TwoDropsState?
    private var shown: SIMD3<Float>?
    private var last: Double?

    func frame(now: Double, state: StatusDotKind, neutral: Bool, color: SIMD3<Float>?, voiceLevel: Float?, reduceMotion: Bool, dark: Bool, scale: Float) -> [Float] {
        let c = color ?? SessionDrop.color(neutral ? .idle : state)
        // The inner drop a lighter shade of the same color: one drop, not two.
        let partner = c + (SIMD3<Float>(repeating: 1) - c) * 0.35
        let d: TwoDropsState
        if let drops { d = drops } else {
            d = TwoDropsState(primary: c, partner: partner, seed: UInt64.random(in: 1...UInt64.max))
            d.solo = true
            drops = d
            shown = c
        }
        if shown != c {
            d.send(.colorChange(primary: c, partner: partner))
            shown = c
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
    private let states: [(StatusDotKind, String)] = [(.working, "在干"), (.waiting, "等你"), (.done, "做完了"), (.idle, "闲着")]

    var body: some View {
        List {
            Section("现在用的：水滴，上面是白色图标或数字（没有玻璃圈）") {
                HStack {
                    ForEach(states, id: \.1) { st, name in
                        VStack(spacing: 6) {
                            SessionIndicator(state: st, size: 46)
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 8)
                HStack {
                    VStack(spacing: 6) {
                        SessionIndicator(state: .working, size: 46, running: 3)
                        Text("在干，3 个子任务").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 6) {
                        SessionIndicator(state: .working, size: 26)
                        Text("标题栏的大小").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
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
                Text("这是试验页，用的就是 Palo 球的引擎，只是一滴水、染状态色。最上面是现在各处用的样子。")
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

#endif
