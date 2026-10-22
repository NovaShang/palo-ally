import PaloAllyKit
import SwiftUI

/// What a pane's ⋯ menu does, set by the workspace's page (whose graph keeps
/// the alerts and the confirmation): one object per page, the same in every
/// pane, so a pane's root never changes because of it.
@MainActor
final class PaneActions {
    var openPane: (String) -> Void = { _ in }
    var openAlone: (String) -> Void = { _ in }
    var rename: (String) -> Void = { _ in }
    var moveOut: (String) -> Void = { _ in }
    var closePane: (String) -> Void = { _ in }
    var end: (String) -> Void = { _ in }
    /// A session as a new pane (beside a pane, or where newcomers go).
    var add: (String, PanePlacement?) -> Void = { _, _ in }
    /// 新开一个会话… as a new pane.
    var addNew: (PanePlacement?) -> Void = { _ in }
    /// 从工作区移开: Palo's pane off the workspace (Palo goes on).
    var removePalo: () -> Void = {}
}

/// The pane's measures (docs/workbench-design/split-final.html).
enum PaneMetrics {
    /// The slim header: the session's name, level with the status drop and ⋯.
    static let headerHeight: CGFloat = 32
    /// The status drop and the ⋯ button, centered on the header's line.
    static let button: CGFloat = 28
    /// The status drop inside the icon's room (bare, no glass circle).
    static let drop: CGFloat = 22
    static let buttonInset: CGFloat = 8
    static let buttonTop: CGFloat = 2
    /// Where the name starts and the status line ends (clear of the two buttons).
    static let titleLeading: CGFloat = 42
    static let titleTrailing: CGFloat = 44
    /// The Mac: the pane in the window's top right corner keeps ⋯ clear of
    /// the window toolbar's 右侧栏 button, this much further in.
    static let cornerShift: CGFloat = 40
    /// The header's band a pane is dragged by (between the two buttons).
    static func grip(in bounds: CGRect, corner: Bool) -> CGRect {
        let trailing = titleTrailing + (corner ? cornerShift : 0)
        return CGRect(x: titleLeading, y: 0, width: max(0, bounds.width - titleLeading - trailing), height: headerHeight)
    }
    /// The status icon's rect, in the pane (what a dragged pane's capsule shows).
    static let iconRect = CGRect(x: buttonInset, y: buttonTop, width: button, height: button)
}

/// One pane of a split workspace, in a view graph of its own (a
/// `UIHostingController` placed by `PaneCanvasController`): the session's
/// page with the slim header, the floating status icon (its details) and ⋯.
/// A tick, a keystroke or a drop's frame in this pane updates this graph
/// only. Everything the page reads from around it is passed in here,
/// exactly as the tile had it in the window's graph.
struct PaneRoot: View {
    let id: String
    let workspaceID: String
    let model: WindowModel
    let store: AppStore
    let voice: VoiceInputController
    let details: TileDetails
    let actions: PaneActions
    let bridge: PaneBridge

    var body: some View {
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("PaneRoot")
        #endif
        Group {
            if id == LayoutTree.paloPane {
                PaloPaneContent(workspaceID: workspaceID, details: details, actions: actions,
                                corner: bridge.cornerPane == id)
            } else {
                PaneContent(id: id, workspaceID: workspaceID, details: details, actions: actions,
                            corner: bridge.cornerPane == id)
            }
        }
            .environment(model)
            .environment(store)
            .environment(voice)
            // The window's (a hosted graph doesn't follow its scene by itself).
            .environment(\.scenePhase, bridge.scenePhase)
            .modifier(PaneTheme())
    }
}

/// A pane's hosting controller. Its conversation's scroll view is not the
/// window's content scroll view: on the Mac the titlebar drew its hard edge
/// (a line) over the top panes' conversations.
final class PaneHostingController: UIHostingController<PaneRoot> {
    override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? { nil }
}

/// What the panes take from the workspace page's graph that changes.
@MainActor
@Observable
final class PaneBridge {
    var scenePhase: ScenePhase = .active
    /// The pane under the Mac window toolbar's trailing button (`PaneMetrics.cornerShift`).
    var cornerPane: String?
}

/// The window's computer's color (it changes with the computer).
private struct PaneTheme: ViewModifier {
    @Environment(WindowModel.self) private var model

