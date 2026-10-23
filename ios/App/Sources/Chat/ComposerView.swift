import PaloAllyKit
import PaloAllyVoice
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
///   slide onto 取消 / 编辑 first to cancel or edit; also while the field is
///   being edited (a press that stays put a little longer, `editHoldSeconds`;
///   a click still places the cursor, a drag still selects). Words spoken
///   continue what the field holds: 发送 sends the two as one message, 编辑
///   puts them in the field, 取消 leaves the field as it was;
/// - tap the mic (always there, also while typing) → dictation into the
///   field: tap again to stop, the words land at the end of the draft to
///   edit (never auto-sent); a send button appears beside it when there's
///   something to send;
/// - [+] → photos or files, staged above the capsule; also dropped on the
///   conversation or pasted into the field (`ComposerIntake`).
///
/// The same composer for the assistant and for a Pal (pals-prd §15).
struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowModel.self) private var model
    @Environment(VoiceInputController.self) private var voice
    @Environment(\.scenePhase) private var scenePhase
    /// Inside a workspace's tile: only the active one takes voice and focus.
    @Environment(\.tile) private var tile
    @Binding var draft: String
    /// How a message goes out: typed (it rises to the top in an animation),
    /// or spoken (placed at once under the voice scrim, its words then fly
    /// into it; sent once the final words come, `AppStore.sendStaged`).
    enum Outgoing { case typed, spoken(cid: String) }
    /// Dropped and pasted images and files, to stage.
    var intake: ComposerIntake? = nil
    let onSend: (String, [AppStore.OutgoingImage], [AppStore.OutgoingFile], Outgoing) -> Void
    /// Images and files picked or pasted for the next message (bento's staged attachments).
    @State private var staged: [Staged] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    /// A newline typed by ⌘↩ just now: not a Return to send.
    @State private var keepNewlineUntil = Date.distantPast
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    /// 电脑上的文件: a file on the computer, by its path (docs/files-prd.md).
    @State private var showComputerFiles = false
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
    /// Counts presses, so a late reveal of an earlier press does nothing.
    @State private var pressSerial = 0
    /// A finished hold is still resolving its final text: ignore new presses.
    @State private var finishingHold = false
    /// The hold under way is the right mouse button's (`pointerHold`), not a press on the field.
    @State private var pointerHolding = false
    @State private var onScreen = false
    /// When the press on the field being edited landed (timing only).
    @State private var editTouchTime: TimeInterval?
    /// Where this composer is, kept for the voice when its tile becomes the active one.
    @State private var capsuleSize: CGSize = .zero
    @State private var capsuleFrame: CGRect = .zero
    @State private var fieldFrame: CGRect = .zero
    /// Words that flew into the field (`.edit`) before the final ones came:
    /// the draft as it was, and what was added. The final words replace
    /// them if the draft is still just that.
    @State private var editedIn: (before: String, words: String)?

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
    /// A tile of a split workspace on the Mac: a one-line capsule this tall,
    /// smaller buttons, tighter margins (the tiles need the room).
    private static let compactHeight: CGFloat = 30
    private static let compactButtonHeight: CGFloat = 30

    private var docked: Bool { !keyboardUp }
    /// The compact composer (a tile on the Mac).
    private var compact: Bool { tile != nil }
    /// Concentric only when the composer actually spans the display's bottom
    /// corners (the phone layout); beside a sidebar or inspector it's a
    /// regular floating capsule with even margins.
    private var spansDisplay: Bool { model.layout == .phone }
    private var concentric: Bool { docked && spansDisplay && displayRadius > 0 }
    private var sideInset: CGFloat {
        if compact { return 8 }
        // Beside a sidebar or inspector: the same even margins as the conversation.
        guard concentric else { return spansDisplay ? Self.minInset : 20 }
        return max(Self.minInset, displayRadius - Self.dockedRadius)
    }
    private var capsuleRadius: CGFloat {
        if compact { return Self.compactHeight / 2 }
        return docked ? Self.dockedRadius : Self.editingRadius
    }
    private var rowHeight: CGFloat {
        if compact { return Self.compactHeight }
        return docked ? Self.dockedHeight : Self.editingHeight
    }
    /// The +, mic and send buttons' height (their tap area).
    private var buttonHeight: CGFloat { compact ? Self.compactButtonHeight : 44 }
    /// The composer sits above the home-indicator inset; docked, the capsule
    /// goes `sideInset` from the screen's bottom edge — into that inset when
    /// the inset is the larger of the two.
    private var bottomPadding: CGFloat {
        if compact { return sideInset } // as far from the bottom as from the sides
        return concentric || (docked && spansDisplay) ? max(0, sideInset - homeInset) : 8
    }
    private var bottomOffset: CGFloat { concentric || (docked && spansDisplay) ? max(0, homeInset - sideInset) : 0 }

    /// From touch-down to "listening". Recording runs the whole time; this
    /// only tells a tap (keyboard) from a hold (voice), and is long enough for
    /// the arming animation to read.
    private static let holdSeconds = 0.22
    /// How long a press shows nothing of the recording UI (it records already).
    private static let showDelay = 0.08
    /// While the field is being edited a press must stay put this long to
    /// talk: longer than a click, or the pause before dragging to select.
    /// Nothing records before it (every click into the text would turn the
    /// microphone on), so the panel comes up at once when it passes.
    private static let editHoldSeconds = 0.35
    /// How far a mouse or trackpad pointer may drift and still be a hold
    /// (a drag to select text moves further).
    private static let editPointerSlop: CGFloat = 4

    /// Typing "/" (and nothing after a space yet) opens command suggestions.
    /// Nothing in the UI mentions this: it's for people who already know.
    private var slashQuery: String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }

    /// The empty field, once it's being typed in: a Pal's page is a
    /// terminal of sorts, the assistant's a request.
    private var prompt: String {
        guard let id = store.palID else { return String(localized: "想让我做点什么？") }
        let name = store.singlePal(id: id)?.displayName ?? String(localized: "它")
        return Copy.spaced(String(localized: "跟\(name)说点什么"))
    }

    /// Where letting go would land, as the hold says it.
    private var releaseHint: String {
        switch voice.target {
        case .send: String(localized: "松开 发送")
        case .cancel: String(localized: "松开 取消")
        default: String(localized: "松开 编辑")
        }
    }

    /// Voice on screen is this composer's: outside a tiling unless a tile
    /// holds it (Palo's popover over the page), else the tile being spoken to.
    private var mine: Bool { voice.owner == tile?.id }
    private var voicePresence: CGFloat { mine ? voice.presence : 0 }
    /// This composer may place the voice's landing spots (the active tile, or no tiling).
    private var placesVoice: Bool { tile?.isActive ?? true }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty }
    /// Idle: not editing — the field reads 「按住说话，轻点打字」 and takes presses.
    /// Not editing: a layer over the field tells a tap (write) from a hold
    /// (talk). On the Mac, not while the field holds words: the layer took
    /// the wheel and the trackpad too, so a long dictation couldn't be
    /// scrolled back to check (a click focuses the field there anyway).
    private var idle: Bool { !focused && !dictating && !(model.layout != .phone && !draft.isEmpty) }

    /// The owner is doing something here — typing, dictating, holding to
    /// talk, staging attachments, quoting. The 「试试」 suggestions at the end
    /// of the conversation stay away meanwhile (SuggestionsGate).
    private var engaged: Bool {
        !idle || !draft.isEmpty || !staged.isEmpty || slashQuery != nil
            || voice.isActive || pressing || store.replyDraft != nil
    }

    var body: some View {
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("ComposerView")
        #endif
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
            if mine, let msg = voice.dictation.errorMessage, !voice.isActive, !voice.mounted, !dictating {
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
        .padding(.top, compact ? 2 : 6)
        .padding(.bottom, bottomPadding)
        .offset(y: bottomOffset)
        // Large screens: same line length as the conversation, centred.
        .frame(maxWidth: spansDisplay ? .infinity : ChatView.readableWidth)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: slashQuery)
        .animation(.snappy, value: staged.count)
        .onChange(of: focusToken) { if tile?.isActive != false { focused = true } }
        // A tile that is no longer the active one lets go of the keyboard.
        .onChange(of: tile?.isActive) { _, active in
            if active == false {
                if focused { focused = false }
            } else if active == true {
                voice.capsuleSize = capsuleSize
                voice.placeCapsule(capsuleFrame)
                voice.placeField(fieldFrame)
            }
        }
        // Back from 回到这里重来 with the message's words: straight on to editing them.
        .onAppear {
            guard model.focusComposerOnAppear else { return }
            model.focusComposerOnAppear = false
            focusToken += 1
        }
        #if DEBUG
        // `-demoKeyboard "4:3"`: type 4 s in (the keyboard rises), stop 3 s later.
        .task {
            guard let plan = UserDefaults.standard.string(forKey: "demoKeyboard"),
                  case let parts = plan.split(separator: ":").compactMap({ Double($0) }), parts.count == 2 else { return }
            try? await Task.sleep(for: .seconds(parts[0]))
            debugLog("[demo] keyboard up")
            focusToken += 1
            try? await Task.sleep(for: .seconds(parts[1]))
            debugLog("[demo] keyboard down")
            model.composerUnfocusRequests += 1
        }
        // `-demoPickFile YES`: 文件 from the ＋ menu, 4 s in (the Mac's file panel).
        .task {
            guard UserDefaults.standard.bool(forKey: "demoPickFile"), placesVoice else { return }
            try? await Task.sleep(for: .seconds(4))
            debugLog("[demo] file picker")
            showFiles = true
        }
        #endif
        // A click elsewhere in the conversation (the Mac) leaves the field.
        .onChange(of: model.composerUnfocusRequests) { if focused { focused = false } }
        // With a keyboard, a click in this conversation puts the keyboard here (ClickFocusesComposer).
        .onReceive(NotificationCenter.default.publisher(for: ComposerFocus.request)) { note in
            guard ComposerFocus.isFor(note, window: ObjectIdentifier(model), tile: tile?.id) else { return }
            guard !dictating, !voice.isActive, !voice.isArmed else {
                debugLog("[focus] the composer is busy with voice: it stays as it is")
                return
            }
            debugLog("[focus] the composer takes the keyboard\(focused ? " (it had it)" : "")\(tile.map { ", pane \($0.id.prefix(8))" } ?? "")")
            focusToken += 1
        }
        #if DEBUG
        // `-demoDraft "已有的字"`: the field starts with these words (voice drills with a draft).
        .task {
            guard let words = UserDefaults.standard.string(forKey: "demoDraft"), draft.isEmpty, placesVoice else { return }
            draft = words
            debugLog("[demo] the composer holds \(words.count) characters")
        }
        #endif
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
            // Words that went into the field: then the keyboard, to edit them.
            voice.onExitDone = { exit in
                if exit == .edit || exit == .unheard(edit: true) { focusToken += 1 }
                debugLog("[voice] down after \(VoiceInputController.name(exit)): the composer has \(draft.count) characters, the list is \(Int(ChatScroll.lastDistance)) pt from the end")
            }
        }
        #if DEBUG
        .task { await runVoiceDrill() }
        #endif
        // The Mac: the right mouse button held anywhere in the window, for this composer (MacRightHold).
        .onReceive(NotificationCenter.default.publisher(for: PointerVoice.note)) { note in
            guard let e = PointerVoice.from(note), e.window == ObjectIdentifier(model), e.owner == tile?.id else { return }
            pointerHold(e)
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
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
        // Dropped on the conversation or pasted: staged as if picked.
        .modifier(IntakeHooks(intake: intake, staged: $staged, focused: focused, room: Self.maxStaged, addImages: addImages))
        .modifier(ComputerFileSheet(shown: $showComputerFiles, draft: $draft))
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
                .fill(Color.accentColor.opacity(0.24 * Double(voicePresence)))
                .allowsHitTesting(false)
        }
        .coordinateSpace(.named(Self.capsuleSpace))
        // Not laid out yet (a window coming up, a tile with no room): a NaN
        // never equals itself, and kept it would come back as a change forever.
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            guard $0.width.isFinite, $0.height.isFinite else { return }
            capsuleSize = $0
            if placesVoice { voice.capsuleSize = $0 }
        }
        // Where the voice words go and land (it changes only when the composer moves).
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            guard $0.isFiniteRect else { return }
            capsuleFrame = $0
            if placesVoice { voice.placeCapsule($0) }
        }
        // Swells with the same hold-driven motion as everything else.
        .scaleEffect(1 + 0.035 * voicePresence)
        .glassEffect(capsuleGlass, in: .rect(cornerRadius: capsuleRadius, style: .continuous))
        .animation(.snappy, value: voice.target)
        .animation(.snappy, value: dictating)
        .animation(.snappy, value: canSend)
        .animation(.snappy, value: idle)
        // The hold-to-talk panel floats just above the capsule, anchored to it.
        .overlay(alignment: .bottom) {
            // One view from arming through listening and back: it grows out
            // of the capsule with `presence` and folds back into it.
            if mine && voice.panelMounted {
                VoiceInputPanel(voice: voice)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, voice.capsuleSize.height + 18)
            }
        }
    }

    /// Keeps the buttons centred on a one-line docked capsule (they stay at
    /// the bottom as the field grows to more lines).
    private var buttonLift: CGFloat { (rowHeight - buttonHeight) / 2 }

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
            Button { showComputerFiles = true } label: {
                Label { Text("电脑上的文件", tableName: "Files") } icon: { Image(systemName: "desktopcomputer") }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: compact ? 15 : 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: compact ? 32 : 40, height: buttonHeight)
                .contentShape(.rect)
        }
        .tint(.secondary) // Menu tints its label with the accent; match the mic
        // The Mac draws a menu as a bordered pop-up with a chevron; keep the
        // bare +, its whole frame clickable (macMenuHitArea).
        .macMenuHitArea()
        .menuIndicator(.hidden)
        .frame(width: compact ? 32 : 40, height: buttonHeight) // the Mac sizes a borderless menu to its glyph
        .padding(.leading, compact ? 2 : 4)
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
            TextField("", text: $draft, prompt: Text(focused ? prompt : ""), axis: .vertical)
                // The Mac page has the room: a long dictation stays readable (tiles keep 6).
                .lineLimit(1...(model.layout != .phone && !compact ? 12 : 6))
                .focused($focused)
                .accessibilityIdentifier("composerField")
                // The Mac: Esc leaves the field (the text stays); with an
                // input method composing, Esc is the input method's.
                .onKeyPress(.escape) {
                    guard Platform.isMac, focused, !HardwareKeyboard.isComposing else { return .ignored }
                    focused = false
                    return .handled
                }
                // Return sends before the field types its newline: no
                // newline flashing in, the message going, the field
                // clearing, one after the other. Shift/Option/⌘ still type
                // a newline; an input method composing keeps Return.
                .onKeyPress(.return, phases: .down) { press in
                    guard focused, !dictating, HardwareKeyboard.isAttached, !HardwareKeyboard.isComposing,
                          press.modifiers.isDisjoint(with: [.shift, .option, .command]) else { return .ignored }
                    sendFromReturn(text: draft)
                    return .handled
                }
                // While idle the press layer owns every touch: the text
                // field's own long-press / selection recognizers must not see it.
                .allowsHitTesting(!idle)
                // While editing: a press that stays put talks, beside the
                // text view's own gestures (a click, a drag, typing: theirs).
                // Always attached, so the field keeps its identity (and focus).
                .gesture(ComposerPressGesture(
                    holdThreshold: Self.editHoldSeconds,
                    space: .named(Self.capsuleSpace),
                    pointerSlop: Self.editPointerSlop,
                    shouldCommit: { beginHoldWhileEditing(touchTime: editTouchTime) },
                    cancelsOthersOnCommit: true,
                    onTouchDown: editPressDown,
                    onTap: {},
                    onAbandon: {},
                    onHold: { state, point in
                        // Only a hold this field started (another tile's voice is not ours).
                        guard pressing || voiceStarted else { return }
                        pressHeld(state, at: point)
                    }))
                // Where words spoken into 编辑 land.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    guard $0.isFiniteRect else { return }
                    fieldFrame = $0
                    if placesVoice { voice.placeField($0) }
                }
                .padding(.vertical, compact ? 6 : 11)
                // Blank while those words fly in; it fades in as they land.
                .opacity(dictating || (mine && voice.veilsField) ? 0 : 1)
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
                        // Just where release lands; the orb is the level meter.
                        Text(releaseHint)
                            .contentTransition(.opacity)
                            .foregroundStyle(voice.target == .send ? Color.primary : .secondary)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    } else {
                        // Morphs toward 「松开 发送」 as the hold arms (and
                        // back from where it was released, as the words go).
                        ZStack {
                            Text("按住说话，轻点打字")
                                .foregroundStyle(pressing ? .secondary : .tertiary)
                                .opacity(1 - Double(voicePresence))
                            Text(releaseHint)
                                .foregroundStyle(voice.target == .send ? Color.primary : .secondary)
                                .opacity(Double(voicePresence))
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
        return finishingDictation ? String(localized: "识别中…") : String(localized: "在听…再点一下麦克风结束")
    }

    /// Mic (always there, also while typing) and, when there's something to
    /// send, the send button to its right.
    private var trailingButton: some View {
        HStack(spacing: 0) {
            // The mic stays while the agent works (停止 is at the conversation's end);
            // typing, or holding to talk, queues the next message.
            micButton
            if canSend && !dictating {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: compact ? 21 : 30))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .frame(width: compact ? 32 : 40, height: buttonHeight)
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
                        .font(.system(size: compact ? 11 : 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: compact ? 24 : 34, height: compact ? 24 : 34)
                        .glassEffect(.regular.tint(Color.accentColor.opacity(0.9)).interactive(), in: .circle)
                        .symbolEffect(.pulse, isActive: !finishingDictation)
                } else {
                    Image(systemName: "mic")
                        .font(.system(size: compact ? 15 : 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: compact ? 34 : 44, height: buttonHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(finishingDictation || voice.isActive || voice.isArmed)
        .accessibilityLabel(dictating ? String(localized: "结束语音输入") : String(localized: "语音输入"))
    }

    // MARK: - Voice

    /// The finger just landed (ComposerPressGesture, straight from UIKit's
    /// touchesBegan). Feedback first, in this very frame; then recording,
    /// whose audio session / engine start runs off the main thread.
    private func pressBegan(touchTime: TimeInterval) -> Bool {
        // In a tiling only the active tile talks; a press elsewhere just activates it.
        guard !finishingHold, idle, tile?.isActive != false else { return false }
        claimVoice()
        VoiceTiming.begin("touch-down", touchTime: touchTime)
        pressing = true
        moved = false
        voiceStarted = false
        // Arming: recording starts now, but the recording UI waits a beat
        // before it grows out of the capsule, so a plain tap shows nothing
        // of it (the owner's ask: 50–100 ms).
        pressSerial += 1
        let serial = pressSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay) {
            guard serial == pressSerial, pressing, !voiceStarted else { return }
            voice.panelMounted = true
            withAnimation(.easeOut(duration: Self.holdSeconds - Self.showDelay)) { voice.presence = 0.72 }
        }
        // Record from the very first instant; no permission yet → the system
        // asks, nothing records, and this press is spent.
        guard voice.arm() else {
            pressing = false
            moved = true
            collapse(.spring(response: 0.26, dampingFraction: 0.92))
            return false
        }
        VoiceTiming.mark("recording requested (arm returned)")
        // The words continue what the field holds.
        voice.draftPrefix = draft
        return true
    }

    /// A press on the field while it is being edited. Only notes it: a
    /// click or a drag is the text view's, and nothing records yet.
    private func editPressDown(touchTime: TimeInterval) -> Bool {
        let ok = !idle && !finishingHold && !dictating && !voice.isActive && !voice.isArmed && tile?.isActive != false
        editTouchTime = ok ? touchTime : nil
        #if DEBUG
        debugLog("[hold] press on the field being edited\(ok ? "" : " (not for voice now)")")
        #endif
        return ok
    }

    /// The press on the field being edited stayed put past `editHoldSeconds`:
    /// recording starts and commits at once, from the words in the field.
    /// False: not now (the text view keeps the press).
    private func beginHoldWhileEditing(touchTime: TimeInterval?) -> Bool {
        guard !finishingHold, !dictating, !voice.isActive, !voice.isArmed, tile?.isActive != false else {
            debugLog("[hold] held on the field, but voice is busy: the press stays the text's")
            return false
        }
        claimVoice()
        VoiceTiming.begin("hold on the field being edited", touchTime: touchTime)
        guard voice.arm() else {
            debugLog("[hold] held on the field, no microphone yet")
            return false
        }
        voice.draftPrefix = draft
        pressing = true
        moved = false
        voiceStarted = false
        pressSerial += 1
        voice.panelMounted = true
        debugLog("[hold] talking from the field (\(draft.count) characters in it)")
        return true
    }

    /// The voice is this composer's for the hold: its place, and where it is told when the words are done.
    private func claimVoice() {
        voice.owner = tile?.id
        if tile != nil {
            voice.capsuleSize = capsuleSize
            voice.placeCapsule(capsuleFrame)
            voice.placeField(fieldFrame)
        }
        voice.onExitDone = { exit in
            if exit == .edit || exit == .unheard(edit: true) { focusToken += 1 }
            debugLog("[voice] down after \(VoiceInputController.name(exit)): the composer has \(draft.count) characters, the list is \(Int(ChatScroll.lastDistance)) pt from the end")
        }
    }

    #if DEBUG
    /// `-voiceDrill <seconds>` (with `-voiceDrillAudio YES`, see VoiceDrill,
    /// or scripted words, `-voiceDrillText`, see SpeechDictation): holds to
    /// talk that long on its own, then releases, through the same calls the
    /// press gesture makes — reproduces a long hold (and, with
    /// `-voiceDrillFailAfter`, a socket failure in it) unattended.
    /// `-voiceDrillTarget cancel|edit`: slides onto that zone first.
    /// `-voiceDrillRepeat <n>`: that many holds, `-voiceDrillGap` s apart (4).
    private func runVoiceDrill() async {
        let seconds = UserDefaults.standard.double(forKey: "voiceDrill")
        guard seconds > 0 else { return }
        let delay = UserDefaults.standard.double(forKey: "voiceDrillDelay")
        try? await Task.sleep(for: .seconds(delay > 0 ? delay : 6))
        let repeats = max(1, UserDefaults.standard.integer(forKey: "voiceDrillRepeat"))
        let gap = UserDefaults.standard.double(forKey: "voiceDrillGap")
        for round in 0..<repeats {
            if round > 0 { try? await Task.sleep(for: .seconds(gap > 0 ? gap : 4)) }
            debugLog("[drill] hold to talk for \(seconds) s\(idle ? "" : " on the field being edited")")
            if idle {
                guard pressBegan(touchTime: ProcessInfo.processInfo.systemUptime) else {
                    debugLog("[drill] press refused")
                    return
                }
                try? await Task.sleep(for: .seconds(Self.holdSeconds))
            } else {
                try? await Task.sleep(for: .seconds(Self.editHoldSeconds))
                guard beginHoldWhileEditing(touchTime: nil) else {
                    debugLog("[drill] press refused")
                    return
                }
            }
            pressHeld(.began, at: .zero)
            var at = CGPoint(x: voice.capsuleSize.width / 2, y: 10)
            switch UserDefaults.standard.string(forKey: "voiceDrillTarget") {
            case "cancel": at = CGPoint(x: voice.capsuleSize.width * 0.25, y: -40)
            case "edit": at = CGPoint(x: voice.capsuleSize.width * 0.75, y: -40)
            default: break
            }
            let slide = at.y < 0 ? min(0.6, seconds / 2) : 0
            try? await Task.sleep(for: .seconds(seconds - slide))
            if slide > 0 {
                pressHeld(.changed, at: at)
                try? await Task.sleep(for: .seconds(slide))
            }
            debugLog("[drill] release")
            pressHeld(.ended, at: at)
        }
    }
    #endif

    /// The Mac: the right mouse button held anywhere in the window (Bento
    /// Term's right-hold): the same hold as a press on the field, already
    /// past its threshold, so it commits at once; the pointer picks 取消 or
    /// 编辑 by going onto them, and letting go anywhere else sends.
    private func pointerHold(_ e: PointerVoice) {
        switch e.phase {
        case .began:
            guard onScreen, !finishingHold, !dictating, !pressing, !voice.isActive, !voice.isArmed else {
                debugLog("[hold] right mouse held, but this composer is busy\(onScreen ? "" : " (not on screen)")")
                return
            }
            claimVoice()
            VoiceTiming.begin("right mouse held")
            guard voice.arm() else {
                debugLog("[hold] right mouse held, no microphone yet")
                return
            }
            voice.draftPrefix = draft
            pressing = true
            moved = false
            voiceStarted = false
            pressSerial += 1
            pointerHolding = true
            voice.panelMounted = true
            pressHeld(.began, at: .zero)
            debugLog("[hold] talking from the right mouse button\(tile.map { ", pane \($0.id.prefix(12))" } ?? ""), the composer at \(Int(capsuleFrame.minX)),\(Int(capsuleFrame.minY)) \(Int(capsuleFrame.width))x\(Int(capsuleFrame.height))")
        case .moved:
            guard pointerHolding else { return }
            pressHeld(.changed, at: capsulePoint(e.point))
        case .ended:
            guard pointerHolding else { return }
            pointerHolding = false
            pressHeld(.ended, at: capsulePoint(e.point))
        case .cancelled:
            guard pointerHolding else { return }
            pointerHolding = false
            debugLog("[hold] the right mouse hold was taken away: nothing sent")
            pressHeld(.cancelled, at: .zero)
        }
    }

    /// A point in the window as the capsule's press would have it
    /// (VoiceLayout): on the 取消 / 编辑 zones above the capsule (a little
    /// around them too) those; anywhere else 发送.
    private func capsulePoint(_ p: CGPoint) -> CGPoint {
        let c = capsuleFrame
        let send = CGPoint(x: c.width / 2, y: c.height / 2)
        guard c.width > 0 else { return send }
        let top = c.minY - VoiceInputPanel.gap - VoiceInputPanel.zoneHeight
        let zones = CGRect(x: c.minX - 16, y: top - 16, width: c.width + 32, height: c.minY - top + 12)
        guard zones.contains(p) else { return send }
        return CGPoint(x: min(max(p.x - c.minX, 0), c.width), y: -40)
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
            voice.panelMounted = true
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
            Task {
                await release()
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
        pointerHolding = false
        voiceStarted = false
        moved = false
        voice.abort()
        voice.presence = 0
        voice.panelMounted = false
    }

    /// Released: the words go where the finger let them go, in one motion
    /// with the scrim, the zones and the orb (design §3.7). Sending, they
    /// fly into the message right away, with what was heard so far; once
    /// they've landed, the final words replace them in place and the
    /// message goes out. Editing, the final words replace them in the field
    /// unless it was changed meanwhile. Nothing heard yet: 识别中… until the
    /// final words come; none: 没听清 (staged pictures stay for the next).
    private func release() async {
        let target = voice.target
        let heard = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // What the field held: the words continue it (cancel leaves it as it is).
        let before = draft
        debugLog("[voice] released on \(target), \(heard.count) characters heard, \(before.count) in the field")
        if target == .cancel {
            voice.leave(.cancel, words: heard)
            _ = await voice.end()
            debugLog("[hold] cancelled: the field keeps its \(draft.count) characters")
            return
        }
        guard !heard.isEmpty else {
            // From touch-down to release, before anything is awaited.
            let pressSeconds = ProcessInfo.processInfo.systemUptime - voiceTouchUptime
            voice.resolve()
            let (_, final) = await voice.end()
            debugLog("[voice] final: \(final.count) characters")
            // A mis-tap: whatever came back after nothing was heard live on
            // a press under a second (realtime too, not only the batch
            // fallback) was made up.
            let madeUp = VoiceGuard.dropsResult(heardLive: false, pressSeconds: pressSeconds)
            if madeUp && !final.isEmpty { debugLog("[voice] dropped \(final.count) characters after a \(Int(pressSeconds * 1000)) ms press") }
            guard !final.isEmpty, !madeUp else {
                voice.leave(.unheard(edit: target == .edit), words: voice.dictation.errorMessage ?? String(localized: "没听清"))
                return
            }
            // Words the batch fallback made up after nothing was heard live
            // wait in the field for the user to confirm; a final that realtime
            // itself delivered after the release sends as usual.
            let landed = VoiceGuard.mustConfirm(heardLive: false, fromBatch: voice.dictation.finalFromBatch) ? VoiceInputController.Target.edit : target
            // Landing a message only stages it (shown, waiting): without the
            // send below it sat on the clock for good.
            if let cid = land(landed, final) { await sendLanded(cid, Self.joined(before, final)) }
            editedIn = nil
            return
        }
        let cid = land(target, heard)
        let (_, final) = await voice.end()
        debugLog("[voice] final: \(final.count) characters, \(final == heard || final.isEmpty ? "as heard" : "changed")")
        let words = final.isEmpty ? heard : final
        if let cid {
            await sendLanded(cid, Self.joined(before, words))
        } else if let e = editedIn, words != e.words, draft == Self.joined(e.before, e.words) {
            draft = Self.joined(e.before, words)
        }
        #if DEBUG
        if cid == nil { debugLog("[hold] the field now reads: \(draft)") }
        #endif
        editedIn = nil
    }

    /// A draft and the words that continue it, as one text: a space between
    /// two Latin words, nothing between Chinese ones.
    static func joined(_ before: String, _ words: String) -> String {
        before + separator(before, words) + words
    }

    static func separator(_ before: String, _ words: String) -> String {
        guard let last = before.last, let first = words.first, !last.isWhitespace, !first.isWhitespace,
              last.isASCII, first.isASCII, first.isLetter || first.isNumber,
              last.isLetter || last.isNumber || ".,;:!?)".contains(last) else { return "" }
        return " "
    }

    /// Sends a spoken message `land` placed, with its final words. Once the
    /// words have landed and the voice UI is down: changing the message under
    /// its flying copy (different final words, or the host's answer to
    /// sending it, which lays the message out again) cost a frame of 45–60 ms.
    /// At most a few tenths of a second later than the final words.
    private func sendLanded(_ cid: String, _ words: String) async {
        await voice.whenGone()
        try? await Task.sleep(for: .milliseconds(34))
        #if DEBUG
        debugLog("[hold] sends: \(words)")
        #endif
        withAnimation(.smooth(duration: 0.3)) { store.sendStaged(cid, text: words) }
    }

    /// The words start on their way: into a message placed where it stays
    /// (returns its client id), or into the field.
    @discardableResult
    private func land(_ target: VoiceInputController.Target, _ words: String) -> String? {
        let before = draft
        if target == .edit {
            editedIn = (before, words)
            // The field takes them in the same motion (it may grow).
            withAnimation(VoiceInputController.exitMotion) { draft = Self.joined(before, words) }
            voice.leave(.edit, words: words)
            return nil
        }
        let cid = UUID().uuidString.lowercased()
        // Hidden before it exists: its first frame is already unseen.
        voice.leave(.send(cid: cid), words: words)
        // What the field held goes with the words, as one message (and its
        // staged pictures and files, as for a typed one).
        if !before.isEmpty {
            draft = ""
            editedIn = nil
        }
        deliver(Self.joined(before, words), .spoken(cid: cid))
        return cid
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
            voice.owner = tile?.id // its errors show here
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

    private func deliver(_ text: String, _ how: Outgoing = .typed) {
        var images: [AppStore.OutgoingImage] = []
        var files: [AppStore.OutgoingFile] = []
        for item in staged {
            switch item {
            case .image(let i): images.append(i)
            case .file(let f): files.append(f)
            }
        }
        onSend(text, images, files, how)
        staged = []
    }

    private func addImages(_ raw: [Data]) {
        let room = Self.maxStaged - staged.count
        let prepared = raw.prefix(room).compactMap(ImagePrep.process)
        staged.append(contentsOf: prepared.map(Staged.image))
        if prepared.count < min(raw.count, room) { voice.dictation.errorMessage = String(localized: "有图片读不了，换一张试试") }
    }

    /// Files from the Files app. Pictures among them go as images (so the
    /// assistant sees them); everything else as files.
    private func addFiles(_ urls: [URL]) {
        var problem: String?
        for url in urls.prefix(Self.maxStaged - staged.count) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { problem = String(localized: "有文件读不了"); continue }
            guard data.count <= Self.maxFileBytes else { problem = String(localized: "文件太大（最多 100MB）"); continue }
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

/// Staging what was dropped or pasted (ComposerIntake), and ⌘V with a
/// picture or a copied file while the field has focus; text pastes as always.
private struct IntakeHooks: ViewModifier {
    let intake: ComposerIntake?
    @Binding var staged: [Staged]
    let focused: Bool
    let room: Int
    let addImages: ([Data]) -> Void

    func body(content: Content) -> some View {
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("IntakeHooks")
        #endif
        content
            .onChange(of: intake?.incoming.count ?? 0, initial: true) { _, n in
                guard n > 0, let intake else { return }
                staged.append(contentsOf: intake.incoming.prefix(max(0, room - staged.count)))
                intake.incoming = []
            }
            .onChange(of: focused, initial: true) { _, on in
                guard let intake else { return }
                ComposerPaste.handler = on ? { [weak intake] pb in
                    guard ComposerPaste.hasAttachable(pb), let intake else { return false }
                    intake.take(pb.itemProviders)
                    return true
                } : nil
            }
            .onDisappear { if focused { ComposerPaste.handler = nil } }
            #if DEBUG
            // `-demoStage YES`: a picture and a file staged, as if picked (UI tests).
            .task {
                guard UserDefaults.standard.bool(forKey: "demoStage"), staged.isEmpty else { return }
                let picture = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { c in
                    UIColor.systemTeal.setFill()
                    c.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
                }
                if let data = picture.pngData() { addImages([data]) }
                staged.append(.file(AppStore.OutgoingFile(data: Data("第一行\n第二行\n".utf8), mediaType: "text/plain", name: "说明.txt")))
            }
            #endif
    }
}

/// Something staged for the next message.
enum Staged: Sendable {
    case image(AppStore.OutgoingImage)
    case file(AppStore.OutgoingFile)
}

/// Staged images (thumbnails) and files (chips), each removable.
private struct StagedRow: View {
    let items: [Staged]
    let remove: (Int) -> Void

    var body: some View {
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("StagedRow")
        #endif
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
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("SlashSuggestions")
        #endif
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
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("QuoteBanner")
        #endif
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

extension CGRect {
    /// Laid out: no NaN or infinity anywhere (a null rect has infinite origins).
    var isFiniteRect: Bool { origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite }
}

/// A single click in a conversation, on a device with a keyboard (the Mac,
/// an iPad with one): its composer takes the keyboard, so typing can start
/// right away. Touch-only iPads keep the old way (the click leaves the
/// field); phones are left alone. Simultaneous: links, buttons, the cards
/// and selecting text get their click as before.
struct ClickFocusesComposer: ViewModifier {
    @Environment(WindowModel.self) private var model
    @Environment(\.tile) private var tile

    func body(content: Content) -> some View {
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("ClickFocusesComposer")
        #endif
        if model.layout != .phone {
            content.simultaneousGesture(TapGesture().onEnded {
                if HardwareKeyboard.isAttached {
                    ComposerFocus.clicked(window: ObjectIdentifier(model), tile: tile?.id)
                } else {
                    model.composerUnfocusRequests += 1
                }
            })
        } else {
            content
        }
    }
}

/// Which composer a click in a conversation asks to take the keyboard, and
/// whether it should: only after a lone click (not the first of a double
/// click), with no text selected and no other text field holding the keyboard.
@MainActor
enum ComposerFocus {
    static let request = Notification.Name("PaloAlly.composerFocusRequest")

    private static var lastClick: TimeInterval = 0
    private static var clicks = 0

    static func clicked(window: ObjectIdentifier, tile: String?) {
        let now = ProcessInfo.processInfo.systemUptime
        let wait = doubleClickInterval
        let again = now - lastClick < wait
        lastClick = now
        clicks += 1
        guard !again else {
            debugLog("[focus] a double click in the conversation: the composer is left alone")
            return
        }
        let serial = clicks
        let keyWindow = Self.keyWindow
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            // Another click came: a double (or triple) click, selecting.
            guard serial == clicks else { return }
            if let why = reasonToLeave(keyWindow: keyWindow) {
                debugLog("[focus] a click in the conversation: \(why), the composer is left alone")
                return
            }
            NotificationCenter.default.post(name: request, object: nil,
                                            userInfo: ["window": window, "tile": tile ?? ""])
        }
    }

    static func isFor(_ note: Notification, window: ObjectIdentifier, tile: String?) -> Bool {
        note.userInfo?["window"] as? ObjectIdentifier == window && note.userInfo?["tile"] as? String == (tile ?? "")
    }

    private static func reasonToLeave(keyWindow: UIWindow?) -> String? {
        let responder = HardwareKeyboard.firstResponder
        if let text = responder as? UITextView {
            if text.isEditable { return "a text field has the keyboard" }
            if text.selectedRange.length > 0 { return "text is selected" }
        }
        if responder is UITextField { return "a text field has the keyboard" }
        let now = Self.keyWindow
        if now !== keyWindow { return "another window came up" }
        if now?.rootViewController?.presentedViewController != nil { return "a sheet came up" }
        return nil
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.lazy
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// The system's double-click time on the Mac (AppKit's, no permission
    /// needed); elsewhere a third of a second.
    private static var doubleClickInterval: TimeInterval {
        guard ProcessInfo.processInfo.isMacCatalystApp, let event = NSClassFromString("NSEvent"),
              let t = ((event as AnyObject).value(forKey: "doubleClickInterval") as? NSNumber)?.doubleValue
        else { return 0.3 }
        return min(max(t, 0.2), 0.5)
    }
}
