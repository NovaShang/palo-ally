import PaloAllyKit
import SwiftUI

// Pieces a conversation page puts at its bottom in place of its input, and
// the quiet labels over messages and cards. Shared by a Pal's page, an
// Ally's (they began as a session's page) and 最近的对话.

/// Small glyph and words, quiet: the label over a message or on a card.
struct QuietLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.caption2)
            configuration.title.font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }
}

/// Something with consequences, asked in the page (never a dialog): what
/// happens, then 算了 and the action.
struct ConfirmPanel: View {
    let title: String
    let text: String
    let action: String
    let working: Bool
    var destructive = true
    /// On glass at the page's bottom; false: inside a list row, where it was tapped.
    var glass = true
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        if glass {
            content
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedText.verbatimKey(title)).font(.headline)
            Text(LocalizedText.verbatimKey(text))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(action: cancel) {
                    Text("算了").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                Button(action: confirm) {
                    Text(working ? String(localized: "正在处理…") : LocalizedText.verbatimKey(action)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(destructive ? .red : .accentColor)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .disabled(working)
        }
    }
}

/// One line about how things stand, and the way on.
struct NoticePanel: View {
    let text: String
    let action: String
    /// On glass at the page's bottom; false: inside a list row.
    var glass = true
    let tap: () -> Void

    var body: some View {
        let line = HStack(spacing: 12) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action, action: tap)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.primary)
        }
        if glass {
            line
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 52)
                .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        } else {
            line
        }
    }
}

/// A line to run in a terminal, with a copy button: what it is, why, and ✕.
struct CommandPanel: View {
    let title: String
    let text: String
    let command: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关上")
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                // Whole where it fits: the folder comes first in the line.
                Text(command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("resume-command")
                Spacer(minLength: 0)
                CopyButton(text: command, label: String(localized: "复制这一行"))
            }
            .padding(.leading, 12)
            .padding(.vertical, 4)
            .background(.fill.tertiary, in: .rect(cornerRadius: 12, style: .continuous))
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }
}

/// The owner's words, on the right: filled when they said them, outlined
/// when someone said them for the owner (with that label above).
struct OwnWords: View {
    let text: String
    var outlined = false
    var label: String? = nil
    var labelSymbol = "arrow.turn.down.right"
    var leading: AnyView? = nil
    /// Small words under the bubble (an exchange's state).
    var caption: String? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 48)
            if let leading { leading }
            VStack(alignment: .trailing, spacing: 4) {
                if let label {
                    Label(label, systemImage: labelSymbol)
                        .labelStyle(QuietLabelStyle())
                }
                Text(MarkdownBlock.attributed(text))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background {
                        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
                        if outlined {
                            shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                        } else {
                            shape.fill(Color(.secondarySystemFill))
                        }
                    }
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("复制", systemImage: "doc.on.doc") { Clipboard.copy(text) }
                    }
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .contentTransition(.opacity)
                }
            }
        }
    }
}

/// A bottom bar's text box and send button, on glass: the owner's words go
/// out as they are. The theme color is on the send arrow only.
struct WordsInputBar: View {
    let placeholder: String
    @Binding var text: String
    let enabled: Bool
    let send: () -> Void
    var identifier = "page-input"
    @FocusState private var focused: Bool
    @Environment(VoiceInputController.self) private var voice
    /// Tap-to-talk dictation is running into this bar (the mic, as in the
    /// conversations' composer): the live words show in the field's place.
    @State private var dictating = false
    @State private var finishing = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let canSend = enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(alignment: .bottom, spacing: 4) {
            ZStack(alignment: .leading) {
                TextField(placeholder, text: $text, axis: .vertical)
                    // The Mac has the room: a long dictation stays readable.
                    .lineLimit(1...(sizeClass == .regular ? 12 : 6))
                    .focused($focused)
                    .opacity(dictating ? 0 : 1)
                    .accessibilityIdentifier(identifier)
                if dictating {
                    HStack(spacing: 8) {
                        LevelBars(level: voice.dictation.level, bars: 4).frame(height: 18)
                        Text(live)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.head)
                    }
                }
            }
            .padding(.vertical, 11)
            .padding(.leading, 16)
            Button(action: toggleDictation) {
                Image(systemName: dictating ? "stop.circle.fill" : "mic")
                    .font(.system(size: dictating ? 26 : 18, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(dictating ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(finishing || voice.isActive || voice.isArmed)
            .accessibilityLabel(dictating ? String(localized: "结束语音输入") : String(localized: "语音输入"))
            if !dictating {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("发送")
            }
        }
        .padding(.trailing, 2)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        .onDisappear { if dictating { voice.dictation.cancel(); dictating = false } }
    }

    private var live: String {
        let t = voice.dictation.transcript
        if !t.isEmpty { return t }
        return finishing ? String(localized: "识别中…") : String(localized: "在听…再点一下麦克风结束")
    }

    /// Tap: listen; tap again: the words land at the end of what's written,
    /// and the field takes the keyboard to check them.
    private func toggleDictation() {
        if dictating {
            finishing = true
            Task {
                let words = await voice.dictation.finish()
                finishing = false
                dictating = false
                if !words.isEmpty { text = text.isEmpty ? words : text + words }
                focused = true
            }
        } else {
            focused = false
            voice.dictation.prewarm()
            voice.dictation.start()
            dictating = true
        }
    }
}
