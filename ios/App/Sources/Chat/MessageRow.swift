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
                Text(MarkdownBlock.attributed(message.text))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.gradient, in: .rect(cornerRadius: 20, style: .continuous))
                    .textSelection(.enabled)
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
                if message.kind == .task, let taskId = message.taskId {
                    TaskChip(taskId: taskId)
                }
                if message.kind == .approval, let id = message.approvalId, let approval = store.approval(id: id) {
                    ApprovalCard(approval: approval)
                }
            }
            Spacer(minLength: 24)
        }
    }

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