    func body(content: Content) -> some View {
        content.appTheme(model.currentTheme).scrollEdgeEffectStyle(.soft, for: .all)
    }
}

private struct PaneContent: View {
    let id: String
    let workspaceID: String
    let details: TileDetails
    let actions: PaneActions
    let corner: Bool
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("PaneContent")
        #endif
        PalPage(palID: id, inTile: true)
            .environment(\.tile, TileContext(id: id, isActive: model.activeTile(in: workspaceID) == id))
            .environment(\.tileDetail, details.binding(id))
            // Each session keeps its own unsent words, here and on its own page.
            .environment(\.chatDraft, model.draftBinding(.pal(id)))
            .environment(\.fileLinks, FileLinkContext(scope: .pal(id), resolver: .shared(for: store)))
            .environment(\.placesAsColumns, false)
            // The conversation scrolls under the header, with the system's soft edge.
            .safeAreaBar(edge: .top, spacing: 0) { PaneTitle(id: id, corner: corner) }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .overlay(alignment: .topLeading) {
                PaneStatusButton(id: id, details: details)
                    .padding(.leading, PaneMetrics.buttonInset)
                    .padding(.top, PaneMetrics.buttonTop)
            }
            .overlay(alignment: .topTrailing) {
                PaneMenu(id: id, workspaceID: workspaceID, actions: actions)
                    .padding(.trailing, PaneMetrics.buttonInset + (corner ? PaneMetrics.cornerShift : 0))
                    .padding(.top, PaneMetrics.buttonTop)
            }
            // Spoken to: the pane's edge glows softly with the voice.
            .overlay { TileVoiceGlow(owner: id, shape: Rectangle()) }
            // Its state as a faint wash over the whole pane (Bento Term's).
            .overlay { PaneStateWash(id: id) }
            .background(Color(uiColor: .systemBackground))
    }
}

/// A faint wash of the pane's state color, Bento Term's values: 在干 5%,
/// 做完了 (not looked at yet) 10%, 等你 12%, 闲着 none. Cross-fades as the
/// state changes; takes no touches. Its own view, so a state change
/// re-renders only it.
private struct PaneStateWash: View {
    let id: String
    @Environment(AppStore.self) private var store

    static func alpha(_ dot: StatusDotKind) -> Double {
        switch dot {
        case .working: 0.05
        case .done: 0.10
        case .waiting: 0.12
        case .idle: 0
        }
    }

