import PaloAllyKit
import SwiftUI

/// 「试试」: a few things the assistant offers to do, as the last item of the
/// conversation — they scroll away with it instead of holding space above the
/// composer, and only show on first use or after the chat has been quiet
/// (SuggestionsGate). Tap sends the full request; the small ✕ (or long-press →
/// 不再显示) dismisses one for good. Quiet styling: in-content, plain, no
/// glass, no theme color.
struct SuggestionChips: View {
    let suggestions: [Suggestion]
    /// The conversation is empty: a short greeting leads in instead of 「试试」.
    let greeting: Bool
    let use: (Suggestion) -> Void
    let dismiss: (Suggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting ? "直接说就行，或者试试这些：" : "试试")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
            ForEach(suggestions) { s in
                chip(s)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ s: Suggestion) -> some View {
        HStack(spacing: 2) {
            Button { use(s) } label: {
                Text(s.chip)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("试试：\(s.chip)")
            .accessibilityHint("把这句话发给助理")

            Button { dismiss(s) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("不再显示这条")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: .capsule)
        .contextMenu {
            Button("发送", systemImage: "arrow.up.circle") { use(s) }
            Button("不再显示", systemImage: "eye.slash", role: .destructive) { dismiss(s) }
        } preview: {
            Text(s.prompt).padding().frame(maxWidth: 320)
        }
    }
}
