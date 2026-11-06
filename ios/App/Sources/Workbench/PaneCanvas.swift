import PaloAllyKit
import SwiftUI
import UIKit

/// A split workspace's panes, laid out by UIKit (docs/workbench-design/split-final.html).
///
/// Each pane is a `UIHostingController` of its own (`PaneRoot`), so a frame
/// of one pane (its drop working, a keystroke, a reply streaming) updates
/// that pane's graph only, never the window's or the other panes'. This
/// controller places them from the `LayoutTree`, with gutters between
/// them, and does all the pointer work (a divider hovered or
/// dragged, a pane dragged by its header) with plain views and layers:
/// no SwiftUI work per pointer move. The tree only changes on release.
@MainActor
final class PaneCanvasController: UIViewController {
    /// Makes a pane's hosting controller.
    var makePane: (String) -> UIViewController = { _ in UIViewController() }
    /// A layout the owner made (a divider let go, a pane dropped).
    var onLayoutChange: (LayoutTree.Node) -> Void = { _ in }
    /// A pane clicked or used: it becomes the workspace's current one.
    var onActivate: (String) -> Void = { _ in }
    /// ⌘⌥→ / ⌘⌥←.
    var onMoveFocus: (Bool) -> Void = { _ in }
    /// The name a dragged pane's capsule shows.
    /// What a dragged pane's capsule shows.
    var paneInfo: (String) -> TileInfo = { TileInfo(name: $0) }
    /// The Mac: the pane under the window toolbar's trailing button, if any.
    var onCornerPane: (String?) -> Void = { _ in }
    private var cornerPane: String?

    private(set) var tree: LayoutTree.Node?
    private var interactive = true
    private var accent: UIColor = .systemBlue
    private var panes: [String: PaneContainerView] = [:]
    private var hosts: [String: UIViewController] = [:]
    private var dividers: [String: DividerView] = [:]
    private var lastSize: CGSize = .zero

    // While a divider moves: where the panes will go.
    private var dividerBase: LayoutTree.Node?
    private var liveTree: LayoutTree.Node?
    private let grabLine = UIView()
    /// The preview of the new layout over the panes: the desk, and each pane
    /// a card showing a picture of its content taken as the drag began.
    private let preview = UIView()
    private var previewCards: [String: PreviewCard] = [:]
    private var previewDivider: String?
    /// Bumped by each drag: an earlier one's fade ending late leaves this
    /// one's preview alone.
    private var previewGeneration = 0
    // While the canvas itself is resized (the sidebar's or the right pane's
    // edge dragged, either shown or put away, the window's edge dragged):
    // the panes keep the size they had under the preview until it settles.
    private var resizeFrozen = false
    private var resizeSettle: DispatchWorkItem?
    /// When the canvas last took a new size laid out for real.
    private var lastResize: CFTimeInterval = 0
    // While a pane is dragged by its header.
    private var dragged: String?
    private var capsule: UIView?
    private var capsuleOffset: CGPoint = .zero
    private var dropTarget: (id: String, zone: PaneDropZone)?
    /// A document's tab being dragged in from the right pane (its leaf id).
    private var documentDragged: String?
    private let lift = UIView()
    private let edge = UIView()

