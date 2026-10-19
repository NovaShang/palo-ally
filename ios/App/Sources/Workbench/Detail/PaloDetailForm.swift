import PaloAllyKit
import SwiftUI

/// Palo's details: the session skeleton (header, big actions, model) plus
/// 它在替你做的事 (目标 / 履历 / 记忆, each pushing the existing section).
/// No end row: Palo can't be ended. The store has no context numbers for the
/// assistant, so there is no 上下文 group here.
struct PaloDetailForm: View {
    @Environment(\.tileDetail) private var tileDetail
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var memoryCount: Int?
    @State private var confirmStop = false
    @State private var failure: String?
    @State private var showSettings = false
    @State private var showIdentity = false
    @State private var showModels = false
    @State private var noRename = false
    @State private var unused = ""

    private var online: Bool { store.connection.isOnline }
    private var waiting: [Pal] { store.pals.filter { $0.attention == .waiting } }

    var body: some View {
        List {
            if let failure {
                Section { Text(Copy.spaced(failure)).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                DetailHeader(indicator: AnyView(SessionIndicator(palo: store.status, contextPct: nil, size: 68)),
                             name: store.assistantName,
                             folder: nil,
                             line: headerLine,
                             lineAction: waiting.isEmpty || store.assistantWorking ? nil : { jumpToWaiting() },
                             editing: $noRename, draft: $unused,
                             onRename: {}, onBeginRename: { showIdentity = true })
                    .detailBare()
                DetailActionRow(actions: actions).detailBare()
            }
            .listSectionSpacing(.compact)

            Section {
                ModelRow { showModels = true }
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
            } header: {
                Text("模型")
            }

            Section("它在替你做的事") {
                NavigationLink { page(.watches) } label: {
                    LabeledContent(AssistantTab.watches.title, value: goalsLine)
                }
                NavigationLink { page(.history) } label: {
                    LabeledContent(AssistantTab.history.title, value: historyLine)
                }
                NavigationLink { page(.memory) } label: {
                    LabeledContent(AssistantTab.memory.title,
                                   value: memoryCount.map { $0 > 0 ? String(localized: "\($0) 条") : String(localized: "还没记下什么") } ?? "…")
                }
            }
        }
        .navigationDestination(isPresented: $showSettings) {
            SettingsView().modifier(InSidebarColumn())
        }
        .sheet(isPresented: $showModels) {
            ModelPickerSheet().environment(model).environment(store)
        }
        .sheet(isPresented: $showIdentity) {
            IdentityEditor(purpose: .edit).environment(model).environment(store)
        }
        .confirmationDialog("让助理停下手上的事？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("停下", role: .destructive) {
                Task { do { try await store.stop() } catch { failure = Copy.error(error) } }
            }
            Button("再想想", role: .cancel) {}
        } message: {
            Text("正在办的事会中断。之后你再说话，它照常工作。")
        }
        .task(id: model.memoryRevision) {
            memoryCount = (try? await store.memoryFiles())?.count
        }
    }

    // MARK: pieces

    private var headerLine: String {
        if store.assistantWorking { return store.status?.activity ?? StatusDot.label(.working) }
        if !waiting.isEmpty { return String(localized: "\(waiting.count) 个会话在等你") }
        return String(localized: "在等你吩咐")
    }

    private var actions: [DetailAction] {
        [
            DetailAction(id: "stop", title: Text("停止"), icon: "stop.fill", enabled: online && store.assistantWorking) { confirmStop = true },
            DetailAction(id: "library", title: Text("成果"), icon: "square.stack") { openPane(files: false) },
            DetailAction(id: "files", title: Text("文件", tableName: "Files"), icon: "folder") { openPane(files: true) },
            DetailAction(id: "settings", title: Text("设置"), icon: "gearshape") { showSettings = true },
        ]
    }

    private var goalsLine: String {
        let n = store.watches.filter { $0.state != .done }.count
        return n > 0 ? String(localized: "\(n) 个") : String(localized: "还没有目标")
    }

    private var historyLine: String {
        let today = store.tasks.filter { Calendar.current.isDateInToday($0.updatedAt.msDate) }.count
        return today > 0 ? String(localized: "今天 \(today) 件") : String(localized: "还没有办过的事")
    }

    private func page(_ tab: AssistantTab) -> some View {
        List {
            switch tab {
            case .watches: WatchesSection()
            case .history: HistorySection()
            case .memory: MemorySection()
            }
        }
        .navigationTitle(tab.title)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(InSidebarColumn())
    }

    private func jumpToWaiting() {
        guard let first = waiting.first else { return }
        model.setDetail(false, tile: tileDetail)
        model.open(.pal(first.id))
    }

    private func openPane(files: Bool) {
        model.setDetail(false, tile: tileDetail)
        // On a phone the pane comes up once this sheet is gone.
        Task {
            try? await Task.sleep(for: .milliseconds(model.libraryBeside ? 0 : 400))
            if model.selection != .palo { model.openPalo() }
            model.openInPane { files ? $0.openFiles($1) : $0.openLibrary($1) }
        }
    }
}
