import PaloAllyKit
import SwiftUI

/// The pieces the details page shares between a session and Palo
/// (docs/workbench-design/details-v2.html): the header, the model and depth
/// pickers, the context line, and the tasks group.

// MARK: - header

/// The indicator on the left; the name (tap to rename), the folder and what
/// it is doing on the right.
struct DetailHeader: View {
    /// The round indicator (a `SessionIndicator`).
    let indicator: AnyView
    let name: String
    /// The folder (a session), or what it is (Palo).
    var caption: String?
    /// What it is doing now (or the state, when it is not), after a dot of its state.
    let line: String
    let state: StatusDotKind
    /// Palo's line is a button (jump to the sessions waiting), in the waiting color.
    var lineAction: (() -> Void)?
    @Binding var editing: Bool
    @Binding var draft: String
    var canRename = true
    var onRename: () -> Void
    var onBeginRename: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 14) {
            indicator
            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    HStack {
                        TextField("名字", text: $draft)
                            .focused($focused)
                            .submitLabel(.done)
                            .font(.title3.bold())
                            .onSubmit(onRename)
                            .accessibilityIdentifier("detail-name-field")
                        Button("好", action: onRename)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .onAppear { focused = true }
                } else {
                    Button(action: onBeginRename) {
                        HStack(spacing: 6) {
                            Text(name).font(.title3.bold()).foregroundStyle(.primary).lineLimit(1)
                            if canRename {
                                Image(systemName: "pencil").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRename)
                    .accessibilityHint(canRename ? Text("改名字") : Text(""))
                    .accessibilityIdentifier("detail-rename")
                }
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let lineAction {
                    Button(action: lineAction) {
                        HStack(spacing: 6) {
                            StatusDot(state, size: 7)
                            Text(line).fontWeight(.semibold)
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        }
                        .font(.footnote)
                        .foregroundStyle(StatusDot.color(state))
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 6) {
                        StatusDot(state, size: 7)
                        Text(line).lineLimit(1)
                    }
                    .font(.footnote)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

extension View {
    /// A section row with no card behind it (the header).
    func detailBare() -> some View {
        self.listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
    }
}

// MARK: - model and depth

extension View {
    /// A picker's or menu's value in gray, not the theme color (that is for the main actions).
    func detailNeutral() -> some View { tint(.secondary) }
}

// MARK: - context

enum DetailTokens {
    /// 82_000 -> "82k", 1_000_000 -> "1M".
    static func short(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
        if n >= 1000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        return "\(n)"
    }

    static func money(_ usd: Double) -> String { String(format: "$%.2f", usd) }
}

/// 「上下文」 as one row: the bar (the indicator's arc colors), "82k / 200k",
/// and 压缩 when the caller gives one.
struct DetailContextRow: View {
    let percent: Int?
    let tokens: Int?
    let window: Int?
    var compact: (() -> Void)?
    var compacting = false
    var canCompact = true

    /// The indicator's arc colors: orange from 80%, red from 95%.
    static func arcTint(_ pct: Int) -> Color {
        switch IndicatorRules.arcTone(fraction: Double(pct) / 100) {
        case .normal: .secondary
        case .warn: Color(rgb: 0xFF9F0A)
        case .danger: Color(rgb: 0xFF453A)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("上下文")
            if let percent {
                ProgressView(value: Double(min(max(percent, 0), 100)) / 100)
                    .tint(Self.arcTint(percent))
                Group {
                    if let tokens, let window, window > 0 {
                        Text("\(DetailTokens.short(tokens)) / \(DetailTokens.short(window))")
                    } else {
                        Text("\(percent)%")
                    }
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            } else {
                Spacer()
                Text("还不知道").font(.footnote).foregroundStyle(.secondary)
            }
            if let compact {
                Button(compacting ? String(localized: "正在压缩…") : String(localized: "压缩"), action: compact)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(.primary)
                    .disabled(!canCompact || compacting)
                    .fixedSize()
                    .accessibilityIdentifier("detail-compact")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - tasks

/// The tasks group's title: 正在进行 · N while some run, else 任务.
func detailTasksHeader(running: Int) -> Text {
    running > 0 ? Text("正在进行 · \(running)") : Text("任务")
}