    /// Panes are cards this far apart and in from the edges, on a desk
    /// lighter than the sidebar (11-05: with a hairline between them,
    /// a screen of text didn't say which pane a line belonged to; an accent
    /// outline was too heavy; a desk almost the sidebar's colour read as a
    /// mismatch, and darker than it was the wrong way: so it is plainly
    /// its own, lighter than the sidebar, the cards white over it).
    static let gap: CGFloat = 8
    /// Concentric with what sits in a card's corners: the composer (15 pt
    /// round, 6 pt in, ComposerView) and the status icon and ⋯ (14 pt round,
    /// 7 pt in, PaneMetrics) (the owner, 11-05).
    static let cardRadius: CGFloat = 21
    /// The desk round the cards, and a workspace's title bar row.
    /// Dark: deeper than the cards, which stand up from it as lit surfaces
    /// do in the dark (at 0.13 it was all but the cards' own grey, 11-05).
    static let backdrop = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.045, green: 0.045, blue: 0.05, alpha: 1)
        : UIColor(red: 246 / 255, green: 246 / 255, blue: 248 / 255, alpha: 1) }

    override func loadView() {
        let v = CanvasView()
        v.backgroundColor = Self.backdrop
        v.clipsToBounds = true
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        grabLine.isHidden = true
        grabLine.isUserInteractionEnabled = false
        // Laying out (11-05, the owner: the lines and boxes looked rough): the
        // new sizes as soft cards of the cards' own shape, the divider a short
        // rounded handle in its gutter, the swap target a lifted card, a
        // split's half a soft block concentric with the card.
        grabLine.layer.cornerRadius = 2
        preview.isHidden = true
        preview.alpha = 0
        preview.isUserInteractionEnabled = false
        lift.isHidden = true
        lift.isUserInteractionEnabled = false
        lift.layer.cornerRadius = Self.cardRadius
        lift.layer.cornerCurve = .continuous
        lift.layer.borderWidth = 1
        lift.layer.shadowColor = UIColor.black.cgColor
        lift.layer.shadowOpacity = 0.16
        lift.layer.shadowRadius = 18
        lift.layer.shadowOffset = CGSize(width: 0, height: 10)
        edge.isHidden = true
        edge.isUserInteractionEnabled = false
        edge.layer.cornerRadius = Self.cardRadius - 6
        edge.layer.cornerCurve = .continuous
        edge.layer.borderWidth = 1
        applyAccent()
        #if DEBUG
        Self.all.add(self)
        #endif
        #if DEBUG || PERF_HARNESS
        startWiggle()
        #endif
    }

    // MARK: - what to show

    func apply(tree incoming: LayoutTree.Node, interactive: Bool, accent: UIColor) {
        // One geometry for panes and dividers: a stored tree whose split
        // nodes' sizes had gone stale against their leaves put the lines
        // where no boundary was, and moving them moved nothing.
        let new = LayoutTree.resized(incoming)
        let accentChanged = !accent.isEqual(self.accent)
        self.accent = accent
        if accentChanged { applyAccent() }
        guard new != tree || interactive != self.interactive else { return }
        #if DEBUG || PERF_HARNESS
        PerfProbe.count("canvas relayout")
        #endif
        // A resize under way ends here: the panes take the new tree at once.
        settleResize()
        // Don't relayout under a drag: it lands with the release.
        tree = new
        self.interactive = interactive
        syncPanes()
        layoutCanvas()
    }

    /// The pane's composer gets the caret (⌘⌥→, ⌘⌥←).
    func focusComposer(of id: String) {
        guard let pane = panes[id] else { return }
        func field(in v: UIView) -> UIView? {
            if let t = v as? UITextView, t.isEditable { return t }
            if let t = v as? UITextField, t.isEnabled { return t }
            for s in v.subviews.reversed() { if let f = field(in: s) { return f } }
            return nil
        }
        _ = field(in: pane)?.becomeFirstResponder()
    }

    private func syncPanes() {
        guard let tree else { return }
        let ids = LayoutTree.leafOrder(of: tree)
        for (id, pane) in panes where !ids.contains(id) {
            let host = hosts[id]
            host?.willMove(toParent: nil)
            pane.removeFromSuperview()
            host?.removeFromParent()
            panes[id] = nil
            hosts[id] = nil
        }
        for id in ids where panes[id] == nil {
            let host = makePane(id)
            addChild(host)
            let pane = PaneContainerView(id: id, content: host.view)
            pane.onTouch = { [weak self] id in self?.touched(id) }
            pane.grip.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragPane(_:))))
            view.insertSubview(pane, at: 0)
            host.didMove(toParent: self)
            panes[id] = pane
            hosts[id] = host
        }
        let wanted = Set(interactive ? LayoutTree.dividers(of: tree).map(\.id) : [])
        for (id, d) in dividers where !wanted.contains(id) { d.removeFromSuperview(); dividers[id] = nil }
        for id in wanted where dividers[id] == nil {
            let d = DividerView(id: id)
            d.pan.addTarget(self, action: #selector(dragDivider(_:)))
            d.accent = accent
            view.addSubview(d)
            dividers[id] = d
        }
        // Over the panes: the drag's pieces.
        view.addSubview(preview)
        // Over the preview of the new layout.
        view.addSubview(grabLine)
        view.addSubview(lift)
        view.addSubview(edge)
        for (_, p) in panes { p.grip.isUserInteractionEnabled = true; p.dragEnabled = interactive }
    }

    private func applyAccent() {
        grabLine.backgroundColor = accent
        // A divider dragged: a clean preview of the new layout over the
        // panes, the desk with the cards where they will be (the panes'
        // content under it, overlaid with outlines, looked muddled).
        preview.backgroundColor = Self.backdrop
        lift.layer.borderColor = accent.withAlphaComponent(0.45).cgColor
        edge.layer.borderColor = accent.withAlphaComponent(0.4).cgColor
        edge.backgroundColor = accent.withAlphaComponent(0.12)
        for d in dividers.values { d.accent = accent }
    }

    // MARK: - layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastSize else { return }
        if freezesResize() {
            resize()
        } else {
            lastResize = CACurrentMediaTime()
            layoutCanvas()
        }
    }

    // MARK: - the canvas resized

    /// The canvas is being resized by something else, a frame at a time:
    /// a second new size within 0.1 s of the last (a column's edge or the
    /// window's dragged, the right pane shown), or one in an animation (the
    /// sidebar shown or put away). Each pane laid out again at every step
    /// was 30 to 60 ms (11-05: the sidebar's edge dragged, 1.7 s of the main
    /// thread for a 2 s drag), so they are pictured once and the preview of
    /// the dividers' drag stands in until it settles. A one-off change (a
    /// pane added, the page first shown) is laid out at once, as before.
    private func freezesResize() -> Bool {
        #if DEBUG
        // `-canvasLiveResize YES`: laid out at every step, as before (to compare).
        if Self.liveResize { return false }
        #endif
        guard tree != nil, lastSize.width > 0, lastSize.height > 0, view.window != nil,
              dividerBase == nil, dragged == nil, documentDragged == nil, !panes.isEmpty else { return false }
        return resizeFrozen || UIView.inheritedAnimationDuration > 0 || CACurrentMediaTime() - lastResize < 0.1
    }

    #if DEBUG
    private static let liveResize = UserDefaults.standard.bool(forKey: "canvasLiveResize")
    #endif

    /// A step of a resize: the cards (pictures of the panes as they were)
    /// take the new sizes, with the system's animation if there is one; the
    /// panes stay as they are under them.
    private func resize() {
        let animation = UIView.inheritedAnimationDuration
        if !resizeFrozen {
            resizeFrozen = true
            beginPreview(divider: nil)
            #if DEBUG
            debugLog("[canvas] resize: preview from \(Int(lastSize.width))x\(Int(lastSize.height))\(animation > 0 ? ", animated \(Int(animation * 1000)) ms" : "")")
            #endif
        }
        #if DEBUG || PERF_HARNESS
        PerfProbe.count("canvas resize step")
        #endif
        lastSize = view.bounds.size
        preview.frame = view.bounds
        if let tree { placePreview(tree, glide: false) }
        resizeSettle?.cancel()
        let settle = DispatchWorkItem { [weak self] in self?.settleResize() }
        resizeSettle = settle
        // Settled once no new size came for 0.15 s (or the animation is over).
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.15, animation + 0.05), execute: settle)
    }

    /// The resize is over (or something else needs the panes now): they are
    /// laid out once at the canvas's size, under the cards, and their own
    /// content fades back in.
    private func settleResize() {
        guard resizeFrozen else { return }
        resizeFrozen = false
        resizeSettle?.cancel()
        resizeSettle = nil
        UIView.performWithoutAnimation { layoutCanvas() }
        lastResize = 0
        #if DEBUG
        debugLog("[canvas] resize settled at \(Int(lastSize.width))x\(Int(lastSize.height))")
        #endif
        endPreview(at: nil)
    }

    /// The panes' frames: the tree's rects, `gap` apart and half of it in from the canvas's edges.
    /// Each pane's frame, on whole device pixels (`scale`, with the canvas
    /// at `origin` in its window): a pane at a half pixel drew its text
    /// blurred, on a 1x display above all.
    static func paneFrames(of tree: LayoutTree.Node, in size: CGSize, scale: CGFloat = 2, origin: CGPoint = .zero) -> [String: CGRect] {
        let s = max(scale, 1)
        let line = gap
        func px(_ v: CGFloat, _ o: CGFloat) -> CGFloat { ((v + o) * s).rounded() / s - o }
        return LayoutTree.fractions(of: tree).mapValues { f in
            var minX = f.x * size.width, minY = f.y * size.height
            var maxX = (f.x + f.w) * size.width, maxY = (f.y + f.h) * size.height
            // Half the gap on every side: `gap` between cards, half of it
            // round the outside (the owner, 11-05).
            minX += line / 2
            minY += line / 2
            maxX -= line / 2
            maxY -= line / 2
            minX = px(minX, origin.x); minY = px(minY, origin.y)
            maxX = px(maxX, origin.x); maxY = px(maxY, origin.y)
            return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        }
    }

    /// This canvas's device pixels: its scale and where it sits in its window.
    private var pixelGrid: (scale: CGFloat, origin: CGPoint) {
        let scale = view.window?.screen.scale ?? view.traitCollection.displayScale
        return (scale, view.window.map { view.convert(CGPoint.zero, to: $0) } ?? .zero)
    }

    private func layoutCanvas() {
        #if DEBUG || PERF_HARNESS
        PerfProbe.count("canvas layout")
        #endif
        lastSize = view.bounds.size
        guard let tree, lastSize.width > 0, lastSize.height > 0 else { return }
        let grid = pixelGrid
        let frames = Self.paneFrames(of: tree, in: lastSize, scale: grid.scale, origin: grid.origin)
        for (id, pane) in panes {
            guard let r = frames[id] else { continue }
            if pane.frame != r { pane.frame = r }
        }
        updateCornerPane(frames)
        guard interactive else { return }
        for d in LayoutTree.dividers(of: tree) {
            dividers[d.id]?.place(d, in: lastSize)
        }
    }

    /// The Mac: the window toolbar's trailing button (右侧栏) floats in the
    /// window's top right corner; the pane there moves its ⋯ clear of it.
    private func updateCornerPane(_ frames: [String: CGRect]) {
        var found: String?
        if Platform.barInWindowToolbar, let window = view.window {
            let corner = view.convert(CGPoint(x: view.bounds.maxX, y: view.bounds.minY), to: window)
            if corner.y < 8, window.bounds.maxX - corner.x < 2 {
                found = frames.first { $0.value.minY < 0.5 && $0.value.maxX > lastSize.width - 0.5 }?.key
            }
        }
        for (id, pane) in panes { pane.corner = id == found }
        guard found != cornerPane else { return }
        cornerPane = found
        onCornerPane(found)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        layoutCanvas()
    }

    // MARK: - the current pane

    private func touched(_ id: String) {
        onActivate(id)
        // The page learns it now, before the touch reaches the composer (a
        // press on another pane's field talks to that pane at once).
        if let host = hosts[id]?.view {
            host.setNeedsLayout()
            host.layoutIfNeeded()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        let next = UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [.command, .alternate], action: #selector(nextPane))
        let previous = UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [.command, .alternate], action: #selector(previousPane))
        next.wantsPriorityOverSystemBehavior = true
        previous.wantsPriorityOverSystemBehavior = true
        return [next, previous]
    }

    @objc private func nextPane() { onMoveFocus(false) }
    @objc private func previousPane() { onMoveFocus(true) }

    // MARK: - dragging a divider

    @objc private func dragDivider(_ pan: UIPanGestureRecognizer) {
        guard let d = pan.view as? DividerView else { return }
        let t = pan.translation(in: view)
        switch pan.state {
        case .began, .changed:
            moveDivider(d.id, by: d.vertical ? t.x : t.y)
        case .ended:
            endDivider(commit: true)
        default:
            endDivider(commit: false)
        }
    }

    /// The divider `id` is `travel` points from where it was: the handle
    /// and the cards of the new sizes follow; the panes stay, under them.
    private func moveDivider(_ id: String, by travel: CGFloat) {
        guard let tree else { return }
        if dividerBase == nil {
            dividerBase = tree
            applyAccent() // the layers' colors, for the appearance now
            beginPreview(divider: id)
        }
        guard let base = dividerBase, let d = LayoutTree.dividers(of: base).first(where: { $0.id == id }) else { return }
        let across = d.vertical ? lastSize.width : lastSize.height
        let next = LayoutTree.movingDivider(path: d.path, index: d.index, by: Double(travel / max(across, 1)), in: base)
        liveTree = next
        dividers[id]?.dragging = true
        placePreview(next)
    }

    private func endDivider(commit: Bool) {
        let final = liveTree
        let base = dividerBase
        dividerBase = nil
        liveTree = nil
        for d in dividers.values { d.dragging = false }
        if commit, let final {
            // Shown at once, under the preview: the panes take their new
            // sizes while the cards hide them; the page keeps it on the
            // computer.
            tree = final
            layoutCanvas()
            onLayoutChange(final)
            endPreview(at: final)
        } else {
            // Let go nowhere: the cards go back where they were.
            endPreview(at: base)
        }
    }

    // MARK: - the preview of a new layout

    /// A divider's drag begins (11-05, the owner: the panes' content all
    /// vanishing at once was abrupt): each pane pictured once, on a card
    /// where it is, the preview fading in over the panes. No SwiftUI work
    /// while it moves: the cards are plain views.
    /// Also while the canvas is resized (`resize`), with no divider.
    private func beginPreview(divider id: String?) {
        if id != nil { settleResize() }
        previewGeneration += 1
        previewDivider = id
        for card in previewCards.values { card.removeFromSuperview() }
        previewCards = [:]
        #if DEBUG
        let began = Date()
        #endif
        for (pid, pane) in panes {
            let card = PreviewCard(picture: Self.picture(of: pane.content), size: pane.bounds.size)
            UIView.performWithoutAnimation {
                card.frame = pane.frame
                card.layoutIfNeeded()
            }
            preview.addSubview(card)
            previewCards[pid] = card
        }
        #if DEBUG
        debugLog("[canvas] preview pictured \(panes.count) panes in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
        #endif
        UIView.performWithoutAnimation {
            preview.frame = view.bounds
            preview.isHidden = false
            if let id, let tree, let handle = handleRect(divider: id, in: tree) {
                grabLine.frame = handle
                if grabLine.isHidden { grabLine.alpha = 0 }
                grabLine.isHidden = false
            }
        }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.preview.alpha = 1
            self.grabLine.alpha = 1
        }
    }

    /// The handle of the divider `id` in `tree`, in the canvas.
    private func handleRect(divider id: String, in tree: LayoutTree.Node) -> CGRect? {
        guard let d = LayoutTree.dividers(of: tree).first(where: { $0.id == id }) else { return nil }
        return DividerView.handleRect(in: DividerView.lineRect(d, in: lastSize, thickness: 4), vertical: d.vertical)
    }

    /// The cards and the handle glide to where `tree` puts them (with
    /// Reduce Motion they are just there). Not gliding (a resize): they go
    /// there at once, or with the animation the canvas is resized in.
    private func placePreview(_ tree: LayoutTree.Node, glide: Bool = true, completion: ((Bool) -> Void)? = nil) {
        let grid = pixelGrid
        let frames = Self.paneFrames(of: tree, in: lastSize, scale: grid.scale, origin: grid.origin)
        let handle = previewDivider.flatMap { handleRect(divider: $0, in: tree) }
        let place = {
            for (id, card) in self.previewCards {
                guard let r = frames[id], card.frame != r else { continue }
                card.frame = r
                card.layoutIfNeeded()
            }
            if let handle { self.grabLine.frame = handle }
        }
        if !glide {
            place()
            completion?(true)
        } else if UIAccessibility.isReduceMotionEnabled {
            UIView.performWithoutAnimation(place)
            completion?(true)
        } else {
            UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                           animations: place, completion: completion)
        }
    }

    /// Let go: the cards settle where `tree` puts them, then the panes'
    /// own content fades back in (nil: it fades at once).
    private func endPreview(at tree: LayoutTree.Node?) {
        let generation = previewGeneration
        let fade = { [weak self] in
            guard let self, generation == self.previewGeneration else { return }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction], animations: {
                self.preview.alpha = 0
                self.grabLine.alpha = 0
            }, completion: { _ in
                guard generation == self.previewGeneration else { return }
                self.preview.isHidden = true
                self.grabLine.isHidden = true
                for card in self.previewCards.values { card.removeFromSuperview() }
                self.previewCards = [:]
                self.previewDivider = nil
            })
        }
        guard let tree else { fade(); return }
        placePreview(tree) { _ in fade() }
    }

    /// A picture of a pane's content as it is on screen now, once per drag
    /// (nil: none could be taken, and its card stays blank).
    private static func picture(of content: UIView) -> UIView? {
        guard content.window != nil, content.bounds.width > 0, content.bounds.height > 0 else { return nil }
        // A snapshot view (2 to 4 ms a pane on the Mac, against 8 to 28
        // for drawing it into an image), scaled as the card is.
        return content.snapshotView(afterScreenUpdates: false)
    }

    // MARK: - dragging a pane by its header

    @objc private func dragPane(_ pan: UIPanGestureRecognizer) {
        guard let pane = pan.view?.superview as? PaneContainerView, interactive else { return }
        let p = pan.location(in: view)
        switch pan.state {
        case .began:
            beginPaneDrag(pane, at: p)
        case .changed:
            movePaneDrag(to: p)
        case .ended:
            endPaneDrag(at: p, commit: true)
        default:
            endPaneDrag(at: p, commit: false)
        }
    }

    private func beginPaneDrag(_ pane: PaneContainerView, at p: CGPoint) {
        dragged = pane.id
        onActivate(pane.id)
        applyAccent()
        let c = makeCapsule(paneInfo(pane.id))
        view.addSubview(c)
        capsule = c
        capsuleOffset = CGPoint(x: -24, y: -c.bounds.height / 2)
        c.center = CGPoint(x: p.x + c.bounds.width / 2 + capsuleOffset.x, y: p.y)
        c.alpha = 0
        c.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.15) {
            c.alpha = 1
            c.transform = .identity
            pane.alpha = 0.45
        }
    }

    /// A small capsule under the pointer: the pane's status icon (a snapshot) and its name.
    private func makeCapsule(_ info: TileInfo) -> UIView {
        let c = UIView()
        c.isUserInteractionEnabled = false
        c.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 0.95) : UIColor(white: 1, alpha: 0.95) }
        c.layer.cornerRadius = 15
        c.layer.shadowColor = UIColor.black.cgColor
        c.layer.shadowOpacity = 0.25
        c.layer.shadowRadius = 8
        c.layer.shadowOffset = CGSize(width: 0, height: 6)
        let icon = UILabel(frame: CGRect(x: 5, y: 4, width: 22, height: 22))
        icon.backgroundColor = UIColor(StatusDot.color(info.dot))
        icon.layer.cornerRadius = 11
        icon.clipsToBounds = true
        icon.textAlignment = .center
        icon.textColor = .white
        icon.font = .systemFont(ofSize: 11, weight: .heavy)
        icon.text = switch info.dot {
        case .waiting: "?"
        case .working: info.running > 0 ? "\(min(info.running, 99))" : "▶"
        case .done: "✓"
        case .idle: "•"
        }
        let label = UILabel()
        label.text = info.name
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .label
        label.sizeToFit()
        let width = min(label.bounds.width, 220)
        label.frame = CGRect(x: 34, y: (30 - label.bounds.height) / 2, width: width, height: label.bounds.height)
        c.frame = CGRect(x: 0, y: 0, width: 34 + width + 12, height: 30)
        c.addSubview(icon)
        c.addSubview(label)
        if let symbol = info.symbol {
            // A document: its mark, grey, where a session's state is.
            icon.text = nil
            icon.backgroundColor = .clear
            let mark = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)))
            mark.tintColor = .secondaryLabel
            mark.contentMode = .center
            mark.frame = icon.frame
            c.addSubview(mark)
        }
        return c
    }

    private func movePaneDrag(to p: CGPoint) {
        guard let id = dragged, let tree, let c = capsule else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        c.center = CGPoint(x: p.x + c.bounds.width / 2 + capsuleOffset.x, y: p.y)
        CATransaction.commit()
        let frames = Self.paneFrames(of: tree, in: lastSize)
        let target = view.bounds.contains(p) ? TileDrop.target(at: p, dragging: id, frames: frames) : nil
        showDropTarget(target, frames: frames)
    }

    /// Where a drop would land, shown: the target lifted for a swap, the half
    /// it would take for a split.
    private func showDropTarget(_ target: (String, PaneDropZone)?, frames: [String: CGRect]) {
        guard target?.0 != dropTarget?.id || target?.1 != dropTarget?.zone else { return }
        let previous = dropTarget?.id
        dropTarget = target.map { (id: $0.0, zone: $0.1) }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            if let previous, previous != target?.0, let pane = self.panes[previous] { Self.unlift(pane) }
            guard let (tid, zone) = target, let frame = frames[tid], let pane = self.panes[tid] else {
                self.lift.isHidden = true
                self.edge.isHidden = true
                return
            }
            if zone == .center {
                // Swapping: the target lifts as a card with the accent edge.
                pane.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
                pane.layer.cornerRadius = Self.cardRadius
                pane.layer.cornerCurve = .continuous
                self.lift.frame = frame.insetBy(dx: frame.width * 0.015, dy: frame.height * 0.015)
                self.lift.isHidden = false
                self.edge.isHidden = true
            } else {
                // Splitting: the half it would take, in light accent.
                Self.unlift(pane)
                self.edge.frame = zone.highlightRect(in: frame).insetBy(dx: 6, dy: 6)
                self.edge.isHidden = false
                self.lift.isHidden = true
            }
        }
    }

    private static func unlift(_ pane: PaneContainerView) {
        pane.transform = .identity
        pane.layer.cornerRadius = Self.cardRadius
    }

    private func endPaneDrag(at p: CGPoint, commit: Bool) {
        defer {
            dragged = nil
            dropTarget = nil
        }
        let id = dragged
        let target = dropTarget
        clearDragPreview()
        // Dropped on the sidebar or outside: nothing happens.
        guard commit, let id, let target, let tree, view.bounds.contains(p),
              let dropped = TileDrop.apply(target.zone, moving: id, onto: target.id, in: tree) else { return }
        let new = LayoutTree.resized(dropped)
        self.tree = new
        // A new shape (a pane docked to another's edge) has new boundaries:
        // their dividers made now. Without it a 2x2 lost a line, and the
        // host's echo of the same tree never brought it back.
        syncPanes()
        UIView.animate(withDuration: 0.2) { self.layoutCanvas() }
        onLayoutChange(new)
    }

    /// The capsule goes and the panes are as they were.
    private func clearDragPreview() {
        let c = capsule
        capsule = nil
        UIView.animate(withDuration: 0.15, animations: {
            c?.alpha = 0
            for pane in self.panes.values {
                pane.alpha = 1
                Self.unlift(pane)
            }
            self.lift.isHidden = true
            self.edge.isHidden = true
        }, completion: { _ in c?.removeFromSuperview() })
    }

    // MARK: - a document's tab dragged in from the right pane

    /// A document's tab is dragged out of the right pane (`point` in the
    /// window): its capsule follows the pointer over the whole window.
    func beginDocumentDrag(_ id: String, info: TileInfo, at point: CGPoint) {
        guard interactive, tree != nil, let window = view.window, documentDragged == nil, dragged == nil else { return }
        documentDragged = id
        applyAccent()
        let c = makeCapsule(info)
        window.addSubview(c)
        capsule = c
        capsuleOffset = CGPoint(x: -24, y: -c.bounds.height / 2)
        c.center = CGPoint(x: point.x + c.bounds.width / 2 + capsuleOffset.x, y: point.y)
        c.alpha = 0
        c.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.15) {
            c.alpha = 1
            c.transform = .identity
        }
    }

    /// Over a card, the edge nearest the pointer shows the half the document
    /// would take (no swap: it has no place of its own yet); a document
    /// already a card lifts that card.
    func moveDocumentDrag(to point: CGPoint) {
        guard let id = documentDragged, let tree, let c = capsule else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        c.center = CGPoint(x: point.x + c.bounds.width / 2 + capsuleOffset.x, y: point.y)
        CATransaction.commit()
        let p = view.convert(point, from: nil)
        let frames = Self.paneFrames(of: tree, in: lastSize)
        var target: (String, PaneDropZone)?
        if view.bounds.contains(p) {
            if frames[id] != nil {
                target = (id, .center)
            } else if let (tid, frame) = frames.first(where: { $0.value.contains(p) }) {
                target = (tid, TileDrop.edgeZone(at: p, in: frame))
            }
        }
        showDropTarget(target, frames: frames)
    }

    /// Let go: over a card, the document docks at its edge as a card of its
    /// own (the page keeps the layout); true when it is a card now.
    func endDocumentDrag(at point: CGPoint, commit: Bool) -> Bool {
        defer {
            documentDragged = nil
            dropTarget = nil
        }
        let id = documentDragged
        let target = dropTarget
        clearDragPreview()
        guard commit, let id, let target, let tree, view.bounds.contains(view.convert(point, from: nil)) else { return false }
        if LayoutTree.leafOrder(of: tree).contains(id) {
            flash(id)
            return true
        }
        guard let dock = target.zone.dock,
              let placed = LayoutTree.splitting(pane: target.id, adding: id, horizontal: dock.horizontal,
                                                newFirst: dock.before, in: tree) else { return false }
        let new = LayoutTree.resized(placed)
        self.tree = new
        syncPanes()
        // The new card starts where it goes; the others make room.
        if let r = Self.paneFrames(of: new, in: lastSize)[id] {
            UIView.performWithoutAnimation { panes[id]?.frame = r; panes[id]?.layoutIfNeeded() }
        }
        UIView.animate(withDuration: 0.2) { self.layoutCanvas() }
        onLayoutChange(new)
        return true
    }

    /// A card pointed out (a document asked for again while it is one): it
    /// lifts with the accent edge for a moment.
    func flash(_ id: String) {
        guard let pane = panes[id] else { return }
        applyAccent()
        lift.frame = pane.frame
        lift.alpha = 0
        lift.isHidden = false
        UIView.animate(withDuration: 0.18, animations: {
            self.lift.alpha = 1
            pane.transform = CGAffineTransform(scaleX: 0.985, y: 0.985)
        }, completion: { _ in
            UIView.animate(withDuration: 0.45, delay: 0.35, options: [.allowUserInteraction], animations: {
                self.lift.alpha = 0
                pane.transform = .identity
            }, completion: { _ in
                self.lift.isHidden = true
                self.lift.alpha = 1
            })
        })
    }

    #if DEBUG || PERF_HARNESS
    /// `-demoWiggle YES`: the first divider dragged back and forth through the
    /// same calls as the pointer's (120 moves a second), let go, over and
    /// over (perf measuring). With `-perfAlternate YES` it moves through each
    /// busy window and is let go as a quiet one starts.
    private func startWiggle() {
        guard UserDefaults.standard.bool(forKey: "demoWiggle") else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            let alternate = UserDefaults.standard.bool(forKey: "perfAlternate")
            while let self, !Task.isCancelled {
                if !PerfSwitch.driving { try? await Task.sleep(for: .milliseconds(20)); continue }
                guard let tree = self.tree, let d = LayoutTree.dividers(of: tree).first else { return }
                let start = Date()
                let width = self.lastSize.width
                while alternate ? PerfSwitch.driving : Date().timeIntervalSince(start) < 3 {
                    let t = Date().timeIntervalSince(start)
                    self.moveDivider(d.id, by: sin(t * 2 * .pi / 1.5) * 0.15 * width)
                    try? await Task.sleep(for: .milliseconds(8))
                }
                self.endDivider(commit: true)
                if !alternate { try? await Task.sleep(for: .seconds(2)) }
            }
        }
    }
    #endif
}

