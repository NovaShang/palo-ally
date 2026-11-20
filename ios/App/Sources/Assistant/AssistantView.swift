import PaloAllyKit
import SwiftUI

/// 关于 the assistant (docs/workbench-design/orb-panel.html): the long-term
/// half of what its orb used to hold, and the old 助理管理 in one page. Who
/// it is (name and color, the language it speaks), what it watches for you
/// (目标和定时), what it remembers and has done (记忆, 历史任务), how it works
/// (the default model and thinking), and 停下 in its header. What happens
/// now is the orb's panel (此刻); app-only settings stay in 设置.
/// Phones push it; large screens show it as a sheet (`inSheet`, with 完成).
struct AssistantView: View {
    /// Shown as a sheet (large screens): it closes with 完成.
    var inSheet = false
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var memoryCount: Int?
    @State private var error: String?

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                AssistantHeader()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            // 它: its color (the app's too) and the language it speaks.
            Section {
                ThemeSwatches(selection: themeBinding)
                Picker("说话用的语言", selection: languageBinding) {
                    Text("自动").tag("")
                    Text(verbatim: "中文").tag("zh")
                    Text(verbatim: "English").tag("en")
                }
                .tint(.primary)
                .disabled(!store.connection.isOnline || store.settings == nil)
            } header: {
                Text("它")
            } footer: {
                Text("颜色也是 App 和桌面图标的颜色。语言和手机的系统语言分开；自动：按第一台连上电脑的设备的语言。")
            }

            // 它在帮你盯的, 它记得的、做过的.
            Section {
                NavigationLink { page(AssistantTab.watches.title) { WatchesSection() } } label: {
                    LabeledContent(String(localized: "目标和定时"), value: goalsLine)
                }
                .accessibilityIdentifier("about-watches")
                NavigationLink { page(AssistantTab.memory.title) { MemorySection() } } label: {
                    LabeledContent(AssistantTab.memory.title,
                                   value: memoryCount.map { $0 > 0 ? String(localized: "\($0) 条") : String(localized: "还没记下什么") } ?? "…")
                }
                .accessibilityIdentifier("about-memory")
                Button { model.showHistoryPage = true } label: {
                    HStack {
                        Text(AssistantTab.history.title).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .tint(.primary)
                .accessibilityIdentifier("about-history")
            }

            // 怎么工作: the default model and thinking.
            Section {
                ModelRow { model.showModelPicker = true }
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
            } header: {
                Text("怎么工作")
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle(String(localized: "关于\(store.assistantName)"))
        .navigationDestination(isPresented: $model.showHistoryPage) {
            page(AssistantTab.history.title) { HistorySection() }
        }
        .task(id: model.memoryRevision) {
            memoryCount = (try? await store.memoryFiles())?.count
        }
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
    }

    private var goalsLine: String {
        let n = store.watches.filter { $0.state != .done }.count
        return n > 0 ? String(localized: "\(n) 个") : String(localized: "还没有目标")
    }

    private func page<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        List { content() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(InSidebarColumn())
    }

    private var languageBinding: Binding<String> {
        Binding(get: { store.settings?.language ?? "" }, set: { lang in
            error = nil
            Task {
                do { try await store.updateSettings(patch: ["language": .string(lang)]) } catch {
                    self.error = String(localized: "没改成：\(Copy.error(error))")
                }
            }
        })
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(get: { model.currentTheme }, set: { t in
            guard let id = model.activeHostID else { return }
            error = nil
            Task {
                do { try await model.setTheme(t, for: id) } catch { self.error = String(localized: "颜色没改成：\(Copy.error(error))") }
            }
        })
    }
}

private struct AssistantHeader: View {
    @Environment(WindowModel.self) private var model
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
                        .contentShape(.circle) // drawn apart, it takes no clicks itself
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
    let model = WindowModel.demo()
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
