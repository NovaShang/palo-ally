import PaloAllyKit
import SwiftUI

struct ChatView: View {
    /// The conversation never gets wider than this (large screens).
    static let readableWidth: CGFloat = 760
    /// Mac: room above the first message for the small floating orb.
    static let macTopMargin: CGFloat = 22
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    /// Kept by MainScreen so it survives the layout switching containers.
    @Environment(\.chatDraft) private var draft
    /// Following the live bottom (streaming keeps the newest text in view).
    /// Detached as soon as the reader drags up even a little; re-attached
    /// when they come back near the bottom or tap the jump button.
    @State private var pinned = true
    /// The finger (or its fling) is moving the list — only that can detach.
    @State private var userScrolling = false
    /// Further from the bottom than the re-attach distance. A flag, not the
    /// raw distance: it changes only when crossing the line, so scrolling and
    /// streaming don't re-render the whole list every frame.
    @State private var awayFromBottom = false
    /// A message just jumped to from search: briefly tinted so the eye lands on it.
    @State private var highlightedID: String?
    @Environment(\.placesAsColumns) private var asColumn
    /// Where the bar's middle is (phones): read only by the orb's own overlay,
    /// so the bar moving (a resize) doesn't re-render the conversation.
    @State private var orbPlacement = OrbPlacement()
    /// Detached from the live end: the message at the top of the view. The
    /// scroll view keeps it where it is when the rows above rewrap (a resize,
    /// a sidebar opening), instead of keeping the raw offset and letting the
    /// text slide. Nil while following the bottom.
    @State private var readingAnchor: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.hasOlderMessages {
                        Button {
                            // Keep the first message where it was: prepending
                            // above must not shove the reader's place down.
                            let anchor = store.messages.first?.id
                            Task {
                                await store.loadOlder()
                                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                            }
                        } label: {
                            if store.isLoadingOlder { ProgressView() } else { Text("看看更早的") }
                        }
                        .buttonStyle(.borderless)
                        .tint(.secondary)
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                    }

                    if store.messages.isEmpty && store.connection == .online {
                        EmptyChatHint()
                    }