#if DEBUG
extension PaneCanvasController {
    /// The canvases on screen (for `-demoActions` `canvas:` steps).
    static let all = NSHashTable<PaneCanvasController>.weakObjects()

    /// A `-demoActions` step on this canvas, through the same calls the
    /// pointer's gestures make (no real events: the Mac's UI automation needs
    /// the owner's permission):
    /// `click:<id>` a click in a pane; `next` ⌘⌥→; `hover` the first divider lit;
    /// `divider:<dx>` the first divider dragged that far and held, `divider-end`
    /// let go, `divider-cancel` the drag cancelled;
    /// `drag:<id>:<target>:<center|left|right|top|bottom>` a pane dragged by
    /// its header and held over the target, `drag-end` dropped.
    func demo(_ step: String) {
        let parts = step.split(separator: ":").map(String.init)
        guard let tree else { return }
        let frames = Self.paneFrames(of: tree, in: lastSize)
        switch parts.first {
        case "click":
            if parts.count > 1 { panes[parts[1]].map { _ = $0.hitTest(CGPoint(x: 100, y: 100), with: DemoTouchEvent()) } }
        case "where":
            for (id, pane) in panes {
                let r = pane.convert(pane.bounds, to: nil)
                debugLog("[canvas] where \(id) \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))")
            }
        case "next":
            onMoveFocus(false)
        case "details":
            if parts.count > 1, let host = hosts[parts[1]] as? PaneHostingController { host.rootView.details.tile = parts[1] }
        case "presented":
            for (id, host) in hosts { debugLog("[canvas] \(id) presents \(host.presentedViewController.map { String(describing: type(of: $0)) } ?? "-")") }
        case "details-close":
            (hosts.values.first as? PaneHostingController)?.rootView.details.tile = nil
        case "hover":
            dividers.values.first?.demoHover(true)
        case "divider":
            if let d = LayoutTree.dividers(of: tree).first { moveDivider(d.id, by: CGFloat(Double(parts.last ?? "0") ?? 0)) }
        case "divider-end":
            dividers.values.forEach { $0.demoHover(false) }
            endDivider(commit: true)
        case "divider-cancel":
            dividers.values.forEach { $0.demoHover(false) }
            endDivider(commit: false)
        case "drag":
            guard parts.count > 3, let pane = panes[parts[1]], let target = frames[parts[2]],
                  let source = frames[parts[1]] else { return }
            let p: CGPoint = switch parts[3] {
            case "left": CGPoint(x: target.minX + target.width * 0.1, y: target.midY)
            case "right": CGPoint(x: target.maxX - target.width * 0.1, y: target.midY)
            case "top": CGPoint(x: target.midX, y: target.minY + target.height * 0.1)
            case "bottom": CGPoint(x: target.midX, y: target.maxY - target.height * 0.1)
            default: CGPoint(x: target.midX, y: target.midY)
            }
            beginPaneDrag(pane, at: CGPoint(x: source.minX + 80, y: source.minY + 12))
            movePaneDrag(to: p)
            demoDrop = p
        case "drag-end":
            endPaneDrag(at: demoDrop ?? .zero, commit: true)
        default:
            break
        }
        let order = LayoutTree.leafOrder(of: self.tree ?? tree)
        let placed = order.map { id in "\(id) \(Self.paneFrames(of: self.tree ?? tree, in: lastSize)[id].map { NSCoder.string(for: $0) } ?? "-")" }
        let focused = panes.first { $0.value.firstResponderInside }?.key ?? "-"
        debugLog("[canvas] \(step): \(placed.joined(separator: ", ")) caret \(focused)")
    }
}

