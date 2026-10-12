import PaloAllyKit
import SwiftUI

/// One Ally: who they are, drafts to them waiting for 发送, every exchange
/// both ways with its state (newest first), and 解除, confirmed in place.
struct AllyDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let allyID: String

    #if DEBUG
    /// `-demoAllyRemove YES`: the page opens on 解除's confirmation (snapshots).
    @State private var confirmingRemove = UserDefaults.standard.bool(forKey: "demoAllyRemove")
    #else
    @State private var confirmingRemove = false
    #endif
    @State private var removing = false
    @State private var loadingOlder = false
    @State private var error: String?

    private var log: [AllyEntry] { store.allyLog(allyID) }

    var body: some View {
        if let ally = store.ally(id: allyID) {
            List {
                Section {
                    header(ally)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                let drafts = log.filter(\.isPendingDraft)
                if !drafts.isEmpty {
                    Section("等你点发送") {
                        ForEach(drafts) { d in
                            AllyDraftCard(entry: d, name: ally.displayName, framed: false)
                                .padding(.vertical, 6)
                        }
                    }
                }

                Section("来往记录") {
                    let shown = log.filter { !$0.isPendingDraft }.reversed()
                    if shown.isEmpty {
                        Text(Copy.spaced("还没有来往。想跟 TA 说什么，直接告诉\(store.assistantName)就行，比如「跟\(ally.displayName)说我晚点到」。"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(shown)) { e in
                        AllyLogRow(entry: e)
                    }
                    if store.allyLogHasMore[allyID] == true {
                        Button {
                            Task { await loadOlder() }
                        } label: {
                            if loadingOlder { ProgressView() } else { Text("看看更早的") }
                        }
                        .tint(.secondary)
                        .frame(maxWidth: .infinity)
                        .disabled(loadingOlder)
                    }
                }

                removeSection(ally)
            }
            .navigationTitle(ally.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .task { _ = try? await store.loadAllyLog(id: allyID) }
            .refreshable { _ = try? await store.loadAllyLog(id: allyID) }
            .animation(.snappy, value: confirmingRemove)
        } else {
            ContentUnavailableView("已经解除了", systemImage: "person.2.slash",
                                   description: Text("要再加，得当面扫码。"))
        }
    }

    private func header(_ ally: AllyInfo) -> some View {
        VStack(spacing: 10) {
            AllyAvatar(ally: ally, size: 72, ring: Color(.systemGroupedBackground))
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text(ally.displayName).font(.title2.bold())
                    AllyKindTag(kind: ally.kind)
                }
                Text(subtitle(ally))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// 「在线 · TA 的助理叫小橘」.
    private func subtitle(_ ally: AllyInfo) -> String {
        var parts = [Copy.allyPresence(ally)]
        let a = ally.assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.isEmpty, a != ally.displayName { parts.append(Copy.spaced("TA 的助理叫\(a)")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func removeSection(_ ally: AllyInfo) -> some View {
        Section {
            if confirmingRemove {
                VStack(alignment: .leading, spacing: 12) {
                    Text("解除后，你们两边的列表里都不再有对方。要再加，得当面扫码。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button {
                            confirmingRemove = false
                        } label: {
                            Text("算了").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        Button {
                            Task { await remove() }
                        } label: {
                            Text(removing ? "正在解除…" : "解除").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .disabled(removing)
                }
                .padding(.vertical, 6)
            } else {
                Button("解除", role: .destructive) { confirmingRemove = true }
                    .disabled(!store.connection.isOnline)
            }
        } footer: {
            if let error { Text(error).foregroundStyle(.red) }
        }
    }

    private func remove() async {
        removing = true
        error = nil
        do {
            try await store.removeAlly(id: allyID)
            dismiss()
        } catch {
            self.error = "没解除成：\(Copy.error(error))"
        }
        removing = false
    }

    private func loadOlder() async {
        loadingOlder = true
        defer { loadingOlder = false }
        let oldest = log.first?.ts
        _ = try? await store.loadAllyLog(id: allyID, before: oldest)
    }
}

/// One exchange in the record: which way and when, the words, its state.
private struct AllyLogRow: View {
    let entry: AllyEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: entry.dir == .incoming ? "arrow.down.left" : "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text("\(entry.dir == .incoming ? "收到" : "发出") · \(Copy.clock(entry.ts))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if entry.urgent {
                    Text("急").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                if let status = Copy.allyStatus(entry) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(entry.text)
                .foregroundStyle(entry.status == .rejected ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let slots = entry.slots, !slots.isEmpty {
                AllySlotList(slots: slots)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
