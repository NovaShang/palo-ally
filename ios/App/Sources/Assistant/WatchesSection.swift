import PaloAllyKit
import SwiftUI

/// 目标: what the assistant is helping with over time. Each one shows a short
/// progress line and a state; underneath it's still a watch (a probe check or
/// a schedule). New goals are asked for in plain words — the assistant sets
/// them up — rather than through a form.
struct WatchesSection: View {
    @Environment(AppStore.self) private var store

    /// Needs-you first, then the ones moving, then paused, then done.
    private var goals: [Watch] {
        func rank(_ w: Watch) -> Int {
            switch w.state {
            case .waiting: 0
            case .tracking, .unknown: 1
            case .paused: 2
            case .done: 3
            }
        }
        return store.watches.sorted {
            let (a, b) = (rank($0), rank($1))
            if a != b { return a < b }
            return ($0.progressAt ?? $0.lastCheckedAt ?? 0) > ($1.progressAt ?? $1.lastCheckedAt ?? 0)
        }
    }

    var body: some View {
        Section {
            AskForGoal()
            if store.watches.isEmpty {
                ContentUnavailableView("还没有目标", systemImage: "scope",
                                       description: Text("告诉它你想长期盯住或推进的事，比如「回国机票降价了告诉我」「每天早上给我一份晨报」。"))
            }
            ForEach(goals) { w in
                NavigationLink {
                    GoalDetail(id: w.id)
                } label: {
                    GoalRow(goal: w)
                }
            }
        } footer: {
            if !store.watches.isEmpty {
                Text("它会定期替你查看或推进，有进展会更新在这里；需要你的时候会标出来。")
            }
        }
    }
}

/// 「想让它帮你盯着什么？」 — sent to the assistant, which sets the goal up.
private struct AskForGoal: View {
    @Environment(AppStore.self) private var store
    @State private var text = ""
    @State private var sent = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("想让它帮你盯着什么？", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel("交给助理")
            } else if sent {
                Text("已交给它").font(.caption).foregroundStyle(.secondary)
            }
        }
        .animation(.snappy, value: text.isEmpty)
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.send("帮我把这件事设成一个目标，长期帮我盯着或推进：\(t)")
        text = ""
        focused = false
        sent = true
    }
}

private struct GoalRow: View {
    let goal: Watch

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GoalStateIcon(state: goal.state)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(goal.title.isEmpty ? goal.instruction : goal.title)
                    .foregroundStyle(goal.state == .paused || goal.state == .done ? .secondary : .primary)
                    .lineLimit(2)
                Text(goalLine)
                    .font(.subheadline)
                    .foregroundStyle(goal.needsOwner ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                if let r = goal.ratio, goal.state != .done {
                    ProgressView(value: r)
                        .tint(.secondary)
                        .padding(.top, 2)
                }
                if let when {
                    Text(when).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var goalLine: String {
        switch goal.state {
        case .done: return goal.outcome ?? goal.progress ?? "办到了"
        case .waiting: return "需要你 · " + (goal.progress ?? "看一下")
        case .paused: return "已暂停" + (goal.progress.map { " · \($0)" } ?? "")
        default: return goal.progress ?? "刚开始，还没有进展"
        }
    }

    private var when: String? {
        guard let t = goal.progressAt ?? goal.lastCheckedAt, t > 0 else { return nil }
        return Copy.relative(t)
    }
}

struct GoalStateIcon: View {
    let state: GoalState

    var body: some View {
        switch state {
        case .waiting:
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .paused:
            Image(systemName: "pause.circle").foregroundStyle(.tertiary)
        case .tracking, .unknown:
            Image(systemName: "scope").foregroundStyle(.secondary)
        }
    }
}

/// One goal: where it stands, how the assistant pursues it, recent progress.
struct GoalDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var error: String?

    private var goal: Watch? { store.watches.first { $0.id == id } }

    var body: some View {
        Group {
            if let g = goal {
                List {
                    Section {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            GoalStateIcon(state: g.state)
                            Text(Copy.goalState(g.state)).foregroundStyle(g.needsOwner ? .orange : .secondary)
                        }
                        .font(.subheadline)
                        if let p = g.state == .done ? (g.outcome ?? g.progress) : g.progress {
                            Text(p).font(.title3.weight(.medium))
                        } else {
                            Text("刚开始，还没有进展").foregroundStyle(.secondary)
                        }
                        if let r = g.ratio {
                            ProgressView(value: r).tint(.secondary)
                        }
                        if let t = g.progressAt {
                            Text("更新于\(Copy.relative(t))").font(.caption).foregroundStyle(.tertiary)
                        }
                    }

                    Section("它怎么做") {
                        Text(g.instruction)
                        LabeledContent(g.kind == .check ? "多久看一次" : "什么时候做", value: Copy.watchSchedule(g))
                        if let t = g.lastCheckedAt {
                            LabeledContent("上次", value: Copy.relative(t))
                        }
                        if g.createdBy == .agent {
                            Text("是它替你设的").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if g.history.count > 1 {
                        Section("最近的进展") {
                            ForEach(Array(g.history.reversed().enumerated()), id: \.offset) { _, h in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.text)
                                    Text(Copy.relative(h.at)).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    Section {
                        Button(g.enabled ? "暂停" : (g.state == .done ? "重新开始" : "继续")) {
                            Task {
                                do { try await store.setWatch(g, enabled: !g.enabled) } catch { self.error = Copy.error(error) }
                            }
                        }
                        Button("调整怎么做") { editing = true }
                        Button("删掉这个目标", role: .destructive) { confirmDelete = true }
                    } footer: {
                        if let error { Text(error).foregroundStyle(.red) }
                    }
                }
                .navigationTitle(g.title.isEmpty ? "目标" : g.title)
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $editing) {
                    NavigationStack { WatchEditor(existing: g) }
                }
                .confirmationDialog("删掉「\(g.title)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删掉", role: .destructive) {
                        Task {
                            do {
                                try await store.removeWatch(id: g.id)
                                dismiss()
                            } catch { self.error = Copy.error(error) }
                        }
                    }
                } message: {
                    Text("它会停止替你盯着这件事。")
                }
            } else {
                ContentUnavailableView("这个目标已经删掉了", systemImage: "scope")
            }
        }
    }
}

/// Add / edit a watch.
struct WatchEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let existing: Watch?

    @State private var title = ""
    @State private var kind: WatchKind = .schedule
    @State private var instruction = ""
    @State private var interval = 30
    /// "到点做" can also run every N minutes instead of at fixed times.
    @State private var scheduleByInterval = false
    @State private var times: [Date] = []
    @State private var enabled = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("叫什么，比如「每日晨报」", text: $title)
                Picker("方式", selection: $kind) {
                    Text("到点做").tag(WatchKind.schedule)
                    Text("隔一阵看看").tag(WatchKind.check)
                }
                .pickerStyle(.segmented)
            }

