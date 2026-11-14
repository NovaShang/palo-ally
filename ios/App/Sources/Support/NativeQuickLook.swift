import PaloAllyKit
import QuickLook
import SwiftUI
import UIKit

extension EnvironmentValues {
    /// The column this is in is held at its size while things move
    /// (`FreezesWhileResized`): what AppKit draws over the window
    /// (`NativeQuickLookView`) is put away until it is laid out again.
    @Entry var layoutHeld = false
}

#if targetEnvironment(macCatalyst)
/// An Office or iWork document on the Mac drawn by AppKit's own previewer
/// (the AppKit bundle's NativePreviews) over the place this view keeps:
/// crisp, scrolling, its text selectable. QuickLook embedded by UIKit drew
/// it as one still picture at 1x (11-14).
///
/// The previewer is in the window above the app's views, so it can't be
/// clipped or covered by them: it is put away while this place moves (a
/// divider dragged, the sidebar or the window resized: shown again 0.15 s
/// after it last moved, where it ended), while its column is held
/// (`layoutHeld`, the columns' own animations), and whenever this place
/// isn't on screen (another tab, the pane closed); it is gone with it.
struct NativeQuickLookView: UIViewRepresentable {
    let url: URL
    let revision: Int64
    @Environment(\.layoutHeld) private var held
    @Environment(WindowModel.self) private var model: WindowModel?

    /// The AppKit bundle is there and has the previewer.
    static var available: Bool {
        #if DEBUG
        // `-nativePreviewOff YES`: the fallback (the button and Quick Look's window).
        if UserDefaults.standard.bool(forKey: "nativePreviewOff") { return false }
        #endif
        return AppKitBundle.object?.responds(to: NSSelectorFromString("nativePreviewUpdate:")) == true
    }

    func makeUIView(context: Context) -> Host { Host() }

    func updateUIView(_ host: Host, context: Context) {
        host.configure(url: url, revision: revision, held: held || model?.columnsMoving == true)
    }

    static func dismantleUIView(_ host: Host, coordinator: ()) {
        host.tearDown()
    }

    /// The place kept: transparent, saying where it is to the bundle.
    final class Host: UIView {
        private let id = UUID().uuidString
        private var url: URL?
        private var revision: Int64 = 0
        private var held = false
        private var gone = false
        /// Where it was last seen (in its window), and since when it hasn't moved.
        private var lastRect: CGRect?
        private var settled = false
        private var settleRun = 0
        /// What the bundle was told last.
        private var pushed: NSDictionary?
        /// A look now and then while shown: a move UIKit doesn't lay this out for.
        private var watch: Timer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            accessibilityIdentifier = "office-native-preview"
        }

        required init?(coder: NSCoder) { fatalError() }

        isolated deinit {
            watch?.invalidate()
            _ = AppKitBundle.object?.perform(NSSelectorFromString("nativePreviewRemove:"), with: id)
        }

        func configure(url: URL, revision: Int64, held: Bool) {
            self.url = url
            self.revision = revision
            if held != self.held {
                self.held = held
                debugLog("[ql] \(url.lastPathComponent) \(held ? "put away while the layout moves" : "may show again")")
                if !held { settled = false; lastRect = nil }
            }
            sync()
        }

