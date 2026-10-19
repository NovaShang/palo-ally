import PaloAllyKit
import SwiftUI

/// The page's title as a glass capsule (workbench-prd §6): its name, the
/// status dot, then status and folder, and a small chevron. The same on
/// Palo's page and a session's; tapping it opens the details
/// (`AgentDetailView`): a popover on the Mac and iPad, a sheet on iPhone.
struct TitleCapsule: View {
    let name: String
    let dot: StatusDotKind
    let subtitle: String
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            model.detailShown.toggle()
        } label: {
            HStack(spacing: 8) {
                StatusDot(dot, size: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .accessibilityIdentifier("page-title")
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentTransition(.opacity)
                            .accessibilityIdentifier("page-status")
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: 340, alignment: .leading)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.snappy, value: subtitle)
        .popover(isPresented: Binding(get: { model.detailShown && !AgentDetailPlacement.usesSheet(model: model, store: store) },
                                      set: { model.detailShown = $0 })) {
            AgentDetailView()
                .environment(model)
                .environment(store)
                .frame(minWidth: 360, idealWidth: 380, minHeight: 420, idealHeight: 560)
        }
        .accessibilityLabel(Text("\(name)，\(subtitle)"))
        .accessibilityHint(Text("打开详情"))
        .accessibilityIdentifier("title-capsule")
    }
}

@MainActor enum AgentDetailPlacement {
    /// iPhone, and Palo's page on an iPad (no capsule there: its orb is the
    /// title): a sheet. Elsewhere a popover under the capsule.
    static func usesSheet(model: AppModel, store: AppStore) -> Bool {
        guard !Platform.barInWindowToolbar else { return false }
        return model.layout == .phone || store.scope == .palo
    }
}

/// Palo's capsule: its name and what it is doing; the same shape as a session's.
struct PaloTitleCapsule: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let working = store.assistantWorking
        let dot: StatusDotKind = working ? .working : .idle
        TitleCapsule(name: store.assistantName, dot: dot,
                     subtitle: working ? (store.status?.activity ?? StatusDot.label(.working)) : StatusDot.label(.idle))
    }
}

/// iPhone (and Palo on an iPad): the details as a sheet with a half and a full height.
struct AgentDetailSheet: ViewModifier {
    /// false inside a tile: its header opens its own details.
    var enabled = true
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { enabled && model.detailShown && AgentDetailPlacement.usesSheet(model: model, store: store) },
                                           set: { model.detailShown = $0 })) {
            AgentDetailView()
                .environment(model)
                .environment(store)
                .presentationDetents([.medium, .large])
        }
    }
}
