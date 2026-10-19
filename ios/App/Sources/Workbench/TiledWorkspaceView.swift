import PaloAllyKit
import SwiftUI

/// What a tile's header shows.
struct TileInfo: Equatable {
    var name: String
    var status: String = ""
    var dot: StatusDotKind = .idle
}

/// The tiling's measures (outside the generic view, which can't hold statics).
private enum TileMetrics {
    static let canvas = "tiled-canvas"
    static let gap: CGFloat = 6
    static let hot: CGFloat = 14
    static let corner: CGFloat = 18
    static let headerHeight: CGFloat = 44
    static let switcherHeight: CGFloat = 48
    static let narrowBelow: Double = 700
}

/// A workspace's sessions tiled on one canvas (workbench-prd §5.3). It draws a
/// `LayoutTree`, hosts what the caller puts in each tile, and reports every
/// change of the layout (a divider moved, a tile swapped or docked) so the
/// caller can keep it and send it to the host. Nothing else is decided here.
///
/// On a narrow width (iPad slide over, split view) only two tiles show and the
/// rest sit in a row of capsules below; the stored layout is left alone and the
/// dividers and dragging are off.
struct TiledWorkspaceView<Content: View>: View {
    /// The tree to draw (any drift is renormalized here).
    let layout: LayoutTree.Node
    let activeId: String?
    let info: (String) -> TileInfo
    /// The new tree, and whether the gesture is over (false while a divider moves).
    var onLayoutChange: (LayoutTree.Node, Bool) -> Void = { _, _ in }
    var onActivate: (String) -> Void = { _ in }
    var onExpand: (String) -> Void = { _ in }
    var onClose: (String) -> Void = { _ in }
    /// The tile whose details are open (its capsule opens them), and what they show.
    var detailFor: Binding<String?> = .constant(nil)
    var detail: (String) -> AnyView = { _ in AnyView(EmptyView()) }
    @ViewBuilder var content: (String) -> Content

    @State private var liveTree: LayoutTree.Node?
    @State private var dividerBase: LayoutTree.Node?
    @State private var hoveredDivider: String?
    @State private var draggingDivider: String?
    @State private var tileDrag: TileDrag?

    private struct TileDrag: Equatable {
        var id: String
        var translation: CGSize
        var location: CGPoint
    }

    var body: some View {
        GeometryReader { outer in
            let normalized = LayoutTree.resized(layout)
            let order = LayoutTree.leafOrder(of: normalized)
            let narrow = LayoutTree.narrowPolicy(order: order, active: activeId, width: outer.size.width,
                                                 narrowBelow: TileMetrics.narrowBelow)
            let shown = narrow.isNarrow ? (LayoutTree.keeping(narrow.visible, in: normalized) ?? normalized) : normalized
            let tree = narrow.isNarrow ? shown : (liveTree ?? shown)
            let size = CGSize(width: outer.size.width,
                              height: outer.size.height - (narrow.isNarrow ? TileMetrics.switcherHeight : 0))
            VStack(spacing: 0) {
                canvas(tree: tree, size: size, interactive: !narrow.isNarrow)
                    .frame(width: size.width, height: size.height)
                if narrow.isNarrow {
                    switcher(narrow.switcher)
                        .frame(height: TileMetrics.switcherHeight)
                }
            }
        }
    }

    // MARK: - the canvas

    private func rect(of f: (w: Double, h: Double, x: Double, y: Double), in size: CGSize) -> CGRect {
        CGRect(x: f.x * size.width, y: f.y * size.height, width: f.w * size.width, height: f.h * size.height)
    }