/// A click, as far as `PaneContainerView.hitTest` can tell.
private final class DemoTouchEvent: UIEvent {
    override var type: UIEvent.EventType { .touches }
}

private extension UIView {
    var firstResponderInside: Bool {
        if isFirstResponder { return true }
        return subviews.contains { $0.firstResponderInside }
    }
}

private nonisolated(unsafe) var demoDropPoints: [ObjectIdentifier: CGPoint] = [:]

private extension PaneCanvasController {
    var demoDrop: CGPoint? {
        get { demoDropPoints[ObjectIdentifier(self)] }
        set { demoDropPoints[ObjectIdentifier(self)] = newValue }
    }
}
#endif

/// Where a dragged pane would land, and what dropping it there makes.
enum TileDrop {
    /// The pane under the point, and where on it the drop would land.
    static func target(at p: CGPoint, dragging id: String, frames: [String: CGRect]) -> (String, PaneDropZone)? {
        guard let (target, frame) = frames.first(where: { $0.key != id && $0.value.contains(p) }) else { return nil }
        return (target, PaneDropZone.zone(at: p, in: frame))
    }

    /// A document coming in has no place to swap with: the nearest edge.
    static func edgeZone(at p: CGPoint, in frame: CGRect) -> PaneDropZone {
        guard frame.width > 0, frame.height > 0 else { return .right }
        let u = (p.x - frame.minX) / frame.width
        let v = (p.y - frame.minY) / frame.height
        let edges: [(CGFloat, PaneDropZone)] = [(u, .left), (1 - u, .right), (v, .top), (1 - v, .bottom)]
        return edges.min { $0.0 < $1.0 }!.1
    }

