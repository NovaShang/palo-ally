#if canImport(UIKit)
import SwiftUI
import UIKit

/// A text file on the computer as a page: Markdown rendered, code and other
/// text highlighted by its extension (preview.js decides from the name), or
/// the source when `raw`. Follows the color scheme without re-rendering.
/// `MarkdownPreview` is this with the name forced to Markdown.
public struct FileTextPreview: UIViewRepresentable {
    let fileName: String
    let text: String
    let raw: Bool
    let imageSource: FilePreviewWebView.ImageSource?
    @Environment(\.colorScheme) private var colorScheme

    public init(fileName: String, text: String, raw: Bool = false,
                imageSource: FilePreviewWebView.ImageSource? = nil) {
        let base = (fileName as NSString).lastPathComponent
        self.fileName = base.isEmpty ? "file.txt" : base
        self.text = text
        self.raw = raw
        self.imageSource = imageSource
    }

    public func makeUIView(context: Context) -> FilePreviewWebView {
        FilePreviewWebView.makePreview()
    }

    public func updateUIView(_ view: FilePreviewWebView, context: Context) {
        let dark = colorScheme == .dark
        let key = MarkdownPreview.RenderKey(fileName: fileName, textHash: text.hashValue, raw: raw)
        if context.coordinator.rendered != key {
            context.coordinator.rendered = key
            view.render(fileName: fileName, text: text, raw: raw, dark: dark, imageSource: imageSource)
        } else {
            view.setDark(dark)
        }
    }

    public func makeCoordinator() -> MarkdownPreview.Coordinator { MarkdownPreview.Coordinator() }
}
#endif
