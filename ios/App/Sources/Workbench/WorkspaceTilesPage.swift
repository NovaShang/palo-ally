import PaloAllyKit
import SwiftUI

/// A workspace's page (workbench-prd §5.3): its sessions tiled on one canvas.
/// Each tile is the session's own page (`PalPage`, minus its chrome: the
/// tile's header is the title); the active tile has the theme-colored border
/// and gets the keyboard and the voice. The layout is kept on the computer.
struct WorkspaceTilesPage: View {
    let workspaceID: String
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    /// The tile whose details are open.
    @State private var detailTile: String?
    /// The tile asked to close (ending its session, after a confirm).
    @State private var closing: String?
    @State private var ending = false
    @State private var failure: String?
    /// The layout just kept, shown until the stored one catches up.
    @State private var pending: LayoutTree.Node?

    private var workspace: Workspace? { store.workspace(id: workspaceID) }
    private var title: String { workspace?.title(pals: store.pals) ?? "" }
    private var count: Int { workspace?.memberIds.count ?? 0 }

    var body: some View {
        Group {
            if let workspace, let tree = model.tree(of: workspace) {
                TiledWorkspaceView(
                    layout: pending ?? tree,
                    activeId: model.activeTile(in: workspaceID),
                    info: info,
                    onLayoutChange: { new, final in if final { save(new) } },
                    onActivate: { model.activate(tile: $0, in: workspaceID) },
                    onExpand: { model.openPal($0) },
                    onClose: { closing = $0 },
                    detailFor: $detailTile,
                    detail: detailView,
                    content: tile)
                    .padding(6)
            } else if workspace != nil {
                Text("这个工作区里没有会话了。")
                    .foregroundStyle(.secondary)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("这个工作区已经不在了。")
                    .foregroundStyle(.secondary)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { StatusBanner() }
        .overlay(alignment: .bottom) { closeConfirm }
        .animation(.snappy, value: closing)
        // ⌘⌥→ / ⌘⌥←: the next and the previous tile.
        .background { focusKeys }
        .navigationTitle(title)
        .navigationSubtitle(String(localized: "\(count) 个会话"))
        .modifier(WorkspaceBar(workspaceID: workspaceID, title: title, subtitle: String(localized: "\(count) 个会话")))
        .accessibilityIdentifier("workspace-page")
        .onChange(of: workspace == nil && store.workspacesSupported == true) { _, gone in
            if gone { model.showList() }
        }
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        }
    }

    // MARK: tiles

    private func info(_ id: String) -> TileInfo {
        guard let pal = store.pal(id: id) else { return TileInfo(name: "") }
        return TileInfo(name: pal.displayName, status: Copy.palSubtitle(pal, waking: false), dot: pal.dot)
    }

    private func detailBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { detailTile == id }, set: { detailTile = $0 ? id : (detailTile == id ? nil : detailTile) })
    }

    private func tile(_ id: String) -> some View {
        PalPage(palID: id, inTile: true)
            .environment(\.tile, TileContext(id: id, isActive: model.activeTile(in: workspaceID) == id))
            .environment(\.tileDetail, detailBinding(id))
            // Each session keeps its own unsent words, here and on its own page.
            .environment(\.chatDraft, Binding(get: { model.drafts[.pal(id)] ?? "" }, set: { model.drafts[.pal(id)] = $0 }))
            .environment(\.fileLinks, FileLinkContext(scope: .pal(id), resolver: .shared(for: store)))
            .environment(\.placesAsColumns, false)
    }

    private func detailView(_ id: String) -> AnyView {
        AnyView(
            AgentDetailView()
                .environment(model)
                .environment(store.palStore(id))
                .environment(\.tileDetail, detailBinding(id)))
    }

    // MARK: layout

    /// The tiling, as the owner left it, kept on the computer.
    private func save(_ tree: LayoutTree.Node) {
        guard let json = tree.json else { return }
        let id = workspaceID
        pending = tree
        Task {
            _ = try? await store.updateWorkspace(id: id, layout: json)
            pending = nil
        }
    }

    // MARK: focus

    @ViewBuilder private var focusKeys: some View {
        Group {
            Button("") { moveFocus(previous: false) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("") { moveFocus(previous: true) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func moveFocus(previous: Bool) {
        guard let workspace, let tree = model.tree(of: workspace), let active = model.activeTile(in: workspaceID),
              let next = LayoutTree.neighbor(of: active, previous: previous, in: tree) else { return }
        model.activate(tile: next, in: workspaceID)
    }

    // MARK: close

    @ViewBuilder private var closeConfirm: some View {
        if let id = closing, let pal = store.pal(id: id) {
            ConfirmPanel(title: Copy.spaced(String(localized: "结束「\(pal.displayName)」？")),
                         text: String(localized: "它会停下，进到「以前的」里，之后还能接着聊。"),
                         action: String(localized: "结束会话"), working: ending,
                         cancel: { closing = nil }, confirm: { end(id) })
                .padding(16)
                .frame(maxWidth: 440)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func end(_ id: String) {
        guard !ending else { return }
        ending = true
        let next = workspace.flatMap { model.tree(of: $0) }.flatMap { LayoutTree.focusAfterClosing(id, in: $0) }
        Task {
            defer { ending = false }
            do {
                try await store.endSession(id: id)
                closing = nil
                if model.activeTiles[workspaceID] == id || model.activeTiles[workspaceID] == nil, let next {
                    model.activate(tile: next, in: workspaceID)
                }
            } catch {
                closing = nil
                failure = Copy.error(error)
            }
        }
    }
}

/// The workspace's title, 并排 and (off the Mac) the right pane's button.
/// The Mac has no navigation bar: its window toolbar holds the pane's button
/// and a strip at the page's top holds the rest.
private struct WorkspaceBar: ViewModifier {
    let workspaceID: String
    let title: String
    let subtitle: String

    func body(content: Content) -> some View {
        if Platform.barInWindowToolbar {
            content.macPageTop(title, subtitle: subtitle, trailing: AnyView(TileMenu(workspaceID: workspaceID, glass: true)))
        } else {
            content.toolbar {
                ToolbarItem(placement: .topBarTrailing) { TileMenu(workspaceID: workspaceID, glass: false) }
                ToolbarItem(placement: .topBarTrailing) { PaneButton() }
            }
        }
    }
}

private struct PaneButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.togglePane() } label: { Image(systemName: "sidebar.trailing") }
            .tint(.primary)
            .accessibilityLabel("右侧栏")
            .accessibilityIdentifier("pane-toggle")
    }
}

/// 并排: one more tile, from the sessions that aren't in this workspace, or a new one.
private struct TileMenu: View {
    let workspaceID: String
    let glass: Bool
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var failure: String?

    private var others: [Pal] { store.listedPals.filter { $0.workspaceId != workspaceID } }

    var body: some View {
        Menu {
            if !others.isEmpty {
                Section("已有的会话") {
                    ForEach(others) { pal in
                        Button(pal.displayName) { add(pal.id) }
                    }
                }
            }
            Button("新开一个会话…", systemImage: "plus") {
                model.newSessionIntoWorkspace = workspaceID
                model.newSession = true
            }
        } label: {
            if glass {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
            } else {
                Image(systemName: "rectangle.split.2x1")
            }
        }
        .modifier(GlassMenuStyle(glass: glass))
        .disabled(!store.connection.isOnline)
        .tint(.primary)
        .accessibilityLabel("并排")
        .accessibilityIdentifier("workspace-tile")
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        }
    }

    private func add(_ id: String) {
        Task {
            do {
                try await store.moveSession(id, to: workspaceID)
                model.activate(tile: id, in: workspaceID)
            } catch {
                failure = Copy.error(error)
            }
        }
    }
}

private struct GlassMenuStyle: ViewModifier {
    let glass: Bool

    func body(content: Content) -> some View {
        if glass {
            content
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .frame(width: 32, height: 32)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
        }
    }
}
