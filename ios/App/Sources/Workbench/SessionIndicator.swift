import PaloAllyKit
import SwiftUI

/// A session's state, the simple way (docs/workbench-design/indicator.html,
/// retired its context arc and effort label on 2026-10-22): the session's
/// live drop (SessionDrop) with the state's white mark on it, or the task
/// count while subagents run; no glass circle under it. The drop is drawn
/// unclipped, its motion spilling a little past `size`, as Palo's orb does.
/// The lists keep Bento's flat glyph (`glyphOnly`). Context, model and
/// effort are said in the details, as text.
struct SessionIndicator: View {
    var state: StatusDotKind
    var size: CGFloat = 38
    /// Only the state glyph, flat (the lists).
    var glyphOnly = false
    /// Subagents and background tasks running: while it works, their count
    /// stands in place of the play mark.
    var running = 0
    /// The conversation the owner may hold to talk to (nil: a single page,
    /// else a tile's session id): while they do, the drop takes the theme
    /// color and live level bars replace the mark. Not set: never.
    var voiceOwner: String?? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: StatusDotKind, size: CGFloat = 38, running: Int = 0, voiceOwner: String?? = nil) {
        self.state = state; self.size = size; self.running = running; self.voiceOwner = voiceOwner
    }

    /// A session.
    init(_ pal: Pal, size: CGFloat = 38, glyphOnly: Bool = false) {
        self.init(state: pal.dot, size: size, running: pal.tasksRunning)
        self.glyphOnly = glyphOnly
    }

    var body: some View {
        Group {
            if glyphOnly { flatGlyph } else { dropWithMark }
        }
        .frame(width: size, height: size)
        .animation(.snappy, value: state)
        .accessibilityElement()
        .accessibilityLabel(StatusDot.label(state))
        .accessibilityValue(state == .working && running > 0 ? String(localized: "\(running) 个任务在跑") : "")
    }

    /// The drop: while the owner holds to talk to it, in the theme color and
    /// trembling with the voice (the owner's ask, 2026-10-21).
    @ViewBuilder private var drop: some View {
        if let owner = voiceOwner {
            ListeningSessionDrop(state: state, owner: owner)
        } else {
            SessionDrop(state: state, voiceLevel: nil)
        }
    }

    /// The drop alone, its motion free to spill out (TitleOrbDrop's canvas),
    /// and its mark.
    private var dropWithMark: some View {
        let r = size * 0.27
        return ZStack {
            drop.frame(width: size / 0.75, height: size / 0.75)
                .frame(width: size, height: size)
            if let owner = voiceOwner {
                IndicatorVoiceCenter(owner: owner, side: size * 0.6) { mark(radius: r) }
            } else {
                mark(radius: r)
            }
        }
        .frame(width: size, height: size)
    }

    /// The lists' flat glyph; working, it breathes, in a view graph of its
    /// own (IsolatedHost): a forever animation in the window's graph
    /// re-rendered the whole window every frame (the sidebar's rows, the Mac).
    @ViewBuilder private var flatGlyph: some View {
        let r = size * 0.4
        let flat = glyph(radius: r)
        if state == .working && !reduceMotion {
            IsolatedHost { Breathing { flat } }.frame(width: r * 2, height: r * 2)
        } else {
            flat
        }
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

    /// The glyph's white mark alone, for a drop to carry: play, the count,
    /// ?, the tick, or (idle) a small dot.
    private func mark(radius r: CGFloat) -> some View {
        ZStack {
            switch state {
            case .idle:
                Circle().fill(.white).frame(width: r * 0.7, height: r * 0.7)
            case .working where running > 0:
                Text(running > 99 ? "99+" : "\(running)")
                    .font(.system(size: r * (running > 9 ? 0.95 : 1.15), weight: .heavy))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .frame(width: r * 1.7)
            case .working:
                Path { p in
                    p.move(to: CGPoint(x: r * 0.72, y: r * 0.58))
                    p.addLine(to: CGPoint(x: r * 1.48, y: r))
                    p.addLine(to: CGPoint(x: r * 0.72, y: r * 1.42))
                    p.closeSubpath()
                }
                .fill(.white)
            case .waiting:
                Text("?").font(.system(size: r * 1.15, weight: .heavy)).fontDesign(.rounded).offset(y: r * 0.02)
            case .done:
                Path { p in
                    p.move(to: CGPoint(x: r * 0.58, y: r * 1.02))
                    p.addLine(to: CGPoint(x: r * 0.9, y: r * 1.34))
                    p.addLine(to: CGPoint(x: r * 1.46, y: r * 0.68))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: r * 0.2, lineCap: .round, lineJoin: .round))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: r * 0.12)
        .frame(width: r * 2, height: r * 2)
    }

}

/// The indicator's middle while the owner holds to talk to its conversation:
/// live level bars in place of the glyph (workbench-prd §11). A view of its
/// own so only it follows the level.
/// A session's drop that listens: the theme color and the voice's level
/// while the owner holds to talk to this conversation.
private struct ListeningSessionDrop: View {
    let state: StatusDotKind
    let owner: String?
    @Environment(VoiceInputController.self) private var voice
    @Environment(\.appTheme) private var theme

    var body: some View {
        let listening = voice.panelMounted && voice.owner == owner
        SessionDrop(state: state, voiceLevel: listening ? voice.dictation.level : nil,
                    listenColor: listening ? theme.glass.primary : nil)
    }
}

private struct IndicatorVoiceCenter<Glyph: View>: View {
    let owner: String?
    let side: CGFloat
    @ViewBuilder let glyph: () -> Glyph
    @Environment(VoiceInputController.self) private var voice

    var body: some View {
        if voice.isActive && voice.owner == owner {
            // White on the drop, which turns the theme color while it listens.
            LevelBars(level: voice.dictation.level, bars: 3, barWidth: max(2, side * 0.08), tallest: side * 0.6)
                .tint(.white)
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
    return VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 20) { ForEach(states, id: \.self) { SessionIndicator(state: $0, size: 44) } }
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
#endif

/// Its content breathing, slowly (the working glyph).
private struct Breathing<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var low = false

    var body: some View {
        content
            .scaleEffect(low ? 0.86 : 1)
            .opacity(low ? 0.8 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { low = true }
            }
    }
}
