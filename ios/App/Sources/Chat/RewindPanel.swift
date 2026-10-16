import PaloAllyKit
import SwiftUI

/// 回到这里重来 (docs/rewind-prd.md §3), asked in place of the composer:
/// what happens in one line, 重来 and 算了. In a Pal, 代码也恢复到那时 when the
/// computer kept the files from then (off unless the owner turns it on).
/// While it's working, 重来 stops it first. Done, the messages that go fade
/// out and the composer comes back with the message's words, ready to edit.
struct RewindPanel: View {
    let target: ChatMessage
    @Environment(AppStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.chatDraft) private var draft
    /// A Pal: whether its files can go back (nil while the computer is asked).
    @State private var canRestore: Bool?
    @State private var restoreFiles = false
    @State private var working = false
    @State private var error: String?

    /// How the messages that would go look while this is asked.
    static let dimmed = 0.35
    /// How they leave once it's done.
    static let leaving = Animation.easeOut(duration: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("回到这里重来？")
                    .font(.headline)
                Text(store.busyForRewind ? String(localized: "它还在忙，重来会先停下这一轮。之后的对话会被撤回，已经做过的事不会撤销。") : String(localized: "之后的对话会被撤回，已经做过的事不会撤销。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.palID != nil {
                if canRestore == true {
                    Toggle("代码也恢复到那时", isOn: $restoreFiles)
                        .font(.subheadline)
                        .accessibilityIdentifier("rewindRestoreFiles")
                } else if canRestore == false {
                    Text("这一步之前的代码没法恢复")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("算了") { close() }
                    .buttonStyle(.glass)
                    .tint(.primary) // neutral: the theme color is for the action
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button { go() } label: {
                    if working {
                        ProgressView().controlSize(.small).frame(minWidth: 36)
                    } else {
                        Text("重来").frame(minWidth: 36)
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(working)
                .accessibilityIdentifier("rewindConfirm")
            }
            .controlSize(.regular)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        // Large screens: the conversation's line length, centred.
        .frame(maxWidth: ChatView.readableWidth)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: canRestore)
        .animation(.snappy, value: error)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rewindPanel")
        .task(id: target.id) {
            canRestore = nil
            restoreFiles = false
            error = nil
            guard store.palID != nil else { return }
            canRestore = await store.canRestoreFiles(to: target)
        }
    }

    private func close() {
        withAnimation(.snappy) { store.rewindTarget = nil }
    }

    private func go() {
        working = true
        error = nil
        // The composer that comes back takes the keyboard.
        model.focusComposerOnAppear = true
        let files = restoreFiles && canRestore == true
        Task { @MainActor in
            do {
                let out = try await store.rewind(to: target, restoreFiles: files)
                // Its words back, ahead of anything typed meanwhile.
                let typed = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.wrappedValue = typed.isEmpty ? out.text : "\(out.text)\n\n\(typed)"
                if store.rewindTarget != nil { close() }
            } catch {
                model.focusComposerOnAppear = false
                working = false
                let why = Friendly.message(error)
                if why.contains("代码没法恢复") || why.contains("can't be restored") {  // i18n-ok: the host's own words, in either language
                    // Said in place of the switch: the conversation can still go back.
                    canRestore = false
                    restoreFiles = false
                } else {
                    self.error = why
                }
            }
        }
    }
}
