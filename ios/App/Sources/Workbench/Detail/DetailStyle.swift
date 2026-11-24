import PaloAllyKit
import SwiftUI

// What the details' tiles look like (docs/workbench-design/details-v5.html):
// their colors, their sizes on the Mac and iPad and on a phone, their
// surface and press, and the rows they stand in.

enum DetailColors {
    /// A tile on the popover's or the sheet's glass; under the pointer.
    static let tile = dynamic(light: .init(white: 1, alpha: 0.72), dark: .init(red: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.26))
    static let hover = dynamic(light: .init(white: 1, alpha: 0.95), dark: .init(red: 140 / 255, green: 140 / 255, blue: 150 / 255, alpha: 0.4))
    /// A hairline round a tile, and one between two rows in it.
    static let edge = dynamic(light: .init(white: 1, alpha: 0.85), dark: .init(white: 1, alpha: 0.13))
    static let line = dynamic(light: .init(white: 0, alpha: 0.07), dark: .init(white: 1, alpha: 0.09))
    /// What isn't filled: a bar, a pill, a round button.
    static let track = dynamic(light: .init(white: 0, alpha: 0.09), dark: .init(white: 1, alpha: 0.13))
    /// What is: a depth bar.
    static let ink = dynamic(light: .init(red: 0x2C / 255, green: 0x2C / 255, blue: 0x30 / 255, alpha: 1), dark: .init(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF6 / 255, alpha: 1))

    /// The context ring: the indicator's arc and its track (indicator.html).
    static let ringTrack = dynamic(light: .init(white: 0, alpha: 0.12), dark: .init(white: 1, alpha: 0.16))
    static func ring(_ pct: Int) -> Color {
        switch IndicatorRules.arcTone(fraction: Double(pct) / 100) {
        case .normal: dynamic(light: .init(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1), dark: .init(white: 1, alpha: 0.9))
        case .warn: Color(rgb: 0xFF9F0A)
        case .danger: Color(rgb: 0xFF453A)
        }
    }

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

struct DetailMetrics: Equatable {
    var phone = false

    static let gap: CGFloat = 10
    static let radius: CGFloat = 22
    var padding: CGFloat { phone ? 16 : 14 }
    var ring: CGFloat { phone ? 124 : 112 }
    var name: CGFloat { phone ? 19 : 16 }
    var status: CGFloat { phone ? 14 : 11.5 }
    var pill: CGFloat { phone ? 32 : 26 }
    var pillText: CGFloat { phone ? 14 : 12 }
    /// A tile's label and its value.
    var label: CGFloat { phone ? 13 : 11 }
    var value: CGFloat { phone ? 18 : 16 }
    /// A task, and the line under it.
    var row: CGFloat { phone ? 15 : 13 }
    var line: CGFloat { phone ? 13.5 : 11.5 }
    var icon: CGFloat { phone ? 23 : 19 }
    var square: CGFloat { phone ? 13 : 11.5 }
    var askButton: CGFloat { phone ? 42 : 32 }
}

extension EnvironmentValues {
    @Entry var detailMetrics = DetailMetrics()
    /// The tiles stand on a popover's or a sheet's glass; false: on a page of their own.
    @Entry var detailOnGlass = true
}

extension View {
    /// A size from the drawing, growing with the owner's text size.
    func detailFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        modifier(DetailFont(size: size, weight: weight))
    }

    /// A tile's fill and edge.
    func detailTile(hovered: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: DetailMetrics.radius, style: .continuous)
        return background(hovered ? DetailColors.hover : DetailColors.tile, in: shape)
            .overlay { shape.strokeBorder(DetailColors.edge, lineWidth: 0.5).allowsHitTesting(false) }
    }

    /// A row of a pushed list, the `i`-th of its section's `n`: together they
    /// are one tile.
    func detailRow(_ i: Int = 0, of n: Int = 1) -> some View {
        let top = i == 0 ? DetailMetrics.radius : 0, bottom = i == n - 1 ? DetailMetrics.radius : 0
        return listRowInsets(EdgeInsets(top: 10, leading: 15, bottom: 10, trailing: 14))
            .listRowBackground(UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                                                      topTrailingRadius: top, style: .continuous).fill(DetailColors.tile))
    }

    /// A list pushed from the tiles: the glass behind it showing.
    func detailList() -> some View {
        scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            .detailGround()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .sidebarToggle)
    }

    /// What the tiles and the pages stand on: the glass round them, or the
    /// grouped gray on a page of their own.
    func detailGround() -> some View { modifier(DetailGround()) }
}

