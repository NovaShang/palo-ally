import PaloAllyKit
import SwiftUI

/// Name the assistant and pick its color. Shown once after the first pairing
/// (「给它起个名字，选个颜色」) and later from the 「它」 header. Both live on
/// the computer: the name in soul.md (so it knows what it's called) and in its
/// settings, the color in its settings — every phone and Mac sees the same.
/// The color is also the app's theme color.
struct IdentityEditor: View {
    enum Purpose { case firstTime, edit }

    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let purpose: Purpose

    @State private var name = AppStore.defaultAssistantName
    @State private var color = AppTheme.default
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Live preview: the drop takes the color as it's picked.
                    AssistantAvatar(tint: color.color)
                        .frame(width: 120, height: 120)
                        .padding(.top, 4)

                    if purpose == .firstTime {
                        Text("给它起个名字，选个颜色")
                            .font(.title3.weight(.semibold))
                    }

                    TextField("名字", text: $name, prompt: Text(AppStore.defaultAssistantName))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { nameFocused = false }
                        .padding(.vertical, 10)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
                        .accessibilityLabel("它的名字")

                    VStack(spacing: 8) {
                        ThemeSwatches(selection: $color)
                        Text("这也是 App 的颜色。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(purpose == .firstTime ? "" : "名字和颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if purpose == .edit {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(purpose == .firstTime ? "好了" : "完成", action: save)
                        .disabled(saving)
                }
            }
        }
        // The sheet already wears the color being picked.
        .tint(color.color)
        .animation(.easeInOut(duration: 0.3), value: color)
        .interactiveDismissDisabled(purpose == .firstTime)
        // A form-sized sheet: the Mac's default one is too small for the swatches.
        .presentationSizing(.form)
        .onAppear(perform: prefill)
    }

    private func prefill() {
        if let s = store.settings, !s.assistantName.isEmpty { name = s.assistantName }
        color = model.currentTheme
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = String((trimmed.isEmpty ? AppStore.defaultAssistantName : trimmed).prefix(20))
        saving = true
        error = nil
        Task {
            do {
                // The computer's answer recolors the app (AppModel follows settings.color).
                try await store.updateSettings(patch: .object(["assistantName": .string(finalName),
                                                               "color": .string(color.rawValue)]))
                model.namingDone = true
                dismiss()
                AppTheme.applyIcon(model.iconTheme)
            } catch {
                self.error = "没存上：\(Copy.error(error))"
            }
            saving = false
        }
    }
}

extension AppStore {
    /// Its name until the owner gives it another.
    static let defaultAssistantName = "Palo"

    /// What the owner calls it.
    var assistantName: String {
        let n = settings?.assistantName ?? ""
        return n.isEmpty ? Self.defaultAssistantName : n
    }

    /// Working: replying, or something still running in the background.
    var assistantWorking: Bool { isBusy || tasks.contains { $0.status == .running } }
}
