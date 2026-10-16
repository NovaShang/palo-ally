import PaloAllyKit
import SwiftUI

/// The assistant's management, behind the orb in its conversation's title
/// (pals-prd §2.3): who it is, the model, what it's helping with over time
/// (目标), what it's doing and got done (履历), what it remembers, and 设置.
/// Phones push it over the conversation; large screens show it as a sheet
/// (`inSheet`, with 完成). Approvals have no tab: they're in the conversation.
struct AssistantView: View {
    /// Shown as a sheet (large screens): it closes with 完成.
    var inSheet = false
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
                ModelRow { model.showModelPicker = true }
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
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
        .accessibilityIdentifier("management")
        .sheet(isPresented: $model.showIdentityEditor) {
            IdentityEditor(purpose: .edit).environment(model).environment(store)
        }
        .sheet(isPresented: $model.showModelPicker) {
            ModelPickerSheet().environment(model).environment(store)
        }
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { model.showManagement = false }
                        .tint(.primary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
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
            SettingsView().modifier(InSidebarColumn())
        }
        // A task opened from the conversation (large screens) or a notification.
        .navigationDestination(item: $model.openTaskID) { id in
            TaskDetailView(taskID: id).modifier(InSidebarColumn())
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
    #if DEBUG
    @State private var showGlassDemo = false
    #endif

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
            #if DEBUG
            // Hidden: long-press opens the system-glass comparison sample.
            .contextMenu {
                Button("玻璃两滴样片", systemImage: "drop.halffull") { showGlassDemo = true }
            }
            .fullScreenCover(isPresented: $showGlassDemo) {
                GlassDropsDemo(theme: model.currentTheme) { showGlassDemo = false }
                    .environment(model)
            }
            #endif

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
        do { try await op() } catch { self.error = String(localized: "没成功：\(Friendly.message(error))") }
        working = false
    }

    /// 「住在 X 上 · 认识你 N 天」 — where it lives and how long you've known each other.
    private var statusLine: String {
        let place = store.hostName.isEmpty ? (model.pairedHost?.hostLabel ?? "") : store.hostName
        var parts: [String] = []
        if !place.isEmpty { parts.append(String(localized: "住在「\(place)」上")) }
        if !store.displayedConnection.isOnline {
            parts.append(Copy.connection(store.displayedConnection))
        } else if let met = store.status?.metAt, met > 0 {
            let days = max(1, Int(Date().timeIntervalSince(met.msDate) / 86_400) + 1)
            parts.append(String(localized: "认识你 \(days) 天"))
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

/// A page pushed inside management. On the Mac: no sidebar toggle, and the
/// grouped background rather than the Mac form's lighter gray.
struct InSidebarColumn: ViewModifier {
    func body(content: Content) -> some View {
        if Platform.barInWindowToolbar {
            content
                .toolbar(removing: .sidebarToggle)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
        } else {
            content
        }
    }
}
