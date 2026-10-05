import PaloAllyKit
import SwiftUI

/// Model and thinking depth for the current assistant. Opened from the
/// title-capsule popover (the one place to change them); /model in the
/// composer still works too.
struct ModelPickerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var working = false

    private var info: ModelInfo? { store.modelInfo }

    /// The row matching the saved choice ("default" when none is saved).
    private var selectedValue: String { info?.setting ?? info?.models.first?.value ?? "default" }

    private var efforts: [String] {
        info?.models.first(where: { $0.value == selectedValue })?.efforts ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                if let info {
                    Section {
                        ForEach(info.models) { m in
                            Button {
                                apply(model: m.value == info.models.first?.value ? .some(nil) : .some(m.value))
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m.displayName).foregroundStyle(.primary)
                                        if !m.description.isEmpty {
                                            Text(m.description).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if m.value == selectedValue { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                        }
                    } header: {
                        Text("模型")
                    } footer: {
                        Text("现在在用：\(ModelName.short(info.model))")
                    }

                    if !efforts.isEmpty {
                        Section {
                            Picker("思考深度", selection: Binding(
                                get: { store.status?.effort ?? "" },
                                set: { apply(effort: .some($0.isEmpty ? nil : $0)) }
                            )) {
                                Text("默认").tag("")
                                ForEach(efforts, id: \.self) { Text(EffortName.label($0)).tag($0) }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } header: {
                            Text("思考深度")
                        } footer: {
                            Text("想得越深，回得越慢、越费额度。日常用默认就好。")
                        }
                    }
                } else {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .disabled(working)
            .navigationTitle("模型与思考")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.tint(.primary) }
            }
            .task {
                do { try await store.loadModels() } catch { self.error = "没取到可选模型：\(Copy.error(error))" }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func apply(model: String?? = .none, effort: String?? = .none) {
        working = true
        error = nil
        Task {
            do { try await store.setModel(model, effort: effort) } catch { self.error = Copy.error(error) }
            working = false
        }
    }
}
