import PaloAllyKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// One Liquid Glass capsule: [+] [message field] [mic / send].
/// - tap the field → keyboard (the system TextField; the on-screen Return is a
///   newline; on a hardware keyboard / Mac Return sends and Shift/Option/⌘+Return
///   is a newline, while an input method composing keeps Return for itself);
/// - press and hold the field → hold-to-talk: recording starts the instant
///   the finger lands (so the first words are never lost) while an arming
///   animation runs; release before it completes = a tap (audio discarded,
///   animation reverses, keyboard); held past it = listening — release sends,
///   slide onto 取消 / 编辑 first to cancel or edit;
/// - tap the mic (always there, also while typing) → dictation into the
///   field: tap again to stop, the words land at the end of the draft to
///   edit (never auto-sent); a send button appears beside it when there's
///   something to send;
/// - [+] → photos or files, staged above the capsule.
struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(VoiceInputController.self) private var voice
    @Environment(\.scenePhase) private var scenePhase
    @Binding var draft: String
    let onSend: (String, [AppStore.OutgoingImage], [AppStore.OutgoingFile]) -> Void
    /// Images and files picked or pasted for the next message (bento's staged attachments).
    @State private var staged: [Staged] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    /// A newline typed by ⌘↩ just now: not a Return to send.
    @State private var keepNewlineUntil = Date.distantPast
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    /// 拍照 only where there is a camera (not on Mac).
    private static let cameraAvailable = !ProcessInfo.processInfo.isMacCatalystApp
        && UIImagePickerController.isSourceTypeAvailable(.camera)
    private static let maxStaged = 6
    private static let maxFileBytes = 100 * 1024 * 1024
    /// Editing (keyboard up). Reported by the text view.
    @FocusState private var focused: Bool
    /// Bump to raise the keyboard (tap on the idle field, after editing a dictation).
    @State private var focusToken = 0
    /// Mic-button dictation (tap to start, tap to stop) — distinct from hold-to-talk.
    @State private var dictating = false
    @State private var finishingDictation = false

    // Press tracking for hold-to-talk on the field (ComposerPressGesture).
    @State private var pressing = false
    @State private var moved = false
    @State private var voiceStarted = false
    /// A finished hold is still resolving its final text: ignore new presses.
    @State private var finishingHold = false

    private static let capsuleSpace = "composerCapsule"

    // Placement. Keyboard down ("docked"): the capsule floats concentric with
    // the display corners, like ChatGPT and the iOS 26 system bars — equal
    // inset from the bottom edge and both sides, and its corner radius is the
    // screen's radius minus that inset, so the curves share a centre. A 56 pt
    // pill (radius 28) gets inset = displayRadius − 28 (34 pt on a 62 pt
    // display). Keyboard up: a plain capsule just above the keyboard.
    @State private var keyboardUp = false
    @State private var displayRadius: CGFloat = 0
    @State private var homeInset: CGFloat = 0
    private static let dockedRadius: CGFloat = 28
    private static let dockedHeight: CGFloat = 56
    private static let editingRadius: CGFloat = 22
    private static let editingHeight: CGFloat = 44
    private static let minInset: CGFloat = 12

    private var docked: Bool { !keyboardUp }
    /// Concentric only when the composer actually spans the display's bottom
    /// corners (the phone layout); beside a sidebar or inspector it's a
    /// regular floating capsule with even margins.
    private var spansDisplay: Bool { model.layout == .phone }
    private var concentric: Bool { docked && spansDisplay && displayRadius > 0 }
    private var sideInset: CGFloat {
        // Beside a sidebar or inspector: the same even margins as the conversation.
        guard concentric else { return spansDisplay ? Self.minInset : 20 }
        return max(Self.minInset, displayRadius - Self.dockedRadius)
    }
    private var capsuleRadius: CGFloat { docked ? Self.dockedRadius : Self.editingRadius }
    private var rowHeight: CGFloat { docked ? Self.dockedHeight : Self.editingHeight }
    /// The composer sits above the home-indicator inset; docked, the capsule
    /// goes `sideInset` from the screen's bottom edge — into that inset when
    /// the inset is the larger of the two.
    private var bottomPadding: CGFloat { concentric || (docked && spansDisplay) ? max(0, sideInset - homeInset) : 8 }
    private var bottomOffset: CGFloat { concentric || (docked && spansDisplay) ? max(0, homeInset - sideInset) : 0 }

    /// From touch-down to "listening". Recording runs the whole time; this
    /// only tells a tap (keyboard) from a hold (voice), and is long enough for
    /// the arming animation to read.
    private static let holdSeconds = 0.22

    /// Typing "/" (and nothing after a space yet) opens command suggestions.
    /// Nothing in the UI mentions this: it's for people who already know.
    private var slashQuery: String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty }
    /// Idle: not editing — the field reads 「按住说话，轻点打字」 and takes presses.
    private var idle: Bool { !focused && !dictating }

    /// The owner is doing something here — typing, dictating, holding to
    /// talk, staging attachments, quoting. The 「试试」 suggestions at the end
    /// of the conversation stay away meanwhile (SuggestionsGate).
    private var engaged: Bool {
        !idle || !draft.isEmpty || !staged.isEmpty || slashQuery != nil
            || voice.isActive || pressing || store.replyDraft != nil
    }

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
            if let reply = store.replyDraft {
                QuoteBanner(reply: reply) { withAnimation(.snappy) { store.replyDraft = nil } }
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
        .background {
            // ⌘↩ types a newline; Return alone sends on a hardware keyboard.
            Button("", action: typeNewline)
                .keyboardShortcut(.return, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onAppear { HardwareKeyboard.startWatching() }
        .padding(.horizontal, sideInset)
        .padding(.top, 6)
        .padding(.bottom, bottomPadding)
        .offset(y: bottomOffset)
        // Large screens: same line length as the conversation, centred.
        .frame(maxWidth: spansDisplay ? .infinity : ChatView.readableWidth)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: slashQuery)
        .animation(.snappy, value: staged.count)
        .onChange(of: focusToken) { focused = true }
        // A click elsewhere in the conversation (the Mac) leaves the field.
        .onChange(of: model.composerUnfocusRequests) { if focused { focused = false } }
        // The orb in the title bar notices the owner typing.
        .onChange(of: draft) { old, new in
            if hardwareReturn(old: old, new: new) {
                sendFromReturn(text: old)
                return
            }
            if focused { OrbInput.shared.typed() }
            SuggestionsGate.shared.touch()
        }
        .onChange(of: engaged, initial: true) { _, on in SuggestionsGate.shared.composer(engaged: on) }
        // 「回复」 / 「引用回复」 / 「聊聊」: open the keyboard to write the reply.
        .onChange(of: store.replyDraft) { _, reply in if reply != nil { focusToken += 1 } }
        .animation(.snappy, value: store.replyDraft)
        .onChange(of: slashQuery) { _, q in
            if q != nil { Task { await store.loadCommands() } }
        }
        // Warm the audio path ahead of the first press (no mic indicator).
        .onAppear {
            voice.prewarm()
            displayRadius = DisplayCorners.radius
            homeInset = DisplayCorners.bottomInset
        }
        // Rotation changes the home-indicator inset.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in homeInset = DisplayCorners.bottomInset }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { keyboardMoved($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { keyboardMoved($0, hiding: true) }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { voice.prewarm(); return }
            if dictating { voice.dictation.cancel(); dictating = false }
            if pressing { resetPress() }
            // After any recording is stopped (same serial audio queue).
            if phase == .background { voice.dictation.coolDown() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: pressing) { _, down in down }
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
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image, let data = image.jpegData(compressionQuality: 0.9) { addImages([data]) }
            }
            .ignoresSafeArea()
        }
    }

    private var capsule: some View {
        HStack(alignment: .bottom, spacing: 2) {
            plusButton.padding(.bottom, buttonLift)
            field
            trailingButton.padding(.bottom, buttonLift)
        }
        .frame(minHeight: rowHeight)
        // The capsule brightens as the recording UI grows out of it.
        .background {
            RoundedRectangle(cornerRadius: capsuleRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.24 * Double(voice.presence)))
                .allowsHitTesting(false)
        }
        .coordinateSpace(.named(Self.capsuleSpace))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { voice.capsuleSize = $0 }
        // Swells with the same hold-driven motion as everything else.
        .scaleEffect(1 + 0.035 * voice.presence)
        .glassEffect(capsuleGlass, in: .rect(cornerRadius: capsuleRadius, style: .continuous))
        .animation(.snappy, value: voice.target)
        .animation(.snappy, value: dictating)
        .animation(.snappy, value: canSend)
        .animation(.snappy, value: idle)
        // The hold-to-talk panel floats just above the capsule, anchored to it.
        .overlay(alignment: .bottom) {
            // One view from arming through listening and back: it grows out
            // of the capsule with `presence` and folds back into it.
            if voice.panelMounted {
                VoiceInputPanel(voice: voice)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, voice.capsuleSize.height + 18)
            }
        }
    }

    /// Keeps the 44 pt buttons centred on a one-line docked capsule (they
    /// stay at the bottom as the field grows to more lines).
    private var buttonLift: CGFloat { (rowHeight - 44) / 2 }

    /// Follows the keyboard: docked when it's down (or only the hardware
    /// keyboard's shortcut bar is showing), a plain capsule above it otherwise.
    private func keyboardMoved(_ note: Notification, hiding: Bool = false) {
        let info = note.userInfo ?? [:]
        let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        let screenHeight = (note.object as? UIScreen)?.bounds.height
            ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }.first ?? 0
        let up = !hiding && end.height > 80 && end.minY < screenHeight - 80
        guard up != keyboardUp else { return }
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        withAnimation(.smooth(duration: max(0.2, duration))) { keyboardUp = up }
    }

    private var capsuleGlass: Glass {
        if dictating { return .regular.tint(Color.accentColor.opacity(0.18)).interactive() }
        return .regular.interactive()
    }

    // MARK: - Pieces

    private var plusButton: some View {
        Menu {
            if Self.cameraAvailable {
                Button("拍照", systemImage: "camera") { showCamera = true }
            }
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
        // The Mac draws a menu as a bordered pop-up with a chevron; keep the bare +.
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .frame(width: 40, height: 44) // the Mac sizes a borderless menu to its glyph
        .padding(.leading, 4)
        .disabled(staged.count >= Self.maxStaged || dictating)
        .accessibilityLabel("添加照片或文件")
    }

    private var field: some View {
        ZStack(alignment: .leading) {
            // The system text field: the input method (pinyin and friends)
            // works exactly as everywhere else. The on-screen keyboard's
            // Return is a newline; sending is the send button. On a hardware
            // keyboard / Mac, Return sends (see hardwareReturn) and
            // Shift/Option/⌘+Return is a newline.
            TextField("", text: $draft, prompt: Text(focused ? "想让我做点什么？" : ""), axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                // The Mac: Esc leaves the field (the text stays); with an
                // input method composing, Esc is the input method's.
                .onKeyPress(.escape) {
                    guard Platform.isMac, focused, !HardwareKeyboard.isComposing else { return .ignored }
                    focused = false
                    return .handled
                }
                // While idle the press layer owns every touch: the text
                // field's own long-press / selection recognizers must not see it.
                .allowsHitTesting(!idle)
                .padding(.vertical, 11)
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
                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
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
                        // Morphs toward 「松开 发送」 as the hold arms.
                        ZStack {
                            Text("按住说话，轻点打字")
                                .foregroundStyle(pressing ? .secondary : .tertiary)
                                .opacity(1 - Double(voice.presence))
                            Text("松开 发送")
                                .foregroundStyle(.primary)
                                .opacity(Double(voice.presence))
                        }
                        .transition(.opacity)
                    }
                }
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight)
        .overlay {
            if idle {
                // Catches tap vs press-and-hold while not editing; while
                // editing it's gone so text selection works normally.
                Color.clear
                    .contentShape(.rect)
                    .gesture(ComposerPressGesture(
                        holdThreshold: Self.holdSeconds,
                        space: .named(Self.capsuleSpace),
                        onTouchDown: pressBegan,
                        onTap: { pressLifted(tap: true) },
                        onAbandon: { pressLifted(tap: false) },
                        onHold: pressHeld))
                    .accessibilityElement()
                    .accessibilityLabel("按住说话，轻点打字")
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

    /// Mic (always there, also while typing) and, when there's something to
    /// send, the send button to its right.
    private var trailingButton: some View {
        HStack(spacing: 0) {
            micButton
            if canSend && !dictating {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .frame(width: 40, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("发送")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.trailing, 2)
    }

    private var micButton: some View {
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
        .disabled(finishingDictation || voice.isActive || voice.isArmed)
        .accessibilityLabel(dictating ? "结束语音输入" : "语音输入")
    }

    // MARK: - Voice

    /// The finger just landed (ComposerPressGesture, straight from UIKit's
    /// touchesBegan). Feedback first, in this very frame; then recording,
    /// whose audio session / engine start runs off the main thread.
    private func pressBegan(touchTime: TimeInterval) -> Bool {
        guard !finishingHold, idle else { return false }
        VoiceTiming.begin("touch-down", touchTime: touchTime)
        pressing = true
        moved = false
        voiceStarted = false
        // Arming: the recording UI starts growing out of the capsule right
        // away, paced by the hold.
        voice.panelMounted = true
        withAnimation(.easeOut(duration: Self.holdSeconds)) { voice.presence = 0.72 }
        // Record from the very first instant; no permission yet → the system
        // asks, nothing records, and this press is spent.
        guard voice.arm() else {
            pressing = false
            moved = true
            collapse(.spring(response: 0.26, dampingFraction: 0.92))
            return false
        }
        VoiceTiming.mark("recording requested (arm returned)")
        return true
    }

    /// Lifted (tap) or moved away (scroll) before the hold committed.
    private func pressLifted(tap: Bool) {
        guard pressing else { return }
        pressing = false
        moved = !tap
        VoiceTiming.mark(tap ? "tap (audio discarded)" : "moved away (audio discarded)")
        disarm()
        if tap { focusToken += 1 }
    }

    /// After the hold committed: dragging between zones, then release.
    private func pressHeld(_ state: UIGestureRecognizer.State, at point: CGPoint) {
        switch state {
        case .began:
            guard pressing else { return }
            voiceStarted = true
            voice.commit()
            VoiceTiming.mark("hold committed")
            // Committed: settle into place.
            withAnimation(.spring(response: 0.32, dampingFraction: 0.74)) { voice.presence = 1 }
        case .changed:
            if voiceStarted { voice.track(point) }
        case .ended:
            guard voiceStarted else { return }
            voice.track(point)
            pressing = false
            voiceStarted = false
            finishingHold = true
            // Released: the recording UI folds back into the capsule (send,
            // cancel, edit alike) while the final text resolves.
            collapse(.spring(response: 0.36, dampingFraction: 0.86))
            Task {
                await finishVoice()
                finishingHold = false
            }
        default: // .cancelled — the system took the touch away
            resetPress()
            withAnimation(.spring(response: 0.26, dampingFraction: 0.92)) { voice.presence = 0 }
        }
    }

    /// Cancels an arming press: recording discarded, the motion plays backwards.
    private func disarm() {
        voice.disarm()
        collapse(.spring(response: 0.26, dampingFraction: 0.92))
    }

    /// Plays the recording UI back into the capsule, then unmounts it.
    private func collapse(_ animation: Animation) {
        withAnimation(animation) {
            voice.presence = 0
        } completion: {
            if !voice.isArmed && !voice.isActive && voice.presence == 0 { voice.panelMounted = false }
        }
    }

    /// Gesture interrupted (app left the foreground).
    private func resetPress() {
        pressing = false
        voiceStarted = false
        moved = false
        voice.abort()
        voice.presence = 0
        voice.panelMounted = false
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
            // Typing → dictating → typing: the words land at the end of the
            // draft and the keyboard comes back when it's done.
            focused = false
            VoiceTiming.begin("mic tap")
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

    /// Return on a hardware keyboard sends. The text view has already typed
    /// the newline when the draft changes, so a newline that just appeared on
    /// its own means Return. It stays a newline when Shift / Option / ⌘ is
    /// held, on the on-screen keyboard, during dictation, or while an input
    /// method composes (pinyin's Return commits the candidate, no newline).
    private func hardwareReturn(old: String, new: String) -> Bool {
        guard focused, !dictating, HardwareKeyboard.isAttached,
              Self.isNewlineTyped(into: old, giving: new) else { return false }
        if Date() < keepNewlineUntil || HardwareKeyboard.newlineModifierDown || HardwareKeyboard.isComposing {
            debugLog("[keys] Return kept as a newline")
            return false
        }
        return true
    }

    /// `new` is `old` with exactly one newline typed into it.
    static func isNewlineTyped(into old: String, giving new: String) -> Bool {
        guard new.count == old.count + 1 else { return false }
        let a = Array(old), b = Array(new)
        var i = 0
        while i < a.count, a[i] == b[i] { i += 1 }
        return b[i] == "\n" && b[(i + 1)...].elementsEqual(a[i...])
    }

    /// Takes the typed newline back out and sends; with nothing to send,
    /// Return just does nothing.
    private func sendFromReturn(text: String) {
        draft = text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty else { return }
        debugLog("[keys] Return sends")
        draft = ""
        deliver(text)
    }

    /// ⌘↩ (and the other modifiers) type a newline at the cursor.
    private func typeNewline() {
        keepNewlineUntil = Date().addingTimeInterval(0.5)
        HardwareKeyboard.insertNewline()
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

/// The system camera (UIImagePickerController); hands back the photo, or nil
/// when cancelled.
private struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
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
                                Image(systemName: "doc").foregroundStyle(.secondary)
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

/// What the next message replies to, above the capsule; ✕ drops it. Quiet,
/// like the staged-attachments row.
private struct QuoteBanner: View {
    let reply: ReplyTo
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Capsule().fill(.tertiary).frame(width: 2.5, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("回复").font(.caption).foregroundStyle(.secondary)
                Text(reply.excerpt.replacingOccurrences(of: "\n", with: " "))
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("不回复了")
        }
        .padding(.leading, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
