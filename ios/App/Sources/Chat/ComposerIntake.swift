import ObjectiveC
import PaloAllyKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Images and files that reach the composer other than through its [+]:
/// dropped on the conversation (the Mac, iPad) or pasted into the field
/// (⌘V with a picture or a copied file on the clipboard). The conversation
/// owns one; the composer stages what comes in, as if picked.
@MainActor @Observable
final class ComposerIntake {
    /// Waiting for the composer to stage (it empties this).
    var incoming: [Staged] = []
    /// Something is being dragged over the conversation.
    var dropTargeted = false

    /// Reads what was dropped or pasted: pictures as images, anything else
    /// as a file under its own name. Plain text isn't taken (the field has it).
    func take(_ providers: [NSItemProvider]) {
        Task {
            var out: [Staged] = []
            for p in providers.prefix(6) {
                if let s = await Self.load(p) { out.append(s) }
            }
            if !out.isEmpty { incoming.append(contentsOf: out) }
        }
    }

    static func load(_ p: NSItemProvider) async -> Staged? {
        let types = p.registeredTypeIdentifiers.compactMap(UTType.init)
        let isFile = types.contains { $0.conforms(to: .fileURL) } || p.suggestedName != nil
        // A picture: decoded and downsized like a picked photo.
        if let image = types.first(where: { $0.conforms(to: .image) }),
           let data = await data(p, image.identifier), let img = ImagePrep.process(data) {
            return .image(img)
        }
        // Text alone (a selection dragged or copied) stays text.
        if !isFile, types.allSatisfy({ $0.conforms(to: .text) && !$0.conforms(to: .fileURL) }) { return nil }
        // A file: its bytes under its own name.
        if let url = await fileURL(p), let d = try? Data(contentsOf: url, options: .mappedIfSafe) {
            return file(d, name: url.lastPathComponent)
        }
        guard let type = types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .text) }) ?? types.first,
              let d = await data(p, type.identifier) else { return nil }
        let name = p.suggestedName.map { n in n.contains(".") ? n : n + (type.preferredFilenameExtension.map { ".\($0)" } ?? "") }
        return file(d, name: name ?? "文件")
    }

    private static func file(_ d: Data, name: String) -> Staged? {
        guard d.count <= 100 * 1024 * 1024 else { return nil }
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        if type?.conforms(to: .image) == true, let img = ImagePrep.process(d) { return .image(img) }
        return .file(AppStore.OutgoingFile(data: d, mediaType: type?.preferredMIMEType ?? "application/octet-stream", name: name))
    }

    private static func data(_ p: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { c in
            _ = p.loadDataRepresentation(forTypeIdentifier: type) { d, _ in c.resume(returning: d) }
        }
    }

    /// A file dragged or copied from Finder or Files: a copy of it, readable here.
    private static func fileURL(_ p: NSItemProvider) async -> URL? {
        guard p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || p.suggestedName != nil else { return nil }
        let type = p.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true } ?? UTType.data.identifier
        return await withCheckedContinuation { c in
            _ = p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                // The system's copy goes away when this returns: keep our own.
                guard let url else { return c.resume(returning: nil) }
                let keep = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dropped-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
                let to = keep.appendingPathComponent(url.lastPathComponent)
                c.resume(returning: (try? FileManager.default.copyItem(at: url, to: to)) != nil ? to : nil)
            }
        }
    }
}

/// ⌘V (and 粘贴 in the field's menu) with a picture or a copied file on the
/// clipboard stages it in the composer; text pastes as always. SwiftUI has no
/// paste hook on a focused text field here (bento: onPasteCommand never fires
/// on one), so the text view's own paste asks the composer first, while the
/// composer's field is the one being typed in.
@MainActor
enum ComposerPaste {
    /// Set by the composer while its field has focus.
    static var handler: ((UIPasteboard) -> Bool)? {
        didSet { if handler != nil { install() } }
    }

    /// The clipboard has something the composer takes: a picture or a file.
    static func hasAttachable(_ pb: UIPasteboard) -> Bool {
        pb.hasImages || pb.itemProviders.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    }

    private static var installed = false

    private static func install() {
        guard !installed else { return }
        installed = true
        swap(UITextView.self, #selector(UIResponderStandardEditActions.paste(_:)), #selector(UITextView.composer_paste(_:)))
        swap(UITextView.self, #selector(UIResponder.canPerformAction(_:withSender:)), #selector(UITextView.composer_canPerformAction(_:withSender:)))
    }

    private static func swap(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(cls, original), let b = class_getInstanceMethod(cls, replacement) else { return }
        // A subclass's own method (if any) stays; this is UITextView's.
        if class_addMethod(cls, original, method_getImplementation(b), method_getTypeEncoding(b)) {
            class_replaceMethod(cls, replacement, method_getImplementation(a), method_getTypeEncoding(a))
        } else {
            method_exchangeImplementations(a, b)
        }
    }
}

extension UITextView {
    @objc func composer_paste(_ sender: Any?) {
        if isFirstResponder, let take = ComposerPaste.handler, take(UIPasteboard.general) { return }
        composer_paste(sender) // the original
    }

    @objc func composer_canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.paste(_:)), isFirstResponder,
           ComposerPaste.handler != nil, ComposerPaste.hasAttachable(UIPasteboard.general) {
            return true
        }
        return composer_canPerformAction(action, withSender: sender)
    }
}

/// The conversation takes images and files dropped anywhere on it while the
/// composer is there; a quiet outline says it will.
struct ComposerDropTarget: ViewModifier {
    let intake: ComposerIntake
    let enabled: Bool

    // One shape whether or not it takes drops: switching would rebuild the
    // conversation under it (its scroll position, the composer's focus).
    func body(content: Content) -> some View {
        content
            .onDrop(of: enabled ? [.image, .fileURL, .data] : [],
                    isTargeted: Binding(get: { intake.dropTargeted }, set: { intake.dropTargeted = $0 })) { providers in
                guard enabled else { return false }
                intake.take(providers)
                return true
            }
            .overlay {
                if enabled && intake.dropTargeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                        .padding(8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: intake.dropTargeted)
    }
}
