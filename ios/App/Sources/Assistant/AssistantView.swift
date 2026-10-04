import PaloAllyKit
import SwiftUI

/// The "inner layer": what the assistant is doing, what it's waiting on,
/// what it watches, and what it remembers.
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
            case .tasks: TasksSection()
            case .approvals: ApprovalsSection()
            case .watches: WatchesSection()
            case .memory: MemorySection()
            }
        }
        .navigationTitle("助理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
        }
        .navigationDestination(isPresented: $model.showSettings) {
            SettingsView()
        }
        .animation(.snappy, value: model.assistantTab)
    }

    private func label(for tab: AssistantTab) -> String {
        switch tab {
        case .approvals:
            let n = store.pendingApprovals.count
            return n > 0 ? "\(tab.title) \(n)" : tab.title
        case .tasks:
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

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 76, height: 76)
                .glassEffect(.regular.tint(.accentColor.opacity(0.18)), in: .circle)

            VStack(spacing: 4) {
                Text("PaloAlly").font(.title2.bold())
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if store.isKilled {
                Button {
                    working = true
                    Task { try? await store.resume(); working = false }
                } label: {
                    Label("继续工作", systemImage: "play.fill")
                        .frame(maxWidth: 240)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(working || !store.connection.isOnline)
            } else {
                Button(role: .destructive) {
                    confirmStop = true
                } label: {
                    Label("全部停下", systemImage: "stop.fill")
                        .frame(maxWidth: 240)
                }
                .buttonStyle(.glass)
                .tint(.red)
                .controlSize(.large)
                .disabled(working || !store.connection.isOnline)
                .confirmationDialog("让助理马上全部停下？", isPresented: $confirmStop, titleVisibility: .visible) {
                    Button("全部停下", role: .destructive) {
                        working = true
                        Task { try? await store.kill(); working = false }
                    }
                    Button("再想想", role: .cancel) {}
                } message: {
                    Text("正在办的事会中断，之后它什么都不会做，直到你让它继续。")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var statusLine: String {
        let place = store.hostName.isEmpty ? (model.pairedHost?.hostLabel ?? "") : store.hostName
        let base = place.isEmpty ? "" : "住在「\(place)」上 · "
        if !store.connection.isOnline { return base + Copy.connection(store.connection) }
        if store.isKilled { return base + "已暂停" }
        let active = store.tasks.filter(\.isActive).count
        return base + (active > 0 ? "正在办 \(active) 件事" : "空闲中")
    }
}

#Preview {
    let model = AppModel.demo()
    NavigationStack { AssistantView() }
        .environment(model)
        .environment(model.store!)
}
