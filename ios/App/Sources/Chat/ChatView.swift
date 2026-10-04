import PaloAllyKit
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @State private var dictation = SpeechDictation()

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

                    if store.awaitingReply {
                        ThinkingIndicator()
                            .id("thinking")
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.last?.id) {
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.messages.last?.text) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: store.awaitingReply) {
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            StatusBanner()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(draft: $draft, dictation: dictation) {
                let text = draft
                draft = ""
                store.send(text)
            }
        }
        .navigationTitle("PaloAlly")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("PaloAlly").font(.headline)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(store.connection.isOnline ? (store.isKilled ? Color.orange : Color.green) : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(subtitle)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
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

    private var subtitle: String {
        if store.connection.isOnline {
            if store.isKilled { return "已暂停" }
            if store.isBusy { return "正在忙…" }
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

/// Banner for connection trouble and the paused state.
struct StatusBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @State private var resuming = false

    var body: some View {
        Group {
            if store.isKilled {
                banner(icon: "pause.circle.fill", tint: .orange, text: "助理已暂停，什么都不会做") {
                    Button(resuming ? "正在恢复…" : "继续工作") {
                        resuming = true
                        Task { try? await store.resume(); resuming = false }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(resuming)
                }
            } else if case .rejected = store.connection {
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
        .animation(.snappy, value: store.isKilled)
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

/// Shows within 2s of sending so the user knows they were heard.
struct ThinkingIndicator: View {
    @State private var slow = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(slow ? "收到啦，正在想…" : "收到")
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
}
