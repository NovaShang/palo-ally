import PaloAllyKit
import SwiftUI

/// 「模型  Opus 5.5 · 思考：中 ›」 for the current assistant; opens the picker.
struct ModelRow: View {
    @Environment(AppStore.self) private var store
    let open: () -> Void

    var body: some View {
        let value = store.modelLine
        Button(action: open) {
            HStack(spacing: 6) {
                Text("模型")
                Spacer(minLength: 12)
                Text(value.isEmpty ? "默认" : value).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .task { try? await store.loadModels() }
        .accessibilityLabel("模型：\(value.isEmpty ? "默认" : value)，点一下更换")
    }
}
