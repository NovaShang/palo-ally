import PaloAllyKit
import SwiftUI

/// The page's title as a glass capsule (workbench-prd §6): its name, the
/// status dot, then status and folder, and a small chevron. The same on
/// Palo's page and a session's; tapping it opens the details
/// (`AgentDetailView`): a popover on the Mac and iPad, a sheet on iPhone.
struct TitleCapsule: View {
    let name: String
    let dot: StatusDotKind
    let subtitle: String
    /// A session's page: while the owner holds to talk to it, the dot
    /// becomes the live level bar (Palo's page has its orb instead).
    var showsVoiceLevel = false
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            model.detailShown.toggle()
        } label: {
            HStack(spacing: 8) {
                if showsVoiceLevel { VoiceLevelDot(dot, owner: nil) } else { StatusDot(dot, size: 8) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .accessibilityIdentifier("page-title")
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentTransition(.opacity)
                            .accessibilityIdentifier("page-status")
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: 340, alignment: .leading)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.snappy, value: subtitle)
        .popover(isPresented: Binding(get: { model.detailShown && !AgentDetailPlacement.usesSheet(model: model, store: store) },
                                      set: { model.detailShown = $0 })) {
            AgentDetailView()
                .environment(model)
                .environment(store)
                .frame(minWidth: 360, idealWidth: 380, minHeight: 420, idealHeight: 560)
        }
        .accessibilityLabel(Text("\(name)，\(subtitle)"))
        .accessibilityHint(Text("打开详情"))
        .accessibilityIdentifier("title-capsule")
    }
}

/// Phones and iPads: the page's title is only the round indicator on its
/// own glass circle (docs/workbench-design/indicator.html): no name, no
/// status line. The same on Palo's page and a session's; tapping it opens
/// the details, as the capsule does. On a phone it is also where Palo's orb
/// rests: holding to talk, the orb flies out of it.
struct PageIndicator: View {
    /// The indicator itself; the glass circle is larger.
    var size: CGFloat = 38
    /// The state to show instead of the session's own (waking).
    var dot: StatusDotKind? = nil
    /// Where the circle is, in window coordinates (the voice flight).
    var onFrame: ((CGRect) -> Void)? = nil
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var token = UUID()

    private var isPalo: Bool { store.scope == .palo }

    var body: some View {
        Button {
            model.detailShown.toggle()
        } label: {
            indicator
                .padding(SessionIndicator.glassPadding(size: size))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .modifier(PaloOrbHomeIfNeeded(enabled: isPalo && restsHere, token: token))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame?($0) }
        .popover(isPresented: Binding(get: { model.detailShown && !AgentDetailPlacement.usesSheet(model: model, store: store) },
                                      set: { model.detailShown = $0 })) {
            AgentDetailView()
                .environment(model)
                .environment(store)
                .frame(minWidth: 360, idealWidth: 380, minHeight: 420, idealHeight: 560)
        }
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text("打开详情"))
        .accessibilityIdentifier(isPalo ? "title-orb" : "title-capsule")
    }

    @ViewBuilder private var indicator: some View {
        if isPalo {
            SessionIndicator(state: store.paloDot, contextPct: store.status?.contextPct, effort: store.status?.effort,
                             model: store.status?.model, size: size, glass: false, running: store.paloTasksRunning)
        } else if let pal = store.palID.flatMap({ store.pal(id: $0) }) {
            // Holding to talk to it: the level in its middle.
            SessionIndicator(state: dot ?? pal.dot, contextPct: pal.contextPct, effort: pal.effort, model: pal.model,
                             size: size, glass: false, running: pal.tasksRunning, voiceOwner: .some(nil))
        } else {
            SessionIndicator(state: dot ?? .idle, size: size, glass: false)
        }
    }


    private var label: String {
        let name = isPalo ? store.assistantName : store.palID.flatMap { store.pal(id: $0)?.displayName } ?? ""
        let state = StatusDot.label(isPalo ? store.paloDot : dot ?? store.palID.flatMap { store.pal(id: $0)?.dot } ?? .idle)
        return "\(name)，\(state)"
    }

    /// Where Palo's orb rests while it isn't listening, when nothing else on
    /// screen holds that place: this circle on a phone, and on an iPad whose
    /// sidebar is away without its capsule.
    private var restsHere: Bool {
        if model.layout == .phone { return true }
        return model.sidebarCollapsed && !model.capsuleOnPad
    }
}

extension AppStore {
    /// Palo's subagents running now, for its indicator.
    var paloTasksRunning: Int { tasks.filter { $0.status == .running }.count }

    /// Palo's state for its indicator: waiting on the owner, working, or idle.
    var paloDot: StatusDotKind {
        switch agentStatusLine.kind {
        case .needsYou: .waiting
        // Its subagents still running after its turn: still at work.
        case .working, .tasks: .working
        default: assistantWorking ? .working : .idle
        }
    }
}

/// `paloOrbHome()` when asked for, with an owner so another place that
/// disappears can't clear this one's frame.
private struct PaloOrbHomeIfNeeded: ViewModifier {
    let enabled: Bool
    let token: UUID

    func body(content: Content) -> some View {
        if enabled { content.paloOrbHome(owner: token) } else { content }
    }
}

@MainActor enum AgentDetailPlacement {
    /// iPhone, and Palo's page on an iPad (no capsule there: its orb is the
    /// title): a sheet. Elsewhere a popover under the capsule.
    static func usesSheet(model: WindowModel, store: AppStore) -> Bool {
        guard !Platform.barInWindowToolbar else { return false }
        return model.layout == .phone || store.scope == .palo
    }
}

/// Palo's capsule: its name and what it is doing; the same shape as a session's.
struct PaloTitleCapsule: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let working = store.assistantWorking
        let dot: StatusDotKind = working ? .working : .idle
        TitleCapsule(name: store.assistantName, dot: dot,
                     subtitle: working ? (store.status?.activity ?? StatusDot.label(.working)) : StatusDot.label(.idle))
    }
}

/// iPhone (and Palo on an iPad): the details as a sheet with a half and a full height.
struct AgentDetailSheet: ViewModifier {
    /// false inside a tile: its header opens its own details.
    var enabled = true
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { enabled && model.detailShown && AgentDetailPlacement.usesSheet(model: model, store: store) },
                                           set: { model.detailShown = $0 })) {
            AgentDetailView()
                .environment(model)
                .environment(store)
                .presentationDetents([.medium, .large])
        }
    }
}
