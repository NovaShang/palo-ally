import PaloAllyKit
import SwiftUI

/// Palo's details: the session's skeleton (header, model and depth, context,
/// its tasks then 历史任务) plus 目标, 记忆 and 设置.
/// No end row: Palo can't be ended. No 压缩: the host has no compact method
/// for the assistant, only its own idle compaction.
struct PaloDetailForm: View {
    @Environment(\.tileDetail) private var tileDetail
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var memoryCount: Int?
    @State private var failure: String?
    @State private var showSettings = false
    @State private var showIdentity = false
    @State private var noRename = false
    @State private var unused = ""

    private var online: Bool { store.connection.isOnline }
    private var waiting: [Pal] { store.pals.filter { $0.attention == .waiting } }
    private var info: ModelInfo? { store.modelInfo }

    var body: some View {
        List {
            if let failure {
                Section { Text(Copy.spaced(failure)).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                DetailHeader(indicator: AnyView(TitleOrbDrop(size: 46)),
                             name: store.assistantName,
                             caption: String(localized: "你的助理"),
                             line: headerLine, state: store.paloDot,
                             lineAction: store.paloDot == .waiting && !waiting.isEmpty ? { jumpToWaiting() } : nil,
                             editing: $noRename, draft: $unused,
                             onRename: {}, onBeginRename: { showIdentity = true })
                    .detailBare()
            }
            .listSectionSpacing(.compact)

            Section {
                pickers
                DetailContextRow(percent: store.status?.contextPct, tokens: store.status?.contextTokens,
                                 window: store.status?.contextWindow)
            }

            let running = store.tasks.filter(\.isActive).sorted { $0.updatedAt > $1.updatedAt }
            Section {
                ForEach(running) { RunningHistoryRow(task: $0) }
                NavigationLink { page(String(localized: "历史任务")) { HistorySection() } } label: {
                    Text("历史任务")
                }
                .accessibilityIdentifier("detail-past-tasks")
            } header: {
                detailTasksHeader(running: running.count)
            }

            Section {
                NavigationLink { page(AssistantTab.watches.title) { WatchesSection() } } label: {
                    LabeledContent(AssistantTab.watches.title, value: goalsLine)
                }
                NavigationLink { page(AssistantTab.memory.title) { MemorySection() } } label: {
                    LabeledContent(AssistantTab.memory.title,
                                   value: memoryCount.map { $0 > 0 ? String(localized: "\($0) 条") : String(localized: "还没记下什么") } ?? "…")
                }
            }

            Section {
                Button { showSettings = true } label: {
                    HStack {
                        Text("设置").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .accessibilityIdentifier("detail-settings")
            }
        }
        .navigationTitle("")
        .navigationDestination(isPresented: $showSettings) {
            SettingsView().modifier(InSidebarColumn())
        }
        .sheet(isPresented: $showIdentity) {
            IdentityEditor(purpose: .edit).environment(model).environment(store)
        }
        .task(id: model.memoryRevision) {
            memoryCount = (try? await store.memoryFiles())?.count
        }
        .task(id: online) {
            guard online, store.modelInfo == nil else { return }
            try? await store.loadModels()
        }
    }

    // MARK: pieces

    /// 模型 and 思考深度: the system's pickers (a menu each).
    @ViewBuilder private var pickers: some View {
        let models = info?.models ?? []
        let selected = info?.setting ?? models.first?.value ?? "default"
        let efforts = models.first { $0.value == selected }?.efforts ?? []
        Picker("模型", selection: Binding(get: { selected }, set: { m in
            apply(model: m == models.first?.value ? .some(nil) : .some(m))
        })) {
            if models.isEmpty { Text(ModelName.short(store.status?.model ?? "")).tag(selected) }
            ForEach(models) { Text($0.displayName).tag($0.value) }
        }
        .pickerStyle(.menu)
        .detailNeutral()
        .disabled(!online || models.isEmpty)
        .accessibilityIdentifier("detail-model")
        if !efforts.isEmpty {
            Picker("思考深度", selection: Binding(get: { store.status?.effort ?? "" },
                                                set: { apply(effort: .some($0.isEmpty ? nil : $0)) })) {
                Text("默认").tag("")
                ForEach(efforts, id: \.self) { Text(EffortName.label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .detailNeutral()
            .disabled(!online)
            .accessibilityIdentifier("detail-effort")
        }
    }

    private var headerLine: String {
        switch store.paloDot {
        case .working: return store.status?.activity ?? StatusDot.label(.working)
        case .waiting: return waiting.isEmpty ? StatusDot.label(.waiting) : String(localized: "\(waiting.count) 个会话在等你")
        default: return String(localized: "在等你吩咐")
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

    private func apply(model: String?? = .none, effort: String?? = .none) {
        failure = nil
        Task {
            do { try await store.setModel(model, effort: effort) } catch { failure = Copy.error(error) }
        }
    }

    private func jumpToWaiting() {
        guard let first = waiting.first else { return }
        model.setDetail(false, tile: tileDetail)
        model.open(.pal(first.id))
    }
}
