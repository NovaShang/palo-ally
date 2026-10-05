import PaloAllyKit
import SwiftUI

/// The assistant switcher, from the title capsule: one row per paired
/// computer — its color, name, state, unread replies and pending approvals —
/// then 添加一台电脑 / 管理. Assistants waiting on an approval come first.
struct HostSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.switcherOrder, id: \.self) { id in
                Button {
                    model.showHostSwitcher = false
                    withAnimation(.snappy) { model.switchTo(id) }
                } label: {
                    HostSwitcherRow(id: id)
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 6)
            HStack(spacing: 18) {
                if model.mode == .paired {
                    Button {
                        model.showHostSwitcher = false
                        model.showPairingSheet = true
                    } label: {
                        Label("添加一台电脑", systemImage: "plus")
                    }
                }
                Spacer(minLength: 0)
                Button {
                    model.showHostSwitcher = false
                    model.showAssistant = true
                    model.showSettings = true
                    model.showHostList = true
                } label: {
                    Text("管理")
                }
            }
            .font(.callout)
            .tint(.primary)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .padding(8)
        .frame(width: 300)
    }
}

private struct HostSwitcherRow: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let store = model.stores[id]
        let current = id == model.activeHostID
        let unread = model.unreadCount(id)
        let pending = model.pendingCount(id)
        HStack(spacing: 12) {
            Circle()
                .fill(model.theme(for: id).color.gradient)
                .frame(width: 26, height: 26)
                .overlay {
                    if current {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName(id)).font(.body.weight(current ? .semibold : .regular)).lineLimit(1)
                Text(state(store)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if pending > 0 {
                Text("\(pending) 件待确认")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.red, in: .capsule)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(current ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func state(_ store: AppStore?) -> String {
        guard let store else { return "没连上" }
        if store.connection.isOnline {
            if store.isBusy { return "正在忙…" }
            return model.mode == .demo ? "演示中" : "在线"
        }
        return Copy.connection(store.connection)
    }
}
