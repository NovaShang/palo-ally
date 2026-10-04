import PaloAllyKit
import SwiftUI

struct TasksSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let active = store.tasks.filter(\.isActive)
        let past = store.tasks.filter { !$0.isActive }
        if store.tasks.isEmpty {
            Section {
                ContentUnavailableView("现在没有在办的事", systemImage: "checklist",
                                       description: Text("在对话里交代一件事，它就会出现在这里。"))
            }
        }
        if !active.isEmpty {
            Section("正在办") {
                ForEach(active) { TaskRow(task: $0) }
            }
        }
        if !past.isEmpty {
            Section("办过的") {
                ForEach(past) { TaskRow(task: $0) }
            }
        }
    }
}

struct TaskRow: View {
    let task: AllyTask

    var body: some View {
        NavigationLink {
            TaskDetailView(taskID: task.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                TaskStatusIcon(status: task.status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title.isEmpty ? "一件事" : task.title)
                        .font(.body)
                        .lineLimit(2)
                    if !task.summary.isEmpty {
                        Text(task.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text("\(Copy.taskStatus(task.status)) · \(Copy.relative(task.updatedAt))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
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
                                    Task { try? await store.stopTask(id: task.id) }
                                }
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
            self.error = error.localizedDescription
        }
    }
}

private struct ActivityRow: View {
    let item: TaskActivity

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(item.kind == .text ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                if item.kind != .text, let tool = item.tool, !tool.isEmpty {
                    Text(item.kind == .toolResult ? "\(Copy.tool(tool)) · 结果" : Copy.tool(tool))
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