                    // Exactly one view per message (the time stamp lives inside
                    // it): a lazy stack whose ForEach yields a varying number of
                    // views per element has to run every element to count them,
                    // on every layout pass, which froze the Mac for 34 s on a
                    // long conversation.
                    ForEach(Array(store.messages.enumerated()), id: \.element.id) { index, message in
                        VStack(alignment: .leading, spacing: 14) {
                            if showsTimestamp(at: index) {
                                Text(Copy.clock(message.ts))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 6)
                            }
                            MessageRow(message: message)
                                .background {
                                    if highlightedID == message.id {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(Color.accentColor.opacity(0.12))
                                            .padding(-6)
                                            .transition(.opacity)
                                    }
                                }
                        }
                        .id(message.id)
                        #if DEBUG
                        .modifier(AnchorProbe(id: message.id, anchor: readingAnchor))
                        #endif
                    }

                    ForEach(store.unanchoredPendingApprovals) { approval in
                        ApprovalCard(approval: approval)
                            .id("approval-\(approval.id)")
                    }

                    if showsBusyIndicator {
                        ThinkingIndicator(activity: busyActivity, justSent: store.awaitingReply && store.status?.busy != true)
                            .id("thinking")
                    }

                    // 「试试」: part of the conversation's end, so scrolling up
                    // leaves them behind; only on first use or after a quiet spell.
                    // Its own view: the gate changes on every keystroke, and
                    // that must not re-render the conversation.
                    SuggestionsSlot(followingEnd: pinned && !userScrolling) {
                        withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .id("suggestions")

                    Color.clear.frame(height: 1).id("bottom")
                }
                .scrollTargetLayout()
                // A quote above a bubble jumps to what it quotes.
                .environment(\.chatScrollTo) { id in
                    withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                }
                // Beside a sidebar or inspector the column gets roomier margins.
                .padding(.horizontal, asColumn ? 28 : 16)
                .environment(\.messageGutter, asColumn ? 28 : 16)
                .padding(.vertical, 12)
                // Wide windows: a comfortable line length, centred.
                .frame(maxWidth: Self.readableWidth)
                .frame(maxWidth: .infinity)
            }
            // Opens at the bottom; growth keeps the bottom in place only while
            // pinned — detached, the offset from the top stays put so the
            // text being read doesn't move under the reader.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .defaultScrollAnchor(pinned ? .bottom : .top, for: .sizeChanges)
            .scrollPosition(id: pinned ? .constant(nil) : $readingAnchor, anchor: .top)
            // The Mac: the orb floats over the top of the column, so the
            // first message starts a little below it.
            .contentMargins(.top, Platform.barInWindowToolbar ? Self.macTopMargin : 0, for: .scrollContent)
            .onChange(of: pinned) { _, now in if now { readingAnchor = nil } }
            #if DEBUG
            // `-demoDetach YES`: read from the middle of the history (for the resize test).
            .task {
                guard AnchorProbe.enabled else { return }
                try? await Task.sleep(for: .seconds(3.5))
                guard store.messages.count > 4 else { return }
                let mid = store.messages[store.messages.count / 2].id
                pinned = false
                readingAnchor = mid
                debugLog("[anchor] reading from \(mid)")
            }
            .onChange(of: readingAnchor) { _, id in
                if AnchorProbe.enabled { debugLog("[anchor] top row now \(id ?? "nil")") }
            }
            #endif
            .scrollDismissesKeyboard(.immediately)
            // The Mac: a click in the conversation takes focus off the
            // composer (links, buttons and selection still get their click).
            .modifier(ClickToUnfocusComposer())
            .onScrollPhaseChange { old, phase in
                let moving = phase == .tracking || phase == .interacting || phase == .decelerating
                userScrolling = moving
                // A scroll of the reader's that comes to rest near the end
                // (after any fling) follows the live bottom again.
                if !moving, old == .tracking || old == .interacting || old == .decelerating,
                   !awayFromBottom, !pinned {
                    pinned = true
                }
            }
            .onScrollGeometryChange(for: ChatScroll.Metrics.self) { g in
                ChatScroll.Metrics(g)
            } action: { old, new in
                let away = new.distanceFromBottom > ChatScroll.reattachDistance
                if away != awayFromBottom { awayFromBottom = away }
                if userScrolling {
                    // Like the ChatGPT / Claude apps: the slightest drag up
                    // stops following; drifting back down near the end resumes.
                    if new.distanceFromBottom > old.distanceFromBottom + 0.5, new.distanceFromBottom > ChatScroll.detachDistance {
                        if pinned { pinned = false }
                    } else if new.distanceFromBottom < old.distanceFromBottom, new.distanceFromBottom <= ChatScroll.reattachDistance {
                        if !pinned { pinned = true }
                    }
                } else if new.bottomInset > old.bottomInset + 1, pinned {
                    // The keyboard (or a taller composer) took space at the
                    // bottom: keep the newest text right above it. Detached,
                    // nothing moves — the reader's place stays put.
                    withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            // A notification tap on an approval brings its card into view.
            .onChange(of: model.focusApprovalID, initial: true) { _, id in
                guard let id else { return }
                model.focusApprovalID = nil
                let target = store.messages.first { $0.approvalId == id }?.id ?? "approval-\(id)"
                pinned = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350)) // let the slide back to the chat land
                    withAnimation(.snappy) { proxy.scrollTo(target, anchor: .center) }
                }
            }
            // …and on a question card.
            .onChange(of: model.focusQuestionID, initial: true) { _, id in
                guard let id, let target = store.messages.first(where: { $0.questionId == id })?.id else { return }
                model.focusQuestionID = nil
                pinned = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(.snappy) { proxy.scrollTo(target, anchor: .center) }
                }
            }
            // A search hit in 成果: make sure it's loaded, then bring it into
            // view and tint it for a moment.
            .onChange(of: model.focusMessageSeq, initial: true) { _, seq in
                guard let seq else { return }
                model.focusMessageSeq = nil
                pinned = false
                Task { @MainActor in
                    guard let id = await store.revealMessage(seq: seq) else { return }
                    try? await Task.sleep(for: .milliseconds(350)) // let the slide back to the chat land
                    withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                    withAnimation(.easeOut(duration: 0.2)) { highlightedID = id }
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation(.easeOut(duration: 0.6)) { if highlightedID == id { highlightedID = nil } }
                }
            }
            // The first page of history can land after the list appeared, and
            // a layout switch rewraps every line: either way, while following
            // the live end, settle on it again once the rows have their sizes.
            .onChange(of: store.messages.isEmpty, initial: true) { _, empty in
                guard !empty, pinned else { return }
                settleAtBottom(proxy)
            }
            .onChange(of: model.layout) {
                // A layout switch rebuilds the column; the bottom anchor keeps
                // the end in place, and a late correction only if it drifted.
                guard pinned else { return }
                settleAtBottom(proxy, onlyIfAway: true)
            }
            .onChange(of: store.messages.last?.id) {
                // Sending always returns to the live bottom.
                if store.messages.last?.role == .user { pinned = true }
                guard pinned, !userScrolling else { return }
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.messages.last?.text) {
                guard pinned, !userScrolling else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: showsBusyIndicator) {
                guard pinned, !userScrolling else { return }
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                let showJump = store.viewingPast || (!pinned && awayFromBottom)
                ZStack {
                    if showJump {
                        JumpToLatestButton(streaming: store.isBusy) {
                            pinned = true
                            if store.viewingPast {
                                // An older stretch is showing: load the live end first.
                                Task { @MainActor in
                                    await store.returnToLatest()
                                    withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                                }
                            } else {
                                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                            }
                        }
                        .padding(.bottom, 10)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                // Scoped to the button: must not animate the list itself.
                .animation(.snappy(duration: 0.2), value: showJump)
            }
        }
        .modifier(TopStrip {
            VStack(spacing: 0) {
                StatusBanner()
                // The Mac: the orb hangs small from the top middle of the
                // column, over the messages (they start just below it and
                // pass under it, fading) — no strip of its own.
                if Platform.barInWindowToolbar { MacTopOrb() }
            }
            .frame(maxWidth: .infinity)
        })
        // While holding to talk, the screen's background rises from the
        // bottom so the live transcript reads cleanly (same hold-driven motion).
        .overlay { VoiceScrimLayer() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(draft: draft) { text, images, files in
                store.send(text, images: images, files: files)
            }
        }
        // The orb over the bar's middle: above the conversation, its edge
        // fade and the voice scrim, and free to be bigger than the bar.
        .overlay(alignment: .topLeading) {
            if !Platform.barInWindowToolbar { PhoneTitleOrb(placement: orbPlacement) }
        }
        .modifier(OrbPresenceTracking(scrolledUp: !pinned || store.viewingPast, scrolling: userScrolling))
        // 「试试」 timing: a reply finishing counts as activity.
        .onChange(of: store.isBusy) { _, busy in if !busy { SuggestionsGate.shared.touch() } }
        .navigationTitle(store.assistantName)
        .navigationBarTitleDisplayMode(.inline)
        // Immersive, the iOS 26 look: the system bar stays but without its
        // material backdrop (iOS 27 gives the bar one by default); the
        // conversation runs under three floating pieces (two round buttons,
        // the orb) with only the soft scroll-edge fade, which keeps text from
        // colliding with the clock and the orb.
        .toolbarBackground(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        // The Mac: the two toggles are the window toolbar's (MacToolbar), the
        // orb floats in the strip above the messages.
        .toolbar(Platform.barInWindowToolbar ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if !Platform.barInWindowToolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.toggleAssistant() // phones: slide to 「它」; large screens: the sidebar
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .tint(.primary) // toolbar glyphs stay neutral; the theme color is for meaning
                    .accessibilityLabel("「它」")
                }
                ToolbarItem(placement: .principal) {
                    TitleOrbSlot { frame in
                        if orbPlacement.slot != frame { orbPlacement.slot = frame }
                    } action: { model.showHostSwitcher = true }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.toggleLibrary() // phones: slide to 成果; large screens: the inspector
                    } label: {
                        Image(systemName: "books.vertical")
                    }
                    .tint(.primary)
                    .accessibilityLabel("成果")
                }
            }
        }
        .sheet(isPresented: Binding(get: { model.showModelPicker }, set: { model.showModelPicker = $0 })) {
            ModelPickerSheet().environment(model).environment(store)
        }
    }

    /// Back to the newest message now and once more after the lazy rows have
    /// measured themselves (their estimated heights put "the end" too high).
    /// `onlyIfAway`: skip the moves when the view is already at the end, so
    /// a resize doesn't make the text twitch for nothing.
    private func settleAtBottom(_ proxy: ScrollViewProxy, onlyIfAway: Bool = false) {
        Task { @MainActor in
            for delay in [30, 250] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard pinned, !userScrolling else { return }
                if onlyIfAway && !awayFromBottom { continue }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Shown whenever the host is working (not just right after a send).
    private var showsBusyIndicator: Bool {
        store.connection.isOnline && (store.awaitingReply || store.status?.busy == true)
    }

    private var busyActivity: String? {
        guard store.status?.busy == true, let a = store.status?.activity?.trimmingCharacters(in: .whitespaces), !a.isEmpty
        else { return nil }
        return a.hasSuffix("…") || a.hasSuffix("...") ? a : a + "…"
    }

    private func showsTimestamp(at index: Int) -> Bool {
        let msgs = store.messages
        guard msgs[index].ts > 0 else { return false }
        if index == 0 { return true }
        return msgs[index].ts - msgs[index - 1].ts > 10 * 60 * 1000
    }
}

/// What sits above the messages: the connection banner, and on the Mac the
/// orb's strip. The Mac's scroll edge is a hard rule line, so there the strip
/// draws its own fade instead: solid behind the toolbar and the orb, then
/// dissolving into the messages scrolling under it. Phones keep a plain inset
/// (their orb floats over the navigation bar, which already has the fade).
private struct TopStrip<Strip: View>: ViewModifier {
    @ViewBuilder let strip: () -> Strip
    /// The Mac: a short fade under the toolbar, not a band.
    private static var fade: CGFloat { 14 }

    func body(content: Content) -> some View {
        if Platform.barInWindowToolbar {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    strip().background {
                        // Solid behind the toolbar and the orb; the messages
                        // fade in just below the strip.
                        VStack(spacing: 0) {
                            Color(.systemBackground)
                            LinearGradient(colors: [Color(.systemBackground), Color(.systemBackground).opacity(0)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: Self.fade)
                        }
                        .padding(.bottom, -Self.fade)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                    }
                }
                .scrollEdgeEffectHidden(true, for: .top)
        } else {
            content.safeAreaInset(edge: .top, spacing: 0, content: strip)
        }
    }
}

#if DEBUG
/// `-demoDetach YES`: logs where the row being read sits in the scroll view
/// as layout changes, so a resize that shifts it shows up in the debug log.
private struct AnchorProbe: ViewModifier {
    static let enabled = UserDefaults.standard.bool(forKey: "demoDetach")
    let id: String
    let anchor: String?

    func body(content: Content) -> some View {
        if Self.enabled && id == anchor {
            content.onGeometryChange(for: Int.self) { Int($0.frame(in: .scrollView).minY.rounded()) } action: { y in
                debugLog("[anchor] \(id) at y \(y)")
            }
        } else {
            content
        }
    }
}
#endif

/// The Mac only (phones keep their own keyboard handling): a click anywhere
/// in the conversation leaves the composer, so an empty one turns back into
/// the press-to-talk button. Simultaneous: the click still reaches links,
/// buttons and text selection.
private struct ClickToUnfocusComposer: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if Platform.isMac {
            content.simultaneousGesture(TapGesture().onEnded { model.composerUnfocusRequests += 1 })
        } else {
            content
        }
    }
}