    static func apply(_ zone: PaneDropZone, moving id: String, onto target: String, in tree: LayoutTree.Node) -> LayoutTree.Node? {
        guard id != target else { return nil }
        guard let dock = zone.dock else { return LayoutTree.swapping(id, target, in: tree) }
        return LayoutTree.docking(pane: id, at: target, horizontal: dock.horizontal, before: dock.before, in: tree)
    }
}

/// The canvas's view (named for the view debugger).
private final class CanvasView: UIView {}

/// A pane in the preview of a new layout: a card of the panes' shape and
/// edge showing the picture of the pane taken as the drag began, filling it
/// from its top leading corner (the name stays in view), a little washed
/// out: a preview, not the pane. Without a picture, a blank card.
private final class PreviewCard: UIView {
    private let clip = UIView()
    private let picture: UIView?
    /// The pane's size when it was pictured.
    private let natural: CGSize
    private let wash = UIView()

    init(picture: UIView?, size: CGSize) {
        self.picture = picture
        natural = size
        super.init(frame: CGRect(origin: .zero, size: size))
        isUserInteractionEnabled = false
        let r = PaneCanvasController.cardRadius
        backgroundColor = .systemBackground
        layer.cornerRadius = r
        layer.cornerCurve = .continuous
        layer.shadowOffset = CGSize(width: 0, height: 1)
        clip.layer.cornerRadius = r
        clip.layer.cornerCurve = .continuous
        clip.clipsToBounds = true
        addSubview(clip)
        if let picture { clip.addSubview(picture) }
        wash.backgroundColor = PaneCanvasController.backdrop.withAlphaComponent(0.35)
        clip.addSubview(wash)
        styleCard()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        clip.frame = bounds
        wash.frame = bounds
        guard let picture, natural.width > 0, natural.height > 0 else { return }
        // Filling the card (aspect fill), pinned to its top leading corner;
        // never larger than life: a widened card shows its picture as it was
        // and the card's own colour beyond it (enlarged text looked wrong).
        let s = min(1, max(bounds.width / natural.width, bounds.height / natural.height))
        picture.bounds = CGRect(origin: .zero, size: natural)
        picture.transform = CGAffineTransform(scaleX: s, y: s)
        picture.center = CGPoint(x: natural.width * s / 2, y: natural.height * s / 2)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        styleCard()
    }

