import Observation
import SwiftUI
import UIKit

/// The assistant's face: two drops of colored liquid glass — 「它」, big, in
/// its theme color, and 「你」, small, in the theme's partner color. How they
/// sit together is the expression: fused by a liquid bridge at rest,
/// orbiting apart while it thinks, reaching out when something waits on the
/// owner, splashing into one when a reply lands. TwoDropsState drives the
/// motion; GlassDropsView draws it — system Liquid Glass for the real
/// refraction and the melting together, TwoDrops.metal over it for the
/// color depth and the light.
///
/// A `live` avatar follows the current assistant — its state and events
/// (AvatarSignals) and the owner's typing and voice (OrbInput). Others (a
/// color preview, another assistant in a list) rest calmly and only animate
/// a color change.
struct AssistantAvatar: View {
    var theme: AppTheme
    var live = false
    /// The assistant shown, for live avatars: a change of identity together
    /// with the color plays the host-switch handover instead of a recolor.
    var hostID: String?
    /// How far the drawing may spill past the frame (1.25 = a quarter on
    /// each side): the pair, its shadow and its motion need more room than
    /// the spot it holds in a layout.
    var bleed: CGFloat = 1
    /// Pressable (the title orb): the glass gives under the finger.
    var interactive = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    /// Off screen (another place, scrolled away) the clock stops.
    @State private var onScreen = true
    @State private var engine = AvatarEngine()
    @State private var calm = 0

    init(theme: AppTheme, live: Bool = false, hostID: String? = nil, bleed: CGFloat = 1, interactive: Bool = false) {
        self.theme = theme
        self.live = live
        self.hostID = hostID
        self.bleed = bleed
        self.interactive = interactive
    }

    var body: some View {
        let input = live ? OrbInput.shared : nil
        // Calm poses need no more than 30 fps; an event, a recolor or the
        // owner's voice get 60. Reduce Motion: still poses, a slow tick so a
        // change of state still shows. (Reading `beat` re-renders on events;
        // `calm` brings the rate back down once they've played.)
        let beat = live ? AvatarSignals.shared.beat : 0
        let now = Date.timeIntervalSinceReferenceDate
        let recentEvent = live && now - AvatarSignals.shared.lastEventAt < AvatarEngine.eventTime
        let fast = (input?.recording ?? false) || recentEvent || engine.recoloring(theme, at: now)
        let interval: Double = reduceMotion ? 0.5 : (fast ? 1.0 / 60 : 1.0 / 30)
        let _ = calm
        let paused = !onScreen || scenePhase == .background
        TimelineView(.animation(minimumInterval: interval, paused: paused)) { ctx in
            let u = engine.frame(
                now: ctx.date.timeIntervalSinceReferenceDate,
                theme: theme, hostID: hostID, live: live,
                typingPulse: input?.typingPulse ?? 0,
                recording: input?.recording ?? false, level: input?.level ?? 0,
                reduceMotion: reduceMotion, dark: scheme == .dark, scale: Float(displayScale))
            GeometryReader { geo in
                let canvas = min(geo.size.width, geo.size.height) * bleed
                GlassDropsView(uniforms: u, canvas: canvas, interactive: interactive)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: beat) { await settle() }
        .task(id: theme) { await settle() }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            let visible = Self.windowBounds.map { $0.intersects(frame) } ?? true
            if visible != onScreen { onScreen = visible }
        }
        .accessibilityHidden(true)
    }

    /// After an event has played, re-render once so the frame rate drops back.
    private func settle() async {
        try? await Task.sleep(for: .seconds(AvatarEngine.eventTime + 0.1))
        if !Task.isCancelled { calm &+= 1 }
    }

    /// The key window's bounds — `.global` frames are in its coordinates.
    private static var windowBounds: CGRect? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.bounds
    }
}

/// One avatar's motion over time: its own TwoDropsState, fed once per frame
/// from the shared signals (live avatars) and stepped by the frame's time.
@MainActor
final class AvatarEngine {
    /// How long an event (or a recolor) plays at the full frame rate.
    static let eventTime = 2.4

    private var state: TwoDropsState?
    private var lastTime: Double?
    private var theme: AppTheme?
    private var hostID: String?
    private var seenEvent = 0
    private var lastPulse: Int?
    private var lastKeystrokeAt = -Double.infinity
    private var recolorUntil = 0.0

    /// A new color is coming in (or has only just).
    func recoloring(_ theme: AppTheme, at now: Double) -> Bool {
        (self.theme != nil && theme != self.theme) || now < recolorUntil
    }

