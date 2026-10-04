import PaloAllyKit
import SwiftUI

struct MessageRow: View {
    @Environment(AppStore.self) private var store
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(message: message)
        case .system:
            NoticeRow(text: message.text)
        default:
            // Anything the assistant says (including pushes it sends) gets full markdown.
            AssistantMessage(message: message)
        }
    }
}

private struct UserBubble: View {
    @Environment(AppStore.self) private var store
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 48)
            if message.delivery == .failed {
                Button {
                    store.retry(message)
                } label: {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("没发出去，点一下重发")
            } else if message.delivery == .sending {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if message.delivery == .queued {
                Image(systemName: "icloud.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("还没发出去，连上后会自动发")
                    .help("连上后会自动发")
            }
            VStack(alignment: .trailing, spacing: 4) {
                if let atts = message.attachments, !atts.isEmpty {
                    AttachmentStrip(attachments: atts)
                }
                if !message.text.isEmpty {
                Text(MarkdownBlock.attributed(message.text))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.gradient, in: .rect(cornerRadius: 20, style: .continuous))
                    .contextMenu {
                        Button("复制", systemImage: "doc.on.doc") { Clipboard.copy(message.text) }
                    }
                    .textSelection(.enabled)
                }
                if message.channel == .wechat || message.channel == .cli {
                    Label(message.channel == .wechat ? "来自微信" : "来自电脑", systemImage: message.channel == .wechat ? "message" : "laptopcomputer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .opacity(message.delivery == .sending || message.delivery == .queued ? 0.75 : 1)
    }
}

private struct AssistantMessage: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    let message: ChatMessage
    /// Mac / pointer: a copy button shows under the answer on hover.
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 26, height: 26)
                .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .circle)
            VStack(alignment: .leading, spacing: 8) {
                if message.proactive == true {
                    Label(proactiveLabel, systemImage: "bell.badge")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                MarkdownText(source: message.text, streaming: message.isStreaming)
                    .contextMenu {
                        Button("复制", systemImage: "doc.on.doc") { Clipboard.copy(message.text) }
                    }
                if Self.pointer, !message.isStreaming, !message.text.isEmpty {
                    // Space is kept so the row doesn't jump when it appears.
                    CopyButton(text: message.text)
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                }
                if message.kind == .task, let taskId = message.taskId {
                    TaskChip(taskId: taskId)
                }
                if message.kind == .approval, let id = message.approvalId, let approval = store.approval(id: id) {
                    ApprovalCard(approval: approval)
                }
            }
            Spacer(minLength: 24)
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
    }

    private static let pointer = ProcessInfo.processInfo.isMacCatalystApp

    private var proactiveLabel: String {
        switch message.channel {
        case .schedule: "到点提醒"
        case .probe: "我留意到"
        default: "主动找你"
        }
    }
}

private struct TaskChip: View {
    @Environment(AppStore.self) private var store
    let taskId: String

    var body: some View {
        if let task = store.task(id: taskId) {
            NavigationLink {
                TaskDetailView(taskID: taskId)
            } label: {
                let (symbol, color) = Copy.taskSymbol(task.status)
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(color)
                    Text(task.title).lineLimit(1)
                    Text("· \(Copy.taskStatus(task.status))").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct NoticeRow: View {
    let text: String

    var body: some View {
        Text(MarkdownBlock.attributed(text))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.fill.quaternary, in: .capsule)
            .frame(maxWidth: .infinity)
    }
}

/// Images sent with a message: thumbnails, tap for full size.
private struct AttachmentStrip: View {
    @Environment(AppStore.self) private var store
    let attachments: [Attachment]
    @State private var viewing: Data?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { a in
                Group {
                    if let data = store.images[a.id], let ui = UIImage(data: data) {
                        Button { viewing = data } label: {
                            Image(uiImage: ui).resizable().scaledToFill()
                        }
                        .buttonStyle(.plain)
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay { ProgressView().controlSize(.small) }
                            .task { await store.loadImage(a.id) }
                    }
                }
                .frame(width: attachments.count == 1 ? 180 : 96, height: attachments.count == 1 ? 180 : 96)
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                .accessibilityLabel("图片")
            }
        }
        .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            if let data = viewing, let ui = UIImage(data: data) {
                ImageViewer(image: ui) { viewing = nil }
            }
        }
    }
}

/// Full-screen image: pinch to zoom, tap or swipe down to close.
private struct ImageViewer: View {
    let image: UIImage
    let close: () -> Void
    @State private var scale: CGFloat = 1
    @State private var drag: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().opacity(1 - min(abs(drag.height) / 400, 0.6))
            Image(uiImage: image).resizable().scaledToFit()
                .scaleEffect(scale)
                .offset(drag)
                .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }.onEnded { _ in
                    withAnimation(.snappy) { if scale < 1.1 { scale = 1 } }
                })
                .simultaneousGesture(DragGesture().onChanged { if scale == 1 { drag = $0.translation } }.onEnded { v in
                    if abs(v.translation.height) > 120 { close() } else { withAnimation(.snappy) { drag = .zero } }
                })
        }
        .onTapGesture { if scale == 1 { close() } }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                ShareLink(item: Image(uiImage: image), preview: SharePreview("图片", image: Image(uiImage: image))) {
                    Image(systemName: "square.and.arrow.up").frame(width: 40, height: 40).glassEffect(.regular.interactive(), in: .circle)
                }
                Button(action: close) {
                    Image(systemName: "xmark").frame(width: 40, height: 40).glassEffect(.regular.interactive(), in: .circle)
                }
                .accessibilityLabel("关闭")
            }
            .foregroundStyle(.white)
            .padding()
        }
    }
}