    /// As `PaneContainerView` draws its card.
    private func styleCard() {
        let dark = traitCollection.userInterfaceStyle == .dark
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = dark ? 0 : 0.10
        layer.shadowRadius = dark ? 0 : 4
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        layer.borderColor = (dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.07)).cgColor
    }
}

/// One pane: its hosting view, and over its header the band it is dragged by.
final class PaneContainerView: UIView {
    let id: String
    let content: UIView
    /// Between the status icon and ⋯, over the name and status line.
    let grip = UIView()
    var onTouch: ((String) -> Void)?
    /// Its ⋯ is moved in, clear of the Mac window toolbar's button.
    var corner = false { didSet { if corner != oldValue { setNeedsLayout() } } }
    var dragEnabled = true {
        didSet { grip.gestureRecognizers?.forEach { $0.isEnabled = dragEnabled } }
    }

    init(id: String, content: UIView) {
        self.id = id
        self.content = content
        super.init(frame: .zero)
        // A card on the desk (PaneCanvasController.gap): the content rounded
        // and clipped, the card itself casting a soft shadow (light) or
        // edged with a faint line (dark, where a shadow doesn't show).
        let r = PaneCanvasController.cardRadius
        layer.cornerRadius = r
        layer.cornerCurve = .continuous
        layer.shadowOffset = CGSize(width: 0, height: 1)
        content.layer.cornerRadius = r
        content.layer.cornerCurve = .continuous
        content.clipsToBounds = true
        styleCard()
        accessibilityIdentifier = "tile-\(id)"
        content.frame = bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(content)
        grip.backgroundColor = .clear
        addSubview(grip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        #if DEBUG || PERF_HARNESS
        PerfProbe.count("pane layout")
        #endif
        grip.frame = PaneMetrics.grip(in: bounds, corner: corner)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: PaneCanvasController.cardRadius).cgPath
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        styleCard()
    }

