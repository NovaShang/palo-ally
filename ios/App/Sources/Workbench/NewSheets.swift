import PaloAllyKit
import SwiftUI

/// 新建工作区: a name (optional) and the sessions to put in it. The host
/// wants at least one.
struct NewWorkspaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var chosen: Set<String>
    @State private var working = false
    @State private var failure: String?

    init(preselected: [String] = []) { _chosen = State(initialValue: Set(preselected)) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("名字（可以不填）", text: $name)
                        .accessibilityIdentifier("new-workspace-name")
                }
                Section {
                    ForEach(store.listedPals) { pal in
                        Button {
                            if chosen.contains(pal.id) { chosen.remove(pal.id) } else { chosen.insert(pal.id) }
                        } label: {
                            HStack(spacing: 10) {
                                StatusDot(pal)
                                Text(pal.displayName).foregroundStyle(.primary).lineLimit(1)
                                Spacer(minLength: 4)
                                if chosen.contains(pal.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.primary)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .tint(.primary)
                        .accessibilityAddTraits(chosen.contains(pal.id) ? .isSelected : [])
                    }
                } header: {
                    Text("放进去的会话")
                } footer: {
                    if let failure {
                        Text(Copy.spaced(failure)).foregroundStyle(.red)
                    } else if store.pals.isEmpty {
                        Text("先新建一个会话，再把它放进工作区。")
                    }
                }
            }
            .navigationTitle("新建工作区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { create() }
                        .disabled(chosen.isEmpty || working || !store.connection.isOnline)
                        .accessibilityIdentifier("new-workspace-create")
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 420, minHeight: 420)
        #endif
        .accessibilityIdentifier("new-workspace")
    }

    private func create() {
        working = true
        failure = nil
        let ids = store.listedPals.map(\.id).filter(chosen.contains)
        Task {
            defer { working = false }
            do {
                let w = try await store.createWorkspace(name: name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, memberIds: ids)
                dismiss()
                model.openWorkspace(w.id)
            } catch {
                failure = Copy.error(error)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A workspace picked in the list. The tiled view comes in a later phase;
/// for now its sessions, each one a tap away.
struct WorkspacePage: View {
    let workspaceID: String
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        let node = store.sidebarTree.workspaces.first { $0.id == workspaceID }
        List {
            if let node {
                Section {
                    ForEach(node.members) { pal in
                        Button {
                            model.openPal(pal.id)
                        } label: {
                            HStack(spacing: 10) {
                                StatusDot(pal)
                                Text(pal.displayName).foregroundStyle(.primary).lineLimit(1)
                                Spacer(minLength: 4)
                                WaitingBadge(count: store.palPendingCount(pal.id))
                            }
                            .contentShape(.rect)
                        }
                        .tint(.primary)
                    }
                } footer: {
                    Text("并排平铺会在之后的版本里加入。")
                }
            }
        }
        .overlay {
            if node == nil {
                Text("这个工作区已经不在了。")
                    .foregroundStyle(.secondary)
                    .padding(32)
            }
        }
        .navigationTitle(node?.title ?? "")
        .accessibilityIdentifier("workspace-page")
        .onChange(of: node == nil && store.workspacesSupported == true) { _, gone in
            if gone { model.showList() }
        }
    }
}
