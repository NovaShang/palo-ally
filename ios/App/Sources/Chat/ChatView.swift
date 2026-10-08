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
    /// The one owner of the scroll position (design §3.6): following the
    /// end, letting go when the reader drags up, 「回到最新」, bringing a
    /// message into view. The views only tell it what happened.
    @State private var scroll = ChatScrollCoordinator()
    /// What the scroll view shows; only `scroll` changes it.
    @State private var position = ScrollPosition(edge: .bottom)
    /// A message just jumped to from search: briefly tinted so the eye lands on it.
    @State private var highlightedID: String?
    /// Where the bar's middle is (phones): read only by the orb's own overlay,
    /// so the bar moving (a resize) doesn't re-render the conversation.
    @State private var orbPlacement = OrbPlacement()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        #if DEBUG
        let _ = RenderTrace.note("ChatView")
        #endif
        ScrollView {
            ConversationRows(scroll: scroll, highlightedID: highlightedID)
        }
        .scrollPosition($position)
        // Opens on the end, and content shorter than the view sits at the
        // bottom. Growth keeps the end in view while the view is on it:
        // that is following the end. Scrolled up even a little, the
        // system's anchor lets go and nothing moves (the scroll lab). The
        // coordinator turns it off while the reader's finger moves the list.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(scroll.sticksToEnd ? .bottom : .top, for: .sizeChanges)
        // The Mac: the orb floats over the top of the column, so the
        // first message starts a little below it.
        .contentMargins(.top, Platform.barInWindowToolbar ? Self.macTopMargin : 0, for: .scrollContent)
        // No scroll targets (`scrollTargetLayout`): with them the scroll
        // view keeps "the view at the top" through every layout change, and
        // the lazy history re-estimating as a fling crosses it turned that
        // into the fling being eaten and the view lurching to where the
        // laid-out end begins.
        .task {
            scroll.attach(position: $position, store: store,
                          contentTop: 12 + (Platform.barInWindowToolbar ? Self.macTopMargin : 0))
        }
        #if DEBUG
        // `-demoDetach YES`: read from the middle of the history (for the resize test).
        .task {
            guard UserDefaults.standard.bool(forKey: "demoDetach") else { return }
            try? await Task.sleep(for: .seconds(3.5))
            guard store.messages.count > 4 else { return }
            let mid = store.messages[store.messages.count / 2].id
            scroll.detach(at: mid)
            debugLog("[anchor] reading from \(mid)")
        }
        // `-demoJump <s>`: tap 「回到最新」 that many seconds in (it logs where it lands).
        .task {
            let at = UserDefaults.standard.double(forKey: "demoJump")
            guard at > 0 else { return }
            try? await Task.sleep(for: .seconds(at))
            scroll.jumpToLatest()
        }
        // `-demoScrollTour YES`: scroll up through the whole conversation
        // and back, as a reader would, so every row has been on screen.
        .task {
            guard UserDefaults.standard.bool(forKey: "demoScrollTour") else { return }
            try? await Task.sleep(for: .seconds(2))
            let ids = store.messages.map(\.id)
            debugLog("[tour] up through \(ids.count) messages")
            await scroll.tour(ids)
            debugLog("[tour] back at the end")
        }
        #endif
        .scrollDismissesKeyboard(.immediately)
        // The Mac: a click in the conversation takes focus off the
        // composer (links, buttons and selection still get their click).
        .modifier(ClickToUnfocusComposer())
        .onScrollPhaseChange { _, phase in scroll.phase(phase) }
        .onScrollGeometryChange(for: ChatScroll.Metrics.self) { g in
            #if DEBUG
            ChatScroll.trace(g)
            #endif
            return ChatScroll.Metrics(g)
        } action: { old, new in
            scroll.geometry(old, new)
        }
        // A notification tap on an approval brings its card into view.
        .onChange(of: model.focusApprovalID, initial: true) { _, id in
            guard let id else { return }
            model.focusApprovalID = nil
            let target = store.messages.first { $0.approvalId == id }?.id ?? "approval-\(id)"
            scroll.reveal(target, after: 0.35) // let the slide back to the chat land
        }
        // …and on a question card.
        .onChange(of: model.focusQuestionID, initial: true) { _, id in
            guard let id, let target = store.messages.first(where: { $0.questionId == id })?.id else { return }
            model.focusQuestionID = nil
            scroll.reveal(target, after: 0.35)
        }
        // A search hit in 成果: make sure it's loaded, then bring it into
        // view and tint it for a moment.
        .onChange(of: model.focusMessageSeq, initial: true) { _, seq in
            guard let seq else { return }
            model.focusMessageSeq = nil
            Task { @MainActor in
                guard let id = await store.revealMessage(seq: seq) else { return }
                try? await Task.sleep(for: .milliseconds(350)) // let the slide back to the chat land
                scroll.reveal(id)
                withAnimation(.easeOut(duration: 0.2)) { highlightedID = id }
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeOut(duration: 0.6)) { if highlightedID == id { highlightedID = nil } }
            }
        }
        .modifier(ConversationChanges(scroll: scroll))
        .overlay(alignment: .bottom) {
            let showJump = store.viewingPast || scroll.showsJump
            ZStack {
                if showJump {
                    JumpToLatestButton(hasNew: scroll.unseenBelow) { scroll.jumpToLatest() }
                    .padding(.bottom, 10)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            // Scoped to the button: must not animate the list itself.
            .animation(.snappy(duration: 0.2), value: showJump)
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
        .modifier(OrbPresenceTracking(scrolledUp: !scroll.following || store.viewingPast, scrolling: scroll.userScrolling))
        // 「试试」 timing: a reply finishing counts as activity.
        .onChange(of: store.isBusy) { _, busy in if !busy { SuggestionsGate.shared.touch() } }
        // Leaving the app, and coming back (after the catch-up).
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                scroll.background()
            } else if phase == .active {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    scroll.foreground()
                }
            }
        }
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

}

