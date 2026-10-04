import PaloAllyKit
import SwiftUI
import UIKit

/// Text the assistant put on the owner's clipboard (copy_to_clipboard).
/// When it arrives live it's already copied (see AppStore.clipboardWriter);
/// the card shows 已复制 then, and can always copy again.
struct ClipboardCard: View {
    @Environment(AppStore.self) private var store
    let message: ChatMessage
    @State private var expanded = false
    @State private var justCopied = false

    private var copied: Bool { justCopied || store.copiedClipboardIDs.contains(message.id) }
    /// Long enough that a few lines won't show it all.
    private var isLong: Bool { message.text.count > 160 || message.text.split(separator: "\n").count > 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(message.label ?? "复制到剪贴板")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    Clipboard.copy(message.text)
                    store.markCopied(message.id)
                    justCopied = true
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(copied ? .secondary : .primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.primary)
                .sensoryFeedback(.success, trigger: justCopied) { _, now in now }
                .accessibilityLabel(copied ? "已复制，再复制一次" : "复制")
            }

            Text(message.text)
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(expanded ? nil : 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isLong {
                Button(expanded ? "收起" : "展开") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        // In-content: a quiet card, same family as approval / file cards.
        .background(.background.secondary, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .task(id: justCopied) {
            guard justCopied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            justCopied = false
        }
    }
}

extension AppStore {
    /// The app's pasteboard writer for live clipboard messages: copies only
    /// while the app is in the foreground (iOS shows the paste banner to the
    /// app that reads it, not the one that writes, so this is quiet).
    static let systemClipboardWriter: @MainActor (String) -> Bool = { text in
        guard UIApplication.shared.applicationState == .active else { return false }
        UIPasteboard.general.string = text
        return true
    }
}
