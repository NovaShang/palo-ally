import PaloAllyKit
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(VoiceInputController.self) private var voice
    @State private var draft = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.hasOlderMessages {
                        Button {
                            Task { await store.loadOlder() }
                        } label: {
                            if store.isLoadingOlder { ProgressView() } else { Text("看看更早的") }
                        }
                        .buttonStyle(.borderless)
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
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: store.messages.last?.id) {
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.messages.last?.text) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: showsBusyIndicator) {
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
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
        // Immersive: the system bar stays, but without its blurred backdrop
        // or the scroll-edge blur — the conversation runs under three glass
        // pieces (two round buttons, the title capsule).
        .toolbarBackground(.hidden, for: .navigationBar)
        .scrollEdgeEffectHidden(true, for: .top)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("PaloAlly").font(.headline)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(store.connection.isOnline ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(subtitle)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 5)
                .frame(minHeight: 44)
                .glassEffect(.regular, in: .capsule)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.showAssistant = true
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .badge(store.pendingApprovals.count)
                .accessibilityLabel("助理详情")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.showLibrary = true
                } label: {
                    Image(systemName: "books.vertical")
                }
                .accessibilityLabel("资料库")
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

    private var subtitle: String {
        if store.connection.isOnline {
            if store.isBusy { return (store.status?.activity).map { "\($0)…" } ?? "正在忙…" }
            return model.mode == .demo ? "演示中" : "在线"
        }
        return Copy.connection(store.connection)
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
                    Button("去配对") { model.showPairingSheet = true }
                        .buttonStyle(.glassProminent)
                }
            } else if case .offline = store.connection {
                banner(icon: "wifi.exclamationmark", tint: .secondary, text: "连不上电脑，正在重试…") {
                    Button("重试") { store.reconnectNow() }
                        .buttonStyle(.glass)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
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
                .foregroundStyle(.tint)
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
