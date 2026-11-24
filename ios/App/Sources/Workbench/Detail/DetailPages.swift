import PaloAllyKit
import SwiftUI

/// What the details' tiles push, inside the same popover, sheet or page.
enum DetailPage: Hashable {
    case history, memory, goals, settings
    /// One of the assistant's tasks.
    case task(String)
}

struct DetailPageView: View {
    let page: DetailPage
    /// A Pal's id; nil: the assistant.
    let agent: String?
    /// An agent's tasks that ended, newest first.
    let past: [AgentTask]

    var body: some View {
        switch page {
        case .history:
            List {
                if agent == nil { HistorySection() } else { AgentHistory(tasks: past) }
            }
            .navigationTitle("历史")
            .detailList()
            .accessibilityIdentifier("detail-history-page")
        case .memory:
            List { MemorySection(agent: agent) }
                .navigationTitle("记忆")
                .detailList()
                .accessibilityIdentifier("detail-memory-page")
        case .goals:
            List { WatchesSection() }
                .navigationTitle("目标")
                .detailList()
                .accessibilityIdentifier("detail-goals-page")
        case .settings:
            AssistantSettingsPage()
        case .task(let id):
            TaskDetailView(taskID: id).detailList()
        }
    }
}

/// An agent's, newest first.
private struct AgentHistory: View {
    let tasks: [AgentTask]

    var body: some View {
        if tasks.isEmpty {
            ContentUnavailableView("还没有记录", systemImage: "clock").listRowBackground(Color.clear)
        }
        ForEach(Array(tasks.enumerated()), id: \.element.id) { i, t in
            AgentTaskRow(task: t).detailRow(i, of: tasks.count)
        }
    }
}

/// A subagent or a background command that ended: what it was, when, how,
/// and its last line.
struct AgentTaskRow: View {
    let task: AgentTask

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.kind == .subagent ? "person.2" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title.isEmpty ? String(localized: "一件事") : task.title).lineLimit(2)
                HStack(spacing: 4) {
                    Text(Self.kindWord(task))
                    if let end = task.endedAt, end > 0 {
                        Text(verbatim: "·")
                        Text(Copy.relative(end))
                    }
                    if let ending = task.ending, ending != .done {
                        Text(verbatim: "·")
                        Text(ending == .failed ? String(localized: "没成") : String(localized: "停了"))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let s = task.summary, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
    }

    static func kindWord(_ task: AgentTask) -> String {
        switch task.kind {
        case .subagent: String(localized: "子 agent")
        case .background: String(localized: "后台任务")
        case .task: String(localized: "在做")
        }
    }
}

/// The assistant's 设置: its color (the app's too), its name, the language
/// it speaks.
private struct AssistantSettingsPage: View {
    @Environment(WindowModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.detailMetrics) private var metrics
    @State private var failure: String?

    private var online: Bool { store.connection.isOnline }

    var body: some View {
        ScrollView {
            VStack(spacing: DetailMetrics.gap) {
                ThemeSwatches(selection: theme, narrowest: 54)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .detailTile()
                    .disabled(!online)
                HStack(spacing: DetailMetrics.gap) {
                    Button { model.showIdentityEditor = true } label: {
                        ValueTileLabel(label: String(localized: "名字"), value: store.assistantName, symbol: "pencil")
                    }
                    .buttonStyle(TileButtonStyle())
                    .accessibilityIdentifier("detail-name")
                    languageTile
                }
                .fixedSize(horizontal: false, vertical: true)
                if let failure {
                    Text(Copy.spaced(failure)).detailFont(metrics.line).foregroundStyle(.red)
                }
            }
            .padding(metrics.padding)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("设置")
        .detailList()
        .accessibilityIdentifier("detail-settings-page")
    }

    private var languageTile: some View {
        Menu {
            Picker("语言", selection: language) {
                Text("自动").tag("")
                Text(verbatim: "中文").tag("zh")
                Text(verbatim: "English").tag("en")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            ValueTileLabel(label: String(localized: "语言"), value: languageName)
        }
        .menuStyle(.button)
        .buttonStyle(TileButtonStyle())
        .menuIndicator(.hidden)
        .disabled(!online || store.settings == nil)
        .accessibilityIdentifier("detail-language")
    }

    private var languageName: String {
        switch store.settings?.language ?? "" {
        case "zh": "中文"  // i18n-ok: the language's own name
        case "en": "English"
        default: String(localized: "自动")
        }
    }

    private var language: Binding<String> {
        Binding(get: { store.settings?.language ?? "" }, set: { lang in
            attempt { try await store.updateSettings(patch: ["language": .string(lang)]) } failed: { String(localized: "没改成：\(Copy.error($0))") }
        })
    }

    private var theme: Binding<AppTheme> {
        Binding(get: { model.currentTheme }, set: { t in
            guard let id = model.activeHostID else { return }
            attempt { try await model.setTheme(t, for: id) } failed: { String(localized: "颜色没改成：\(Copy.error($0))") }
        })
    }

    private func attempt(_ op: @escaping () async throws -> Void, failed: @escaping (Error) -> String) {
        failure = nil
        Task { do { try await op() } catch { failure = failed(error) } }
    }
}
