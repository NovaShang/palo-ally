import PaloAllyKit
import SwiftUI

/// 「试试」: a few things the assistant offers to do, floating just above the
/// composer while the chat is quiet. Tap sends the full request; the small ✕
/// (or long-press → 不再显示) dismisses one for good. Quiet styling: a dashed
/// capsule, no glass, no theme color.
struct SuggestionChips: View {
    let suggestions: [Suggestion]
    /// The conversation is empty: a short greeting goes above the chips.
    let greeting: Bool
    let use: (Suggestion) -> Void
    let dismiss: (Suggestion) -> Void
    @Environment(\.placesAsColumns) private var asColumn

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if greeting {
                Text("直接说就行，或者试试这些：")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            if asColumn {
                // Beside a sidebar or inspector the row stays in its column
                // and fades out at the end.
                row.mask {
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 28)
                    }
                }
            } else {
                // Phones: the row runs to the screen edges.
                row.scrollClipDisabled()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var row: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { s in
                    chip(s)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            // Room for the fade to land past the last chip.
            .padding(.trailing, asColumn ? 24 : 0)
        }
    }

    private func chip(_ s: Suggestion) -> some View {
        HStack(spacing: 6) {
            Button { use(s) } label: {
                HStack(spacing: 4) {
                    Text("试试").foregroundStyle(.tertiary)
                    Text(s.chip).foregroundStyle(.primary)
                }
                .font(.subheadline)
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("试试：\(s.chip)")
            .accessibilityHint("把这句话发给助理")

            Button { dismiss(s) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("不再显示这条")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground).opacity(0.6), in: .capsule)
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contextMenu {
            Button("发送", systemImage: "arrow.up.circle") { use(s) }
            Button("不再显示", systemImage: "eye.slash", role: .destructive) { dismiss(s) }
        } preview: {
            Text(s.prompt).padding().frame(maxWidth: 320)
        }
    }
}
