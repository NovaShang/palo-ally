import PaloAllyKit
import SwiftUI

/// 设置 → 我的助理: every paired computer, each an independent assistant.
/// Rename, pick its color, reorder, unpair, or add another computer.
struct HostsView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: String?
    @State private var newName = ""
    @State private var confirmUnpair: String?
    @State private var unpairing: String?

    var body: some View {
        List {
            Section {
                ForEach(model.hostIDs, id: \.self) { id in
                    row(id)
                        .swipeActions {
                            if model.mode == .paired {
                                Button("解除配对", role: .destructive) { confirmUnpair = id }
                            }
                        }
                }
                .onMove { model.moveHosts(from: $0, to: $1) }
            } footer: {
                Text("每台电脑上是一个独立的助理：各自的对话、记忆和任务。点对话顶部的名字切换。")
            }

            Section {
                if model.mode == .paired {
                    Button {
                        model.showPairingSheet = true
                    } label: {
                        Label("添加一台电脑", systemImage: "plus")
                    }
                } else {
                    Button("退出演示，去配对") { model.exitDemo() }
                }
            }
            .tint(.primary)
        }
        .navigationTitle("我的助理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.hostIDs.count > 1 { EditButton().tint(.primary) }
        }
        .alert("改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newName)
            Button("好") {
                if let id = renaming { model.rename(id, to: newName) }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        } message: {
            Text("只改这台设备上看到的名字，比如「家里 Mac」「云端」。留空就用电脑自己的名字。")
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmUnpair != nil }, set: { if !$0 { confirmUnpair = nil } }),
                            titleVisibility: .visible) {
            Button("解除配对", role: .destructive) {
                guard let id = confirmUnpair else { return }
                unpairing = id
                Task {
                    await model.unpair(id)
                    unpairing = nil
                }
            }
        } message: {
            Text("之后要重新扫码才能连回来。这台电脑上的对话和记忆不受影响。")
        }
    }

    private var confirmTitle: String {
        "解除和「\(confirmUnpair.map(model.displayName) ?? "")」的配对？"
    }

    private func row(_ id: String) -> some View {
        let store = model.stores[id]
        let current = id == model.activeHostID
        return HStack(spacing: 12) {
            Circle()
                .fill(model.theme(for: id).color.gradient)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.displayName(id)).font(.body.weight(current ? .semibold : .regular))
                    if current {
                        Text("当前").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(detail(store)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if unpairing == id {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    if !current {
                        Button("切换到这个助理", systemImage: "arrow.left.arrow.right") { model.switchTo(id) }
                    }
                    Button("改名", systemImage: "pencil") {
                        newName = model.displayName(id)
                        renaming = id
                    }
                    Picker(selection: Binding(get: { model.theme(for: id) }, set: { model.setTheme($0, for: id) })) {
                        ForEach(AppTheme.allCases) { t in Text(t.name).tag(t) }
                    } label: {
                        Label("颜色", systemImage: "paintpalette")
                    }
                    .pickerStyle(.menu)
                    if model.mode == .paired {
                        Divider()
                        Button("解除配对", systemImage: "link.badge.minus", role: .destructive) { confirmUnpair = id }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .tint(.secondary) // a menu tints its label with the accent otherwise
                .accessibilityLabel("\(model.displayName(id)) 的选项")
            }
        }
        .padding(.vertical, 2)
    }

    private func detail(_ store: AppStore?) -> String {
        var parts: [String] = []
        if let store {
            parts.append(store.connection.isOnline ? (model.mode == .demo ? "演示中" : "在线") : Copy.connection(store.connection))
            if store.status?.wechat == .connected { parts.append("微信已接入") }
            else if store.status?.wechat == .expired { parts.append("微信需要重新登录") }
        } else {
            parts.append("没连上")
        }
        return parts.joined(separator: " · ")
    }
}
