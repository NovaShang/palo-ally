import PaloAllyKit
import SwiftUI
import UIKit

/// A hold to talk made with the pointer rather than on the composer: the
/// Mac's right mouse button held anywhere in a window (MacRightHold). Told
/// to the composer it names, which runs it as its own press
/// (`ComposerView.pointerHold`).
struct PointerVoice {
    enum Phase: String { case began, moved, ended, cancelled }

    static let note = Notification.Name("PaloAlly.pointerVoice")

    /// The window's model (`ObjectIdentifier(model)`).
    let window: ObjectIdentifier
    /// The composer's tile (`voice.owner`); nil: the page's own composer.
    let owner: String?
    let phase: Phase
    /// In the window's coordinates (SwiftUI's `.global`).
    let point: CGPoint

    static func from(_ note: Notification) -> PointerVoice? { note.userInfo?["event"] as? PointerVoice }
}

#if targetEnvironment(macCatalyst)
/// The Mac: holding the right mouse button anywhere in a window talks
/// (the AppKit bundle's RightHold, Bento Term's right-hold). It talks to
/// the conversation under the pointer: in a split workspace the pane there
/// (it becomes the current one), else the window's conversation (a
/// workspace's current pane); in Palo's popover, to Palo.
@MainActor
enum MacRightHold {
    private static var observer: NSObjectProtocol?
    /// The hold under way: its window and composer.
    private static var current: (window: ObjectIdentifier, owner: String?)?

    static func install() {
        guard observer == nil else { return }
        _ = AppKitBundle.object?.perform(NSSelectorFromString("installRightHold"))
        observer = NotificationCenter.default.addObserver(forName: Notification.Name("PaloAllyRightHold"), object: nil, queue: .main) { note in
            nonisolated(unsafe) let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { handle(info) }
        }
    }

    private static func handle(_ info: [AnyHashable: Any]) {
        let phase = info["phase"] as? String ?? ""
        if phase == "log" {
            debugLog("[rhold] \(info["text"] as? String ?? "")")
            return
        }
        let point = CGPoint(x: info["x"] as? Double ?? 0, y: info["y"] as? Double ?? 0)
        switch phase {
        case "begin":
            let toolbar = info["toolbar"] as? String ?? ""
            guard let (model, owner) = route(toolbar: toolbar, at: point) else {
                debugLog("[rhold] held in a \(info["window"] as? String ?? "?") with no conversation: nothing")
                current = nil
                return
            }
            current = (ObjectIdentifier(model), owner)
            debugLog("[rhold] held at \(Int(point.x)),\(Int(point.y)) in \(model.traceName): talks to \(owner.map { "pane \($0.prefix(12))" } ?? "the page")")
            send(.began, point)
        case "move": send(.moved, point)
        case "end":
            send(.ended, point)
            current = nil
        default:
            send(.cancelled, point)
            current = nil
        }
    }

    private static func send(_ phase: PointerVoice.Phase, _ point: CGPoint) {
        guard let current else { return }
        let event = PointerVoice(window: current.window, owner: current.owner, phase: phase, point: point)
        NotificationCenter.default.post(name: PointerVoice.note, object: nil, userInfo: ["event": event])
    }

    /// The window and the composer a hold at `point` talks to.
    private static func route(toolbar: String, at point: CGPoint) -> (WindowModel, String?)? {
        guard let model = MacToolbar.model(toolbar: toolbar) else { return nil }
        guard case .workspace(let ws) = model.selection else { return (model, nil) }
        if let pane = pane(at: point, in: model) {
            model.activate(tile: pane, in: ws)
            return (model, pane)
        }
        return (model, model.activeTile(in: ws))
    }

    /// The split workspace's pane under `point`, if any.
    private static func pane(at point: CGPoint, in model: WindowModel) -> String? {
        for window in model.scene?.windows ?? [] {
            var v = window.hitTest(point, with: nil)
            while let view = v {
                if let pane = view as? PaneContainerView { return pane.id }
                v = view.superview
            }
        }
        return nil
    }
}
#endif
