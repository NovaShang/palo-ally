import PaloAllyKit
import SwiftUI

/// 履历: what it's doing right now (pinned), then what it got done, by day.
/// Each finished row is one outcome line — what came of it, not the mechanism.
struct HistorySection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let active = store.tasks.filter(\.isActive).sorted { $0.updatedAt > $1.updatedAt }
        let finished = store.tasks.filter { !$0.isActive }.sorted { $0.updatedAt > $1.updatedAt }
        if store.tasks.isEmpty {
            Section {
                ContentUnavailableView("还没有办过的事", systemImage: "checklist",
                                       description: Text("在对话里交代一件事，它在做和做完的都会记在这里。"))
            }
        }
        if !active.isEmpty {
            Section("正在做") {
                ForEach(active) { RunningHistoryRow(task: $0) }
            }
        }
        ForEach(HistoryDay.group(finished), id: \.title) { day in
            Section(day.title) {
                ForEach(day.tasks) { DoneHistoryRow(task: $0) }
            }
        }
    }
}

/// Finished tasks bucketed by local day: 今天 / 昨天 / 10月2日 (年份 when not this year).
struct HistoryDay {
    let title: String
    let tasks: [AllyTask]

    static func group(_ tasks: [AllyTask], now: Date = Date(), calendar: Calendar = .current) -> [HistoryDay] {
        var order: [String] = []
        var buckets: [String: [AllyTask]] = [:]
        for t in tasks {
            let title = dayTitle(t.updatedAt.msDate, now: now, calendar: calendar)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(t)
        }
        return order.map { HistoryDay(title: $0, tasks: buckets[$0] ?? []) }
    }

    static func dayTitle(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "今天" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "昨天" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = sameYear ? "M月d日" : "yyyy年M月d日"
        return f.string(from: date)
    }
}

/// A rough kind for the row icon, read from the task's own words.
enum TaskKind {
    case document, web, email, code, calendar, generic

    init(_ task: AllyTask) {
        let text = (task.title + " " + task.summary).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if has(["邮件", "邮箱", "email", "gmail", "mail", "回信"]) { self = .email }
        else if has(["日程", "日历", "会议", "提醒", "calendar", "约"]) { self = .calendar }
        else if has(["代码", "脚本", "bug", "程序", "部署", "仓库", "code", "git"]) { self = .code }
        else if has(["ppt", "pptx", "文档", "报告", "pdf", "表格", "excel", "xlsx", "doc", "周报", "文章", "稿"]) { self = .document }
        else if has(["网页", "网站", "浏览", "搜索", "查", "比价", "订", "http", "链接"]) { self = .web }
        else { self = .generic }
    }

    var symbol: String {
        switch self {
        case .document: "doc.text"
        case .web: "globe"
        case .email: "envelope"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .calendar: "calendar"
        case .generic: "sparkles"
        }
    }
}

/// A task in progress: its title and latest progress line.
private struct RunningHistoryRow: View {
    let task: AllyTask

    var body: some View {
        SidebarItemLink(detail: .task(task.id)) {
            TaskDetailView(taskID: task.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                TaskStatusIcon(status: task.status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title.isEmpty ? "一件事" : task.title)
                        .font(.body)
                        .lineLimit(2)
                    Text(task.summary.isEmpty ? (task.status == .needsInput ? "需要你" : "刚开始") : task.summary)
                        .font(.subheadline)
                        .foregroundStyle(task.status == .needsInput ? Color.orange : .secondary)
                        .lineLimit(2)
                    Text("\(Copy.taskStatus(task.status)) · \(Copy.relative(task.updatedAt))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// A finished task: one outcome line with a type icon. Didn't-work-out and
/// stopped ones stay quiet (gray).
private struct DoneHistoryRow: View {
    let task: AllyTask

    private var succeeded: Bool { task.status == .done }

    /// What came of it: the result line when there is one, else the title.
    private var outcome: String {
        let firstLine = task.summary
            .split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if succeeded, !firstLine.isEmpty { return firstLine }
        return task.title.isEmpty ? "一件事" : task.title
    }

    var body: some View {
        SidebarItemLink(detail: .task(task.id)) {
            TaskDetailView(taskID: task.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: TaskKind(task).symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(outcome)
                        .font(.body)
                        .foregroundStyle(succeeded ? Color.primary : .secondary)
                        .lineLimit(3)
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var meta: String {
        var parts: [String] = []
        switch task.status {
        case .failed: parts.append("没办成")
        case .stopped: parts.append("停下了")
        default: break
        }
        // The title, when the outcome line isn't already it.
        if succeeded, !task.title.isEmpty, task.title != outcome { parts.append(task.title) }
        parts.append(Copy.clock(task.updatedAt))
        return parts.joined(separator: " · ")
    }
}

struct TaskStatusIcon: View {
    let status: TaskStatus

    var body: some View {
        let (symbol, color) = Copy.taskSymbol(status)
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(color)
            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: status == .running)
            .frame(width: 28)
    }
}

struct TaskDetailView: View {
    @Environment(AppStore.self) private var store
    let taskID: String
    @State private var activity: [TaskActivity] = []
    @State private var loading = true
    @State private var error: String?
    @State private var confirmStop = false

    private var task: AllyTask? { store.task(id: taskID) }

    var body: some View {
        List {
            if let task {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            TaskStatusIcon(status: task.status)
                            Text(Copy.taskStatus(task.status))
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(Copy.relative(task.updatedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(task.title).font(.title3.bold())
                        if !task.summary.isEmpty {
                            MarkdownText(source: task.summary)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if task.isActive {
                    Section {
                        Button("停下这件事", role: .destructive) { confirmStop = true }
                            .confirmationDialog("停下「\(task.title)」？", isPresented: $confirmStop, titleVisibility: .visible) {
                                Button("停下", role: .destructive) {
                                    Task {
                                        do { try await store.stopTask(id: task.id) } catch {
                                            self.error = "没停下来：\(Copy.error(error))"
                                        }
                                    }
                                }
                            }
                        if let error, !activity.isEmpty {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                    }
                }

                Section("过程") {
                    if loading && activity.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if activity.isEmpty {
                        Text(error ?? "还没有记录到过程").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(activity.enumerated()), id: \.offset) { _, item in
                            ActivityRow(item: item)
                        }
                    }
                }
            } else {
                ContentUnavailableView("找不到这件事", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle("任务")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        // Detail refreshes whenever the task row changes.
        .task(id: task?.updatedAt) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let d = try await store.taskDetail(id: taskID)
            activity = d.activity
            error = nil
        } catch {
            self.error = Copy.error(error)
        }
    }
}

private struct ActivityRow: View {
    let item: TaskActivity

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(item.kind == .text ? Color.primary : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                if item.kind != .text, let tool = item.tool, !tool.isEmpty {
                    let name = item.label ?? Copy.tool(tool)
                    Text(item.kind == .toolResult ? "\(name) · 结果" : name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(item.text)
                    .font(item.kind == .text ? .body : .callout)
                    .foregroundStyle(item.kind == .toolResult ? .secondary : .primary)
                    .lineLimit(item.kind == .toolResult ? 6 : nil)
                    .textSelection(.enabled)
                Text(Copy.clock(item.ts))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch item.kind {
        case .toolUse: "hammer"
        case .toolResult: "arrow.turn.down.right"
        case .text: "text.bubble"
        case .unknown: "circle.dashed"
        }
    }
}
