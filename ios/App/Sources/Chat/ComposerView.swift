import PaloAllyKit
import PhotosUI
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
    let onSend: (String, [AppStore.OutgoingImage]) -> Void
    /// Images picked or pasted for the next message (bento's staged attachments).
    @State private var staged: [AppStore.OutgoingImage] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    private static let maxImages = 6
    /// Editing (keyboard up). Reported by the text view.
    @State private var focused = false
    @State private var focusToken = 0
    @State private var editorHeight: CGFloat = 0
    @State private var composing = false

    // Press tracking for the idle capsule.
    @State private var pressTask: Task<Void, Never>?
    @State private var pressing = false
    @State private var moved = false
    @State private var voiceStarted = false

    /// Hold this long before voice input starts.
    /// Short: the capsule reacts on touch-down, so this only has to tell a
    /// tap (keyboard) from a hold (voice).
    private static let capsuleSpace = "composerCapsule"
    private static let maxEditorHeight: CGFloat = 160

    private let holdDelay: Duration = .milliseconds(160)

    /// Typing "/" (and nothing after a space yet) opens command suggestions.
    /// Nothing in the UI mentions this: it's for people who already know.
    private var slashQuery: String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty }
    /// Idle: not editing — the capsule reads 「按住 说话」 and takes presses.
    private var idle: Bool { !focused }

    var body: some View {
        VStack(spacing: 6) {
            if let typed = slashQuery {
                SlashSuggestions(commands: SlashCommand.filter(store.commands, typed: typed)) { cmd in
                    draft = "/\(cmd.name) "
                    focusToken += 1
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !staged.isEmpty {
                StagedImages(images: staged) { i in staged.remove(at: i) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let msg = voice.dictation.errorMessage, !voice.isActive {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .bottom, spacing: 6) {
                ZStack(alignment: .leading) {
                    // bento's UITextView-backed editor: smooth with big pastes,
                    // and Return never sends while picking a pinyin candidate.
                    ComposerTextEditor(text: $draft, measuredHeight: $editorHeight, isComposing: $composing,
                                       isFocused: $focused, maxHeight: Self.maxEditorHeight,
                                       focusToken: focusToken, onReturn: send,
                                       onPasteImages: { add($0) })
                        .frame(height: min(max(editorHeight, 44), Self.maxEditorHeight))
                        .padding(.leading, 18)
                        .padding(.trailing, canSend ? 0 : 14)
                        .overlay(alignment: .leading) {
                            if focused && draft.isEmpty && !composing {
                                Text("想让我做点什么？")
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 18)
                                    .allowsHitTesting(false)
                            }
                        }
                    if idle && draft.isEmpty {
                        Group {
                            if voiceStarted {
                                HStack(spacing: 10) {
                                    LevelBars(level: voice.dictation.level, bars: 4).frame(height: 18)
                                    Text(voice.target == .send ? "松开 发送" : "松开 \(voice.target == .cancel ? "取消" : "编辑")")
                                        .contentTransition(.opacity)
                                    LevelBars(level: voice.dictation.level, bars: 4).frame(height: 18)
                                }
                                .foregroundStyle(voice.target == .send ? Color.primary : .secondary)
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                            } else {
                                Text("按住 说话")
                                    .foregroundStyle(pressing ? .secondary : .tertiary)
                                    .transition(.opacity)
                            }
                        }
                        .font(.body.weight(.medium))
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
                            .accessibilityAction { focusToken += 1 }
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
            .coordinateSpace(.named(Self.capsuleSpace))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { voice.capsuleSize = $0 }
            // Reacts the instant the finger lands; lights up once it's listening.
            .scaleEffect(pressing ? (voiceStarted ? 1.03 : 0.97) : 1)
            .glassEffect(voiceStarted && voice.target == .send ? .regular.tint(Color.accentColor.opacity(0.35)).interactive()
                                                               : .regular.interactive(),
                         in: .rect(cornerRadius: 22))
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressing)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: voiceStarted)
            .animation(.snappy, value: voice.target)
            // The voice panel floats just above the capsule, anchored to it.
            .overlay(alignment: .bottom) {
                if voice.isActive {
                    VoiceInputPanel(voice: voice)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, voice.capsuleSize.height + 18)
                        .transition(.opacity)
                }
            }
            .animation(.snappy, value: canSend)
            .animation(.snappy, value: idle)

                // Photos: a glass circle beside the capsule (WeChat's ⊕ spot).
                PhotosPicker(selection: $pickerItems, maxSelectionCount: Self.maxImages - staged.count, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .disabled(staged.count >= Self.maxImages)
                .accessibilityLabel("发图片")
            }
            .animation(.snappy, value: staged.count)
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                pickerItems = []
                Task {
                    var picked: [Data] = []
                    for item in items { if let d = try? await item.loadTransferable(type: Data.self) { picked.append(d) } }
                    add(picked)
                }
            }
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
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.capsuleSpace))
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
                    focusToken += 1
                }
            }
    }

    private func finishVoice() async {
        let (target, text) = await voice.end()
        switch target {
        case .cancel:
            break
        case .edit:
            guard !text.isEmpty else { focusToken += 1; return }
            draft = draft.isEmpty ? text : draft + text
            focusToken += 1
        case .send:
            if !text.isEmpty || !staged.isEmpty {
                onSend(text, staged)
                staged = []
            }
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        onSend(text, staged)
        staged = []
    }

    private func add(_ raw: [Data]) {
        let room = Self.maxImages - staged.count
        let prepared = raw.prefix(room).compactMap(ImagePrep.process)
        staged.append(contentsOf: prepared)
        if prepared.count < min(raw.count, room) { voice.dictation.errorMessage = "有图片读不了，换一张试试" }
    }
}

/// Thumbnails of images staged for the next message, each removable.
private struct StagedImages: View {
    let images: [AppStore.OutgoingImage]
    let remove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                    ZStack(alignment: .topTrailing) {
                        if let ui = UIImage(data: img.data) {
                            Image(uiImage: ui).resizable().scaledToFill()
                                .frame(width: 60, height: 60)
                                .clipShape(.rect(cornerRadius: 12))
                        }
                        Button { remove(i) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.primary)
                                .frame(width: 20, height: 20)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("移除这张图片")
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
