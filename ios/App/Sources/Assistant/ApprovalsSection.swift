import PaloAllyKit
import SwiftUI

struct ApprovalsSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let pending = store.pendingApprovals
        let decided = store.approvals.filter { !$0.isPending }
        Section {
            if pending.isEmpty {
                ContentUnavailableView("没有要你拍板的事", systemImage: "hand.thumbsup",
                                       description: Text("需要你点头的时候，会在这里和对话里同时出现。"))
            } else {
                ForEach(pending) { a in
                    ApprovalCard(approval: a)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }
        } header: {
            if !pending.isEmpty { Text("等你决定") }
        }

        if !decided.isEmpty {
            Section("处理过的") {
                ForEach(decided) { a in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(a.title.isEmpty ? Copy.tool(a.tool) : a.title)
                        HStack(spacing: 6) {
                            Text(Copy.approvalStatus(a.status))
                                .foregroundStyle(a.status == .allowed ? .green : .secondary)
                            Text("· \(Copy.relative(a.decidedAt ?? a.createdAt))")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }
}
