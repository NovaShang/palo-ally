import SwiftUI
import UIKit

/// The assistant's face: one drop of liquid glass in its color, ray-marched
/// and lit by `PaloGlass.metal`. Nearly still when idle (a slow breath);
/// livelier, with a slow current inside, while it's working. There's one form
/// on purpose — the color is the personal choice.
struct AssistantAvatar: View {
    var tint: Color
    /// Working: replying or running something in the background.
    var active = false
    /// Reacts to the owner: a small springy nudge per keystroke, and a swell
    /// and jiggle with the voice while recording (the title bar's orb, the
    /// 「它」 header).
    var listens = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.self) private var environment
    /// Off screen (another place, scrolled away) the clock stops.
    @State private var onScreen = true
    @State private var spring = OrbSpring()
    /// A typing nudge is still settling: keep the frame rate up until it has.
    @State private var settling = false

    init(tint: Color, active: Bool = false, listens: Bool = false) {
        self.tint = tint
        self.active = active
        self.listens = listens
    }

    var body: some View {
        let input = listens ? OrbInput.shared : nil
        let recording = input?.recording ?? false
        let level = Double(input?.level ?? 0)
        let pulse = input?.typingPulse ?? 0
        // Idle needs only a slow breath; busy gets a smoother frame rate, and
        // the owner's voice or a fresh nudge the full one.
        let interval: Double = recording || settling ? 1.0 / 60 : (active ? 1.0 / 30 : 1.0 / 15)
        let color = tint.resolve(in: environment)
        TimelineView(.animation(minimumInterval: interval, paused: reduceMotion || !onScreen)) { ctx in
            // A fixed, nicely lit frame when motion is reduced.
            let now = ctx.date.timeIntervalSinceReferenceDate
            let t = reduceMotion ? 1.0 : now.truncatingRemainder(dividingBy: 3600)
            let deform = spring.step(now: now, level: level, pulse: pulse, still: reduceMotion)
            GlassSurface(time: t, activity: active ? 1 : 0, tint: color, dark: scheme == .dark,
                         scale: displayScale, deform: deform)
                .animation(.easeInOut(duration: 1.2), value: active)
                .animation(.easeInOut(duration: 0.35), value: color)
        }
        .aspectRatio(1, contentMode: .fit)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            let visible = Self.windowBounds.map { $0.intersects(frame) } ?? true
            if visible != onScreen { onScreen = visible }
        }
        .task(id: pulse) {
            guard listens, pulse > 0, !reduceMotion else { return }
            settling = true
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { settling = false }
        }
        .accessibilityHidden(true)
    }

    /// The key window's bounds — `.global` frames are in its coordinates.
    private static var windowBounds: CGRect? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.bounds
    }
}

/// The owner's input as motion: one damped spring (squash) that keystrokes
/// and rising voice kick, plus a swell that follows the voice level. Stepped
/// once per frame by the timeline; small and capped, so typing fast reads as
/// attention, not a bounce.
final class OrbSpring {
    private var x = 0.0          // squash, > 0 flatter
    private var v = 0.0
    private var swell = 0.0
    private var lastTime: Double?
    private var lastPulse: Int?
    private var lastLevel = 0.0
    private var lastKick = 0.0

    private static let omega = 2 * Double.pi * 3.2   // ~3 wobbles a second
    private static let damping = 0.32
    private static let maxSquash = 0.075

    /// (swell, squash, jiggle) for the shader.
    func step(now: Double, level: Double, pulse: Int, still: Bool) -> SIMD3<Float> {
        let dt = min(max(now - (lastTime ?? now), 0), 1.0 / 20)
        lastTime = now
        let firstPulse = lastPulse == nil
        defer { lastPulse = pulse; lastLevel = level }
        if still {
            // Reduce Motion: no bouncing, only a gentle swell with the voice.
            x = 0; v = 0
            return SIMD3(Float(level * 0.035), 0, 0)
        }
        // A keystroke: one small press, at most every 70 ms (fast typing
        // coalesces into a steady attentive quiver, never a pile-up).
        if !firstPulse, pulse != lastPulse, now - lastKick > 0.07 {
            v = min(v + 0.55, 1.1)
            lastKick = now
        }
        // Speaking: each rise in loudness kicks; the body swells with it.
        let rise = level - lastLevel
        if rise > 0.04 { v = min(v + rise * 1.4, 1.3) }
        let target = level * 0.06
        let tau = target > swell ? 0.045 : 0.16
        swell += (target - swell) * (1 - exp(-dt / tau))
        // Semi-implicit Euler in small steps keeps it stable at any frame rate.
        var left = dt
        while left > 0 {
            let h = min(left, 1.0 / 240)
            let a = -Self.omega * Self.omega * x - 2 * Self.damping * Self.omega * v
            v += a * h
            x += v * h
            left -= h
        }
        x = min(max(x, -Self.maxSquash), Self.maxSquash)
        let jiggle = min(1.0, level * 1.1 + abs(v) * 0.7)
        return SIMD3(Float(swell), Float(x), Float(jiggle))
    }
}

/// The shader quad. Animatable so the activity level eases in and out
/// instead of snapping when the assistant starts or stops working, and a new
/// color flows in rather than switching.
private struct GlassSurface: View, @preconcurrency Animatable {
    var time: Double
    var activity: Double
    var tint: Color.Resolved
    var dark: Bool
    var scale: CGFloat
    var deform: SIMD3<Float> = .zero

    var animatableData: AnimatablePair<Double, Color.Resolved.AnimatableData> {
        get { AnimatablePair(activity, tint.animatableData) }
        set {
            activity = newValue.first
            tint.animatableData = newValue.second
        }
    }

    var body: some View {
        GeometryReader { geo in
            // The shader paints every pixel itself (transparent outside the
            // drop); the fill only gives it a layer to run on.
            Rectangle()
                .fill(.black)
                .colorEffect(ShaderLibrary.paloGlass(
                    .float2(geo.size),
                    .float(Float(time)),
                    .color(Color(tint)),
                    .float(Float(activity)),
                    .float(dark ? 1 : 0),
                    .float(Float(scale)),
                    .float3(deform.x, deform.y, deform.z)
                ))
        }
    }
}

/// `-demoScreen avatars`: the drop in several colors, idle and working, at
/// the 「它」 header size and the toolbar size (screenshots).
struct AvatarGallery: View {
    private let groups: [[AppTheme]] = [[.magenta, .blue, .teal], [.orange, .violet, .graphite]]

    var body: some View {
        VStack(spacing: 28) {
            ForEach(groups.indices, id: \.self) { g in
                Grid(horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow {
                        ForEach(groups[g]) { t in AssistantAvatar(tint: t.color).frame(width: 96, height: 96) }
                    }
                    GridRow {
                        ForEach(groups[g]) { t in AssistantAvatar(tint: t.color, active: true).frame(width: 96, height: 96) }
                    }
                    GridRow {
                        ForEach(groups[g]) { t in
                            HStack(spacing: 14) {
                                AssistantAvatar(tint: t.color).frame(width: 28, height: 28)
                                AssistantAvatar(tint: t.color, active: true).frame(width: 28, height: 28)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
