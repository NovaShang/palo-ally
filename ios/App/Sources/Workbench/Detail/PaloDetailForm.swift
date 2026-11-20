import PaloAllyKit
import SwiftUI

/// Palo's details: 此刻 (docs/workbench-design/orb-panel.html). Who it is
/// and what it's doing (with 关于 ›), what waits on the owner (等你), what
/// runs now (在做), and at the bottom its model, thinking and context.
/// Everything long-term (名字和颜色, 语言, 目标和定时, 记忆, 历史任务, 停下)
/// lives on 关于 (AssistantView). No end row: Palo can't be ended.
struct PaloDetailForm: View {
    @Environment(\.tileDetail) private var tileDetail
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var failure: String?
    @State private var showAbout = false
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
                             onRename: {}, onBeginRename: { showAbout = true })
                    .detailBare()
                Button { showAbout = true } label: {
                    HStack {
                        Text(String(localized: "关于\(store.assistantName)")).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .tint(.primary)
                .accessibilityIdentifier("detail-about")
            }
            .listSectionSpacing(.compact)

            // 等你: the assistant's own items (its, a brief's, the computer's sessions').
            let mine = store.openPending(forPal: nil)
            if !mine.isEmpty {
                Section {
                    ForEach(mine) { item in
                        PendingRow(item: item, dismiss: { model.setDetail(false, tile: tileDetail) })
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    HStack {
                        Text(String(localized: "等你 · \(mine.count)"))
                        Spacer()
                        Button(String(localized: "从头过一遍")) {
                            model.setDetail(false, tile: tileDetail)
                            model.talk(about: mine[0], in: store)
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("detail-agenda")
                    }
                }
            }

            // 在做: what runs now.
            let running = store.tasks.filter(\.isActive).sorted { $0.updatedAt > $1.updatedAt }
            if !running.isEmpty {
                Section {
                    ForEach(running) { RunningHistoryRow(task: $0) }
                } header: {
                    Text(String(localized: "在做 · \(running.count)"))
                }
            }

            // At the bottom: model · thinking · context.
            Section {
                pickers
                DetailContextRow(percent: store.status?.contextPct, tokens: store.status?.contextTokens,
                                 window: store.status?.contextWindow)
            }
        }
        .navigationTitle("")
        .navigationDestination(isPresented: $showAbout) {
            AssistantView().modifier(InSidebarColumn())
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
