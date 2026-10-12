import PaloAllyKit
import SwiftUI

/// Management's 切换助理 (only with several paired computers): each
/// assistant with what waits on it, then 添加 / 管理.
struct HostsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hasSeveralHosts {
            Section {
                ForEach(model.switcherOrder, id: \.self) { id in
                    Button {
                        withAnimation(.snappy) { model.switchTo(id) }
                        model.closeManagement()
                    } label: {
                        HostSwitcherRow(id: id)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                }
                HStack(spacing: 18) {
                    if model.mode == .paired {
                        Button {
                            model.startPairing(.add)
                        } label: {
                            Label("添加一台电脑", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                    Spacer(minLength: 0)
                    Button("管理") {
                        model.showSettings = true
                        model.showHostList = true
                    }
                    .buttonStyle(.borderless)
                }
                .font(.callout)
                .tint(.primary)
            } header: {
                Text("切换助理")
            }
        }
    }
}

/// 「模型  Opus 5.5 · 思考：中 ›」 for the current assistant; opens the picker.
struct ModelRow: View {
    @Environment(AppStore.self) private var store
    let open: () -> Void

    var body: some View {
        let value = store.modelLine
        Button(action: open) {
            HStack(spacing: 6) {
                Text("模型")
                Spacer(minLength: 12)
                Text(value.isEmpty ? "默认" : value).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .task { try? await store.loadModels() }
        .accessibilityLabel("模型：\(value.isEmpty ? "默认" : value)，点一下更换")
    }
}

private struct HostSwitcherRow: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let store = model.stores[id]
        let current = id == model.activeHostID
        let unread = model.unreadCount(id)
        let pending = model.pendingCount(id)
        HStack(spacing: 12) {
            AssistantAvatar(theme: model.theme(for: id), bleed: 1.3)
                .frame(width: 30, height: 30)
                .overlay(alignment: .bottomTrailing) {
                    if current {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .primary)
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                // Named assistants go by their name; the computer and its state below.
                let named = !(store?.settings?.assistantName.isEmpty ?? true)
                Text(named ? store!.assistantName : model.displayName(id))
                    .font(.body.weight(current ? .semibold : .regular)).lineLimit(1)
                Text(named ? "\(model.displayName(id)) · \(state(store))" : state(store))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if pending > 0 {
                Text("\(pending) 件待确认")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.red, in: .capsule)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(current ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func state(_ store: AppStore?) -> String {
        guard let store else { return "没连上" }
        // As the owner is shown it: a short drop on returning to the app isn't news.
        if store.displayedConnection.isOnline {
            if store.isBusy { return "正在忙…" }
            return model.mode == .demo ? "演示中" : "在线"
        }
        return Copy.connection(store.displayedConnection)
    }
}