    private func styleCard() {
        let dark = traitCollection.userInterfaceStyle == .dark
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = dark ? 0 : 0.10
        layer.shadowRadius = dark ? 0 : 4
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        layer.borderColor = (dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.07)).cgColor
    }

    /// None from the window: the Mac's titlebar inset made the top panes'
    /// conversations start below it, with a hard edge line there. The pane
    /// places its own header.
    override var safeAreaInsets: UIEdgeInsets { .zero }

    /// A click or touch anywhere in the pane makes it the current one, before
    /// anything in it handles the touch (hovers and scrolls don't).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil, event?.type == .touches { onTouch?(id) }
        return hit
    }
}

/// The handle of a gutter between panes: nothing drawn (the gutter shows).
/// Hovered a short grey rounded handle in its middle (and the Mac shows a
/// resize cursor); dragged, the canvas draws the handle in the accent and the
/// new sizes as soft cards.
final class DividerView: UIView {
    let id: String
    private(set) var vertical = true
    private let line = UIView()
    let pan = UIPanGestureRecognizer()
    private var hovered = false
    var dragging = false { didSet { restyle() } }
    var accent: UIColor = .systemBlue { didSet { restyle() } }
    static let hot: CGFloat = 9


    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        backgroundColor = .clear
        line.isUserInteractionEnabled = false
        addSubview(line)
        addGestureRecognizer(pan)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        isAccessibilityElement = false
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The line of a divider, `thickness` across, in the canvas.
    static func lineRect(_ d: LayoutTree.Divider, in size: CGSize, thickness: CGFloat) -> CGRect {
        let along: CGFloat = d.vertical ? size.height : size.width
        let across: CGFloat = d.vertical ? size.width : size.height
        let at = (CGFloat(d.position) * across).rounded()
        let from = (CGFloat(d.span.lowerBound) * along).rounded()
        let length = (CGFloat(d.span.upperBound) * along).rounded() - from
        return d.vertical
            ? CGRect(x: at - thickness / 2, y: from, width: thickness, height: length)
            : CGRect(x: from, y: at - thickness / 2, width: length, height: thickness)
    }