/// Where the phone bar's middle is, in window coordinates. A reference type
/// on purpose: the bar reports it, only the orb's overlay reads it, so a
/// resize moving the bar doesn't re-render the conversation.
@Observable final class OrbPlacement {
    var slot: CGRect = .zero
}

/// Phones and iPads: the orb over the bar's middle, positioned from the bar's
/// slot. Keeps its own idea of where the column is, for the same reason.
private struct PhoneTitleOrb: View {
    let placement: OrbPlacement
    @Environment(AppModel.self) private var model
    @State private var column: CGRect = .zero

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { column = $0 }
            .overlay(alignment: .topLeading) {
                let slot = placement.slot
                if slot.width > 0 {
                    FloatingTitleOrb(barCenterY: slot.midY, columnWidth: column.width) {
                        model.showHostSwitcher = true
                    }
                    .position(x: slot.midX - column.minX, y: slot.midY - column.minY)
                }
            }
    }
}

/// The Mac: the orb hanging from the top middle of the conversation column.
/// Zero height itself, so it takes no room; the orb overflows below it.
private struct MacTopOrb: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 0

    var body: some View {
        Color.clear
            .frame(height: 0)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .top) {
                FloatingTitleOrb(barCenterY: nil, columnWidth: width, topAligned: true) {
                    model.showHostSwitcher = true
                }
                .frame(height: 0, alignment: .top)
            }
    }
}

