import PaloAllyKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// One Liquid Glass capsule: [+] [message field] [mic / send].
/// - tap the field → keyboard (Return sends on a hardware keyboard / Mac,
///   Shift+Return is a newline);
/// - press and hold the field → hold-to-talk: release sends, slide onto
///   取消 / 编辑 first to cancel or edit;
/// - tap the mic → dictation into the field: tap again to stop, the text stays
///   in the field to edit (never auto-sent); with text, the mic becomes send;
/// - [+] → photos or files, staged above the capsule.
struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @Environment(VoiceInputController.self) private var voice
    @Environment(\.scenePhase) private var scenePhase
    @Binding var draft: String
    let onSend: (String, [AppStore.OutgoingImage], [AppStore.OutgoingFile]) -> Void
    /// Images and files picked or pasted for the next message (bento's staged attachments).
    @State private var staged: [Staged] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    private static let maxStaged = 6
    private static let maxFileBytes = 100 * 1024 * 1024
    /// Editing (keyboard up). Reported by the text view.
    @State private var focused = false
    @State private var focusToken = 0
    @State private var editorHeight: CGFloat = 0
    @State private var composing = false
    /// Mic-button dictation (tap to start, tap to stop) — distinct from hold-to-talk.
    @State private var dictating = false
    @State private var finishingDictation = false

    // Press tracking for hold-to-talk on the field.
    @State private var pressTask: Task<Void, Never>?
    @State private var pressing = false
    @State private var moved = false
    @State private var voiceStarted = false

    private static let capsuleSpace = "composerCapsule"
    private static let maxEditorHeight: CGFloat = 160

    /// Short: the capsule reacts on touch-down, so this only has to tell a
    /// tap (keyboard) from a hold (voice).
    private let holdDelay: Duration = .milliseconds(160)

    /// Typing "/" (and nothing after a space yet) opens command suggestions.
    /// Nothing in the UI mentions this: it's for people who already know.
    private var slashQuery: String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty }
    /// Idle: not editing — the field reads 「按住 语音输入」 and takes presses.
    private var idle: Bool { !focused && !dictating }

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
                StagedRow(items: staged) { i in staged.remove(at: i) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let msg = voice.dictation.errorMessage, !voice.isActive, !dictating {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            capsule
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.snappy, value: slashQuery)
        .animation(.snappy, value: staged.count)
        .onChange(of: slashQuery) { _, q in
            if q != nil { Task { await store.loadCommands() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, dictating { voice.dictation.cancel(); dictating = false }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: voiceStarted) { _, started in started }
        .sensoryFeedback(.impact(weight: .light), trigger: dictating)
        .photosPicker(isPresented: $showPhotos, selection: $pickerItems,
                      maxSelectionCount: max(1, Self.maxStaged - staged.count), matching: .images)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task {
                var picked: [Data] = []
                for item in items { if let d = try? await item.loadTransferable(type: Data.self) { picked.append(d) } }
                addImages(picked)
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
    }

    private var capsule: some View {
        HStack(alignment: .bottom, spacing: 2) {
            plusButton
            field
            trailingButton
        }
        .frame(minHeight: 44)
        .coordinateSpace(.named(Self.capsuleSpace))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { voice.capsuleSize = $0 }
        // Reacts the instant the finger lands; lights up once it's listening.
        .scaleEffect(pressing ? (voiceStarted ? 1.03 : 0.97) : 1)
        .glassEffect(capsuleGlass, in: .rect(cornerRadius: 22))
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressing)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: voiceStarted)
        .animation(.snappy, value: voice.target)
        .animation(.snappy, value: dictating)
        .animation(.snappy, value: canSend)
        .animation(.snappy, value: idle)
        // The hold-to-talk panel floats just above the capsule, anchored to it.
        .overlay(alignment: .bottom) {
            if voice.isActive {
                VoiceInputPanel(voice: voice)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, voice.capsuleSize.height + 18)
                    .transition(.opacity)
            }
        }
    }

    private var capsuleGlass: Glass {
        if voiceStarted && voice.target == .send { return .regular.tint(Color.accentColor.opacity(0.35)).interactive() }
        if dictating { return .regular.tint(Color.accentColor.opacity(0.18)).interactive() }
        return .regular.interactive()
    }

    // MARK: - Pieces

    private var plusButton: some View {
        Menu {
            Button("照片", systemImage: "photo.on.rectangle") { showPhotos = true }
            Button("文件", systemImage: "doc") { showFiles = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 44)
                .contentShape(.rect)
        }
        .tint(.secondary) // Menu tints its label with the accent; match the mic
        .padding(.leading, 4)
        .disabled(staged.count >= Self.maxStaged || dictating)
        .accessibilityLabel("添加照片或文件")
    }

    private var field: some View {
        ZStack(alignment: .leading) {
            // bento's UITextView-backed editor: smooth with big pastes,
            // and Return never sends while picking a pinyin candidate.
            ComposerTextEditor(text: $draft, measuredHeight: $editorHeight, isComposing: $composing,
                               isFocused: $focused, maxHeight: Self.maxEditorHeight,
                               focusToken: focusToken, onReturn: send,
                               onPasteImages: { addImages($0) })
                .frame(height: min(max(editorHeight, 44), Self.maxEditorHeight))
                .overlay(alignment: .leading) {
                    if focused && draft.isEmpty && !composing && !dictating {
                        Text("想让我做点什么？")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }
                .opacity(dictating ? 0 : 1)
            if dictating {
                // Mic dictation: the live words, in the field where they'll land.
                HStack(spacing: 8) {
                    LevelBars(level: voice.dictation.level, bars: 4).frame(height: 18)
                    Text(dictationPreview)
                        .foregroundStyle(voice.dictation.transcript.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .allowsHitTesting(false)
                .transition(.opacity)
            } else if idle && draft.isEmpty {
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
                        Text("按住 语音输入")
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
                    .accessibilityLabel("按住语音输入，轻点打字")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { focusToken += 1 }
            }
        }
    }

    private var dictationPreview: String {
        let t = voice.dictation.transcript
        if !t.isEmpty { return t }
        return finishingDictation ? "识别中…" : "在听…再点一下麦克风结束"
    }

    @ViewBuilder private var trailingButton: some View {
        if canSend && !dictating {
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("发送")
            .transition(.scale.combined(with: .opacity))
        } else {
            Button(action: toggleDictation) {
                Group {
                    if dictating {
                        // Listening: a tinted glass stop button — tap again to finish.
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .glassEffect(.regular.tint(Color.accentColor.opacity(0.9)).interactive(), in: .circle)
                            .symbolEffect(.pulse, isActive: !finishingDictation)
                    } else {
                        Image(systemName: "mic")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
            .disabled(finishingDictation || voice.isActive)
            .accessibilityLabel(dictating ? "结束语音输入" : "语音输入")
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Voice

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
            if !text.isEmpty || !staged.isEmpty { deliver(text) }
        }
    }

    /// Mic button: first tap listens, second tap stops and leaves the words in
    /// the field to edit (bento's tap-to-toggle; never sends by itself).
    private func toggleDictation() {
        if dictating {
            finishingDictation = true
            Task {
                let text = await voice.dictation.finish()
                finishingDictation = false
                dictating = false
                if !text.isEmpty { draft = draft.isEmpty ? text : draft + text }
                focusToken += 1
            }
        } else {
            voice.dictation.prewarm()
            voice.dictation.start()
            dictating = true
        }
    }

    // MARK: - Sending and staging

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        deliver(text)
    }

    private func deliver(_ text: String) {
        var images: [AppStore.OutgoingImage] = []
        var files: [AppStore.OutgoingFile] = []
        for item in staged {
            switch item {
            case .image(let i): images.append(i)
            case .file(let f): files.append(f)
            }
        }
        onSend(text, images, files)
        staged = []
    }

    private func addImages(_ raw: [Data]) {
        let room = Self.maxStaged - staged.count
        let prepared = raw.prefix(room).compactMap(ImagePrep.process)
        staged.append(contentsOf: prepared.map(Staged.image))
        if prepared.count < min(raw.count, room) { voice.dictation.errorMessage = "有图片读不了，换一张试试" }
    }

    /// Files from the Files app. Pictures among them go as images (so the
    /// assistant sees them); everything else as files.
    private func addFiles(_ urls: [URL]) {
        var problem: String?
        for url in urls.prefix(Self.maxStaged - staged.count) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { problem = "有文件读不了"; continue }
            guard data.count <= Self.maxFileBytes else { problem = "文件太大（最多 100MB）"; continue }
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true, let img = ImagePrep.process(data) {
                staged.append(.image(img))
            } else {
                let mime = type?.preferredMIMEType ?? "application/octet-stream"
                staged.append(.file(AppStore.OutgoingFile(data: data, mediaType: mime, name: url.lastPathComponent)))
            }
        }
        if let problem { voice.dictation.errorMessage = problem }
    }
}

/// Something staged for the next message.
enum Staged {
    case image(AppStore.OutgoingImage)
    case file(AppStore.OutgoingFile)
}

/// Staged images (thumbnails) and files (chips), each removable.
private struct StagedRow: View {
    let items: [Staged]
    let remove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    ZStack(alignment: .topTrailing) {
                        switch item {
                        case .image(let img):
                            if let ui = UIImage(data: img.data) {
                                Image(uiImage: ui).resizable().scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .clipShape(.rect(cornerRadius: 12))
                            }
                        case .file(let f):
                            HStack(spacing: 8) {
                                Image(systemName: "doc").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.name).font(.caption.weight(.medium)).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(f.data.count), countStyle: .file))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: 180, minHeight: 60)
                            .glassEffect(.regular, in: .rect(cornerRadius: 12))
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
                        .accessibilityLabel("移除")
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
