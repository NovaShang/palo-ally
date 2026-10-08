#if canImport(UIKit)
import SwiftUI
import UIKit

/// A Markdown file as a page: rendered, or its source text when `raw`.
/// Follows the color scheme without re-rendering (Bento's `WebPreviewText`).
public struct MarkdownPreview: UIViewRepresentable {
    let fileName: String
    let text: String
    let raw: Bool
    let imageSource: FilePreviewWebView.ImageSource?
    @Environment(\.colorScheme) private var colorScheme

    /// `fileName` names the file (any extension: it always renders as
    /// Markdown). `imageSource` fills the document's relative images; without
    /// one they show as stubs.
    public init(fileName: String, text: String, raw: Bool = false,
                imageSource: FilePreviewWebView.ImageSource? = nil) {
        self.fileName = FilePreviewRoute.markdownRenderName(fileName)
        self.text = text
        self.raw = raw
        self.imageSource = imageSource
    }

    public func makeUIView(context: Context) -> FilePreviewWebView {
        FilePreviewWebView.makePreview()
    }

    public func updateUIView(_ view: FilePreviewWebView, context: Context) {
        let dark = colorScheme == .dark
        let key = RenderKey(fileName: fileName, textHash: text.hashValue, raw: raw)
        if context.coordinator.rendered != key {
            context.coordinator.rendered = key
            view.render(fileName: fileName, text: text, raw: raw, dark: dark, imageSource: imageSource)
        } else {
            view.setDark(dark)
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    struct RenderKey: Equatable {
        let fileName: String
        /// Content hash, not length — a live artifact can change in place.
        let textHash: Int
        let raw: Bool
    }

    public final class Coordinator {
        var rendered: RenderKey?
    }
}
#endif
