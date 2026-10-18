import Foundation

/// Answers "these relative images are near the viewport" for a preview page:
/// one at a time (each is its own round trip to the host), each resolved
/// against the document's own folder, each refused unless it is a plain image
/// inside that folder tree, small enough, and within the page's resident
/// budget. Shared by the Markdown page and the sandboxed HTML page.
///
/// The answer is a `data:` URI, or nil for a miss (the page then shows a quiet
/// stub instead of a blank box).
@MainActor
final class PreviewImageFiller {
    /// One image. The host serves files up to 5 MB; anything bigger is a photo
    /// the preview has no business holding in the DOM.
    static let maxBytes = 5 * 1024 * 1024
    /// Per page. Every fill stays resident as a base64 data: URI (~4/3 of the
    /// file), so this, not a count of images, keeps a photo-heavy page from
    /// evicting the app on iOS.
    static let byteBudget = 24 * 1024 * 1024

    var source: FilePreviewWebView.ImageSource?
    /// (src as the page wrote it, data URI or nil on a miss)
    var deliver: (String, String?) -> Void = { _, _ in }

    private(set) var bytesUsed = 0
    private var queue: [String] = []
    private var filling = false
    private var generation = 0

    nonisolated init() {}

    /// A new document: forget what the old one asked for and spent.
    func reset() {
        generation += 1
        queue.removeAll()
        bytesUsed = 0
    }

    func enqueue(_ srcs: [String]) {
        guard source != nil else { return }
        queue.append(contentsOf: srcs)
        pump()
    }

    private func pump() {
        guard !filling, !queue.isEmpty, source != nil else { return }
        filling = true
        let gen = generation
        Task { @MainActor [weak self] in
            while let self, self.generation == gen, !self.queue.isEmpty, let source = self.source {
                await self.fillOne(self.queue.removeFirst(), source: source, generation: gen)
            }
            guard let self else { return }
            self.filling = false
            // A reset that landed mid-drain abandoned the old queue; whatever
            // the new document asked for since is still waiting.
            self.pump()
        }
    }

    private func fillOne(_ src: String, source: FilePreviewWebView.ImageSource, generation gen: Int) async {
        guard let path = FilePreviewPaths.resolve(src, documentDirectory: source.directory),
              let mime = FilePreviewImageMIME.forPath(path),
              let bytes = await source.load(path),
              bytes.count <= Self.maxBytes,
              gen == generation,
              bytesUsed + bytes.count <= Self.byteBudget
        else {
            if gen == generation { deliver(src, nil) }
            return
        }
        bytesUsed += bytes.count
        deliver(src, "data:\(mime);base64,\(bytes.base64EncodedString())")
    }
}
