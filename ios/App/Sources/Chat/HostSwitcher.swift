import PaloAllyKit
import SwiftUI

/// The card behind the title bar's orb: what it's doing right now (and 停下
/// while it works), the things running in the background (tap one for its
/// detail), the model and thinking depth (the one place to change them),
/// and — only with several paired computers — the assistants to switch
/// between, with 添加 / 管理. With one computer and nothing running it's the
/// status line and the model.
struct StatusCard: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    /// 停下 asks once more in place (no dialog inside a popover).
    @State private var confirmingStop = false
    @State private var stopping = false
    @State private var error: String?

    /// Waiting on the owner first, then the most recently updated.
    private var activeTasks: [AllyTask] {
        store.tasks.filter(\.isActive).sorted {
            if ($0.status == .needsInput) != ($1.status == .needsInput) { return $0.status == .needsInput }
            return $0.updatedAt > $1.updatedAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if !activeTasks.isEmpty {
                Divider().padding(.vertical, 6)
                ForEach(activeTasks.prefix(5)) { task in
                    Button { open { model.openTask(task.id) } } label: { RunningTaskRow(task: task) }
                        .buttonStyle(.plain)
                }
                if activeTasks.count > 5 {
                    Text("还有 \(activeTasks.count - 5) 件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
            }
            Divider().padding(.vertical, 6)
            ModelRow { open { model.showModelPicker = true } }
            // Most people have one computer: then there's nothing to switch.
            if model.hasSeveralHosts {
                Divider().padding(.vertical, 6)
                Text("切换助理")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)
                ForEach(model.switcherOrder, id: \.self) { id in
                    Button {
                        model.showHostSwitcher = false
                        withAnimation(.snappy) { model.switchTo(id) }
                    } label: {
                        HostSwitcherRow(id: id)
                    }
                    .buttonStyle(.plain)
                }
                manageRow.padding(.top, 4)
            }
        }
        .padding(8)
        .frame(width: 320)
        .animation(.snappy, value: store.isBusy)
    }

    /// Closes the card, then does what was picked once it has gone (a sheet
    /// or a slide shouldn't start under a closing popover).
    private func open(_ then: @escaping @MainActor () -> Void) {
        model.showHostSwitcher = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            then()
        }
    }

    private var header: some View {
        let line = store.agentStatusLine
        return HStack(spacing: 12) {
            AssistantAvatar(theme: model.currentTheme, live: true, hostID: model.activeHostID, bleed: 1.3)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.assistantName).font(.headline).lineLimit(1)
                Text(line.text)
                    .font(.subheadline)
                    .foregroundStyle(line.kind == .needsYou ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .contentTransition(.opacity)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if store.isBusy { stopButton }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var stopButton: some View {
        Button {
            guard confirmingStop else {
                confirmingStop = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    confirmingStop = false
                }
                return
            }
            stopping = true
            error = nil
            Task { @MainActor in
                do { try await store.stop() } catch { self.error = "没停下：\(Friendly.message(error))" }
                stopping = false
                confirmingStop = false
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill").font(.caption2).foregroundStyle(.red)
                Text(confirmingStop ? "确定停下？" : "停下").font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.fill.tertiary, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(stopping || !store.connection.isOnline)
        .accessibilityHint("正在办的事会中断")
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

/// 「模型  Opus 5.5 · 思考：中 ›」 for the current assistant; opens the picker.
private struct ModelRow: View {
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
