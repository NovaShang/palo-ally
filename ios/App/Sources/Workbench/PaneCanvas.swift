import PaloAllyKit
import SwiftUI
import UIKit

/// A split workspace's panes, laid out by UIKit (docs/workbench-design/split-final.html).
///
/// Each pane is a `UIHostingController` of its own (`PaneRoot`), so a frame
/// of one pane (its drop working, a keystroke, a reply streaming) updates
/// that pane's graph only, never the window's or the other panes'. This
/// controller places them from the `LayoutTree`, draws the 1pt hairlines
/// between them, and does all the pointer work (a divider hovered or
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
    private let ghosts = CAShapeLayer()
    // While a pane is dragged by its header.
    private var dragged: String?
    private var capsule: UIView?
    private var capsuleOffset: CGPoint = .zero
    private var dropTarget: (id: String, zone: PaneDropZone)?
    private let lift = UIView()
    private let edge = UIView()

    override func loadView() {
        let v = CanvasView()
        v.backgroundColor = .systemBackground
        v.clipsToBounds = true
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        grabLine.isHidden = true
        grabLine.isUserInteractionEnabled = false
        ghosts.lineWidth = 1.5
        ghosts.isHidden = true
        lift.isHidden = true
        lift.isUserInteractionEnabled = false
        lift.layer.cornerRadius = 12
        lift.layer.cornerCurve = .continuous
        lift.layer.borderWidth = 2
        lift.layer.shadowColor = UIColor.black.cgColor
        lift.layer.shadowOpacity = 0.22
        lift.layer.shadowRadius = 15
        lift.layer.shadowOffset = CGSize(width: 0, height: 14)
        edge.isHidden = true
        edge.isUserInteractionEnabled = false
        edge.layer.cornerRadius = 10
        edge.layer.cornerCurve = .continuous
        edge.layer.borderWidth = 2
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
        // Don't relayout under a drag: it lands with the release.
        tree = new
        self.interactive = interactive
        syncPanes()
        layoutCanvas()
    }

    /// The pane's composer gets the caret (⌘⌥→, ⌘⌥←: there is no other
    /// mark of the current pane).
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
        view.addSubview(grabLine)
        view.layer.addSublayer(ghosts)
        view.addSubview(lift)
        view.addSubview(edge)
        for (_, p) in panes { p.grip.isUserInteractionEnabled = true; p.dragEnabled = interactive }
    }

    private func applyAccent() {
        grabLine.backgroundColor = accent
        ghosts.strokeColor = accent.cgColor
        ghosts.fillColor = accent.withAlphaComponent(0.04).cgColor
        lift.layer.borderColor = accent.cgColor
        edge.layer.borderColor = accent.cgColor
        edge.backgroundColor = accent.withAlphaComponent(0.18)
        for d in dividers.values { d.accent = accent }
    }

    // MARK: - layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.bounds.size != lastSize { layoutCanvas() }
    }

    /// The panes' frames: the tree's rects, 1pt hairlines between them (none at the canvas's edges).
    static func paneFrames(of tree: LayoutTree.Node, in size: CGSize) -> [String: CGRect] {
        let line: CGFloat = 1
        return LayoutTree.fractions(of: tree).mapValues { f in
            var minX = (f.x * size.width).rounded(), minY = (f.y * size.height).rounded()
            var maxX = ((f.x + f.w) * size.width).rounded(), maxY = ((f.y + f.h) * size.height).rounded()
            if minX > 0.5 { minX += line / 2 }
            if minY > 0.5 { minY += line / 2 }
            if maxX < size.width - 0.5 { maxX -= line / 2 }
            if maxY < size.height - 0.5 { maxY -= line / 2 }
            return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        }
    }

    private func layoutCanvas() {
        lastSize = view.bounds.size
        guard let tree, lastSize.width > 0, lastSize.height > 0 else { return }
        let frames = Self.paneFrames(of: tree, in: lastSize)
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

    /// The divider `id` is `travel` points from where it was: a line and
    /// outlines of the new sizes follow; the panes stay.
    private func moveDivider(_ id: String, by travel: CGFloat) {
        guard let tree else { return }
        if dividerBase == nil {
            dividerBase = tree
            applyAccent() // the layers' colors, for the appearance now
        }
        guard let base = dividerBase, let d = LayoutTree.dividers(of: base).first(where: { $0.id == id }) else { return }
        let across = d.vertical ? lastSize.width : lastSize.height
        let next = LayoutTree.movingDivider(path: d.path, index: d.index, by: Double(travel / max(across, 1)), in: base)
        liveTree = next
        dividers[id]?.dragging = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let moved = LayoutTree.dividers(of: next).first(where: { $0.id == id }) {
            grabLine.frame = DividerView.lineRect(moved, in: lastSize, thickness: 3)
            grabLine.isHidden = false
        }
        let path = UIBezierPath()
        for r in Self.paneFrames(of: next, in: lastSize).values {
            path.append(UIBezierPath(rect: r.insetBy(dx: 0.75, dy: 0.75)))
        }
        ghosts.frame = view.bounds
        ghosts.path = path.cgPath
        ghosts.isHidden = false
        CATransaction.commit()
    }

    private func endDivider(commit: Bool) {
        let final = liveTree
        dividerBase = nil
        liveTree = nil
        grabLine.isHidden = true
        ghosts.isHidden = true
        for d in dividers.values { d.dragging = false }
        guard commit, let final else { return }
        // Shown at once; the page keeps it on the computer.
        tree = final
        layoutCanvas()
        onLayoutChange(final)
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
        let c = makeCapsule(for: pane)
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
    private func makeCapsule(for pane: PaneContainerView) -> UIView {
        let c = UIView()
        c.isUserInteractionEnabled = false
        c.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 0.95) : UIColor(white: 1, alpha: 0.95) }
        c.layer.cornerRadius = 15
        c.layer.shadowColor = UIColor.black.cgColor
        c.layer.shadowOpacity = 0.25
        c.layer.shadowRadius = 8
        c.layer.shadowOffset = CGSize(width: 0, height: 6)
        let info = paneInfo(pane.id)
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
                pane.layer.cornerRadius = 12
                pane.layer.cornerCurve = .continuous
                self.lift.frame = frame.insetBy(dx: frame.width * 0.015, dy: frame.height * 0.015)
                self.lift.isHidden = false
                self.edge.isHidden = true
            } else {
                // Splitting: the half it would take, in light accent.
                Self.unlift(pane)
                self.edge.frame = zone.highlightRect(in: frame).insetBy(dx: 4, dy: 4)
                self.edge.isHidden = false
                self.lift.isHidden = true
            }
        }
    }

    private static func unlift(_ pane: PaneContainerView) {
        pane.transform = .identity
        pane.layer.cornerRadius = 0
    }

    private func endPaneDrag(at p: CGPoint, commit: Bool) {
        defer {
            dragged = nil
            dropTarget = nil
        }
        let id = dragged
        let target = dropTarget
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
        // Dropped on the sidebar or outside: nothing happens.
        guard commit, let id, let target, let tree, view.bounds.contains(p),
              let new = TileDrop.apply(target.zone, moving: id, onto: target.id, in: tree) else { return }
        self.tree = new
        UIView.animate(withDuration: 0.2) { self.layoutCanvas() }
        onLayoutChange(new)
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
    /// let go; `drag:<id>:<target>:<center|left|right|top|bottom>` a pane
    /// dragged by its header and held over the target, `drag-end` dropped.
    func demo(_ step: String) {
        let parts = step.split(separator: ":").map(String.init)
        guard let tree else { return }
        let frames = Self.paneFrames(of: tree, in: lastSize)
        switch parts.first {
        case "click":
            if parts.count > 1 { panes[parts[1]].map { _ = $0.hitTest(CGPoint(x: 100, y: 100), with: DemoTouchEvent()) } }
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

    static func apply(_ zone: PaneDropZone, moving id: String, onto target: String, in tree: LayoutTree.Node) -> LayoutTree.Node? {
        guard id != target else { return nil }
        guard let dock = zone.dock else { return LayoutTree.swapping(id, target, in: tree) }
        return LayoutTree.docking(pane: id, at: target, horizontal: dock.horizontal, before: dock.before, in: tree)
    }
}

/// The canvas's view (named for the view debugger).
private final class CanvasView: UIView {}

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
        clipsToBounds = true
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
        grip.frame = PaneMetrics.grip(in: bounds, corner: corner)
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

/// A hairline between panes: 1pt, light gray (white 10% in dark mode).
/// Hovered it thickens to 3pt light accent (and the Mac shows a resize
/// cursor); dragged, it moves the line and outlines only.
final class DividerView: UIView {
    let id: String
    private(set) var vertical = true
    private let line = UIView()
    let pan = UIPanGestureRecognizer()
    private var hovered = false
    var dragging = false { didSet { restyle() } }
    var accent: UIColor = .systemBlue { didSet { restyle() } }
    static let hot: CGFloat = 9

    static let hairline = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.10) }

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

    private func restyle() {
        let lit = hovered || dragging
        let t: CGFloat = lit ? 3 : 1
        line.frame = vertical
            ? CGRect(x: (bounds.width - t) / 2, y: 0, width: t, height: bounds.height)
            : CGRect(x: 0, y: (bounds.height - t) / 2, width: bounds.width, height: t)
        line.backgroundColor = lit ? accent.withAlphaComponent(0.5) : Self.hairline
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
        update(c)
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