/// Banner for connection trouble.
struct StatusBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            // Only a drop that has lasted (or a refusal): returning to the app
            // always starts with a quick reconnect, which isn't news.
            if case .rejected = store.displayedConnection {
                banner(icon: "link.badge.plus", tint: .red, text: "这台设备需要重新配对") {
                    Button("去配对") { model.startPairing(.replace) }
                        .buttonStyle(.glassProminent)
                }
            } else if store.connectionTrouble {
                banner(icon: "wifi.exclamationmark", tint: .secondary, text: "连不上电脑，正在重试…") {
                    Button("重试") { store.reconnectNow() }
                        .buttonStyle(.glass)
                        .tint(.primary)
                }
            }
        }
    }

    private func banner(icon: String, tint: Color, text: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.subheadline)
            Spacer(minLength: 8)
            action().controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// "Working on it" line: what the host is doing right now (status.activity),
/// or a quick "收到" right after a send.
struct ThinkingIndicator: View {
    var activity: String?
    var justSent = false
    @State private var slow = false

    private var text: String {
        if let activity { return activity }
        if justSent { return slow ? "收到啦，正在想…" : "收到" }
        return "正在想…"
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        // In-content: just the spinner and words, no container.
        .padding(.vertical, 4)
        .task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { slow = true }
        }
    }
}