    private func canvas(tree: LayoutTree.Node, size: CGSize, interactive: Bool) -> some View {
        let fractions = LayoutTree.fractions(of: tree)
        let order = LayoutTree.leafOrder(of: tree)
        let frames: [String: CGRect] = fractions.mapValues { rect(of: $0, in: size) }
        let inset = TileMetrics.gap / 2
        return ZStack(alignment: .topLeading) {
            ForEach(order, id: \.self) { id in
                if let r = frames[id]?.insetBy(dx: inset, dy: inset) {
                    tile(id, in: r)
                }
            }
            if interactive {
                ForEach(LayoutTree.dividers(of: tree)) { d in
                    divider(d, size: size, tree: tree)
                }
            }
            ForEach(order, id: \.self) { id in
                if let r = frames[id]?.insetBy(dx: inset, dy: inset) {
                    chrome(id, in: r, interactive: interactive, frames: frames, tree: tree)
                }
            }
            dropPreview(frames: frames, inset: inset)
        }
        .coordinateSpace(name: TileMetrics.canvas)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    // MARK: - one tile

    @ViewBuilder
    private func tile(_ id: String, in r: CGRect) -> some View {
        let active = id == activeId
        let shape = RoundedRectangle(cornerRadius: TileMetrics.corner, style: .continuous)
        content(id)
            // The floating header takes room, so a page inside sees an inset.
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: TileMetrics.headerHeight) }
            .frame(width: max(r.width, 1), height: max(r.height, 1))
            .background(.background, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(active ? Color.accentColor : Color.primary.opacity(0.10),
                                   lineWidth: active ? 1.5 : 0.5)
            }
            .shadow(color: active ? Color.accentColor.opacity(0.28) : .clear, radius: 10)
            // Spoken to: the border glows softly with the voice.
            .overlay { TileVoiceGlow(owner: id, shape: shape) }
            .contentShape(shape)
            // Alongside whatever the page does with a touch, never instead.
            .simultaneousGesture(TapGesture().onEnded { onActivate(id) })
            .animation(.snappy(duration: 0.2), value: active)
            .position(x: r.midX, y: r.midY)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tile-\(id)")
    }

    // MARK: - header capsule and buttons

    @ViewBuilder
    private func chrome(_ id: String, in r: CGRect, interactive: Bool, frames: [String: CGRect], tree: LayoutTree.Node) -> some View {
        let i = info(id)
        let dragging = tileDrag?.id == id
        let buttonsWidth: CGFloat = 76
        let capsuleMax = max(r.width - buttonsWidth - 28, 60)
        ZStack(alignment: .topLeading) {
            header(i, id: id)
                .frame(maxWidth: min(capsuleMax, 320), alignment: .leading)
                .offset(x: 8 + (dragging ? tileDrag?.translation.width ?? 0 : 0),
                        y: 6 + (dragging ? tileDrag?.translation.height ?? 0 : 0))
                .scaleEffect(dragging ? 1.04 : 1, anchor: .topLeading)
                .zIndex(dragging ? 2 : 0)
                .onTapGesture {
                    onActivate(id)
                    detailFor.wrappedValue = detailFor.wrappedValue == id ? nil : id
                }
                .gesture(headerDrag(id, frames: frames, tree: tree), including: interactive ? .all : .subviews)
                .popover(isPresented: Binding(get: { detailFor.wrappedValue == id },
                                              set: { if !$0, detailFor.wrappedValue == id { detailFor.wrappedValue = nil } })) {
                    detail(id)
                        .frame(minWidth: 360, idealWidth: 380, minHeight: 420, idealHeight: 560)
                        .presentationCompactAdaptation(.sheet)
                }
                .accessibilityIdentifier("tile-header-\(id)")
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    glassButton("arrow.up.left.and.arrow.down.right", label: String(localized: "展开")) { onExpand(id) }
                    glassButton("xmark", label: String(localized: "关闭")) { onClose(id) }
                }
            }
            .frame(width: r.width - 8, height: 32, alignment: .trailing)
        }
        .frame(width: r.width, height: r.height, alignment: .topLeading)
        .position(x: r.midX, y: r.midY)
        // Only the capsule and the buttons take touches: empty frame space is not
        // hit-testable, so the page below keeps the rest.
    }

    private func header(_ i: TileInfo, id: String) -> some View {
        HStack(spacing: 8) {
            VoiceLevelDot(i.dot, owner: id)
            Text(i.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if !i.status.isEmpty {
                Text(i.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 32)
        .glassEffect(.regular, in: .capsule)
        .contentShape(.capsule)
    }

    private func glassButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    // MARK: - dragging a tile by its capsule

    private func headerDrag(_ id: String, frames: [String: CGRect], tree: LayoutTree.Node) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(TileMetrics.canvas))
            .onChanged { v in
                onActivate(id)
                tileDrag = TileDrag(id: id, translation: v.translation, location: v.location)
            }
            .onEnded { v in
                defer { tileDrag = nil }
                guard let (target, zone) = dropTarget(at: v.location, dragging: id, frames: frames) else { return }
                if let new = Self.apply(zone, moving: id, onto: target, in: tree) { onLayoutChange(new, true) }
            }
    }

    /// The tile under the point, and where on it the drop would land.
    private func dropTarget(at p: CGPoint, dragging id: String, frames: [String: CGRect]) -> (String, PaneDropZone)? {
        guard let (target, frame) = frames.first(where: { $0.key != id && $0.value.contains(p) }) else { return nil }
        return (target, PaneDropZone.zone(at: p, in: frame))
    }

    static func apply(_ zone: PaneDropZone, moving id: String, onto target: String, in tree: LayoutTree.Node) -> LayoutTree.Node? {
        guard id != target else { return nil }
        guard let dock = zone.dock else { return LayoutTree.swapping(id, target, in: tree) }
        return LayoutTree.docking(pane: id, at: target, horizontal: dock.horizontal, before: dock.before, in: tree)
    }

    @ViewBuilder
    private func dropPreview(frames: [String: CGRect], inset: CGFloat) -> some View {
        if let d = tileDrag, let (target, zone) = dropTarget(at: d.location, dragging: d.id, frames: frames),
           let frame = frames[target]?.insetBy(dx: inset, dy: inset) {
            let r = zone.highlightRect(in: frame)
            RoundedRectangle(cornerRadius: TileMetrics.corner, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .overlay {
                    RoundedRectangle(cornerRadius: TileMetrics.corner, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                }
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
                .animation(.snappy(duration: 0.15), value: zone)
                .animation(.snappy(duration: 0.15), value: target)
        }
    }

    // MARK: - dividers

    /// No resize cursor: SwiftUI's `pointerStyle` is macOS-only, not on Catalyst or iPad;
    /// the line lights up under the pointer instead.
    private func divider(_ d: LayoutTree.Divider, size: CGSize, tree: LayoutTree.Node) -> some View {
        let along: CGFloat = d.vertical ? size.height : size.width
        let across: CGFloat = d.vertical ? size.width : size.height
        let center: CGFloat = CGFloat(d.position) * across
        let from: CGFloat = CGFloat(d.span.lowerBound) * along
        let length: CGFloat = CGFloat(d.span.upperBound - d.span.lowerBound) * along
        let lit = hoveredDivider == d.id || draggingDivider == d.id
        let line: CGFloat = max(length - 24, 0)
        let hotSize = CGSize(width: d.vertical ? TileMetrics.hot : length, height: d.vertical ? length : TileMetrics.hot)
        let lineSize = CGSize(width: d.vertical ? 3 : line, height: d.vertical ? line : 3)
        let mid = CGPoint(x: d.vertical ? center : from + length / 2, y: d.vertical ? from + length / 2 : center)
        let tint: Color = draggingDivider == d.id ? Color.accentColor.opacity(0.8) : Color.primary.opacity(lit ? 0.35 : 0)
        return Capsule()
            .fill(tint)
            .frame(width: lineSize.width, height: lineSize.height)
            .frame(width: hotSize.width, height: hotSize.height)
            .contentShape(Rectangle())
            .position(mid)
            .onHover { inside in
                if inside { hoveredDivider = d.id } else if hoveredDivider == d.id { hoveredDivider = nil }
            }
            .gesture(dividerDrag(d, across: across, tree: tree))
            .animation(.easeOut(duration: 0.12), value: lit)
            .accessibilityHidden(true)
    }

    private func dividerDrag(_ d: LayoutTree.Divider, across: CGFloat, tree: LayoutTree.Node) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(TileMetrics.canvas))
            .onChanged { v in
                if dividerBase == nil { dividerBase = tree }
                draggingDivider = d.id
                let travel: CGFloat = d.vertical ? v.translation.width : v.translation.height
                let delta = Double(travel / max(across, 1))
                let next = LayoutTree.movingDivider(path: d.path, index: d.index, by: delta, in: dividerBase ?? tree)
                liveTree = next
                onLayoutChange(next, false)
            }
            .onEnded { _ in
                if let final = liveTree { onLayoutChange(final, true) }
                liveTree = nil; dividerBase = nil; draggingDivider = nil
            }
    }

    // MARK: - the narrow switcher

    private func switcher(_ ids: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(ids, id: \.self) { id in
                        let i = info(id)
                        Button { onActivate(id) } label: {
                            HStack(spacing: 6) {
                                StatusDot(i.dot, size: 8)
                                Text(i.name).font(.subheadline).lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .accessibilityIdentifier("tile-switch-\(id)")
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

#if DEBUG
/// Three tiles with placeholder pages, to see the tiling work: drag the
/// dividers, drag a capsule onto another tile, tap to focus, close, expand.
struct TiledWorkspaceDemo: View {
    @State private var tree = LayoutTree.tiledPreset(panes: ["alpha", "beta", "gamma"])!
    @State private var active: String? = "alpha"
    @State private var expanded: String?

    private let names = ["alpha": "Landing page", "beta": "API cleanup", "gamma": "Release notes"]
    private let dots: [String: StatusDotKind] = ["alpha": .working, "beta": .waiting, "gamma": .done]
    private let tints: [String: Color] = ["alpha": .teal, "beta": .orange, "gamma": .indigo]

    var body: some View {
        Group {
            if let e = expanded {
                ZStack(alignment: .topTrailing) {
                    placeholder(e)
                    Button("Back") { expanded = nil }.padding()
                }
            } else if LayoutTree.leafOrder(of: tree).isEmpty {
                Text("No tiles")
            } else {
                TiledWorkspaceView(
                    layout: tree, activeId: active,
                    info: { TileInfo(name: names[$0] ?? $0, status: "demo", dot: dots[$0] ?? .idle) },
                    onLayoutChange: { t, _ in tree = t },
                    onActivate: { active = $0 },
                    onExpand: { expanded = $0 },
                    onClose: { id in
                        if let t = LayoutTree.removing(pane: id, from: tree) {
                            active = LayoutTree.focusAfterClosing(id, in: tree)
                            tree = t
                        }
                    },
                    content: placeholder)
                .padding(6)
            }
        }
    }

    private func placeholder(_ id: String) -> some View {
        ZStack {
            (tints[id] ?? .gray).opacity(0.12)
            VStack(spacing: 6) {
                Text(names[id] ?? id).font(.title3.weight(.semibold))
                Text("placeholder page").foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Tiled workspace") { TiledWorkspaceDemo() }
#endif
