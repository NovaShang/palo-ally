import PaloAllyKit
import SwiftUI

struct ChatView: View {
    /// The conversation never gets wider than this (large screens).
    static let readableWidth: CGFloat = 760
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(VoiceInputController.self) private var voice
    /// Kept by MainScreen so it survives the layout switching containers.
    @Environment(\.chatDraft) private var draft
    /// Following the live bottom (streaming keeps the newest text in view).
    /// Detached as soon as the reader drags up even a little; re-attached
    /// when they come back near the bottom or tap the jump button.
    @State private var pinned = true
    /// The finger (or its fling) is moving the list — only that can detach.
    @State private var userScrolling = false
    @State private var distanceFromBottom: CGFloat = 0
    /// A message just jumped to from search: briefly tinted so the eye lands on it.
    @State private var highlightedID: String?
    @Environment(\.placesAsColumns) private var asColumn
    /// Where the bar's middle is, and where this view is (both in window
    /// coordinates): the orb floats over the bar, centered on its middle.
    @State private var orbSlot: CGRect = .zero
    @State private var ownFrame: CGRect = .zero

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

                    ForEach(Array(store.messages.enumerated()), id: \.element.id) { index, message in
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
                            .id(message.id)
                            // A quote above a bubble jumps to what it quotes.
                            .environment(\.chatScrollTo) { id in
                                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                            }
                    }

                    ForEach(store.unanchoredPendingApprovals) { approval in
                        ApprovalCard(approval: approval)
                            .id("approval-\(approval.id)")
                    }

                    if showsBusyIndicator {
                        ThinkingIndicator(activity: busyActivity, justSent: store.awaitingReply && store.status?.busy != true)
                            .id("thinking")
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                // Beside a sidebar or inspector the column gets roomier margins.
                .padding(.horizontal, asColumn ? 28 : 16)
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
            .scrollDismissesKeyboard(.immediately)
            .onScrollPhaseChange { old, phase in
                let moving = phase == .tracking || phase == .interacting || phase == .decelerating
                userScrolling = moving
                // A scroll of the reader's that comes to rest near the end
                // (after any fling) follows the live bottom again.
                if !moving, old == .tracking || old == .interacting || old == .decelerating,
                   distanceFromBottom <= ChatScroll.reattachDistance, !pinned {
                    pinned = true
                }
            }
            .onScrollGeometryChange(for: ChatScroll.Metrics.self) { g in
                ChatScroll.Metrics(g)
            } action: { old, new in
                distanceFromBottom = new.distanceFromBottom
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
                guard pinned else { return }
                settleAtBottom(proxy)
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
                let showJump = store.viewingPast || (!pinned && distanceFromBottom > ChatScroll.reattachDistance)
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
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) { StatusBanner() }
                .frame(maxWidth: .infinity)
                // Mac: the window toolbar spans every column, and the sidebar
                // and inspector beside keep their own color under it. The
                // conversation does the same instead of a blurred band of text.
                .background(Platform.barInWindowToolbar ? Color(.systemBackground) : .clear,
                            ignoresSafeAreaEdges: .top)
        }
        .scrollEdgeEffectHidden(Platform.barInWindowToolbar, for: .top)
        // While holding to talk, the screen's background rises from the
        // bottom so the live transcript reads cleanly (same hold-driven motion).
        .overlay {
            if voice.panelMounted { VoiceScrim(presence: voice.presence) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(draft: draft) { text, images, files in
                store.send(text, images: images, files: files)
            }
        }
        // The orb over the bar's middle: above the conversation, its edge
        // fade and the voice scrim, and free to be bigger than the bar.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ownFrame = $0 }
        .overlay(alignment: .topLeading) {
            if !Platform.barInWindowToolbar, orbSlot.width > 0 {
                FloatingTitleOrb(barCenterY: orbSlot.midY, columnWidth: ownFrame.width) {
                    model.showHostSwitcher = true
                }
                .position(x: orbSlot.midX - ownFrame.minX, y: orbSlot.midY - ownFrame.minY)
            }
        }
        // The Mac's orb stays in the window toolbar; listening, a big one
        // rises at the top of the conversation instead.
        .overlay(alignment: .top) {
            if Platform.barInWindowToolbar, voice.panelMounted {
                ListeningOrb(columnWidth: ownFrame.width)
                    .padding(.top, 16)
            }
        }
        .modifier(OrbPresenceTracking(scrolledUp: !pinned || store.viewingPast, scrolling: userScrolling))
        .navigationTitle(store.assistantName)
        .navigationBarTitleDisplayMode(.inline)
        // Immersive, the iOS 26 look: the system bar stays but without its
        // material backdrop (iOS 27 gives the bar one by default); the
        // conversation runs under three floating pieces (two round buttons,
        // the orb) with only the soft scroll-edge fade, which keeps text from
        // colliding with the clock and the orb.
        .toolbarBackground(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        // The Mac shows the same three in the window's own toolbar (MacToolbar).
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
                    TitleOrbSlot { orbSlot = $0 } action: { model.showHostSwitcher = true }
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
    private func settleAtBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            for delay in [30, 250] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard pinned, !userScrolling else { return }
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