struct EmptyChatHint: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("有什么想让我做的？")
                .font(.headline)
            Text("随便说，比如「明早八点提醒我交报销单」，或者「帮我比较一下这两款耳机」。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 24)
    }
}

#Preview {
    let model = AppModel.demo()
    NavigationStack { ChatView() }
        .environment(model)
        .environment(model.store!)
        .environment(VoiceInputController())
}

/// 「试试」 at the end of the conversation. Reads the gate (which changes on
/// every keystroke) and keeps the quiet-spell clock itself, so none of that
/// re-renders the message list around it.
private struct SuggestionsSlot: View {
    /// The reader is following the live end: a newly shown row scrolls into view.
    let followingEnd: Bool
    let scrollToBottom: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    /// Re-read when a quiet spell may have become long enough.
    @State private var quietClock = Date()

    var body: some View {
        let gate = SuggestionsGate.shared
        let shows = gate.shows(store, now: quietClock)
        VStack(alignment: .leading, spacing: 0) {
            if shows {
                SuggestionChips(suggestions: Array(store.suggestions.prefix(store.messages.isEmpty ? 4 : 3)),
                                greeting: store.messages.isEmpty,
                                use: { store.use($0) },
                                dismiss: { s in withAnimation(.snappy) { store.dismiss(s) } })
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.35), value: shows)
        // Arriving at the end, they come into view only for a reader already
        // there; scrolled up, nothing moves.
        .onChange(of: shows) { _, shown in
            #if DEBUG
            debugLog("[suggestions] \(shown ? "shown" : "hidden")")
            #endif
            guard shown, followingEnd else { return }
            scrollToBottom()
        }
        .task(id: gate.quietSince(store)) {
            let due = gate.quietSince(store).addingTimeInterval(SuggestionsGate.quietInterval)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait + 0.5)) }
            guard !Task.isCancelled else { return }
            quietClock = .now
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { quietClock = .now } }
    }
}

/// The hold-to-talk scrim, reading the voice controller itself: its presence
/// changes every frame while talking, and that must not re-render the list.
private struct VoiceScrimLayer: View {
    @Environment(VoiceInputController.self) private var voice

    var body: some View {
        if voice.panelMounted { VoiceScrim(presence: voice.presence) }
    }
}
