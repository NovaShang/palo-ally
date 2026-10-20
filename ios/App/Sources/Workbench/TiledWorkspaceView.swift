import PaloAllyKit
import SwiftUI

/// What a tile's header shows.
struct TileInfo: Equatable {
    var name: String
    var status: String = ""
    var dot: StatusDotKind = .idle
    var contextPct: Int? = nil
    var effort: String? = nil
    var model: String? = nil
    var running = 0
}

/// The tiling's measures (outside the generic view, which can't hold statics).
private enum TileMetrics {
    static let canvas = "tiled-canvas"
    static let gap: CGFloat = 6

    /// A tile's rect inside its slot; a slot with no room yet (a window just
    /// coming up) gives an empty rect at its middle, not a null one (whose
    /// infinite origin makes every frame inside NaN).
    static func inset(_ slot: CGRect, by d: CGFloat) -> CGRect {
        let r = slot.insetBy(dx: d, dy: d)
        return r.isNull ? CGRect(x: slot.midX, y: slot.midY, width: 0, height: 0) : r
    }
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

    /// What the pointer is doing (a divider or a header being dragged, a
    /// divider under it). Read only by the layers that draw it, never by
    /// this body: a drag's every move re-renders those, not the tiles' pages.
    @State private var pointer = TileCanvasPointer()

    var body: some View {
        #if DEBUG || PERF_HARNESS
        let _ = PerfProbe.count("Tiled")
        #endif
        GeometryReader { outer in
            let normalized = LayoutTree.resized(layout)
            let order = LayoutTree.leafOrder(of: normalized)
            let narrow = LayoutTree.narrowPolicy(order: order, active: activeId, width: outer.size.width,
                                                 narrowBelow: TileMetrics.narrowBelow)
            let shown = narrow.isNarrow ? (LayoutTree.keeping(narrow.visible, in: normalized) ?? normalized) : normalized
            // While a divider moves the tiles keep their places: only the
            // divider and an outline of where the tiles will go follow the
            // pointer (relaying out every chat per frame made it crawl);
            // the new layout lands once, on release.
            // A window just coming up has no size yet: no negative heights
            // (or tiles inset into null rects, whose frames are NaN).
            let size = CGSize(width: max(0, outer.size.width),
                              height: max(0, outer.size.height - (narrow.isNarrow ? TileMetrics.switcherHeight : 0)))
            VStack(spacing: 0) {
                canvas(tree: shown, size: size, interactive: !narrow.isNarrow)
                    .frame(width: size.width, height: size.height)
                if narrow.isNarrow {
                    switcher(narrow.switcher)
                        .frame(height: TileMetrics.switcherHeight)
                }
            }
            #if DEBUG || PERF_HARNESS
            .task { await TileCanvasPointer.wiggle(pointer, layout: layout, width: outer.size.width, onLayoutChange: onLayoutChange) }
            #endif
        }
    }

    // MARK: - the canvas

