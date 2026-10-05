import PaloAllyKit
import SwiftUI

/// Name the assistant and pick its form. Shown once after the first pairing
/// (「给它起个名字」, skippable) and later from the 「它」 header. Both live on
/// the computer: the name in soul.md (so it knows what it's called), the form
/// in its settings — every phone and Mac sees the same.
struct IdentityEditor: View {
    enum Purpose { case firstTime, edit }

    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let purpose: Purpose

    @State private var name = ""
    @State private var avatar = AvatarStyle.default.id
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    static let suggestions = ["帕帕", "小帕", "团子", "阿福", "豆豆", "小满"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    AssistantAvatar(avatar, tint: model.currentTheme.color, active: true)
                        .frame(width: 112, height: 112)
                        .padding(.top, 8)

                    VStack(spacing: 10) {
                        TextField("名字", text: $name, prompt: Text(Self.suggestions[0]))
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit { nameFocused = false }
                            .padding(.vertical, 10)
                            .background(.fill.tertiary, in: .rect(cornerRadius: 14))
                            .accessibilityLabel("它的名字")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Self.suggestions, id: \.self) { s in
                                    Button(s) { name = s }
                                        .buttonStyle(.bordered)
                                        .tint(.secondary)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("它的样子").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        AvatarPicker(selection: $avatar, tint: model.currentTheme.color)
                    }

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle(purpose == .firstTime ? "给它起个名字" : "名字和样子")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if purpose == .firstTime {
                        Button("先跳过") { save(name: "PaloAlly", avatar: AvatarStyle.default.id) }
                            .disabled(saving)
                    } else {
                        Button("取消") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(purpose == .firstTime ? "好了" : "完成") {
                        save(name: trimmedName.isEmpty ? Self.suggestions[0] : trimmedName, avatar: avatar)
                    }
                    .disabled(saving)
                }
            }
        }
        .interactiveDismissDisabled(purpose == .firstTime)
        .onAppear(perform: prefill)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func prefill() {
        guard let s = store.settings else { return }
        if !s.assistantName.isEmpty { name = s.assistantName }
        if !s.avatar.isEmpty { avatar = s.avatar }
    }

    private func save(name: String, avatar: String) {
        saving = true
        error = nil
        Task {
            do {
                try await store.updateSettings(patch: .object(["assistantName": .string(String(name.prefix(20))),
                                                               "avatar": .string(avatar)]))
                model.namingDone = true
                dismiss()
            } catch {
                self.error = "没存上：\(Copy.error(error))"
            }
            saving = false
        }
    }
}

extension AppStore {
    /// What the owner calls it ("PaloAlly" until named).
    var assistantName: String {
        let n = settings?.assistantName ?? ""
        return n.isEmpty ? "PaloAlly" : n
    }

    /// Its form ("" → the default).
    var assistantAvatar: String { settings?.avatar ?? "" }

    /// Working: replying, or something still running in the background.
    var assistantWorking: Bool { isBusy || tasks.contains { $0.status == .running } }
}
