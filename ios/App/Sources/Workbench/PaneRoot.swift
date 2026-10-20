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
}

/// The pane's measures (docs/workbench-design/split-final.html).
enum PaneMetrics {
    /// The slim header: the name and what the session is doing.
    static let headerHeight: CGFloat = 24
    /// The glass status icon and the ⋯ button, floating half out of the header.
    static let button: CGFloat = 28
    static let buttonInset: CGFloat = 8
    static let buttonTop: CGFloat = 5
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
        PaneContent(id: id, workspaceID: workspaceID, details: details, actions: actions,
                    corner: bridge.cornerPane == id)
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
        content.appTheme(model.currentTheme)
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
            // The conversation scrolls under the header, softly faded at the top.
            .safeAreaBar(edge: .top, spacing: 0) { PaneTitle(id: id, corner: corner) }
            .overlay(alignment: .topLeading) {
                PaneStatusButton(id: id, details: details)
                    .padding(.leading, PaneMetrics.buttonInset)
                    .padding(.top, PaneMetrics.buttonTop)
            }
            .overlay(alignment: .topTrailing) {
                PaneMenu(id: id, actions: actions)
                    .padding(.trailing, PaneMetrics.buttonInset + (corner ? PaneMetrics.cornerShift : 0))
                    .padding(.top, PaneMetrics.buttonTop)
            }
            // Spoken to: the pane's edge glows softly with the voice.
            .overlay { TileVoiceGlow(owner: id, shape: Rectangle()) }
            .background(Color(uiColor: .systemBackground))
    }
}

/// The header: the name (semibold) and what the session is doing (gray).
/// No background, no line: it is part of the conversation.
private struct PaneTitle: View {
    let id: String
    let corner: Bool
    @Environment(AppStore.self) private var store

    var body: some View {
        let pal = store.singlePal(id: id)
        HStack(spacing: 8) {
            Text(pal?.displayName ?? "")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Text(pal.map { Copy.palSubtitle($0, waking: false) } ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
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
            SessionIndicator(state: dot, size: PaneMetrics.button, glass: true, running: running, voiceOwner: .some(id), innerOnly: true)
        }
        #else
        SessionIndicator(state: dot, size: PaneMetrics.button, glass: true, running: running, voiceOwner: .some(id), innerOnly: true)
        #endif
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

/// ⋯: the pane's menu, a floating glass button that is always there.
private struct PaneMenu: View {
    let id: String
    let actions: PaneActions
    @Environment(AppStore.self) private var store

    var body: some View {
        let online = store.connection.isOnline
        Menu {
            Button("右栏（成果 / 文件）", systemImage: "sidebar.trailing") { actions.openPane(id) }
            Button("单独打开", systemImage: "arrow.up.left.and.arrow.down.right") { actions.openAlone(id) }
            Button("重命名…", systemImage: "pencil") { actions.rename(id) }
                .disabled(!online)
            Button("移出工作区", systemImage: "rectangle.portrait.and.arrow.right") { actions.moveOut(id) }
                .disabled(!online)
            Divider()
            Button("关闭这格", systemImage: "xmark") { actions.closePane(id) }
                .disabled(!online)
            Button("结束会话…", systemImage: "stop.circle", role: .destructive) { actions.end(id) }
                .disabled(!online)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: PaneMetrics.button, height: PaneMetrics.button)
                .contentShape(.circle)
        }
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .tint(.primary)
        .frame(width: PaneMetrics.button, height: PaneMetrics.button)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("更多")
        .accessibilityIdentifier("tile-menu-\(id)")
    }
}