            Section("要做什么") {
                TextField("比如：汇总今天的日程和重要邮件", text: $instruction, axis: .vertical)
                    .lineLimit(3...8)
            }

            if kind == .schedule {
                Section {
                    Picker("怎么算时间", selection: $scheduleByInterval) {
                        Text("每天几点").tag(false)
                        Text("每隔一段时间").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }

            if kind == .schedule && scheduleByInterval {
                Section("多久做一次") { intervalStepper }
            } else if kind == .schedule {
                Section {
                    ForEach(times.indices, id: \.self) { i in
                        DatePicker("时间 \(i + 1)", selection: $times[i], displayedComponents: .hourAndMinute)
                    }
                    .onDelete { times.remove(atOffsets: $0) }
                    Button {
                        times.append(Self.date(hour: 9, minute: 0))
                    } label: {
                        Label("加一个时间", systemImage: "plus")
                    }
                } header: {
                    Text("每天几点")
                } footer: {
                    Text("按电脑那边的时区。")
                }
            } else {
                Section("多久看一次") { intervalStepper }
            }

            Section {
                Toggle("开启", isOn: $enabled)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(existing == nil ? "新的目标" : "调整怎么做")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!canSave || saving)
            }
        }
        .onAppear(perform: prefill)
    }

    /// 5-minute steps up to an hour, 30-minute steps above (60 → 55 going
    /// down, not 30).
    private var intervalStepper: some View {
        Stepper {
            Text(Copy.every(interval))
        } onIncrement: {
            interval = IntervalStep.up(interval)
        } onDecrement: {
            interval = IntervalStep.down(interval)
        }
    }

    private var usesInterval: Bool { kind == .check || scheduleByInterval }

    private var canSave: Bool {
        !instruction.trimmingCharacters(in: .whitespaces).isEmpty && (usesInterval || !times.isEmpty)
    }

    private func prefill() {
        guard let w = existing else {
            times = [Self.date(hour: 8, minute: 30)]
            return
        }
        title = w.title
        kind = w.kind == .unknown ? .schedule : w.kind
        instruction = w.instruction
        interval = min(max(w.intervalMinutes ?? 30, IntervalStep.range.lowerBound), IntervalStep.range.upperBound)
        scheduleByInterval = w.isIntervalSchedule
        enabled = w.enabled
        times = (w.at ?? []).compactMap(Self.parse)
        if times.isEmpty { times = [Self.date(hour: 8, minute: 30)] }
    }

    private func save() {
        saving = true
        error = nil
        let draft = WatchDraft(
            title: title.trimmingCharacters(in: .whitespaces).isEmpty ? String(instruction.prefix(16)) : title,
            kind: kind,
            instruction: instruction,
            intervalMinutes: usesInterval ? interval : nil,
            at: usesInterval ? nil : times.map(Self.format).sorted(),
            enabled: enabled,
            skipIfActiveMinutes: existing?.skipIfActiveMinutes
        )
        Task {
            do {
                if let existing {
                    try await store.updateWatch(id: existing.id, patch: AppStore.watchPatch(from: draft))
                } else {
                    try await store.addWatch(draft)
                }
                dismiss()
            } catch {
                self.error = "没保存上：\(Copy.error(error))"
            }
            saving = false
        }
    }

    static func date(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    static func parse(_ s: String) -> Date? {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return date(hour: parts[0], minute: parts[1])
    }

    static func format(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
