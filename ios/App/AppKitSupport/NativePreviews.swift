import AppKit
import Quartz

/// Office and iWork documents shown by the system's own previewer inside a
/// window, over a place the app keeps for them (NativeQuickLookView): the
/// QuickLook embedded by UIKit on the Mac drew them as one still picture at
/// 1x, blurred and not scrolling (11-14). Here they are AppKit's
/// QLPreviewView, crisp, scrolling, their text selectable.
///
/// Each view is the app's by an id. The app says where it goes (a rect in
/// the window's top-left coordinates, as UIKit has them), whether it shows,
/// and takes it away; the view sits in the window's content view, above the
/// app's, so it moves with the window.
@MainActor
final class NativePreviews {
    static let shared = NativePreviews()

    private final class Entry {
        let container: NSView
        let preview: QLPreviewView
        weak var window: NSWindow?
        var url: URL?
        var revision = ""

        init(container: NSView, preview: QLPreviewView) {
            self.container = container
            self.preview = preview
        }
    }

    private var entries: [String: Entry] = [:]

    /// Whether the keyboard is with a previewer of ours (its keys are left alone).
    static func hasKeyboard(_ window: NSWindow?) -> Bool {
        guard let v = window?.firstResponder as? NSView else { return false }
        return sequence(first: v, next: \.superview).contains { $0 is QLPreviewView }
    }

    /// Whether `point` (in the window's base coordinates) is over a
    /// previewer of ours that shows.
    static func covers(_ point: NSPoint, in window: NSWindow) -> Bool {
        shared.entries.values.contains { e in
            guard e.window === window, !e.container.isHidden, let superview = e.container.superview else { return false }
            return e.container.frame.contains(superview.convert(point, from: nil))
        }
    }

    /// The app's window for `uiWindow` (a UIWindow), else the one whose
    /// toolbar is `toolbar`.
    private func window(for uiWindow: AnyObject?, toolbar: String?) -> NSWindow? {
        let windows = NSApplication.shared.windows
        if let uiWindow {
            let key = NSSelectorFromString("uiWindows")
            for w in windows where w.responds(to: key) {
                if let list = w.value(forKey: "uiWindows") as? [AnyObject], list.contains(where: { $0 === uiWindow }) { return w }
            }
        }
        if let toolbar, !toolbar.isEmpty {
            return windows.first { $0.toolbar?.identifier == toolbar }
        }
        return nil
    }

    /// Creates or updates the previewer `id`: "url" (a file path),
    /// "revision", "x"/"y"/"w"/"h" in the window's top-left coordinates,
    /// "radius", "visible", and "window" (the UIWindow) or "toolbar".
    func update(_ spec: NSDictionary) -> String {
        guard let id = spec["id"] as? String else { return "no id" }
        guard let window = window(for: spec["window"] as AnyObject?, toolbar: spec["toolbar"] as? String),
              let content = window.contentView, let frame = content.superview else {
            remove(id)
            return "no window"
        }
        let entry: Entry
        if let e = entries[id] {
            entry = e
        } else {
            let container = NSView()
            container.wantsLayer = true
            container.layer?.masksToBounds = true
            container.isHidden = true
            let preview = QLPreviewView(frame: .zero, style: .normal)!
            preview.autostarts = true
            preview.shouldCloseWithWindow = false
            preview.autoresizingMask = [.width, .height]
            container.addSubview(preview)
            entry = Entry(container: container, preview: preview)
            entries[id] = entry
        }
        // In this window's content, above the app's.
        if entry.window !== window || entry.container.superview !== content || content.subviews.last !== entry.container {
            entry.container.removeFromSuperview()
            content.addSubview(entry.container, positioned: .above, relativeTo: nil)
            entry.window = window
        }
        let x = spec["x"] as? Double ?? 0, y = spec["y"] as? Double ?? 0
        let w = spec["w"] as? Double ?? 0, h = spec["h"] as? Double ?? 0
        let inFrame = NSRect(x: x, y: frame.bounds.height - y - h, width: w, height: h)
        let rect = content.convert(inFrame, from: frame).integral
        if entry.container.frame != rect {
            entry.container.frame = rect
            entry.preview.frame = entry.container.bounds
        }
        // Rounded where what it sits in is (a workspace's card): "tl,br" in
        // UIKit's terms (top at the top), the layer's top being its maxY here.
        if let layer = entry.container.layer {
            let corners = (spec["corners"] as? String ?? "").split(separator: ",")
            var mask: CACornerMask = []
            if corners.contains("tl") { mask.insert(.layerMinXMaxYCorner) }
            if corners.contains("tr") { mask.insert(.layerMaxXMaxYCorner) }
            if corners.contains("bl") { mask.insert(.layerMinXMinYCorner) }
            if corners.contains("br") { mask.insert(.layerMaxXMinYCorner) }
            let radius = mask.isEmpty ? 0 : spec["radius"] as? Double ?? 0
            if layer.cornerRadius != radius || layer.maskedCorners != mask {
                layer.cornerRadius = radius
                layer.cornerCurve = .continuous
                layer.maskedCorners = mask
            }
        }
        if let path = spec["url"] as? String {
            let url = URL(fileURLWithPath: path)
            let revision = spec["revision"] as? String ?? ""
            if entry.url != url || entry.revision != revision {
                let reload = entry.url == url
                entry.url = url
                entry.revision = revision
                entry.preview.previewItem = url as NSURL
                if reload { entry.preview.refreshPreviewItem() }
            }
        }
        let visible = (spec["visible"] as? Bool ?? false) && w > 1 && h > 1
        if entry.container.isHidden == visible {
            if !visible, Self.hasKeyboard(window) { window.makeFirstResponder(content) }
            entry.container.isHidden = !visible
        }
        return "\(visible ? "shown" : "hidden") at \(Int(x)),\(Int(y)) \(Int(w))x\(Int(h))"
    }

