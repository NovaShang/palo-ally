import PaloAllyKit
import SwiftUI

/// 模型: the system's menu. With `defaultChoice` the first model is the
/// default (picking it sends none).
struct DetailModelTile: View {
    let detail: AgentDetail
    /// `.some(nil)`: back to the default.
    let set: (String??) -> Void

    var body: some View {
        let selected = detail.selectedModel
        let first = detail.models.first?.id
        let pick = Binding(get: { selected }, set: { m in
            guard m != selected else { return }
            set(detail.capabilities.defaultChoice && m == first ? .some(nil) : .some(m))
        })
        Menu {
            Picker("模型", selection: pick) {
                if !detail.models.contains(where: { $0.id == selected }) {
                    Text(ModelName.short(detail.runningModel)).tag(selected)
                }
                ForEach(detail.models) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            ValueTileLabel(label: String(localized: "模型"), value: detail.modelName)
        }
        .menuStyle(.button)
        .buttonStyle(TileButtonStyle())
        .menuIndicator(.hidden)
        .disabled(detail.models.isEmpty)
        .accessibilityIdentifier("detail-model")
    }
}

/// 思考深度: a column of growing bars, as many as the model takes. A whole
/// column is pressed, and a drag goes across them. The assistant's word at
/// the top is a menu with 默认 too.
struct DetailDepthTile: View {
    let detail: AgentDetail
    /// nil: back to the default.
    let set: (String?) -> Void

    @Environment(\.detailMetrics) private var metrics
    /// The bar under the finger.
    @State private var dragged: Int?
    @State private var hovered: Int?

    private var shown: Int? { dragged ?? detail.depthIndex }
    private var word: String {
        if let dragged { return detail.harness.effortLabel(detail.efforts[dragged]) }
        return detail.harness.effortLabel(detail.effort.flatMap { $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("思考深度").detailFont(metrics.label).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if detail.capabilities.defaultChoice { wordMenu } else { wordText }
            }
            Spacer(minLength: 0)
            bars
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: .infinity, alignment: .leading)
        .detailTile()
        .sensoryFeedback(.selection, trigger: shown)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-effort")
    }

    private var wordText: some View {
        Text(word)
            .detailFont(metrics.label, .semibold)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var wordMenu: some View {
        Menu {
            Picker("思考深度", selection: Binding(get: { detail.effort ?? "" }, set: { set($0.isEmpty ? nil : $0) })) {
                Text(detail.harness.effortLabel(nil)).tag("")
                ForEach(detail.efforts, id: \.self) { Text(detail.harness.effortLabel($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            wordText
                .padding(.vertical, 6)
                .padding(.leading, 12)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(TileInnerButtonStyle())
        .menuIndicator(.hidden)
        .padding(.vertical, -6)
        .accessibilityIdentifier("detail-effort-menu")
    }

    private var bars: some View {
        GeometryReader { geo in
            let n = detail.efforts.count
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(detail.efforts.enumerated()), id: \.element) { i, id in
                    Button { pick(i) } label: {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(i <= (shown ?? -1) ? DetailColors.ink : DetailColors.track)
                            .frame(height: AgentDetail.barHeight(i, of: n))
                            .brightness(hovered == i ? -0.06 : 0)
                            .padding(.horizontal, 3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .contentShape(.rect)
                    }
                    .buttonStyle(TileInnerButtonStyle())
                    .onHover { on in hovered = on ? i : (hovered == i ? nil : hovered) }
                    .accessibilityLabel(detail.harness.effortLabel(id))
                    .accessibilityAddTraits(i == shown ? .isSelected : [])
                    .accessibilityIdentifier("detail-effort-\(id)")
                }
            }
            .animation(.easeOut(duration: 0.18), value: shown)
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { g in
                        guard n > 0, dragged != nil || abs(g.translation.width) > abs(g.translation.height) else { return }
                        dragged = min(max(Int(g.location.x / (geo.size.width / CGFloat(n))), 0), n - 1)
                    }
                    .onEnded { _ in
                        guard let i = dragged else { return }
                        dragged = nil
                        pick(i)
                    }
            )
        }
        .frame(height: 40)
        .padding(.horizontal, -3)
    }

    private func pick(_ i: Int) {
        guard detail.efforts.indices.contains(i), detail.efforts[i] != detail.effort else { return }
        set(detail.efforts[i])
    }
}