/// The conversation's rows: its own view, so a change in the scroll state
/// (following, the finger on the list) re-renders the scroll view's
/// modifiers, not every message row. Re-measured rows came back a little
/// taller or shorter, hundreds of points over the whole laid-out end, which
/// pushed the view past the end at the start of a drag and sprang it back.
private struct ConversationRows: View {
    let scroll: ChatScrollCoordinator
    let highlightedID: String?
    @Environment(AppStore.self) private var store
    @Environment(\.placesAsColumns) private var asColumn

    var body: some View {
        #if DEBUG
        let _ = RenderTrace.note("list")
        #endif
        let messages = store.messages
        // What's laid out: a window of messages, every one measured exactly
        // (no lazy estimates), chosen by the scroll coordinator (design §3.4).
        let window = scroll.window(in: messages)
        let atTheEnd = window.upperBound == messages.count
        VStack(alignment: .leading, spacing: 14) {
            if window.lowerBound > 0 || store.hasOlderMessages {
                // Reading up toward the top lays more out on its own; this
                // is for doing it at once (and for VoiceOver). The message
                // being read stays where it is.
                Button {
                    scroll.revealOlder()
                } label: {
                    if store.isLoadingOlder { ProgressView() } else { Text("看看更早的") }
                }
                .buttonStyle(.borderless)
                .tint(.secondary)
                .font(.footnote)
                .frame(maxWidth: .infinity)
            }

            if messages.isEmpty && store.connection == .online {
                EmptyChatHint()
            }

            ForEach(Array(messages[window].enumerated()), id: \.element.id) { offset, message in
                messageRow(message, at: window.lowerBound + offset)
            }

            // The live end: approvals, the working line and 「试试」 (not
            // while a stretch far back is laid out on its own).
            if atTheEnd {
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
                SuggestionsSlot()
                    .id("suggestions")
            }
        }
        // Rows report their place in the content (it changes only
        // when the layout does), for holding the row being read.
        .coordinateSpace(.named(ChatScrollCoordinator.contentSpace))
        // The scroll view's pan gesture is the reader's finger.
        .background(ScrollViewHook { scroll.attach(scrollView: $0) })
        // A quote above a bubble jumps to what it quotes.
        .environment(\.chatScrollTo) { id in scroll.reveal(id) }
        // Beside a sidebar or inspector the column gets roomier margins.
        .padding(.horizontal, asColumn ? 28 : 16)
        .environment(\.messageGutter, asColumn ? 28 : 16)
        .padding(.vertical, 12)
        // Wide windows: a comfortable line length, centred.
        .frame(maxWidth: ChatView.readableWidth)
        .frame(maxWidth: .infinity)
    }

