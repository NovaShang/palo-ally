import PaloAllyKit
import SwiftUI

/// The assistant's orb at the top of the conversation. Its motion is the
/// status — calm when idle, livelier while it works, and it listens as the
/// owner types or speaks. No caption (the owner's ask, 2026-10-20): what it
/// does shows in its motion and size. Tapping opens the assistant's management
/// (目标, 履历, 记忆, the model, 设置).
///
/// Phones and iPads: the orb may be bigger than the bar (see OrbPresence), so
/// the bar only holds an invisible target (TitleOrbSlot) and the orb itself
/// floats over the bar from the conversation (FloatingTitleOrb). The Mac's
/// window toolbar holds only the system toggles: there the orb floats in the
/// conversation's own top strip, centered in its column (ChatView).

/// The bar's middle on phones and iPads: an invisible target where the
/// floating orb sits (the bar takes touches over its own height). Reports
/// where it is so the orb can center on it.
struct TitleOrbSlot: View {
    /// A session's page (nil: Palo's).
    var session: SessionOrb? = nil
    let frame: (CGRect) -> Void
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Color.clear.frame(width: 48, height: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame($0) }
        if let session {
            button
                .accessibilityLabel(Text("\(session.name)，\(StatusDot.label(session.state))"))
                .accessibilityHint(Text("打开详情"))
                .accessibilityIdentifier("title-capsule")
        } else {
            button.modifier(TitleOrbAccessibility())
        }
    }
}

/// The orb floating over the bar's middle (phones and iPads), centered on
/// the bar's center line. Its size follows `WindowModel.orbPresence` on a
/// spring; past the bar it simply spills over the content and the status
/// bar's margin (a little lower rather than into the Dynamic Island).
///
/// While the owner holds to talk it drops out of the bar into the upper
/// conversation, very large, and listens — following the same hold-driven
/// motion that grows the recording UI, so it starts the moment the finger
/// lands and folds back when it lifts. Then it takes no touches.
struct FloatingTitleOrb: View {
    /// The bar's middle, in window coordinates; nil where nothing overlaps
    /// the top (the Mac: below the window toolbar).
    let barCenterY: CGFloat?
    /// The conversation column's width: the listening size follows it.
    let columnWidth: CGFloat
    /// The Mac: hangs from the top of the column, smaller (no bar to fill,
    /// and it shouldn't crowd the messages it floats over).
    var topAligned = false
    /// The Mac: the title bar row's middle line, from this view's top (the
    /// window's): the resting orb sits centered on it, in the row.
    var rowMidY: CGFloat? = nil
    /// A session's page: its drop in its state's color with the state's white
    /// mark, instead of Palo's pair; same place, same motion when listening.
    var session: SessionOrb? = nil
    let action: () -> Void
    @Environment(WindowModel.self) private var model
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
    /// The Mac's sizes in the title bar row relative to the phone's: 26 pt
    /// resting, a little bigger while something waits on the owner.
    static let macScale: CGFloat = 26 / 56
    /// The Mac: the orb's top below the column's top edge.
    private static let macTopPad: CGFloat = 4
    /// The Mac: the strip the resting orb hangs in, below the titlebar.
    static var macRestHeight: CGFloat { macTopPad + OrbPresence.rest.body * macScale }

