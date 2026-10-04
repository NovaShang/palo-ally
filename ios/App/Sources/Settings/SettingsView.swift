import PaloAllyKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    @State private var quietOn = false
    @State private var quietStart = WatchEditor.date(hour: 23, minute: 0)
    @State private var quietEnd = WatchEditor.date(hour: 8, minute: 0)
    @State private var maxPerDay = 6
    @State private var loaded = false
    @State private var error: String?
    @State private var confirmUnpair = false
    @State private var showModels = false
    @State private var unpairing = false
    /// Pending quiet-hours save; DatePickers fire on every tick of the wheel.
    @State private var quietSave: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Button {
                    showModels = true
                } label: {
                    LabeledContent("模型与思考", value: "\(ModelName.short(store.status?.model ?? "")) · \(EffortName.label(store.status?.effort))")
                }
                .foregroundStyle(.primary)
            }
            .sheet(isPresented: $showModels) { ModelPickerSheet().environment(store) }

            Section {
                Toggle("免打扰", isOn: $quietOn)
                if quietOn {
                    DatePicker("从", selection: $quietStart, displayedComponents: .hourAndMinute)
                    DatePicker("到", selection: $quietEnd, displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("什么时候别打扰我")
            } footer: {
                Text("这段时间里，不急的事只放进对话，不推送。")
            }

            Section {
                Stepper(value: $maxPerDay, in: 0...30) {
                    HStack {
                        Text("每天最多主动找我")
                        Spacer()
                        Text(maxPerDay == 0 ? "不主动" : "\(maxPerDay) 次")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text("超过之后的提醒会留在对话里，等你来看。")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            Section("连接") {
                LabeledContent("状态", value: Copy.connection(store.connection))
                if model.mode == .demo {
                    LabeledContent("电脑", value: "演示")
                    Button("退出演示，去配对") { model.exitDemo() }
                } else {
                    LabeledContent("电脑", value: store.hostName.isEmpty ? (model.pairedHost?.hostLabel ?? "—") : store.hostName)
                    Button("换一台电脑配对") { model.showPairingSheet = true }
                    Button(unpairing ? "正在解除…" : "解除配对", role: .destructive) { confirmUnpair = true }
                        .disabled(unpairing)
                        .confirmationDialog("解除和这台电脑的配对？", isPresented: $confirmUnpair, titleVisibility: .visible) {
                            Button("解除配对", role: .destructive) {
                                unpairing = true
                                Task { await model.unpair() }
                            }
                        } message: {
                            Text("之后要重新扫码才能连回来。")
                        }
                }
            }

            Section {
                LabeledContent("版本", value: model.clientVersion)
                if !store.hostVersion.isEmpty {
                    LabeledContent("电脑上的版本", value: store.hostVersion)
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: prefill)
        .onChange(of: store.settings) { prefill() }
        .onChange(of: quietOn) { if loaded { quietSave?.cancel(); push(["quietHours": quietValue]) } }
        .onChange(of: quietStart) { if loaded && quietOn { scheduleQuietSave() } }
        .onChange(of: quietEnd) { if loaded && quietOn { scheduleQuietSave() } }
        .onChange(of: maxPerDay) { if loaded { push(["maxProactivePerDay": .number(Double(maxPerDay))]) } }
        .onDisappear {
            // Leaving mid-debounce: save right away.
            if let pending = quietSave, !pending.isCancelled {
                pending.cancel()
                push(["quietHours": quietValue])
            }
        }
    }

    private var quietValue: JSONValue {
        quietOn ? ["start": .string(WatchEditor.format(quietStart)), "end": .string(WatchEditor.format(quietEnd))] : .null
    }

    private func prefill() {
        guard let s = store.settings else { return }
        loaded = false
        quietOn = s.quietHours != nil
        if let q = s.quietHours {
            quietStart = WatchEditor.parse(q.start) ?? quietStart
            quietEnd = WatchEditor.parse(q.end) ?? quietEnd
        }
        maxPerDay = s.maxProactivePerDay
        DispatchQueue.main.async { loaded = true }
    }

    private func scheduleQuietSave() {
        quietSave?.cancel()
        quietSave = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            quietSave = nil
            push(["quietHours": quietValue])
        }
    }

    private func push(_ patch: JSONValue) {
        error = nil
        Task {
            do {
                try await store.updateSettings(patch: patch)
            } catch {
                self.error = "没改成：\(Copy.error(error))"
                // Put the controls back to what the computer actually has.
                prefill()
            }
        }
    }
}
