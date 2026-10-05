import PaloAllyKit
import SwiftUI

/// 「它」, the place left of the conversation: who it is, what it's helping
/// with over time (目标), what it's doing and got done (履历), and what it
/// remembers. Approvals have no tab: they're in the conversation.
struct AssistantView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                AssistantHeader()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Picker("分类", selection: $model.assistantTab) {
                    ForEach(AssistantTab.allCases, id: \.self) { tab in
                        Text(label(for: tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            switch model.assistantTab {
            case .watches: WatchesSection()
            case .history: HistorySection()
            case .memory: MemorySection()
            }
        }
        .navigationTitle(store.assistantName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $model.showIdentityEditor) {
            IdentityEditor(purpose: .edit).environment(model).environment(store)
        }
        .toolbar {
            // The trailing side faces the conversation (「对话 ›」 lives there).
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .tint(.primary)
                .accessibilityLabel("设置")
            }
        }
        .navigationDestination(isPresented: $model.showSettings) {
            SettingsView()
        }
        // Notification tap on a task opens its detail.
        .navigationDestination(item: $model.openTaskID) { id in
            TaskDetailView(taskID: id)
        }
        .animation(.snappy, value: model.assistantTab)
    }

    private func label(for tab: AssistantTab) -> String {
        switch tab {
        case .history:
            let n = store.tasks.filter(\.isActive).count
            return n > 0 ? "\(tab.title) \(n)" : tab.title
        default:
            return tab.title
        }
    }
}

private struct AssistantHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var confirmStop = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Button { model.showIdentityEditor = true } label: {
                VStack(spacing: 10) {
                    AssistantAvatar(theme: model.currentTheme, live: true, hostID: model.activeHostID, bleed: 1.3)
                        .frame(width: 96, height: 96)
                    Text(store.assistantName).font(.title2.bold()).foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(store.assistantName)，改名字和颜色")

            VStack(spacing: 4) {
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Small, and only while there's something to stop.
            if store.assistantWorking {
                Button {
                    confirmStop = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.caption2).foregroundStyle(.red)
                        Text("停下").font(.footnote.weight(.medium)).foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.fill.tertiary, in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(working || !store.connection.isOnline)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .animation(.snappy, value: store.assistantWorking)
        .confirmationDialog("让助理停下手上的事？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("停下", role: .destructive) {
                working = true
                Task { await run { try await store.stop() } }
            }
            Button("再想想", role: .cancel) {}
        } message: {
            Text("正在办的事会中断。之后你再说话，它照常工作。")
        }
    }

    private func run(_ op: () async throws -> Void) async {
        error = nil
        do { try await op() } catch { self.error = "没成功：\(Friendly.message(error))" }
        working = false
    }

    /// 「住在 X 上 · 认识你 N 天」 — where it lives and how long you've known each other.
    private var statusLine: String {
        let place = store.hostName.isEmpty ? (model.pairedHost?.hostLabel ?? "") : store.hostName
        var parts: [String] = []
        if !place.isEmpty { parts.append("住在「\(place)」上") }
        if !store.displayedConnection.isOnline {
            parts.append(Copy.connection(store.displayedConnection))
        } else if let met = store.status?.metAt, met > 0 {
            let days = max(1, Int(Date().timeIntervalSince(met.msDate) / 86_400) + 1)
            parts.append("认识你 \(days) 天")
        }
        return parts.joined(separator: " · ")
    }
}

#Preview {
    let model = AppModel.demo()
    NavigationStack { AssistantView() }
        .environment(model)
        .environment(model.store!)
}