    var body: some View {
        @Bindable var model = model
        let presence = session?.presence ?? model.orbPresence
        // In the bar, the size the state asks for; listening grows from the largest.
        let barSize = (presence == .voice ? OrbPresence.present : presence).body * (topAligned ? Self.macScale : 1)
        // With a resting place on screen (the sidebar's Palo item) the
        // listening orb flies out from there (`FlyingPaloOrb`): this one
        // stays where it is and gives way as the hold begins.
        let flies = session == nil && model.orbHome.frame != nil
        let listen = flies ? 0 : listening
        let big = OrbPresence.voiceDiameter(width: columnWidth)
        let d = barSize + (big - barSize) * listen
        let canvas = TitleOrbDrop.canvas(for: d)
        let boxHeight = max(Self.box.height, canvas)
        // Where it rests and where it drops to listen, from the box's center.
        let (rest, dropped) = offsets(barSize: barSize, big: big, boxHeight: boxHeight)
        ZStack {
            Button(action: action) {
                Group {
                    if reduceMotion {
                        // No spring when motion is reduced: a short crossfade between sizes.
                        drop(d).id("\(presence.rawValue)-\(listen)").transition(.opacity)
                    } else {
                        drop(d)
                    }
                }
                .background { ListeningGlow(size: big).opacity(Double(listen)) }
            }
            .buttonStyle(.plain)
        }
        .frame(width: max(Self.box.width, canvas), height: boxHeight)
        .offset(y: rest + (dropped - rest) * listen)
        .opacity(flies ? 1 - Double(min(1, listening * 4)) : 1)
        .allowsHitTesting(!voice.panelMounted)
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 0.62),
                   value: presence)
        // Lively, with a little overshoot, as it drops out to listen.
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.42, dampingFraction: 0.58),
                   value: listen)
        // Phones: the slot in the bar speaks for it. The Mac has no slot.
        .modifier(FloatingOrbAccessibility(speaks: barCenterY == nil))
    }

    /// Where it rests and where it drops to listen, from the box's center.
    private func offsets(barSize: CGFloat, big: CGFloat, boxHeight: CGFloat) -> (CGFloat, CGFloat) {
        if let rowMidY {
            // In the row; it drops to where it did below the row before.
            return (rowMidY - boxHeight / 2, 2 * rowMidY + Self.macTopPad + Self.listenGap + big / 2 - boxHeight / 2)
        }
        if topAligned {
            return (Self.macTopPad + barSize / 2 - boxHeight / 2, Self.macTopPad + Self.listenGap + big / 2 - boxHeight / 2)
        }
        return (barCenterY.map { Self.islandClearance(d: barSize, barCenterY: $0) } ?? 0, Self.halfBar + Self.listenGap + big / 2)
    }

    @ViewBuilder private func drop(_ d: CGFloat) -> some View {
        if let session {
            SessionOrbDrop(session: session, size: d)
        } else {
            TitleOrbDrop(size: d)
        }
    }

    /// 0…1: how far it has dropped out of the bar to listen — the hold-to-talk
    /// motion's own progress (with Reduce Motion: in or out, nothing between).
    private var listening: CGFloat {
        let p = voice.panelMounted ? min(max(voice.presence, 0), 1) : 0
        return reduceMotion ? (p > 0 ? 1 : 0) : p
    }

    /// Where the listening orb's bottom is, in global coordinates: below the
    /// bar's middle on phones and iPads, below the column's top on the Mac
    /// (`columnTop`). The words sit below it (`VoiceWordsLayer`).
    static func listeningBottom(barCenterY: CGFloat?, columnTop: CGFloat, columnWidth: CGFloat) -> CGFloat {
        let big = OrbPresence.voiceDiameter(width: columnWidth)
        if let barCenterY { return barCenterY + halfBar + listenGap + big }
        return columnTop + macTopPad + listenGap + big
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

/// The listening orb of the Palo page when the orb has a resting place on
/// screen (`PaloOrbHome`, docs/workbench-prd.md §11): it flies from there to
/// its listening spot over the chat column, and back on release or cancel.
/// The same orb view and the same springs as the one that drops out of a
/// bar; only the start and end points differ. Lives in the page's overlay,
/// so it sits over this column only.
struct FlyingPaloOrb: View {
    /// Where the phone bar's middle is (an iPad's page); the end point
    /// follows the same rule as the words' (`VoiceWordsLayer`).
    let placement: OrbPlacement
    @Environment(WindowModel.self) private var model
    @Environment(VoiceInputController.self) private var voice
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let out = model.orbHome.frame != nil && voice.panelMounted
        flight
            .onChange(of: out, initial: true) { _, now in model.orbHome.flying = now }
            .onDisappear { model.orbHome.flying = false }
    }

    @ViewBuilder private var flight: some View {
        if let home = model.orbHome.frame, voice.panelMounted {
            let p = min(max(voice.presence, 0), 1)
            let listen = reduceMotion ? (p > 0 ? 1 : 0) : p
            GeometryReader { proxy in
                let layer = proxy.frame(in: .global)
                let big = OrbPresence.voiceDiameter(width: layer.width)
                let bottom = FloatingTitleOrb.listeningBottom(
                    barCenterY: placement.slot.width > 0 ? placement.slot.midY : nil,
                    columnTop: layer.minY + proxy.safeAreaInsets.top, columnWidth: layer.width)
                let end = CGPoint(x: layer.width / 2, y: bottom - big / 2 - layer.minY)
                let start = CGPoint(x: home.midX - layer.minX, y: home.midY - layer.minY)
                let startSize = min(max(min(home.width, home.height), 20), 44)
                let d = startSize + (big - startSize) * listen
                TitleOrbDrop(size: d)
                    .background { ListeningGlow(size: big).opacity(Double(listen)) }
                    .opacity(Double(min(1, listen * 4)))
                    .position(x: start.x + (end.x - start.x) * listen, y: start.y + (end.y - start.y) * listen)
                    .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.42, dampingFraction: 0.58),
                               value: listen)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
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
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    /// The pair fills about three quarters of the shader's canvas.
    static func canvas(for size: CGFloat) -> CGFloat { size / 0.75 }

    var body: some View {
        let canvas = Self.canvas(for: size)
        AssistantAvatar(theme: model.currentTheme, live: true, hostID: model.activeHostID, interactive: true)
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

/// A session's page title on phones and iPads, as Palo's orb: what it shows.
struct SessionOrb: Equatable {
    var state: StatusDotKind
    var running: Int
    var name: String
    /// Its size: resting, smaller while reading back, larger while it waits on the owner.
    var presence: OrbPresence
}

/// A session's drop as its page's title (SessionOrb): no glass circle, no
/// context arc, no model or effort (the details have them); while the owner
/// holds to talk to it, the live level stands in for the mark.
struct SessionOrbDrop: View {
    let session: SessionOrb
    let size: CGFloat

    var body: some View {
        SessionIndicator(state: session.state, size: size, running: session.running, voiceOwner: .some(nil))
            .contentShape(Circle())
    }
}

private struct FloatingOrbAccessibility: ViewModifier {
    let speaks: Bool

    func body(content: Content) -> some View {
        if speaks { content.modifier(TitleOrbAccessibility()) } else { content.accessibilityHidden(true) }
    }
}

private struct TitleOrbAccessibility: ViewModifier {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content
            .accessibilityLabel("\(store.assistantName)：\(store.agentStatusLine.text)")
            .accessibilityHint("管理它：目标、履历、记忆和设置")
            .accessibilityIdentifier("title-orb")
    }
}

extension AppStore {
    /// What the agent is doing, in priority order (see AgentStatusLine).
    var agentStatusLine: AgentStatusLine {
        AgentStatusLine.make(
            // Only a drop the owner is shown (see displayedConnection).
            offlineText: connectionTrouble ? Copy.connectionShort(displayedConnection) : nil,
            pendingApprovals: pendingApprovals.count,
            pendingQuestions: pendingQuestions.count,
            pendingDrafts: pendingAllyDrafts.count,
            pendingProposals: pendingProposalCount,
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
        return String(localized: "\(name) · 思考：\(EffortName.label(effort))")
    }
}
