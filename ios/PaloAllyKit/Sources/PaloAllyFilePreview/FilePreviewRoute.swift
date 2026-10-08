import Foundation

/// Which renderer opens a file: Markdown is ours (markdown-it + highlight.js
/// in `FilePreviewWebView`, ported from Bento Term), everything else stays with
/// the system's Quick Look.
///
/// Decided from the name alone, like Bento's `QuickLookRouting`: it costs no
/// bytes, so a file is routed before it is fetched. The media type only
/// speaks for a name with no extension.
public enum FilePreviewRoute: Equatable, Sendable {
    case markdown
    case quickLook

    /// The extensions `preview.js` renders as Markdown (its `MARKDOWN_EXTS`).
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    static let markdownMediaTypes: Set<String> = ["text/markdown", "text/x-markdown"]

    public static func forFile(name: String, mediaType: String? = nil) -> FilePreviewRoute {
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty {
            return markdownExtensions.contains(ext) ? .markdown : .quickLook
        }
        let type = mediaType?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return markdownMediaTypes.contains(type) ? .markdown : .quickLook
    }

    /// The name the page renders under. `preview.js` picks Markdown by
    /// extension, so a file routed here for another reason (no extension, or
    /// an artifact whose declared type is Markdown) gets one.
    public static func markdownRenderName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let ext = (base as NSString).pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return base }
        return (base.isEmpty ? "file" : base) + ".md"
    }
}

/// Where a Markdown file's relative image points, as a path relative to the
/// same root the document lives under (an artifact's folder). Standard
/// Markdown semantics: relative to the document's own directory. Nil for
/// anything that isn't a plain relative path inside that root — absolute
/// paths, `~`, URLs, or `..` climbing out.
public enum FilePreviewPaths {
    public static func resolve(_ src: String, documentDirectory dir: String) -> String? {
        let raw = (src.removingPercentEncoding ?? src).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.hasPrefix("~"), !raw.contains(":") else { return nil }
        // Query and fragment never name part of the file.
        let path = raw.split(separator: "?", maxSplits: 1).first.map(String.init) ?? raw
        let bare = path.split(separator: "#", maxSplits: 1).first.map(String.init) ?? path
        var parts: [Substring] = []
        for piece in (dir.split(separator: "/") + bare.split(separator: "/")) {
            switch piece {
            case "", ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(piece)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }
}

/// Image formats, extension → MIME, for the images the page inlines as
/// `data:` URIs (Bento's `FilePreviewImageMIME`).
public enum FilePreviewImageMIME {
    public static let table: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml",
        "bmp": "image/bmp", "tiff": "image/tiff", "tif": "image/tiff",
        "ico": "image/x-icon", "heic": "image/heic", "heif": "image/heif",
        "avif": "image/avif",
    ]

    public static func forPath(_ path: String) -> String? {
        table[(path as NSString).pathExtension.lowercased()]
    }
}
