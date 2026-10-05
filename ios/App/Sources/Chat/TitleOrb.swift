import PaloAllyKit
import SwiftUI

/// The middle of the title bar: the assistant's orb. Its motion is the
/// status — calm when idle, livelier while it works, and it listens as the
/// owner types or speaks. Only when it isn't idle does a short caption say
/// what it's doing (or that something waits on the owner). Tapping opens the
/// status card.
///
/// Phones and iPads: the orb may be bigger than the bar (see OrbPresence), so
/// the bar only holds an invisible target (TitleOrbSlot) and the orb itself
/// floats over the bar from the conversation (FloatingTitleOrb), with the
/// caption as a small glass label across its lower part. The Mac's window
/// toolbar can't be overdrawn: there the orb (TitleOrb) stays inside it, as
/// big as it allows, with the caption to its right.
struct TitleOrb: View {
    let action: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    /// Mac toolbar: room for the caption on each side, so the orb stays centered.
    static let inlineCaptionWidth: CGFloat = 140
    static let inlineOrbSize: CGFloat = 38

    var body: some View {
        let line = store.agentStatusLine
        let caption = line.kind == .idle ? nil : line.text
        let s = Self.inlineOrbSize
        let side = Self.inlineCaptionWidth + 8
        Button(action: action) {
            TitleOrbDrop(size: s)
                .frame(width: s + 2 * side, height: s + 2)
                .overlay(alignment: .leading) {
                    if let caption {
                        TitleOrbCaption(text: caption, kind: line.kind, glass: false)
                            .frame(maxWidth: Self.inlineCaptionWidth, alignment: .leading)
                            .padding(.leading, side + s + 6)
                            .transition(.opacity)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: caption)
        .modifier(TitleOrbAccessibility())
    }
}

/// The bar's middle on phones and iPads: an invisible target where the
/// floating orb sits (the bar takes touches over its own height). Reports
/// where it is so the orb can center on it.
struct TitleOrbSlot: View {
    let frame: (CGRect) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Color.clear.frame(width: 48, height: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame($0) }
        .modifier(TitleOrbAccessibility())
    }
}

/// The orb floating over the bar's middle (phones and iPads), centered on
/// the bar's center line. Its size follows `AppModel.orbPresence` on a
/// spring; past the bar it simply spills over the content and the status
/// bar's margin (a little lower rather than into the Dynamic Island). The
/// caption is a small glass label across its lower part.
///
/// While the owner holds to talk it drops out of the bar into the upper
/// conversation, very large, and listens — following the same hold-driven
/// motion that grows the recording UI, so it starts the moment the finger
/// lands and folds back when it lifts. Then it takes no touches.
struct FloatingTitleOrb: View {
    /// The bar's middle, in window coordinates.
    let barCenterY: CGFloat
    /// The conversation column's width: the listening size follows it.
    let columnWidth: CGFloat
    let action: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(VoiceInputController.self) private var voice
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The box it lives in, centered on the bar's center: room for the
    /// largest in-bar orb's canvas and the widest caption.
    static let box = CGSize(width: 220, height: 96)
    /// Half the bar's height: the label keeps inside the bar while the orb does.
    private static let halfBar: CGFloat = 22
    /// Listening: the gap between the bar's bottom and the big orb.
    private static let listenGap: CGFloat = 14

    var body: some View {
        @Bindable var model = model
        let presence = model.orbPresence
        // In the bar, the size the state asks for; listening grows from the largest.
        let barSize = (presence == .voice ? OrbPresence.present : presence).body
        let listen = listening
        let big = OrbPresence.voiceDiameter(width: columnWidth)
        let d = barSize + (big - barSize) * listen
        let inBar = Self.islandClearance(d: barSize, barCenterY: barCenterY)
        let dropped = Self.halfBar + Self.listenGap + big / 2
        let line = store.agentStatusLine
        // While it listens the label steps aside: nothing else to say.
        let caption = line.kind == .idle || voice.panelMounted ? nil : line.text
        let canvas = TitleOrbDrop.canvas(for: d)
        Button(action: action) {
            ZStack {
                Group {
                    if reduceMotion {
                        // No spring when motion is reduced: a short crossfade between sizes.
                        TitleOrbDrop(size: d).id("\(presence.rawValue)-\(listen)").transition(.opacity)
                    } else {
                        TitleOrbDrop(size: d)
                    }
                }
                .background { ListeningGlow(size: big).opacity(Double(listen)) }
                if let caption {
                    TitleOrbCaption(text: caption, kind: line.kind, glass: true)
                        .frame(maxWidth: 200)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: Self.captionOffset(d))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: max(Self.box.width, canvas), height: max(Self.box.height, canvas))
            .offset(y: inBar + (dropped - inBar) * listen)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!voice.panelMounted)
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 0.62),
                   value: presence)
        // Lively, with a little overshoot, as it drops out to listen.
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.42, dampingFraction: 0.58),
                   value: listen)
        .animation(.snappy, value: caption)
        .popover(isPresented: $model.showHostSwitcher, arrowEdge: .top) {
            StatusCard()
                // Presented outside this view's hierarchy on some platforms: pass what it reads.
                .environment(model)
                .environment(store)
                .presentationCompactAdaptation(.popover)
        }
        // The slot in the bar speaks for it.
        .accessibilityHidden(true)
    }

    /// 0…1: how far it has dropped out of the bar to listen — the hold-to-talk
    /// motion's own progress (with Reduce Motion: in or out, nothing between).
    private var listening: CGFloat {
        let p = voice.panelMounted ? min(max(voice.presence, 0), 1) : 0
        return reduceMotion ? (p > 0 ? 1 : 0) : p
    }

    /// The label's center below the orb's: across its lower part — low
    /// enough to leave most of the drops showing — but never much past the
    /// bar (or the orb, when the orb spills further).
    static func captionOffset(_ d: CGFloat) -> CGFloat {
        let halfLabel: CGFloat = 10
        return min(max(14, d * 0.28), max(halfBar, d / 2) - halfLabel + 3)
    }

    /// How far below the bar's center line the orb sits so its top stays
    /// clear of the Dynamic Island (or the status bar): rather than shrink,
    /// a big orb moves down a little.
    static func islandClearance(d: CGFloat, barCenterY: CGFloat) -> CGFloat {
        let top = DisplayCorners.topInset
        guard top > 0 else { return 0 }
        return max(0, top - 6 + d / 2 - barCenterY)
    }
}