    /// One message, with its time stamp when it starts a new stretch. It
    /// reports its place in the content (that changes only when the layout
    /// does, not when scrolling), for holding the row being read.
    @ViewBuilder
    private func messageRow(_ message: ChatMessage, at index: Int) -> some View {
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
        .onGeometryChange(for: CGFloat.self) {
            $0.frame(in: .named(ChatScrollCoordinator.contentSpace)).minY
        } action: { scroll.rowMoved(message.id, to: $0) }
        .onDisappear { scroll.forget(message.id) }
        #if DEBUG
        .modifier(TopRowProbe(id: message.id))
        #endif
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

/// What the scroll coordinator hears about the conversation changing.
private struct ConversationChanges: ViewModifier {
    let scroll: ChatScrollCoordinator
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content
            // A layout switch rebuilds the column: back onto the end if it was there.
            .onChange(of: model.layout) { scroll.layoutChanged() }
            .onChange(of: store.messages.last?.id) {
                // What this device just sent (its echo) always returns to the
                // live end; anything else arriving marks the jump button.
                if let last = store.messages.last, last.role == .user, last.seq == 0 {
                    scroll.sent()
                } else {
                    scroll.grewBelow()
                }
            }
            // A reply growing: the coordinator listens to the reply itself
            // (`messages` doesn't change while it's written, and nothing here
            // re-evaluates per piece).
            .onChange(of: store.latestStream?.id, initial: true) { scroll.follow(store.latestStream) }
            .onChange(of: store.messages.last?.text.utf8.count) { scroll.grewBelow() }
            #if DEBUG
            // `-renderTrace YES`: what re-rendered while each reply was written.
            .onChange(of: store.latestStream?.id) { old, new in
                if let old { RenderTrace.report(while: old) }
                if new != nil { RenderTrace.reset() }
            }
            #endif
            // What's laid out follows the messages (the window, design §3.4).
            .onChange(of: store.messages.count) { scroll.messagesChanged() }
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
/// `-topRowTrace YES`: logs the message under the top of the view each time
/// it changes, so a scroll that jumps back to an earlier message shows up in
/// the debug log (ChatScrollUITests).
private struct TopRowProbe: ViewModifier {
    static let enabled = UserDefaults.standard.bool(forKey: "topRowTrace")
    /// Just under the navigation bar, where reading starts.
    static let line: CGFloat = 120
    let id: String

    func body(content: Content) -> some View {
        if Self.enabled {
            content.onGeometryChange(for: Bool.self) { g in
                let f = g.frame(in: .scrollView)
                return f.minY <= Self.line && f.maxY > Self.line
            } action: { atTop in
                if atTop { debugLog("[top] \(id)") }
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
        // Animated, so for a reader on the end the end glides up with them
        // (the bottom anchor); scrolled up, nothing moves.
        .animation(.easeInOut(duration: 0.35), value: shows)
        #if DEBUG
        .onChange(of: shows) { _, shown in debugLog("[suggestions] \(shown ? "shown" : "hidden")") }
        #endif
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