    private func canvas(tree: LayoutTree.Node, size: CGSize, interactive: Bool) -> some View {
        let frames = TileCanvasPointer.frames(of: tree, in: size)
        let order = LayoutTree.leafOrder(of: tree)
        let inset = TileMetrics.gap / 2
        return ZStack(alignment: .topLeading) {
            ForEach(order, id: \.self) { id in
                if let r = frames[id].map({ TileMetrics.inset($0, by: inset) }) {
                    tile(id, in: r)
                }
            }
            if interactive {
                // Where the tiles will go while a divider moves: outlines only.
                TileGhostLayer(pointer: pointer, size: size)
                // The dividers follow the outline while one moves.
                TileDividerLayer(pointer: pointer, tree: tree, size: size, onLayoutChange: onLayoutChange)
            }
            ForEach(order, id: \.self) { id in
                if let r = frames[id].map({ TileMetrics.inset($0, by: inset) }) {
                    TileChrome(id: id, rect: r, interactive: interactive, frames: frames, tree: tree, pointer: pointer,
                               info: info, onLayoutChange: onLayoutChange, onActivate: onActivate, onExpand: onExpand,
                               onClose: onClose, detailFor: detailFor, detail: detail)
                }
            }
            TileDropPreview(pointer: pointer, frames: frames)
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

    static func apply(_ zone: PaneDropZone, moving id: String, onto target: String, in tree: LayoutTree.Node) -> LayoutTree.Node? {
        TileCanvasPointer.apply(zone, moving: id, onto: target, in: tree)
    }

    // MARK: - the narrow switcher

    private func switcher(_ ids: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(ids, id: \.self) { id in
                        TileSwitchButton(id: id, info: info, onActivate: onActivate)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// What the pointer is doing on a tiled canvas. Its own observable object so
/// that a drag's moves re-render only what reads it (the dividers, the
/// outlines, the dragged header and the drop preview), not every tile.
@MainActor
@Observable
final class TileCanvasPointer {
    /// While a divider moves: where the tiles will go.
    var liveTree: LayoutTree.Node?
    @ObservationIgnored var dividerBase: LayoutTree.Node?
    var hoveredDivider: String?
    var draggingDivider: String?
    var tileDrag: TileDrag?

    struct TileDrag: Equatable {
        var id: String
        var translation: CGSize
        var location: CGPoint
    }

    static func frames(of tree: LayoutTree.Node, in size: CGSize) -> [String: CGRect] {
        LayoutTree.fractions(of: tree).mapValues { f in
            CGRect(x: f.x * size.width, y: f.y * size.height, width: f.w * size.width, height: f.h * size.height)
        }
    }

    /// The tile under the point, and where on it the drop would land.
    static func dropTarget(at p: CGPoint, dragging id: String, frames: [String: CGRect]) -> (String, PaneDropZone)? {
        guard let (target, frame) = frames.first(where: { $0.key != id && $0.value.contains(p) }) else { return nil }
        return (target, PaneDropZone.zone(at: p, in: frame))
    }

    static func apply(_ zone: PaneDropZone, moving id: String, onto target: String, in tree: LayoutTree.Node) -> LayoutTree.Node? {
        guard id != target else { return nil }
        guard let dock = zone.dock else { return LayoutTree.swapping(id, target, in: tree) }
        return LayoutTree.docking(pane: id, at: target, horizontal: dock.horizontal, before: dock.before, in: tree)
    }

    #if DEBUG || PERF_HARNESS
    /// `-demoWiggle YES`: the first divider is dragged back and forth (what
    /// `TileDividerLayer`'s drag does per pointer move, 120 moves a second),
    /// and let go, over and over (perf measuring). With `-perfAlternate YES`
    /// it moves through each busy window and is let go as a quiet one starts.
    static func wiggle(_ pointer: TileCanvasPointer, layout: LayoutTree.Node, width: CGFloat,
                       onLayoutChange: @escaping (LayoutTree.Node, Bool) -> Void) async {
        guard UserDefaults.standard.bool(forKey: "demoWiggle") else { return }
        try? await Task.sleep(for: .seconds(4))
        let alternate = UserDefaults.standard.bool(forKey: "perfAlternate")
        while !Task.isCancelled {
            if !PerfSwitch.driving { try? await Task.sleep(for: .milliseconds(20)); continue }
            let tree = LayoutTree.resized(layout)
            guard let d = LayoutTree.dividers(of: tree).first else { return }
            let start = Date()
            while alternate ? PerfSwitch.driving : Date().timeIntervalSince(start) < 3 {
                let t = Date().timeIntervalSince(start)
                let dx = sin(t * 2 * .pi / 1.5) * 0.15 * width
                if pointer.dividerBase == nil { pointer.dividerBase = tree }
                pointer.draggingDivider = d.id
                let next = LayoutTree.movingDivider(path: d.path, index: d.index, by: Double(dx / max(width, 1)),
                                                    in: pointer.dividerBase ?? tree)
                pointer.liveTree = next
                onLayoutChange(next, false)
                try? await Task.sleep(for: .milliseconds(8))
            }
            if let final = pointer.liveTree { onLayoutChange(final, true) }
            pointer.liveTree = nil; pointer.dividerBase = nil; pointer.draggingDivider = nil
            if !alternate { try? await Task.sleep(for: .seconds(2)) }
        }
    }
    #endif
}

/// Where the tiles will go while a divider moves: outlines only.
private struct TileGhostLayer: View {
    let pointer: TileCanvasPointer
    let size: CGSize

    var body: some View {
        if let ghost = pointer.liveTree {
            let inset = TileMetrics.gap / 2
            let ghostFrames = TileCanvasPointer.frames(of: ghost, in: size)
            ForEach(LayoutTree.leafOrder(of: ghost), id: \.self) { id in
                if let r = ghostFrames[id].map({ TileMetrics.inset($0, by: inset) }) {
                    RoundedRectangle(cornerRadius: TileMetrics.corner, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                        .frame(width: max(r.width, 1), height: max(r.height, 1))
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// The dividers: lit under the pointer, dragged to resize (the tiles follow
/// on release).
private struct TileDividerLayer: View {
    let pointer: TileCanvasPointer
    let tree: LayoutTree.Node
    let size: CGSize
    let onLayoutChange: (LayoutTree.Node, Bool) -> Void

    var body: some View {
        ForEach(LayoutTree.dividers(of: pointer.liveTree ?? tree)) { d in
            divider(d)
        }
    }

    /// No resize cursor: SwiftUI's `pointerStyle` is macOS-only, not on Catalyst or iPad;
    /// the line lights up under the pointer instead.
    private func divider(_ d: LayoutTree.Divider) -> some View {
        let along: CGFloat = d.vertical ? size.height : size.width
        let across: CGFloat = d.vertical ? size.width : size.height
        let center: CGFloat = CGFloat(d.position) * across
        let from: CGFloat = CGFloat(d.span.lowerBound) * along
        let length: CGFloat = CGFloat(d.span.upperBound - d.span.lowerBound) * along
        let lit = pointer.hoveredDivider == d.id || pointer.draggingDivider == d.id
        let line: CGFloat = max(length - 24, 0)
        let hotSize = CGSize(width: d.vertical ? TileMetrics.hot : length, height: d.vertical ? length : TileMetrics.hot)
        let lineSize = CGSize(width: d.vertical ? 3 : line, height: d.vertical ? line : 3)
        let mid = CGPoint(x: d.vertical ? center : from + length / 2, y: d.vertical ? from + length / 2 : center)
        let tint: Color = pointer.draggingDivider == d.id ? Color.accentColor.opacity(0.8) : Color.primary.opacity(lit ? 0.35 : 0)
        return Capsule()
            .fill(tint)
            .frame(width: lineSize.width, height: lineSize.height)
            .frame(width: hotSize.width, height: hotSize.height)
            .contentShape(Rectangle())
            .position(mid)
            .onHover { inside in
                if inside { pointer.hoveredDivider = d.id } else if pointer.hoveredDivider == d.id { pointer.hoveredDivider = nil }
            }
            .gesture(drag(d, across: across))
            .animation(.easeOut(duration: 0.12), value: lit)
            .accessibilityHidden(true)
    }

    private func drag(_ d: LayoutTree.Divider, across: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(TileMetrics.canvas))
            .onChanged { v in
                if pointer.dividerBase == nil { pointer.dividerBase = tree }
                if pointer.draggingDivider != d.id { pointer.draggingDivider = d.id }
                let travel: CGFloat = d.vertical ? v.translation.width : v.translation.height
                let delta = Double(travel / max(across, 1))
                let next = LayoutTree.movingDivider(path: d.path, index: d.index, by: delta, in: pointer.dividerBase ?? tree)
                if pointer.liveTree != next { pointer.liveTree = next }
                onLayoutChange(next, false)
            }
            .onEnded { _ in
                if let final = pointer.liveTree { onLayoutChange(final, true) }
                pointer.liveTree = nil; pointer.dividerBase = nil; pointer.draggingDivider = nil
            }
    }
}

/// A tile's header (its round indicator, dragged to swap or dock the tile)
/// and its buttons. Its own view: what the header shows of the session is
/// read here, so a session ticking re-renders its own header only.
private struct TileChrome: View {
    let id: String
    let rect: CGRect
    let interactive: Bool
    let frames: [String: CGRect]
    let tree: LayoutTree.Node
    let pointer: TileCanvasPointer
    let info: (String) -> TileInfo
    let onLayoutChange: (LayoutTree.Node, Bool) -> Void
    let onActivate: (String) -> Void
    let onExpand: (String) -> Void
    let onClose: (String) -> Void
    let detailFor: Binding<String?>
    let detail: (String) -> AnyView

    var body: some View {
        let r = rect
        let drag = pointer.tileDrag?.id == id ? pointer.tileDrag : nil
        let dragging = drag != nil
        ZStack(alignment: .topLeading) {
            header(info(id))
                .offset(x: 8 + (drag?.translation.width ?? 0), y: 6 + (drag?.translation.height ?? 0))
                .scaleEffect(dragging ? 1.04 : 1, anchor: .topLeading)
                .zIndex(dragging ? 2 : 0)
                .onTapGesture {
                    onActivate(id)
                    detailFor.wrappedValue = detailFor.wrappedValue == id ? nil : id
                }
                .gesture(headerDrag, including: interactive ? .all : .subviews)
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

    /// The tile's title: the session's round indicator on its glass circle,
    /// as a session's page has it (no name capsule: the sidebar names it);
    /// holding to talk to the tile, the level in its middle.
    private func header(_ i: TileInfo) -> some View {
        SessionIndicator(state: i.dot, contextPct: i.contextPct, effort: i.effort, model: i.model,
                         size: 26, glass: true, running: i.running, voiceOwner: .some(id))
            .contentShape(.circle)
            .accessibilityLabel(Text(verbatim: "\(i.name)，\(StatusDot.label(i.dot))"))
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

    // MARK: dragging a tile by its header

    private var headerDrag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(TileMetrics.canvas))
            .onChanged { v in
                if pointer.tileDrag == nil { onActivate(id) }
                pointer.tileDrag = TileCanvasPointer.TileDrag(id: id, translation: v.translation, location: v.location)
            }
            .onEnded { v in
                defer { pointer.tileDrag = nil }
                guard let (target, zone) = TileCanvasPointer.dropTarget(at: v.location, dragging: id, frames: frames) else { return }
                if let new = TileCanvasPointer.apply(zone, moving: id, onto: target, in: tree) { onLayoutChange(new, true) }
            }
    }
}

/// Where a dragged header would land: the tile under it, or a side of it.
private struct TileDropPreview: View {
    let pointer: TileCanvasPointer
    let frames: [String: CGRect]

    var body: some View {
        let inset = TileMetrics.gap / 2
        if let d = pointer.tileDrag, let (target, zone) = TileCanvasPointer.dropTarget(at: d.location, dragging: d.id, frames: frames),
           let frame = frames[target].map({ TileMetrics.inset($0, by: inset) }) {
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
}

/// One capsule of the narrow switcher (reads its session itself).
private struct TileSwitchButton: View {
    let id: String
    let info: (String) -> TileInfo
    let onActivate: (String) -> Void

    var body: some View {
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
