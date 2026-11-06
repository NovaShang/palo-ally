import PaloAllyKit
import SwiftUI

// 「TL;DR」 (PaloAllyKit Models/Tldr.swift): a quiet button under the
// conversation's latest long reply asks its agent for the points; the ask
// sits in the conversation folded to one small line.

/// Under the latest long reply, once its turn is over: text only, like a
/// quiet action (no fill, no glass, not the theme color). The ask goes as
/// a message, so the conversation moves as it does on a send.
struct TldrButton: View {
    /// A message is about to go (the scroll coordinator's send).
    let willSend: () -> Void
    @Environment(AppStore.self) private var store

    #if DEBUG
    /// `-demoActions tldr`: the button shown tapped.
    static let demoTap = Notification.Name("PaloAlly.demoTapTldr")
    #endif

    var body: some View {
        Button(action: tap) {
            Text(verbatim: "TL;DR")
                .font(.caption.weight(.medium))
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .tint(.secondary)
        .foregroundStyle(.secondary)
        .help(String(localized: "让它把最近这段对话整理成要点"))
        .accessibilityLabel(String(localized: "TL;DR：整理最近这段对话的要点"))
        .frame(maxWidth: .infinity, alignment: .leading)
        // Close under the reply it sums up (the rows are 14 apart).
        .padding(.top, -6)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Self.demoTap)) { _ in tap() }
        #endif
    }

    private func tap() {
        willSend()
        ChatMotion.with(ChatMotion.send) { store.askTldr() }
    }
}

/// The owner's TL;DR ask: one small line on the owner's side, 「TL;DR」 and a
/// chevron; tapped, the instruction it sent shows under it (and folds again).
struct TldrAskRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.chatRowResizing) private var resizing
    let message: ChatMessage

    var body: some View {
        let open = store.unfolded.contains(message.id)
        let words = TldrAsk.shown(message.text)
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
            if message.delivery == .failed {
                Button {
                    store.retry(message)
                } label: {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("没发出去，点一下重发")
            }
            Button {
                let animates = resizing?.resizing(message.id, folding: open) ?? true
                if animates {
                    withAnimation(.snappy) { store.setUnfolded(message.id, !open) }
                } else {
                    store.setUnfolded(message.id, !open)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: "TL;DR")
                        .font(.caption.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background { Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1) }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(words.isEmpty)
            .accessibilityLabel(open ? String(localized: "TL;DR 请求，收起") : String(localized: "TL;DR 请求，展开看发了什么"))
            }
            if open, !words.isEmpty {
                Text(MarkdownBlock.attributed(words))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    }
                    .transition(.opacity)
            }
        }
        .opacity(message.delivery == .sending || message.delivery == .queued ? 0.75 : 1)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }
}
