import PaloAllyKit
import SwiftUI

/// The details' large tile: the live indicator with the context ring round
/// it, the name (renamed in place), one line of how it stands, and the pill
/// with the context's numbers, which compacts it.
struct DetailHeroTile<Indicator: View>: View {
    let name: String
    let status: String
    /// The context used, 0 to 100 (nil: not known).
    let fill: Int?
    let tokens: Int?
    let window: Int?
    /// nil: it can't be compacted from here.
    var compact: (() -> Void)?
    var compacting = false
    var canCompact = true
    /// Not to be touched at all (offline, open in a terminal).
    var held = false
    var canRename = true
    /// Its name changed here; nil: the pencil opens `edit` instead.
    var rename: ((String) -> Void)?
    var edit: () -> Void = {}
    /// The demo's `detail-rename`.
    var renaming: Binding<Bool>
    @ViewBuilder let indicator: (CGFloat) -> Indicator

    @Environment(\.detailMetrics) private var metrics
    @State private var hovered = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ContextRing(fill: fill)
                indicator(metrics.ring)
            }
            .frame(width: metrics.ring, height: metrics.ring)
            Group {
                if renaming.wrappedValue { field } else { title }
            }
            .padding(.top, 9)
            Text(status)
                .detailFont(metrics.status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 3)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("detail-status")
            if pillShown {
                pill.padding(.top, 10)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .detailTile()
        .onHover { hovered = $0 }
        .onChange(of: renaming.wrappedValue, initial: true) { _, on in
            if on { draft = name }
        }
    }

    // MARK: the name

    private var title: some View {
        Button {
            if rename != nil { renaming.wrappedValue = true } else { edit() }
        } label: {
            HStack(spacing: 5) {
                // The name stays in the middle, the pencil beside it.
                if canRename { Color.clear.frame(width: 14, height: 1) }
                Text(name)
                    .detailFont(metrics.name, .bold)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if canRename {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                        .opacity(metrics.phone || hovered ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: hovered)
                }
            }
            .frame(minHeight: metrics.phone ? 28 : nil)
            .contentShape(.rect)
        }
        .buttonStyle(TileInnerButtonStyle())
        .disabled(!canRename)
        .accessibilityLabel(name)
        .accessibilityHint(canRename ? Text("改名字") : Text(""))
        .accessibilityIdentifier("detail-rename")
    }

    private var field: some View {
        TextField("名字", text: $draft)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .detailFont(metrics.name, .bold)
            .focused($focused)
            .submitLabel(.done)
            .onSubmit(commit)
            .onKeyPress(.escape) {
                renaming.wrappedValue = false
                return .handled
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(DetailColors.track, in: .rect(cornerRadius: 8, style: .continuous))
            .padding(.vertical, -1)
            .padding(.horizontal, 6)
            .onAppear { focused = true }
            .onChange(of: focused) { _, on in
                if !on { commit() }
            }
            .accessibilityIdentifier("detail-name-field")
    }

    private func commit() {
        guard renaming.wrappedValue else { return }
        renaming.wrappedValue = false
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty, words != name { rename?(words) }
    }

    // MARK: the pill

    private var numbers: String? {
        if let tokens, let window, window > 0 { return "\(DetailTokens.short(tokens)) / \(DetailTokens.short(window))" }
        return fill.map { "\($0)%" }
    }

    private var pillShown: Bool { numbers != nil || compact != nil }

    @ViewBuilder private var pill: some View {
        if let compact {
            Button(action: compact) { pillLabel }
                .buttonStyle(TileInnerButtonStyle())
                .disabled(held || !canCompact || compacting)
                .opacity(held ? 0.42 : 1)
                .accessibilityIdentifier("detail-compact")
        } else {
            pillLabel
        }
    }

    private var pillLabel: some View {
        HStack(spacing: 7) {
            if let numbers {
                Text(verbatim: numbers)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if compact != nil {
                Text(compacting ? String(localized: "正在压缩…") : String(localized: "压缩"))
                    .foregroundStyle(canCompact && !compacting ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            }
        }
        .detailFont(metrics.pillText, .semibold)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 12)
        .frame(minHeight: metrics.pill)
        .background(DetailColors.track, in: .capsule)
    }
}

/// The context used, round the indicator: from the top, clockwise.
private struct ContextRing: View {
    let fill: Int?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let stroke = StrokeStyle(lineWidth: side * 0.04, lineCap: .round)
            let pct = min(max(fill ?? 0, 0), 100)
            ZStack {
                Circle().stroke(DetailColors.ringTrack, style: stroke)
                if pct > 0 {
                    Circle().trim(from: 0, to: Double(pct) / 100)
                        .stroke(DetailColors.ring(pct), style: stroke)
                        .rotationEffect(.degrees(-90))
                }
            }
            .padding(side * 0.04)
            .animation(.easeInOut(duration: 0.5), value: pct)
        }
        .accessibilityElement()
        .accessibilityLabel("上下文")
        .accessibilityValue(fill.map { "\($0)%" } ?? String(localized: "还不知道"))
        .accessibilityIdentifier("detail-context")
    }
}