    var body: some View {
        let dot = store.singlePal(id: id)?.dot ?? .idle
        StatusDot.color(dot).opacity(Self.alpha(dot))
            .animation(.easeInOut(duration: 0.25), value: dot)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Palo's pane (a view of the assistant, not a member): its conversation as
/// on its own page, under the same slim header with its orb and its name.
/// Holding to talk here talks to Palo; its orb drops out to listen inside
/// this pane (TilePaloOrb), as a session pane's drop listens in its header.
private struct PaloPaneContent: View {
    let workspaceID: String
    let details: TileDetails
    let actions: PaneActions
    let corner: Bool
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    private let id = LayoutTree.paloPane

    var body: some View {
        ChatView(inTile: true)
            .environment(\.tile, TileContext(id: id, isActive: model.activeTile(in: workspaceID) == id))
            .environment(\.tileDetail, details.binding(id))
            .environment(\.chatDraft, model.draftBinding(.palo))
            .environment(\.fileLinks, FileLinkContext(scope: .palo, resolver: .shared(for: store)))
            .environment(\.placesAsColumns, false)
            .overlay { TilePaloOrb(owner: id, from: CGPoint(x: PaneMetrics.iconRect.midX, y: PaneMetrics.iconRect.midY)) }
            .safeAreaBar(edge: .top, spacing: 0) { PaneTitle(id: id, corner: corner) }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .overlay(alignment: .topLeading) {
                PaloPaneOrbButton(details: details)
                    .padding(.leading, PaneMetrics.buttonInset)
                    .padding(.top, PaneMetrics.buttonTop)
            }
            .overlay(alignment: .topTrailing) {
                PaloPaneMenu(workspaceID: workspaceID, actions: actions)
                    .padding(.trailing, PaneMetrics.buttonInset + (corner ? PaneMetrics.cornerShift : 0))
                    .padding(.top, PaneMetrics.buttonTop)
            }
            .overlay { TileVoiceGlow(owner: id, shape: Rectangle()) }
            .background(Color(uiColor: .systemBackground))
    }
}

/// Palo's orb in its pane's header, bare at the drop's size; opens Palo's
/// details. While the owner holds to talk in this pane it is out listening.
private struct PaloPaneOrbButton: View {
    let details: TileDetails
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(VoiceInputController.self) private var voice
    private let id = LayoutTree.paloPane

    var body: some View {
        let out = voice.panelMounted && voice.owner == id
        Button {
            details.tile = details.tile == id ? nil : id
        } label: {
            TitleOrbDrop(size: PaneMetrics.drop)
                .frame(width: PaneMetrics.button, height: PaneMetrics.button)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .opacity(out ? 0 : 1)
        .animation(.easeOut(duration: 0.12), value: out)
        .popover(isPresented: details.binding(id)) {
            AgentDetailView()
                .environment(model)
                .environment(store)
                .environment(\.tileDetail, details.binding(id))
                .frame(minWidth: 360, idealWidth: 380, minHeight: 420, idealHeight: 560)
                .presentationCompactAdaptation(.sheet)
        }
        .accessibilityLabel(Text(verbatim: "\(store.assistantName)：\(store.agentStatusLine.text)"))
        .accessibilityIdentifier("tile-header-\(id)")
    }
}

/// Palo's pane's ⋯: split it like any pane, or take it off the workspace.
/// Nothing else (Palo isn't renamed, moved or ended from here).
private struct PaloPaneMenu: View {
    let workspaceID: String
    let actions: PaneActions
    @Environment(AppStore.self) private var store

    var body: some View {
        let online = store.connection.isOnline
        let id = LayoutTree.paloPane
        Menu {
            Menu("向右分出", systemImage: "rectangle.split.2x1") {
                PaneChoices(workspaceID: workspaceID, placement: PanePlacement(pane: id, horizontal: true), actions: actions)
            }
            .disabled(!online)
            Menu("向下分出", systemImage: "rectangle.split.1x2") {
                PaneChoices(workspaceID: workspaceID, placement: PanePlacement(pane: id, horizontal: false), actions: actions)
            }
            .disabled(!online)
            Divider()
            Button("从工作区移开", systemImage: "rectangle.portrait.and.arrow.right") { actions.removePalo() }
                .disabled(!online)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: PaneMetrics.button, height: PaneMetrics.button)
                .contentShape(.circle)
        }
        .macMenuHitArea()
        .menuIndicator(.hidden)
        .tint(.primary)
        .frame(width: PaneMetrics.button, height: PaneMetrics.button)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("更多")
        .accessibilityIdentifier("tile-menu-\(id)")
    }
}

/// The header: the session's name only (its state is the drop's).
/// No background, no line: it is part of the conversation.
private struct PaneTitle: View {
    let id: String
    let corner: Bool
    @Environment(AppStore.self) private var store

    var body: some View {
        let name = id == LayoutTree.paloPane ? store.assistantName : store.singlePal(id: id)?.displayName ?? ""
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, PaneMetrics.titleLeading)
        .padding(.trailing, PaneMetrics.titleTrailing + (corner ? PaneMetrics.cornerShift : 0))
        .frame(height: PaneMetrics.headerHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tile-title-\(id)")
    }
}

/// The session's state as a glass icon (the indicator's inner part); opens
/// the pane's details. Waiting on the owner shows only in its color.
private struct PaneStatusButton: View {
    let id: String
    let details: TileDetails
    @Environment(AppStore.self) private var store

    var body: some View {
        let pal = store.singlePal(id: id)
        let dot = pal?.dot ?? .idle
        Button {
            details.tile = details.tile == id ? nil : id
        } label: {
            icon(dot: dot, running: pal?.tasksRunning ?? 0)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .popover(isPresented: details.binding(id)) {
            PaneDetail(id: id, details: details)
                .frame(minWidth: 360, idealWidth: 380, minHeight: 420, idealHeight: 560)
                .presentationCompactAdaptation(.sheet)
        }
        .accessibilityLabel(Text(verbatim: "\(pal?.displayName ?? "")，\(StatusDot.label(dot))"))
        .accessibilityIdentifier("tile-header-\(id)")
    }

    @ViewBuilder private func icon(dot: StatusDotKind, running: Int) -> some View {
        #if DEBUG || PERF_HARNESS
        // Perf measuring, `-paneIcon flat`: the state's flat dot, no drop
        // (each working drop costs about 7% of a core on the Mac, whether
        // hosted with its pane or in a graph of its own).
        if UserDefaults.standard.string(forKey: "paneIcon") == "flat" {
            StatusDot(dot, size: 20).frame(width: PaneMetrics.button, height: PaneMetrics.button)
        } else {
            drop(dot: dot, running: running)
        }
        #else
        drop(dot: dot, running: running)
        #endif
    }

    /// The session's live drop with its mark, bare (no glass circle, as
    /// the page title's SessionOrbDrop), centered where the glass icon was.
    private func drop(dot: StatusDotKind, running: Int) -> some View {
        SessionIndicator(state: dot, size: PaneMetrics.drop, running: running, voiceOwner: .some(id))
            .frame(width: PaneMetrics.button, height: PaneMetrics.button)
    }
}

/// The details the status icon opens: the session's own store.
private struct PaneDetail: View {
    let id: String
    let details: TileDetails
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        AgentDetailView()
            .environment(model)
            .environment(store.palStore(id))
            .environment(\.tileDetail, details.binding(id))
    }
}

/// ⋯: the pane's menu, a floating glass button that is always there. Its
/// first two entries split this pane (Bento Term's Split Right / Split
/// Down, ⌘D / ⌘⇧D for the active pane).
private struct PaneMenu: View {
    let id: String
    let workspaceID: String
    let actions: PaneActions
    @Environment(AppStore.self) private var store

    var body: some View {
        let online = store.connection.isOnline
        Menu {
            Menu("向右分出", systemImage: "rectangle.split.2x1") { choices(horizontal: true) }
                .disabled(!online)
            Menu("向下分出", systemImage: "rectangle.split.1x2") { choices(horizontal: false) }
                .disabled(!online)
            Divider()
            Button("右栏（成果 / 文件）", systemImage: "sidebar.trailing") { actions.openPane(id) }
            Button("单独打开", systemImage: "arrow.up.left.and.arrow.down.right") { actions.openAlone(id) }
            Button("重命名…", systemImage: "pencil") { actions.rename(id) }
                .disabled(!online)
            Button("移出工作区", systemImage: "rectangle.portrait.and.arrow.right") { actions.moveOut(id) }
                .disabled(!online)
            Divider()
            Button("结束会话…", systemImage: "stop.circle", role: .destructive) { actions.end(id) }
                .disabled(!online)
        } label: {
            // Frame, then the hit shape, then the glass: the whole circle takes the click.
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: PaneMetrics.button, height: PaneMetrics.button)
                .contentShape(.circle)
        }
        .macMenuHitArea()
        .menuIndicator(.hidden)
        .tint(.primary)
        .frame(width: PaneMetrics.button, height: PaneMetrics.button)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("更多")
        .accessibilityIdentifier("tile-menu-\(id)")
    }

    /// Palo (when it isn't a pane here yet), the sessions not in this workspace, then a new one.
    @ViewBuilder private func choices(horizontal: Bool) -> some View {
        PaneChoices(workspaceID: workspaceID, placement: PanePlacement(pane: id, horizontal: horizontal), actions: actions)
    }
}

/// What 向右分出 / 向下分出 offer: Palo first (when it isn't a pane here
/// yet), the sessions not in this workspace, then a new one.
private struct PaneChoices: View {
    let workspaceID: String
    let placement: PanePlacement
    let actions: PaneActions
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        if !model.showsPalo(in: workspaceID) {
            Button(store.assistantName) { actions.add(LayoutTree.paloPane, placement) }
        }
        let others = store.paneCandidates(for: workspaceID)
        if !others.isEmpty {
            Section("已有的会话") {
                ForEach(others) { pal in
                    Button(pal.displayName) { actions.add(pal.id, placement) }
                }
            }
        }
        Button("新开一个会话…", systemImage: "plus") { actions.addNew(placement) }
    }
}

extension AppStore {
    /// The sessions a split workspace can take as a new pane: the listed
    /// ones not already in it.
    func paneCandidates(for workspaceID: String) -> [Pal] {
        listedPals.filter { $0.workspaceId != workspaceID }
    }
}
