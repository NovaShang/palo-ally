import PaloAllyKit
import SwiftUI

struct WatchesSection: View {
    @Environment(AppStore.self) private var store
    @State private var editing: Watch?
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        Section {
            if store.watches.isEmpty {
                ContentUnavailableView("还没有定时的事", systemImage: "alarm",
                                       description: Text("比如每天早上的晨报，或者帮你盯着某封邮件。"))
            }
            ForEach(store.watches) { w in
                WatchRow(watch: w) { editing = w }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                do { try await store.removeWatch(id: w.id) } catch { self.error = Copy.error(error) }
                            }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
            Button {
                adding = true
            } label: {
                Label("新加一个", systemImage: "plus.circle.fill")
            }
        } footer: {
            if let error { Text(error).foregroundStyle(.red) } else {
                Text("「到点做」按时间表跑；「隔一阵看看」会定期帮你查一下，有新情况才找你。")
            }
        }
        .sheet(item: $editing) { w in
            NavigationStack { WatchEditor(existing: w) }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { WatchEditor(existing: nil) }
        }
    }
}

private struct WatchRow: View {
    @Environment(AppStore.self) private var store
    let watch: Watch
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: watch.kind == .schedule ? "alarm" : "eye")
                .foregroundStyle(watch.enabled ? Color.accentColor : .secondary)
                .frame(width: 26)
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(watch.title.isEmpty ? watch.instruction : watch.title)
                        .foregroundStyle(watch.enabled ? .primary : .secondary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(Copy.watchSchedule(watch))
                        if watch.createdBy == .agent { Text("· 助理加的") }
                        if let t = watch.lastTriggeredAt ?? watch.lastCheckedAt {
                            Text("· 上次 \(Copy.relative(t))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("开启", isOn: Binding(
                get: { watch.enabled },
                set: { on in Task { try? await store.setWatch(watch, enabled: on) } }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 2)
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
        .navigationTitle(existing == nil ? "新的定时" : "改一改")
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
