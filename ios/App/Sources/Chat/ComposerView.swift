import PaloAllyKit
import SwiftUI

struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @Binding var draft: String
    let dictation: SpeechDictation
    let onSend: () -> Void
    @FocusState private var focused: Bool

    /// Typing "/" (and nothing after a space yet) opens command suggestions.
    /// Nothing in the UI mentions this: it's for people who already know.
    private var slashQuery: String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 6) {
            if let typed = slashQuery {
                SlashSuggestions(commands: SlashCommand.filter(store.commands, typed: typed)) { cmd in
                    draft = "/\(cmd.name) "
                    focused = true
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let msg = dictation.errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            GlassEffectContainer(spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    Button {
                        toggleDictation()
                    } label: {
                        Image(systemName: dictation.isRecording ? "waveform" : "mic")
                            .font(.title3)
                            .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                            .foregroundStyle(dictation.isRecording ? Color.red : Color.primary)
                            .frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel(dictation.isRecording ? "说完了" : "用说的")

                    HStack(alignment: .bottom, spacing: 6) {
                        TextField(dictation.isRecording ? "在听…" : "想让我做点什么？", text: $draft, axis: .vertical)
                            .lineLimit(1...6)
                            .focused($focused)
                            .padding(.vertical, 11)
                            .padding(.leading, 16)
                            .onSubmit(send)
                        if canSend {
                            Button(action: send) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 30))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.tint)
                            }
                            .padding(.trailing, 6)
                            .padding(.bottom, 6)
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityLabel("发送")
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .frame(minHeight: 44)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                }
            }
            .animation(.snappy, value: canSend)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.snappy, value: slashQuery)
        .onChange(of: slashQuery) { _, q in
            if q != nil { Task { await store.loadCommands() } }
        }
        .onChange(of: dictation.transcript) { _, text in
            if dictation.isRecording { draft = dictation.prefix + text }
        }
    }

    private func send() {
        guard canSend else { return }
        if dictation.isRecording { dictation.stop() }
        onSend()
    }

    private func toggleDictation() {
        if dictation.isRecording {
            dictation.stop()
        } else {
            dictation.prefix = draft.isEmpty ? "" : draft + " "
            Task { await dictation.start() }
        }
    }
}

private struct SlashSuggestions: View {
    let commands: [SlashCommand]
    let pick: (SlashCommand) -> Void

    var body: some View {
        if !commands.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commands) { c in
                    Button { pick(c) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("/\(c.name)").font(.callout.monospaced()).foregroundStyle(.primary)
                            if let hint = c.argumentHint { Text(hint).font(.caption.monospaced()).foregroundStyle(.tertiary) }
                            Text(c.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }
}
