import PaloAllyKit
import SwiftUI

/// "Needs your OK" card. Shown inline in the chat and in the 审批 tab.
struct ApprovalCard: View {
    @Environment(AppStore.self) private var store
    let approval: Approval
    @State private var working = false
    @State private var error: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: approval.careful ? "exclamationmark.shield.fill" : "hand.raised.fill")
                    .foregroundStyle(approval.careful ? Color.orange : Color.secondary)
                Text(approval.title.isEmpty ? "需要你点个头" : approval.title)
                    .font(.headline)
                Spacer(minLength: 0)
                if !approval.isPending {
                    Text(Copy.approvalStatus(approval.status))
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }

            if !approval.detail.isEmpty {
                Text(approval.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    // While pending show everything: the tail of a long
                    // command is often the part that matters.
                    .lineLimit(approval.isPending || expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                if !approval.isPending && approval.detail.count > 120 {
                    Button(expanded ? "收起" : "展开") { expanded.toggle() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .tint(.secondary)
                }
            }

            HStack(spacing: 6) {
                let tool = Copy.tool(approval.tool)
                if !tool.isEmpty { Text(tool) }
                if let taskId = approval.taskId, let task = store.task(id: taskId) {
                    Text("· 为了「\(task.title)」")
                }
                if approval.isPending { Text("· \(Copy.relative(approval.createdAt))") }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)

            if approval.isPending {
                if let reason = approval.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if approval.careful {
                    Label("这一步需要你仔细看一下。", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        answer(allow: false)
                    } label: {
                        Text("拒绝").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .tint(.primary) // only the primary action (允许) carries the theme color

                    Button {
                        answer(allow: true)
                    } label: {
                        Text("允许").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
                .controlSize(.large)
                .disabled(working)

                if approval.canRemember {
                    Button {
                        answer(allow: true, remember: true)
                    } label: {
                        Text(rememberTitle)
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                    .tint(.secondary)
                    .disabled(working)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(approval.isPending ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 1)
        }
        .animation(.snappy, value: approval.status)
    }

    private var rememberTitle: String {
        if let scope = approval.friendlyScope {
            return "以后都允许：\(scope)"
        }
        return "以后这类都允许"
    }

    private var statusColor: Color {
        switch approval.status {
        case .allowed: .green
        case .denied, .expired: .secondary
        default: .secondary
        }
    }

    private func answer(allow: Bool, remember: Bool = false) {
        working = true
        error = nil
        Task {
            do {
                try await store.answer(approval, allow: allow, remember: remember)
            } catch {
                self.error = "没发出去：\(Friendly.message(error))"
            }
            working = false
        }
    }
}