/// The Mac: the toolbar's orb can't leave the toolbar, so while the owner
/// holds to talk a big listening orb rises at the top of the conversation
/// column instead (the phone's drops out of the bar).
struct ListeningOrb: View {
    let columnWidth: CGFloat
    @Environment(VoiceInputController.self) private var voice
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = voice.panelMounted ? min(max(voice.presence, 0), 1) : 0
        let listen = reduceMotion ? (p > 0 ? 1 : 0) : p
        let big = OrbPresence.voiceDiameter(width: columnWidth)
        TitleOrbDrop(size: big)
            .background { ListeningGlow(size: big) }
            .scaleEffect(0.35 + 0.65 * listen)
            .opacity(Double(min(1, listen * 1.6)))
            .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.42, dampingFraction: 0.58),
                       value: listen)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A soft wash of the background behind the listening orb, so it reads over
/// the conversation (the voice scrim rises from the bottom; this is its top).
private struct ListeningGlow: View {
    let size: CGFloat

    var body: some View {
        RadialGradient(
            stops: [
                // Not opaque: the conversation still shows faintly through the glass.
                .init(color: Color(.systemBackground).opacity(0.72), location: 0),
                .init(color: Color(.systemBackground).opacity(0.6), location: 0.5),
                .init(color: Color(.systemBackground).opacity(0), location: 1),
            ],
            center: .center, startRadius: 0, endRadius: size * 1.15)
            .frame(width: size * 2.3, height: size * 2.3)
            .allowsHitTesting(false)
    }
}

/// The avatar itself, `size` = the pair's visible size. The shader's canvas
/// is larger (highlights, the contact shadow, the drops orbiting apart), so
/// it spills past `size` on every side.
struct TitleOrbDrop: View {
    let size: CGFloat
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    /// The pair fills about three quarters of the shader's canvas.
    static func canvas(for size: CGFloat) -> CGFloat { size / 0.75 }

    var body: some View {
        let canvas = Self.canvas(for: size)
        AssistantAvatar(theme: model.currentTheme, live: true, hostID: model.activeHostID)
            .frame(width: canvas, height: canvas)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                // Another assistant has something new.
                if model.hasSeveralHosts && model.othersNeedAttention {
                    Circle().fill(.red).frame(width: 8, height: 8)
                        .accessibilityLabel("别的助理有新消息")
                }
            }
            .contentShape(Circle())
    }
}

/// What it's doing, one line. On phones a small glass label laid over the
/// orb; on the Mac plain text beside it.
struct TitleOrbCaption: View {
    let text: String
    let kind: AgentStatusLine.Kind
    let glass: Bool

    var body: some View {
        let label = Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(kind == .needsYou ? AnyShapeStyle(Color.orange) : AnyShapeStyle(glass ? .primary : .secondary))
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.opacity)
        if glass {
            label
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .glassEffect(.regular, in: .capsule)
        } else {
            label
        }
    }
}

private struct TitleOrbAccessibility: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content
            .accessibilityLabel("\(store.assistantName)：\(store.agentStatusLine.text)")
            .accessibilityHint(model.hasSeveralHosts ? "看它在做什么、换模型或切换助理" : "看它在做什么、换模型")
    }
}

extension AppStore {
    /// What the agent is doing, in priority order (see AgentStatusLine).
    var agentStatusLine: AgentStatusLine {
        AgentStatusLine.make(
            // Only a drop the owner is shown (see displayedConnection).
            offlineText: connectionTrouble ? Copy.connectionShort(displayedConnection) : nil,
            pendingApprovals: pendingApprovals.count,
            busy: isBusy,
            activity: status?.activity,
            tasks: tasks
        )
    }

    /// 「Opus 5.5 · 思考：中」; the thinking part only when the model has one.
    var modelLine: String {
        let name = ModelName.short(status?.model ?? modelInfo?.model ?? "")
        guard !name.isEmpty else { return "" }
        guard let effort = status?.effort, !effort.isEmpty else { return name }
        return "\(name) · 思考：\(EffortName.label(effort))"
    }
}
