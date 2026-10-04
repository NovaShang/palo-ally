import PaloAllyKit
import SwiftUI

struct ComposerView: View {
    @Binding var draft: String
    let dictation: SpeechDictation
    let onSend: () -> Void
    @FocusState private var focused: Bool

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 6) {
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
