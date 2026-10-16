import PaloAllyKit
import SwiftUI

/// 「模型  Opus 5.5 · 思考：中 ›」 for the current assistant; opens the picker.
struct ModelRow: View {
    @Environment(AppStore.self) private var store
    let open: () -> Void

    var body: some View {
        let value = store.modelLine
        let shown = value.isEmpty ? String(localized: "默认") : value
        Button(action: open) {
            HStack(spacing: 6) {
                Text("模型")
                Spacer(minLength: 12)
                Text(shown).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .task { try? await store.loadModels() }
        .accessibilityLabel(String(localized: "模型：\(shown)，点一下更换"))
    }
}
