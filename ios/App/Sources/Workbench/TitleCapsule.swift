import PaloAllyKit
import SwiftUI

/// The page's title: only the round session indicator on its own glass
/// circle (indicator-design; workbench-prd §6). No name and no status line:
/// the name lives in the details, the sidebar and the quick-switch strip.
/// The same on Palo's page and a session's; the button opens the details
/// (`AgentDetailView`): a popover on the Mac and iPad, a sheet on iPhone.
struct TitleCapsule: View {
    /// The indicator itself: 38 on phones, 32 on the Mac (the glass is larger).
    var size: CGFloat = 38
    /// The state to show instead of the session's own (waking), or of one this app only reads (no `Pal`).
    var dot: StatusDotKind? = nil
    /// Where the circle is, in window coordinates (phones: the voice flight).
    var onFrame: ((CGRect) -> Void)? = nil
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var token = UUID()

    /// The whole circle's width: the indicator and the glass around it.
    static func outerSize(_ size: CGFloat) -> CGFloat { SessionIndicator.outerSize(size: size, glass: true) }

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
        .tint(.primary)
        .glassEffect(.regular.interactive(), in: .circle)
        .modifier(PaloOrbHomeIfNeeded(enabled: isPalo && restsHere, token: token))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame?($0) }
        .popover(isPresented: Binding(get: { model.detailShown && !AgentDetailPlacement.usesSheet(model: model, store: store) },
                                      set: { model.detailShown = $0 })) {
            AgentDetailView()
                .environment(model)
                .environment(store)
                .frame(width: 380)
        }
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text("打开详情"))
        .accessibilityIdentifier(isPalo ? "title-orb" : "title-capsule")
    }

    @ViewBuilder private var indicator: some View {
        if isPalo {
            SessionIndicator(state: paloState, contextPct: store.status?.contextPct, effort: store.status?.effort,
                             model: store.status?.model, size: size, glass: false)
        } else if let pal = store.palID.flatMap({ store.pal(id: $0) }) {
            SessionIndicator(state: dot ?? pal.dot, contextPct: pal.contextPct, effort: pal.effort, model: pal.model,
                             size: size, glass: false)
        } else {
            SessionIndicator(state: dot ?? .idle, size: size, glass: false)
        }
    }

    /// Palo is working, or waits on the owner, or is idle.
    private var paloState: StatusDotKind {
        switch store.agentStatusLine.kind {
        case .needsYou: .waiting
        case .working: .working
        default: store.assistantWorking ? .working : .idle
        }
    }

    private var label: String {
        let name = isPalo ? store.assistantName
            : store.palID.flatMap { store.pal(id: $0)?.displayName } ?? store.viewedSessionID.flatMap { store.viewedSession($0)?.name } ?? ""
        let state = StatusDot.label(isPalo ? paloState : dot ?? store.palID.flatMap { store.pal(id: $0)?.dot } ?? .idle)
        return "\(name)，\(state)"
    }

    /// Where Palo's orb rests while it isn't listening, when nothing else on
    /// screen holds that place: this circle on a phone, and on an iPad whose
    /// sidebar is away without a capsule. The listening orb flies out of it.
    private var restsHere: Bool {
        if Platform.isMac { return false }
        if model.layout == .phone { return true }
        return model.sidebarCollapsed && !SidebarChrome.shared.capsuleOnPad
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

/// The Mac: the indicator in the window's title bar row, centered on the
/// traffic lights' line and so on the line of the toolbar's right button, with
/// the sidebar's capsule to clear when the sidebar is away. The page runs
/// under the row (it is the window's own title bar band, not a second strip).
struct MacTitlebarIndicator: ViewModifier {
    let enabled: Bool
    var dot: StatusDotKind? = nil
    @Environment(AppModel.self) private var model

    static let size: CGFloat = 32

    func body(content: Content) -> some View {
        if enabled {
            let half = TitleCapsule.outerSize(Self.size) / 2
            content.overlay(alignment: .topLeading) {
                TitleCapsule(size: Self.size, dot: dot)
                    // Clear of the sidebar's capsule while the sidebar is away.
                    .padding(.leading, model.sidebarCollapsed ? 280 : 14)
                    .padding(.top, max(2, SidebarChrome.shared.midY - half))
                    .ignoresSafeArea(edges: .top)
            }
        } else {
            content
        }
    }
}

@MainActor enum AgentDetailPlacement {
    /// iPhone: a sheet. Elsewhere a popover under the indicator.
    static func usesSheet(model: AppModel, store: AppStore) -> Bool {
        !Platform.barInWindowToolbar && model.layout == .phone
    }
}

/// iPhone: the details as a sheet with a half and a full height.
struct AgentDetailSheet: ViewModifier {
    /// false inside a tile: its header opens its own details.
    var enabled = true
    @Environment(AppModel.self) private var model
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