private struct DetailGround: ViewModifier {
    @Environment(\.detailOnGlass) private var onGlass

    func body(content: Content) -> some View {
        // One ground that fades: it must be there by the time the sheet is
        // up (the system's white under it), and the page stays the same one.
        content.containerBackground(for: .navigation) {
            Color(.systemGroupedBackground)
                .opacity(onGlass ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: onGlass)
                .ignoresSafeArea()
        }
    }
}

/// How much larger than the drawing the owner's text is.
struct DetailScale: DynamicProperty {
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var value: CGFloat {
        #if DEBUG
        // `-demoDetailType YES`: the largest (a Mac doesn't scale; snapshots).
        if UserDefaults.standard.bool(forKey: "demoDetailType") { return 53.0 / 17 }
        #endif
        return scale
    }
}

private struct DetailFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    private var scale = DetailScale()

    init(size: CGFloat, weight: Font.Weight) { self.size = size; self.weight = weight }

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale.value, weight: weight))
    }
}

/// A tile that is pressed: brighter under the pointer, faded when it can't be.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pressed(configuration: configuration)
    }

    private struct Pressed: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .detailTile(hovered: enabled && (hovered || configuration.isPressed))
                .contentShape(.rect(cornerRadius: DetailMetrics.radius, style: .continuous))
                .opacity(enabled ? 1 : 0.42)
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.15), value: hovered)
        }
    }
}

/// Something small pressed inside a tile (the pill, a stop button).
struct TileInnerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A square tile: its icon and name, a count at its corner (orange while
/// some of them wait on the owner).
struct SquareTileLabel: View {
    let symbol: String
    let name: String
    var count: Int = 0
    var waiting = false
    @Environment(\.detailMetrics) private var metrics
    @Environment(\.dynamicTypeSize) private var typeSize
    private let scale = DetailScale()

    init(symbol: String, name: String, count: Int = 0, waiting: Bool = false) {
        self.symbol = symbol; self.name = name; self.count = count; self.waiting = waiting
    }

    /// With large text the count is beside the name: alone in its corner it is lost.
    private var large: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        let icon = min(metrics.icon * scale.value, 34)
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: icon, weight: .medium))
                .frame(minHeight: icon + 4)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Text(name)
                    .detailFont(metrics.square, .medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if large { badge }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, large ? 14 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if !large {
                badge
                    .padding(.top, waiting ? 6 : 8)
                    .padding(.trailing, waiting ? 6 : 10)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var badge: some View {
        if count > 0 {
            if waiting {
                let side = 17 * scale.value
                Text(verbatim: "\(count)")
                    .monospacedDigit()
                    .detailFont(10, .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: side, minHeight: side)
                    .background(StatusDot.color(.waiting), in: .capsule)
            } else {
                Text(verbatim: "\(count)")
                    .monospacedDigit()
                    .detailFont(11, .semibold)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A tile with a label at its top and its value, opening a menu or a page.
struct ValueTileLabel: View {
    let label: String
    let value: String
    var symbol = "chevron.up.chevron.down"
    @Environment(\.detailMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).detailFont(metrics.label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(value)
                    .detailFont(metrics.value, .semibold)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: symbol)
                    .detailFont(metrics.label - 1, .semibold)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The square tiles: four to a row (two, with large text). Fewer of them
/// share the row, at the same height.
struct TileRow: Layout {
    var columns = 4

    private func side(_ width: CGFloat) -> CGFloat { (width - DetailMetrics.gap * 3) / 4 }

    private func rows(_ count: Int) -> [Range<Int>] {
        stride(from: 0, to: count, by: columns).map { $0..<min($0 + columns, count) }
    }

    private func height(_ row: Range<Int>, width: CGFloat, _ subviews: Subviews) -> CGFloat {
        let w = (width - DetailMetrics.gap * CGFloat(row.count - 1)) / CGFloat(row.count)
        return max(side(width), row.map { subviews[$0].sizeThatFits(.init(width: w, height: nil)).height }.max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions(by: .init(width: 352, height: 0)).width
        let rows = rows(subviews.count)
        let h = rows.reduce(0) { $0 + height($1, width: width, subviews) } + DetailMetrics.gap * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews.count) {
            let h = height(row, width: bounds.width, subviews)
            let w = (bounds.width - DetailMetrics.gap * CGFloat(row.count - 1)) / CGFloat(row.count)
            for (i, index) in row.enumerated() {
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(i) * (w + DetailMetrics.gap), y: y),
                                      proposal: .init(width: w, height: h))
            }
            y += h + DetailMetrics.gap
        }
    }
}