    func place(_ d: LayoutTree.Divider, in size: CGSize) {
        vertical = d.vertical
        frame = Self.lineRect(d, in: size, thickness: Self.hot)
        restyle()
    }

    /// A short rounded handle in the middle of the gutter `line` runs along.
    static func handleRect(in line: CGRect, vertical: Bool) -> CGRect {
        let t: CGFloat = 4, length = min(44, vertical ? line.height : line.width)
        return vertical
            ? CGRect(x: line.midX - t / 2, y: line.midY - length / 2, width: t, height: length)
            : CGRect(x: line.midX - length / 2, y: line.midY - t / 2, width: length, height: t)
    }

    private func restyle() {
        // Hovered: a grey handle in the gutter; dragged (the canvas draws
        // its own then): none here.
        line.layer.cornerRadius = 2
        line.frame = Self.handleRect(in: bounds, vertical: vertical)
        line.backgroundColor = hovered && !dragging ? UIColor.secondaryLabel.withAlphaComponent(0.45) : .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        restyle()
    }

    #if DEBUG
    func demoHover(_ on: Bool) { hovered = on; restyle() }
    #endif

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            if !hovered { hovered = true; restyle() }
            ResizeCursor.show(vertical: vertical)
        default:
            if hovered { hovered = false; restyle() }
            ResizeCursor.reset()
        }
    }
}

/// The Mac's resize cursor over a divider (UIKit has none on Catalyst: it
/// comes from the AppKit bundle). Nothing elsewhere.
@MainActor
enum ResizeCursor {
    static func show(vertical: Bool) {
        #if targetEnvironment(macCatalyst)
        AppKitBundle.setResizeCursor(vertical: vertical)
        #endif
    }

    static func reset() {
        #if targetEnvironment(macCatalyst)
        AppKitBundle.setResizeCursor(vertical: nil)
        #endif
    }
}

#if targetEnvironment(macCatalyst)
extension AppKitBundle {
    /// The resize cursor across a vertical divider (left-right) or a
    /// horizontal one (up-down); nil: the arrow.
    static func setResizeCursor(vertical: Bool?) {
        let kind = vertical.map { $0 ? "h" : "v" } ?? ""
        _ = object?.perform(NSSelectorFromString("setResizeCursor:"), with: kind)
    }
}
#endif

/// The canvas in SwiftUI: the tree and whether it can be rearranged (not on
/// narrow widths) go in; the panes come from `makePane`.
struct PaneCanvas: UIViewControllerRepresentable {
    let tree: LayoutTree.Node
    let interactive: Bool
    let accent: UIColor
    let handle: PaneCanvasHandle
    let makePane: (String) -> UIViewController
    let onLayoutChange: (LayoutTree.Node) -> Void
    let onActivate: (String) -> Void
    let onMoveFocus: (Bool) -> Void
    let paneInfo: (String) -> TileInfo
    let onCornerPane: (String?) -> Void

    func makeUIViewController(context: Context) -> PaneCanvasController {
        let c = PaneCanvasController()
        handle.controller = c
        update(c)
        return c
    }

    func updateUIViewController(_ c: PaneCanvasController, context: Context) {
        #if DEBUG || PERF_HARNESS
        PerfProbe.count("upd PaneCanvas")
        #endif
        update(c)
    }

    /// Any size it's offered: the panes fit themselves into it. Asked for
    /// its own size instead, the canvas answered with what its panes'
    /// hosting views wanted side by side, and the split view squeezed the
    /// right pane to make room for that.
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: PaneCanvasController, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 320))
    }

    private func update(_ c: PaneCanvasController) {
        c.makePane = makePane
        c.onLayoutChange = onLayoutChange
        c.onActivate = onActivate
        c.onMoveFocus = onMoveFocus
        c.paneInfo = paneInfo
        c.onCornerPane = onCornerPane
        c.apply(tree: tree, interactive: interactive, accent: accent)
    }
}

/// The workspace page's way to the canvas (to put the caret in a pane).
@MainActor
final class PaneCanvasHandle {
    weak var controller: PaneCanvasController?
}
