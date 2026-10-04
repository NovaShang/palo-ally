import PaloAllyKit
import SwiftUI

/// One Liquid Glass capsule, WeChat-style:
/// - tap → keyboard, normal editing (Return sends on a hardware keyboard /
///   Mac, Shift+Return is a newline; the send button appears with text);
/// - press and hold → voice input with the full-screen overlay; release to
///   send, slide onto 取消 / 编辑 to cancel or edit first.
struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @Environment(VoiceInputController.self) private var voice
    @Binding var draft: String
    let onSend: (String) -> Void
    @FocusState private var focused: Bool

    // Press tracking for the idle capsule.
    @State private var pressTask: Task<Void, Never>?
    @State private var pressing = false
    @State private var moved = false
    @State private var voiceStarted = false

    /// Hold this long before voice input starts.
    private let holdDelay: Duration = .milliseconds(280)

    /// Typing "/" (and nothing after a space yet) opens command suggestions.
    /// Nothing in the UI mentions this: it's for people who already know.
    private var slashQuery: String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Idle: not editing — the capsule reads 「按住 说话」 and takes presses.
    private var idle: Bool { !focused }

    var body: some View {
        VStack(spacing: 6) {
            if let typed = slashQuery {
                SlashSuggestions(commands: SlashCommand.filter(store.commands, typed: typed)) { cmd in
                    draft = "/\(cmd.name) "
                    focused = true
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let msg = voice.dictation.errorMessage, !voice.isActive {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ZStack(alignment: .leading) {
                    TextField("", text: $draft, prompt: Text(focused ? "想让我做点什么？" : ""), axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                        .padding(.vertical, 11)
                        .padding(.leading, 18)
                        .onKeyPress(keys: [.return], phases: .down) { press in
                            // Hardware keyboard / Mac: Return sends, Shift+Return
                            // (or Option+Return) is a newline. The on-screen
                            // keyboard doesn't come through here.
                            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                            send()
                            return .handled
                        }
                    if idle && draft.isEmpty {
                        Text("按住 说话")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay {
                    if idle {
                        // Catches tap vs press-and-hold while not editing; while
                        // editing it's gone so text selection works normally.
                        Color.clear
                            .contentShape(.rect)
                            .gesture(pressGesture)
                            .accessibilityElement()
                            .accessibilityLabel("按住说话，轻点打字")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { focused = true }
                    }
                }

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
            .scaleEffect(pressing && voiceStarted ? 0.97 : 1)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
            .animation(.snappy, value: canSend)
            .animation(.snappy, value: idle)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.snappy, value: slashQuery)
        .onChange(of: slashQuery) { _, q in
            if q != nil { Task { await store.loadCommands() } }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: voiceStarted) { _, started in started }
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                if !pressing {
                    pressing = true
                    moved = false
                    voiceStarted = false
                    voice.prewarm()
                    pressTask = Task { @MainActor in
                        try? await Task.sleep(for: holdDelay)
                        guard !Task.isCancelled, pressing, !moved else { return }
                        voiceStarted = true
                        voice.begin()
                    }
                } else if voiceStarted {
                    voice.track(v.location)
                } else if hypot(v.translation.width, v.translation.height) > 12 {
                    // Moved before the hold kicked in: not a press-and-hold.
                    moved = true
                    pressTask?.cancel()
                }
            }
            .onEnded { v in
                pressTask?.cancel()
                pressTask = nil
                let wasVoice = voiceStarted
                let wasMoved = moved
                pressing = false
                voiceStarted = false
                if wasVoice {
                    voice.track(v.location)
                    Task { await finishVoice() }
                } else if !wasMoved {
                    focused = true
                }
            }
    }

    private func finishVoice() async {
        let (target, text) = await voice.end()
        switch target {
        case .cancel:
            break
        case .edit:
            guard !text.isEmpty else { focused = true; return }
            draft = draft.isEmpty ? text : draft + text
            focused = true
        case .send:
            if !text.isEmpty { onSend(text) }
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        onSend(text)
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