    func frame(now: Double, theme: AppTheme, hostID: String?, live: Bool,
               typingPulse: Int, recording: Bool, level: Float,
               reduceMotion: Bool, dark: Bool, scale: Float) -> [Float] {
        let colors = theme.glass
        let signals = AvatarSignals.shared
        let st: TwoDropsState
        if let s = state {
            st = s
        } else {
            st = TwoDropsState(primary: colors.primary, partner: colors.partner,
                               seed: UInt64(truncatingIfNeeded: ObjectIdentifier(self).hashValue))
            state = st
            self.theme = theme
            self.hostID = hostID
            seenEvent = signals.seq   // what happened before it appeared isn't replayed
            lastPulse = typingPulse
        }
        st.reduceMotion = reduceMotion

        // A new color: handed over from one assistant to another, or recolored.
        if theme != self.theme {
            if live && hostID != self.hostID {
                st.send(.hostSwitch(primary: colors.primary, partner: colors.partner))
            } else {
                st.send(.colorChange(primary: colors.primary, partner: colors.partner))
            }
            self.theme = theme
            recolorUntil = now + Self.eventTime
        }
        self.hostID = hostID

        if live {
            var inputs = signals.inputs
            if typingPulse != lastPulse {
                lastPulse = typingPulse
                lastKeystrokeAt = now
                st.send(.keystroke)
            }
            inputs.typing = now - lastKeystrokeAt < 1.8
            inputs.speaking = recording
            inputs.voiceLevel = level
            #if DEBUG
            if let forced = AvatarSignals.forcedMode { inputs = forced }
            #endif
            st.inputs = inputs
            for (seq, event) in signals.events where seq > seenEvent { st.send(event) }
            seenEvent = signals.seq
        }

        let dt = Float(min(max(now - (lastTime ?? now), 0), 0.1))
        lastTime = now
        st.advance(by: dt)
        return st.uniforms(dark: dark, scale: scale)
    }
}

/// What every live avatar follows: the assistant's state (kept by
/// OrbPresenceTracking, which already watches the conversation) and a short
/// log of recent events, read by each avatar once per frame. Only `beat` is
/// observed, so avatars speed up for an event without re-rendering per chunk.
@MainActor
@Observable
final class AvatarSignals {
    static let shared = AvatarSignals()

    /// Offline / approval / thinking / streaming / background / quiet;
    /// typing and speaking come from OrbInput.
    @ObservationIgnored var inputs = TwoDropsState.Inputs()
    @ObservationIgnored private(set) var seq = 0
    /// The last few events, oldest first.
    @ObservationIgnored private(set) var events: [(seq: Int, event: TwoDropsState.Event)] = []
    @ObservationIgnored private(set) var lastEventAt = -Double.infinity
    /// The one observed value: bumps on each event worth the full frame rate
    /// (not on every streamed chunk).
    private(set) var beat = 0

    func emit(_ event: TwoDropsState.Event) {
        seq += 1
        events.append((seq, event))
        if events.count > 16 { events.removeFirst(events.count - 16) }
        if case .chunk = event { return }
        lastEventAt = Date.timeIntervalSinceReferenceDate
        beat &+= 1
    }

    #if DEBUG
    /// `-avatarMode thinking` (idle, typing, speaking, thinking, streaming,
    /// background, approval, quiet, offline) holds one state for screenshots.
    static let forcedMode: TwoDropsState.Inputs? = {
        guard let name = UserDefaults.standard.string(forKey: "avatarMode") else { return nil }
        var i = TwoDropsState.Inputs()
        switch name {
        case "typing": i.typing = true
        case "speaking": i.speaking = true; i.voiceLevel = 0.5
        case "thinking": i.thinking = true; i.busyness = 0.6
        case "streaming": i.streaming = true
        case "background": i.background = true
        case "approval": i.approval = true
        case "quiet": i.quiet = true
        case "offline": i.offline = true
        default: break
        }
        return i
    }()
    #endif
}

/// `-demoScreen avatars`: the pair in several colors at the 「它」 header size
/// and the title-bar sizes (screenshots).
struct AvatarGallery: View {
    private let groups: [[AppTheme]] = [[.magenta, .blue, .teal], [.orange, .violet, .graphite]]

    var body: some View {
        VStack(spacing: 28) {
            ForEach(groups.indices, id: \.self) { g in
                Grid(horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow {
                        ForEach(groups[g]) { t in AssistantAvatar(theme: t, live: true).frame(width: 96, height: 96) }
                    }
                    GridRow {
                        ForEach(groups[g]) { t in
                            HStack(spacing: 10) {
                                ForEach([32, 44, 58] as [CGFloat], id: \.self) { d in
                                    AssistantAvatar(theme: t, live: true).frame(width: d / 0.75, height: d / 0.75)
                                        .frame(width: d, height: d)
                                }
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