    func remove(_ id: String) {
        guard let e = entries.removeValue(forKey: id) else { return }
        if let window = e.window, Self.hasKeyboard(window), let content = window.contentView {
            window.makeFirstResponder(content)
        }
        e.preview.close()
        e.container.removeFromSuperview()
    }

    /// For the debug log: every previewer, where and whether it shows.
    func facts() -> String {
        if entries.isEmpty { return "none" }
        return entries.sorted { $0.key < $1.key }.map { id, e in
            let f = e.container.frame
            let item = (e.preview.previewItem as? NSURL)?.lastPathComponent ?? "-"
            let corners = (e.container.layer?.cornerRadius ?? 0) > 0 ? " radius \(Int(e.container.layer?.cornerRadius ?? 0)) corners \(e.container.layer?.maskedCorners.rawValue ?? 0)" : ""
            var line = "\(id.prefix(8)) \(item) \(e.container.isHidden ? "hidden" : "shown") \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))\(corners) in \(e.window.map { "\(Int($0.frame.width))x\(Int($0.frame.height)) @\(Int($0.backingScaleFactor))x" } ?? "no window")\(e.container.superview == nil ? " detached" : "")"
            if let w = e.window {
                line += ", keyboard \(Self.hasKeyboard(w) ? "in it" : String(describing: w.firstResponder.map { type(of: $0) }))"
            }
            #if DEBUG
            func walk(_ v: NSView, _ depth: Int) -> [String] {
                var out = [String(repeating: " ", count: depth) + "\(type(of: v)) \(Int(v.frame.width))x\(Int(v.frame.height))"]
                if let s = v as? NSScrollView { out[0] += " scrolled to \(Int(s.contentView.bounds.minY))" }
                guard depth < 6 else { return out }
                for sub in v.subviews { out += walk(sub, depth + 1) }
                return out
            }
            line += "\n" + walk(e.preview, 1).joined(separator: "\n")
            #endif
            return line
        }.joined(separator: "; ")
    }
}

/// Files in Quick Look's own window (QLPreviewPanel), from the app: a
/// QLPreviewController presented by UIKit for them left our sheet, or a dimmed
/// window, behind it (11-14).
@MainActor
final class PanelSource: NSObject, QLPreviewPanelDataSource {
    static let shared = PanelSource()
    /// Read by the panel on the main thread.
    nonisolated(unsafe) var urls: [URL] = []

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}

extension ImmersiveWindows {
    /// Quick Look's window on "paths" (file paths), at "start".
    @objc func nativePreviewPanel(_ spec: NSDictionary) -> String {
        guard let paths = spec["paths"] as? [String], !paths.isEmpty, let panel = QLPreviewPanel.shared() else { return "nothing to show" }
        PanelSource.shared.urls = paths.map { URL(fileURLWithPath: $0) }
        panel.dataSource = PanelSource.shared
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(spec["start"] as? Int ?? 0, 0), paths.count - 1)
        panel.makeKeyAndOrderFront(nil)
        return "Quick Look's window on \(paths.count) file(s)"
    }

    /// NativePreviews.update: the spec as a dictionary; what it did.
    @objc func nativePreviewUpdate(_ spec: NSDictionary) -> String {
        NativePreviews.shared.update(spec)
    }

    @objc func nativePreviewRemove(_ id: String) {
        NativePreviews.shared.remove(id)
    }

    @objc func nativePreviewFacts() -> String {
        NativePreviews.shared.facts()
    }
}
