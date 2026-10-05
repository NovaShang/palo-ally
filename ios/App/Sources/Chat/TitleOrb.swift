import PaloAllyKit
import SwiftUI

/// The middle of the title bar: the assistant's orb. Its motion is the
/// status — calm when idle, livelier while it works, and it listens as the
/// owner types or speaks. Only when it isn't idle does a short caption say
/// what it's doing (or that something waits on the owner). Tapping opens the
/// status card. Phones stack the caption under the orb; the Mac's window
/// toolbar is too short for that, so it sits to the orb's right there, with
/// the orb kept at the center.
struct TitleOrb: View {
    enum Arrangement { case stacked, inline }
    var arrangement: Arrangement = .stacked
    let action: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    /// Mac toolbar: room for the caption on each side, so the orb stays centered.
    static let inlineCaptionWidth: CGFloat = 140
    static let inlineOrbSize: CGFloat = 28

    var body: some View {
        let line = store.agentStatusLine
        let caption = line.kind == .idle ? nil : line.text
        Button(action: action) {
            switch arrangement {
            case .stacked: stacked(caption, line.kind)
            case .inline: inline(caption, line.kind)
            }
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: caption)
        .accessibilityLabel("\(store.assistantName)：\(line.text)")
        .accessibilityHint(model.hasSeveralHosts ? "看它在做什么、换模型或切换助理" : "看它在做什么、换模型")
    }

    private func stacked(_ caption: String?, _ kind: AgentStatusLine.Kind) -> some View {
        VStack(spacing: 1) {
            // A touch smaller while a caption shares the bar's height.
            orb(size: caption == nil ? 30 : 26)
            if let caption {
                captionText(caption, kind)
                    .frame(maxWidth: 220)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
    }

    private func inline(_ caption: String?, _ kind: AgentStatusLine.Kind) -> some View {
        let s = Self.inlineOrbSize
        let side = Self.inlineCaptionWidth + 8
        return orb(size: s)
            .frame(width: s + 2 * side, height: 36)
            .overlay(alignment: .leading) {
                if let caption {
                    captionText(caption, kind)
                        .frame(maxWidth: Self.inlineCaptionWidth, alignment: .leading)
                        .padding(.leading, side + s + 8)
                        .transition(.opacity)
                }
            }
            .contentShape(.rect)
    }

    private func orb(size: CGFloat) -> some View {
        AssistantAvatar(tint: model.currentTheme.color, active: store.assistantWorking, listens: true)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                // Another assistant has something new.
                if model.hasSeveralHosts && model.othersNeedAttention {
                    Circle().fill(.red).frame(width: 7, height: 7).offset(x: 2, y: -1)
                        .accessibilityLabel("别的助理有新消息")
                }
            }
    }

    private func captionText(_ text: String, _ kind: AgentStatusLine.Kind) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(kind == .needsYou ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.opacity)
    }
}

extension AppStore {
    /// What the agent is doing, in priority order (see AgentStatusLine).
    var agentStatusLine: AgentStatusLine {
        AgentStatusLine.make(
            offlineText: connection.isOnline ? nil : Copy.connectionShort(connection),
            pendingApprovals: pendingApprovals.count,
            busy: isBusy,
            activity: status?.activity,
            tasks: tasks
        )
    }

    /// 「Opus 5.5 · 思考：中」; the thinking part only when the model has one.
    var modelLine: String {
        let name = ModelName.short(status?.model ?? modelInfo?.model ?? "")
        guard !name.isEmpty else { return "" }
        guard let effort = status?.effort, !effort.isEmpty else { return name }
        return "\(name) · 思考：\(EffortName.label(effort))"
    }
}
