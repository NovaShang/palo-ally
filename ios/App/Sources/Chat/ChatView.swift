import PaloAllyKit
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(VoiceInputController.self) private var voice
    @State private var draft = ""
    @State private var showModelPicker = false
    /// Following the live bottom (streaming keeps the newest text in view).
    /// Detached as soon as the reader drags up even a little; re-attached
    /// when they come back near the bottom or tap the jump button.
    @State private var pinned = true
    /// The finger (or its fling) is moving the list — only that can detach.
    @State private var userScrolling = false
    @State private var distanceFromBottom: CGFloat = 0

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
                            .id(message.id)
                    }

                    ForEach(store.unanchoredPendingApprovals) { approval in
                        ApprovalCard(approval: approval)
                    }

                    if showsBusyIndicator {
                        ThinkingIndicator(activity: busyActivity, justSent: store.awaitingReply && store.status?.busy != true)
                            .id("thinking")
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
                let showJump = !pinned && distanceFromBottom > ChatScroll.reattachDistance
                ZStack {
                    if showJump {
                        JumpToLatestButton(streaming: store.isBusy) {
                            pinned = true
                            withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
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
            StatusBanner()
        }
        // While holding to talk, the screen's background rises from the
        // bottom so the live transcript reads cleanly (same hold-driven motion).
        .overlay {
            if voice.panelMounted { VoiceScrim(presence: voice.presence) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(draft: $draft) { text, images, files in
                store.send(text, images: images, files: files)
            }
        }
        .navigationTitle("PaloAlly")
        .navigationBarTitleDisplayMode(.inline)
        // Immersive, the iOS 26 look: the system bar stays but without its
        // material backdrop (iOS 27 gives the bar one by default); the
        // conversation runs under three floating glass pieces (two round
        // buttons, the title capsule) with only the soft scroll-edge fade,
        // which keeps text from colliding with the clock and the title.
        .toolbarBackground(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .toolbar {
            ToolbarItem(placement: .principal) {
                titleCapsule
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.showAssistant = true
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .tint(.primary) // toolbar glyphs stay neutral; the theme color is for meaning
                .badge(store.pendingApprovals.count)
                .accessibilityLabel("助理详情")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.showLibrary = true
                } label: {
                    Image(systemName: "books.vertical")
                }
                .tint(.primary)
                .accessibilityLabel("资料库")
            }
        }
    }

    /// The agent's live status: line 1 is what it's doing (needs you >
    /// working > background tasks > idle; connection trouble first), line 2
    /// the model and thinking depth. Assistants are told apart by their color,
    /// not a name. Tapping opens the popover: running tasks, assistants (2+),
    /// model / thinking.
    @ViewBuilder private var titleCapsule: some View {
        @Bindable var model = model
        let line = statusLine
        let label = VStack(spacing: 1) {
            HStack(spacing: 6) {
                StatusDot(kind: line.kind, rejected: store.connection.isRejected)
                Text(line.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(line.kind == .needsYou ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            if !modelLine.isEmpty {
                Text(modelLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
        }
        .frame(maxWidth: 230)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .frame(minHeight: 44)
        .animation(.snappy, value: line)
        .animation(.snappy, value: modelLine)
        .overlay(alignment: .topTrailing) {
            if model.hasSeveralHosts && model.othersNeedAttention {
                Circle().fill(.red).frame(width: 8, height: 8).offset(x: -6, y: 4)
                    .accessibilityLabel("别的助理有新消息")
            }
        }

        Button { model.showHostSwitcher = true } label: { label }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel("\(line.text)\(modelLine.isEmpty ? "" : "，\(modelLine)")")
            .accessibilityHint(model.hasSeveralHosts ? "看在做的事、切换助理或换模型" : "看在做的事或换模型")
            .popover(isPresented: $model.showHostSwitcher, arrowEdge: .top) {
                HostSwitcher(
                    openModelPicker: {
                        // Let the popover finish closing before the sheet comes up.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            showModelPicker = true
                        }
                    },
                    openTask: { id in
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            model.openTask(id)
                        }
                    }
                )
                .environment(store)
                .presentationCompactAdaptation(.popover)
            }
            .sheet(isPresented: $showModelPicker) { ModelPickerSheet().environment(store) }
    }

    private var statusLine: AgentStatusLine {
        let online = store.connection.isOnline
        return AgentStatusLine.make(
            offlineText: online ? nil : Copy.connectionShort(store.connection),
            pendingApprovals: store.pendingApprovals.count,
            busy: store.isBusy,
            activity: store.status?.activity,
            tasks: store.tasks
        )
    }

    /// 「Opus 5.5 · 思考：中」; the thinking part only when the model has one.
    private var modelLine: String {
        let name = ModelName.short(store.status?.model ?? store.modelInfo?.model ?? "")
        guard !name.isEmpty else { return "" }
        guard let effort = store.status?.effort, !effort.isEmpty else { return name }
        return "\(name) · 思考：\(EffortName.label(effort))"
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
            if case .rejected = store.connection {
                banner(icon: "link.badge.plus", tint: .red, text: "这台设备需要重新配对") {
                    Button("去配对") { model.startPairing(.replace) }
                        .buttonStyle(.glassProminent)
                }
            } else if case .offline = store.connection {
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

/// The capsule's state dot: green idle, orange when the owner is needed, a
/// softly pulsing theme dot while working, gray/red when not connected.
private struct StatusDot: View {
    let kind: AgentStatusLine.Kind
    let rejected: Bool
    @State private var pulse = false

    var body: some View {
        let live = kind == .working || kind == .tasks
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(live && pulse ? 0.35 : 1)
            .animation(live ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = live }
            .onChange(of: live) { _, now in pulse = now }
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch kind {
        case .offline: rejected ? .red : .secondary
        case .needsYou: .orange
        case .working, .tasks: .accentColor
        case .idle: .green
        }
    }
}
