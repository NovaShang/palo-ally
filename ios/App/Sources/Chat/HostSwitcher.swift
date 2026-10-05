import PaloAllyKit
import SwiftUI

/// The popover behind the title capsule (the agent's status): what's being
/// done right now (running tasks, those waiting on the owner first; tap one
/// for its detail), then — with several paired computers — the assistants
/// (color, name, state, unread, pending approvals), then the model and
/// thinking depth (the one place to change them), and 添加 / 管理 for 2+.
/// With one computer and nothing running it's only the model.
struct HostSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    /// Opens the model picker (presented by the chat screen, not the popover).
    let openModelPicker: () -> Void
    /// Opens a task's detail.
    let openTask: (String) -> Void

    /// Waiting on the owner first, then the most recently updated.
    private var activeTasks: [AllyTask] {
        store.tasks.filter(\.isActive).sorted {
            if ($0.status == .needsInput) != ($1.status == .needsInput) { return $0.status == .needsInput }
            return $0.updatedAt > $1.updatedAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !activeTasks.isEmpty {
                ForEach(activeTasks.prefix(5)) { task in
                    Button {
                        model.showHostSwitcher = false
                        openTask(task.id)
                    } label: {
                        RunningTaskRow(task: task)
                    }
                    .buttonStyle(.plain)
                }
                if activeTasks.count > 5 {
                    Text("还有 \(activeTasks.count - 5) 件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                Divider().padding(.vertical, 6)
            }
            if model.hasSeveralHosts {
                ForEach(model.switcherOrder, id: \.self) { id in
                    Button {
                        model.showHostSwitcher = false
                        withAnimation(.snappy) { model.switchTo(id) }
                    } label: {
                        HostSwitcherRow(id: id)
                    }
                    .buttonStyle(.plain)
                }
                Divider().padding(.vertical, 6)
            }
            ModelRows(open: {
                model.showHostSwitcher = false
                openModelPicker()
            })
            // Most people have one computer: then this is just the model.
            if model.hasSeveralHosts {
                Divider().padding(.vertical, 6)
                manageRow
            }
        }
        .padding(8)
        .frame(width: 300)
    }

    private var manageRow: some View {
            HStack(spacing: 18) {
                if model.mode == .paired {
                    Button {
                        model.showHostSwitcher = false
                        model.startPairing(.add)
                    } label: {
                        Label("添加一台电脑", systemImage: "plus")
                    }
                }
                Spacer(minLength: 0)
                Button {
                    model.showHostSwitcher = false
                    model.showAssistant = true
                    model.showSettings = true
                    model.showHostList = true
                } label: {
                    Text("管理")
                }
            }
            .font(.callout)
            .tint(.primary)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
    }
}

/// 「模型  Opus 5.5 ›」 and 「思考  中 ›」 for the current assistant; either
/// opens the picker. The thinking row only shows when the model has levels.
private struct ModelRows: View {
    @Environment(AppStore.self) private var store
    let open: () -> Void

    private var efforts: [String] {
        guard let info = store.modelInfo else { return [] }
        let selected = info.setting ?? info.models.first?.value
        return info.models.first(where: { $0.value == selected })?.efforts ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            row("模型", ModelName.short(store.status?.model ?? store.modelInfo?.model ?? ""))
            if !efforts.isEmpty || store.status?.effort != nil {
                row("思考", EffortName.label(store.status?.effort))
            }
        }
        .task { try? await store.loadModels() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Text(title)
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
        .accessibilityLabel("\(title)：\(value.isEmpty ? "默认" : value)，点一下更换")
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
            Circle()
                .fill(model.theme(for: id).color.gradient)
                .frame(width: 26, height: 26)
                .overlay {
                    if current {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName(id)).font(.body.weight(current ? .semibold : .regular)).lineLimit(1)
                Text(state(store)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        if store.connection.isOnline {
            if store.isBusy { return "正在忙…" }
            return model.mode == .demo ? "演示中" : "在线"
        }
        return Copy.connection(store.connection)
    }
}

/// One thing the agent is doing: status icon, title, the latest progress line.
private struct RunningTaskRow: View {
    let task: AllyTask

    var body: some View {
        let (symbol, color) = Copy.taskSymbol(task.status)
        let line = task.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(task.status == .needsInput && line.isEmpty ? "需要你" : (line.isEmpty ? "刚开始" : line))
                    .font(.caption)
                    .foregroundStyle(task.status == .needsInput ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("看详情")
    }
}
