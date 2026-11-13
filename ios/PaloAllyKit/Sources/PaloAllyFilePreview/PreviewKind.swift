import Foundation
import UniformTypeIdentifiers

/// How a file opens, wherever it is opened from (成果, the file page, a file
/// sent in a conversation, a workspace's document card): one decision, so the
/// same file looks the same everywhere. From its name first (it costs no
/// bytes), then its media type, then its first bytes; a library item's
/// declared type is a hint for its main file.
public enum PreviewKind: Equatable, Sendable {
    /// Rendered Markdown (its source on request).
    case markdown
    /// Code and other text, highlighted.
    case text
    /// A web page, rendered offline in its own sandbox (its source on request).
    case html
    /// PDFKit, page after page, from the file.
    case pdf
    /// A picture, decoded at the size it's shown.
    case image
    case video
    case audio
    /// Word, Excel, PowerPoint, RTF and iWork documents.
    case office
    /// The system's previewer.
    case quickLook

    /// What a library item says its main file is.
    public enum Hint: Sendable { case markdown, html }

    /// Read and shown as text (and, in a file's own tab, edited as text).
    public var isText: Bool { self == .markdown || self == .text || self == .html }

    public static let officeExtensions: Set<String> = [
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf", "pages", "numbers", "key",
    ]
    /// Pictures shown by our own viewer (an animated GIF and SVG go to the system's).
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "tif", "tiff", "bmp"]
    static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]

    public static func classify(name: String, mediaType: String? = nil, hint: Hint? = nil, head: Data? = nil) -> PreviewKind {
        switch hint {
        case .markdown: return .markdown
        case .html: return .html
        case nil: break
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty {
            if FilePreviewRoute.markdownExtensions.contains(ext) { return .markdown }
            if htmlExtensions.contains(ext) { return .html }
            if ext == "pdf" { return .pdf }
            if imageExtensions.contains(ext) { return .image }
            if officeExtensions.contains(ext) { return .office }
            // Drawn by the system (its type is XML, which would make it text).
            if ext == "svg" { return .quickLook }
            if let type = UTType(filenameExtension: ext), !QuickLookRouting.isTrap(ext) {
                if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
                if type.conforms(to: .audio) { return .audio }
            }
            if QuickLookRouting.prefersQuickLook(fileName: name) { return .quickLook }
        } else if let type = mediaType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(), !type.isEmpty {
            if FilePreviewRoute.markdownMediaTypes.contains(type) { return .markdown }
            if type == "text/html" { return .html }
            if type == "application/pdf" { return .pdf }
            if type.hasPrefix("video/") { return .video }
            if type.hasPrefix("audio/") { return .audio }
            if type.hasPrefix("image/") { return type == "image/gif" || type.contains("svg") ? .quickLook : .image }
        }
        // Text by its name; the bytes may still say otherwise.
        if let head, FileContentKind.sniff(head) == .quickLook {
            return FileContentKind.looksLikeImage(head.prefix(16)) ? .image : .quickLook
        }
        return .text
    }
}
