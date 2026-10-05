import PaloAllyKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    @State private var quietOn = false
    @State private var quietStart = WatchEditor.date(hour: 23, minute: 0)
    @State private var quietEnd = WatchEditor.date(hour: 8, minute: 0)
    @State private var loaded = false
    @State private var error: String?
    @State private var confirmUnpair = false
    @State private var unpairing = false
    /// Pending quiet-hours save; DatePickers fire on every tick of the wheel.
    @State private var quietSave: Task<Void, Never>?
    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ThemePicker(selection: themeBinding)
            } header: {
                Text("主题色")
            } footer: {
                if model.hasSeveralHosts {
                    Text("这是「\(model.displayName(model.activeHostID ?? ""))」的颜色；每个助理一个颜色，切换时整个 App 跟着换。")
                } else {
                    Text("App 的颜色和桌面图标都会换成这个颜色。")
                }
            }

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

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            Section("连接") {
                LabeledContent("状态", value: Copy.connection(store.connection))
                if model.mode == .demo {
                    LabeledContent("电脑", value: "演示")
                    if model.hasSeveralHosts {
                        NavigationLink { HostsView() } label: {
                            LabeledContent("我的助理", value: "\(model.hostIDs.count) 个")
                        }
                    }
                    Button("退出演示，去配对") { model.exitDemo() }
                        .tint(.primary)
                } else if model.hasSeveralHosts {
                    LabeledContent("电脑", value: model.displayName(model.activeHostID ?? ""))
                    NavigationLink { HostsView() } label: {
                        LabeledContent("我的助理", value: "\(model.hostIDs.count) 个")
                    }
                } else {
                    // One computer (most people): the plain section, as before.
                    LabeledContent("电脑", value: store.hostName.isEmpty ? (model.pairedHost?.hostLabel ?? "—") : store.hostName)
                    Button("换一台电脑配对") { model.startPairing(.replace) }
                        .tint(.primary)
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
                    Button {
                        model.startPairing(.add)
                    } label: {
                        Text("添加另一台电脑").font(.footnote)
                    }
                    .tint(.secondary)
                }
            }

            Section {
                LabeledContent("版本", value: model.clientVersion)
                // From bento: one file to send when something goes wrong.
                ShareLink(item: DebugLog.shared.fileURL) {
                    Label("导出调试日志", systemImage: "doc.text.magnifyingglass")
                }
                .tint(.primary)
                if !store.hostVersion.isEmpty {
                    LabeledContent("电脑上的版本", value: store.hostVersion)
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $model.showHostList) { HostsView() }
        .onAppear(perform: prefill)
        .onChange(of: store.settings) { prefill() }
        .onChange(of: quietOn) { if loaded { quietSave?.cancel(); push(["quietHours": quietValue]) } }
        .onChange(of: quietStart) { if loaded && quietOn { scheduleQuietSave() } }
        .onChange(of: quietEnd) { if loaded && quietOn { scheduleQuietSave() } }
        .onDisappear {
            // The icon switches once on the way out, not on every swatch tap
            // (iOS confirms each switch with its own alert).
            AppTheme.applyIcon(model.iconTheme)
            // Leaving mid-debounce: save right away.
            if let pending = quietSave, !pending.isCancelled {
                pending.cancel()
                push(["quietHours": quietValue])
            }
        }
    }

    /// The current assistant's color.
    private var themeBinding: Binding<AppTheme> {
        Binding(get: { model.currentTheme },
                set: { t in if let id = model.activeHostID { model.setTheme(t, for: id) } })
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

/// The theme swatches: glass circles in each color, a checkmark on the
/// current one. Picking one recolors the app right away.
private struct ThemePicker: View {
    @Binding var selection: AppTheme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 10)], spacing: 14) {
            ForEach(AppTheme.allCases) { t in
                Button {
                    withAnimation(.snappy) { selection = t }
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(t.color.gradient)
                            .frame(width: 40, height: 40)
                            .overlay {
                                if t == selection {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.white)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .padding(4)
                            .glassEffect(t == selection ? .regular.tint(t.color.opacity(0.25)).interactive() : .regular.interactive(), in: .circle)
                        Text(t.name)
                            .font(.caption)
                            .foregroundStyle(t == selection ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.name)
                .accessibilityAddTraits(t == selection ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