        func tearDown() {
            guard !gone else { return }
            gone = true
            watch?.invalidate()
            watch = nil
            _ = AppKitBundle.object?.perform(NSSelectorFromString("nativePreviewRemove:"), with: id)
            pushed = nil
            debugLog("[ql] \(url?.lastPathComponent ?? "-") removed")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            sync()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            sync()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                // Out of the window (or into another): taken away, made again when back.
                _ = AppKitBundle.object?.perform(NSSelectorFromString("nativePreviewRemove:"), with: id)
                pushed = nil
                lastRect = nil
                settled = false
                watch?.invalidate()
                watch = nil
            } else {
                gone = false
                sync()
                if watch == nil {
                    let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                        MainActor.assumeIsolated { self?.sync() }
                    }
                    RunLoop.main.add(t, forMode: .common)
                    watch = t
                }
            }
        }

        /// Where it is in its window, clipped by what clips it, whether it
        /// is on screen at all, and the rounded corners it shares with what
        /// it is in (a workspace's card): their radius and which ("tl",
        /// "tr", "bl", "br").
        private func placement(in window: UIWindow) -> (rect: CGRect, onScreen: Bool, radius: CGFloat, corners: [String]) {
            // Below what floats over the top of the page (the Mac's strip
            // with its ⋯): AppKit's view would cover it.
            var rect = convert(bounds.inset(by: UIEdgeInsets(top: max(0, safeAreaInsets.top), left: 0, bottom: 0, right: 0)), to: window)
            var onScreen = !isHidden && alpha > 0.01
            var rounded: [(CGRect, CGFloat)] = []
            var v: UIView? = superview
            while let view = v {
                if view.isHidden || view.alpha < 0.01 { onScreen = false }
                let frame = view.convert(view.bounds, to: window)
                if view.clipsToBounds { rect = rect.intersection(frame) }
                if view.layer.cornerRadius > 0 { rounded.append((frame, view.layer.cornerRadius)) }
                v = view.superview
            }
            rect = rect.intersection(window.bounds)
            if rect.isNull || rect.width < 2 || rect.height < 2 { onScreen = false }
            if window.isHidden || window.windowScene?.activationState == .background { onScreen = false }
            guard !rect.isNull else { return (.zero, false, 0, []) }
            var radius: CGFloat = 0
            var corners: Set<String> = []
            for (frame, r) in rounded {
                let near = { (a: CGFloat, b: CGFloat) in abs(a - b) < max(1, r / 3) }
                let found = [
                    ("tl", near(rect.minX, frame.minX) && near(rect.minY, frame.minY)),
                    ("tr", near(rect.maxX, frame.maxX) && near(rect.minY, frame.minY)),
                    ("bl", near(rect.minX, frame.minX) && near(rect.maxY, frame.maxY)),
                    ("br", near(rect.maxX, frame.maxX) && near(rect.maxY, frame.maxY)),
                ].filter(\.1).map(\.0)
                if !found.isEmpty {
                    radius = max(radius, r)
                    corners.formUnion(found)
                }
            }
            return (rect, onScreen, radius, corners.sorted())
        }

        private func sync() {
            guard !gone, let window, let url else { return }
            let (rect, onScreen, radius, corners) = placement(in: window)
            if rect != lastRect {
                // Moving: away now, back once it has stayed put for 0.15 s.
                lastRect = rect
                settled = false
                settleRun += 1
                let run = settleRun
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, run == self.settleRun else { return }
                    self.settled = true
                    self.sync()
                }
            }
            push(window: window, url: url, rect: rect, radius: radius, corners: corners, visible: onScreen && settled && !held)
        }

        private func push(window: UIWindow, url: URL, rect: CGRect, radius: CGFloat, corners: [String], visible: Bool) {
            let spec: NSDictionary = [
                "id": id, "url": url.path, "revision": "\(revision)",
                "x": Double(rect.minX), "y": Double(rect.minY), "w": Double(rect.width), "h": Double(rect.height),
                "radius": Double(radius), "corners": corners.joined(separator: ","),
                "visible": visible,
                "toolbar": window.windowScene?.titlebar?.toolbar?.identifier ?? "",
            ]
            guard spec != pushed else { return }
            // The window goes along (not compared: it is the same one while this is in it).
            let full = NSMutableDictionary(dictionary: spec)
            full["window"] = window
            let r = AppKitBundle.object?.perform(NSSelectorFromString("nativePreviewUpdate:"), with: full)?
                .takeUnretainedValue() as? String ?? "no AppKit bundle"
            if (pushed?["visible"] as? Bool) != visible || pushed?["url"] as? String != url.path {
                debugLog("[ql] \(url.lastPathComponent): \(r)")
            }
            pushed = spec
        }
    }
}

extension AppKitBundle {
    /// For the debug log: every AppKit previewer, where and whether it shows.
    static func nativePreviewFacts() -> String { call("nativePreviewFacts") ?? "no AppKit bundle" }
}
#endif
