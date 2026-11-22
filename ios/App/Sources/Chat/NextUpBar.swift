import PaloAllyKit
import SwiftUI

/// 下一件 (docs/workbench-design/backlog.html): above an agent's composer
/// once it has finished a turn with nothing waiting on the owner, the first
/// item of its folder's 待办 in line for it. 开始 sends the item to it as the
/// owner's words, quoting it, and marks it being done by it; 换一件 offers
/// the next (the order stays); ✕ puts the offer away for the rest of the day.
struct NextUpBar: View {
    let palID: String
    /// The message is about to go out (it rises like a typed one).
    var willSend: () -> Void = {}

    @Environment(AppStore.self) private var store

    var body: some View {
        let item = store.nextBacklog(forPal: palID)
        // A stack, not a Group: an empty Group has nothing to run the task on.
        VStack(spacing: 0) {
            if let item {
                bar(item)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: item?.id)
        .task(id: "\(palID)|\(store.connection.isOnline)") {
            if store.connection.isOnline, store.backlog(forPal: palID) == nil { await store.loadBacklog(forPal: palID) }
        }
    }

    private func bar(_ item: BacklogItem) -> some View {
        HStack(spacing: 8) {
            Text(String(localized: "下一件", table: "Files"))
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(item.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(String(localized: "开始", table: "Files")) {
                willSend()
                store.startBacklog(item, by: palID, words: String(localized: "开始做待办里的这件", table: "Files"))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .accessibilityIdentifier("next-up-start")
            Button(String(localized: "换一件", table: "Files")) {
                withAnimation(.snappy) { store.skipNextBacklog(forPal: palID) }
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .accessibilityIdentifier("next-up-skip")
            Button {
                withAnimation(.snappy) { store.dismissNextBacklog(forPal: palID) }
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "今天不再提示", table: "Files"))
            .help(String(localized: "今天不再提示", table: "Files"))
        }
        .font(.subheadline)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        // Inside the composer's width.
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("next-up")
    }
}
