import Foundation
import UniformTypeIdentifiers

/// Decides which files leave our renderer and go to the system's (ported
/// from Bento Term's `QuickLookRouting`). Text, code and Markdown stay ours:
/// the web renderer highlights code and follows the color scheme. Quick Look
/// takes pictures, PDFs, Office and iWork documents, media, fonts, archives.
///
/// Decided from the extension alone: it costs no bytes. An extension we
/// can't map falls through to a byte sniff (`FileContentKind.sniff`).
public enum QuickLookRouting {
    /// Types the system previews well that a conformance check would miss or
    /// misroute (RTF and iWork conform to text-ish types).
    private static let alwaysExtensions: Set<String> = [
        "pdf", "rtf", "rtfd", "doc", "docx", "dot", "dotx", "xls", "xlsx", "xlsm", "ppt", "pptx",
        "pages", "numbers", "key", "epub", "usdz", "usda", "usdc", "usd", "ics", "vcf",
    ]

    /// Extensions whose system type is a trap: `.ts` is an MPEG transport
    /// stream to the system, `.dts` audio; `.bin` claims MacBinary.
    private static let neverExtensions: Set<String> = ["ts", "mts", "cts", "dts", "dtsi", "bin"]

    private static let previewableFamilies: [UTType] = [
        .image, .movie, .audio, .audiovisualContent, .threeDContent, .font, .archive, .pdf,
    ]

    private static func isOurs(_ type: UTType) -> Bool {
        type.conforms(to: .plainText) || type.conforms(to: .sourceCode) || type.conforms(to: .script)
            || type.conforms(to: .shellScript) || type.conforms(to: .delimitedText) || type.conforms(to: .json)
            || type.conforms(to: .yaml) || type.conforms(to: .xml) || type.conforms(to: .html)
    }

    public static func prefersQuickLook(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if neverExtensions.contains(ext) { return false }
        if alwaysExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        if isOurs(type) { return false }
        return previewableFamilies.contains { type.conforms(to: $0) }
    }
}

/// How a file on the computer opens (docs/files-prd.md): Markdown rendered,
/// code and text highlighted, everything else in Quick Look.
public enum FileContentKind: Equatable, Sendable {
    case markdown
    case text
    case quickLook

    /// From the name; `.text` may still turn out binary (see `sniff`).
    public static func forName(_ name: String) -> FileContentKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if FilePreviewRoute.markdownExtensions.contains(ext) { return .markdown }
        if FilePreviewImageMIME.table[ext] != nil || QuickLookRouting.prefersQuickLook(fileName: name) { return .quickLook }
        return .text
    }

    /// What the bytes say for a file the name sent to `.text`: a NUL byte in
    /// the first 8 KB, or a picture's signature, means it isn't text.
    public static func sniff(_ data: Data) -> FileContentKind {
        let head = data.prefix(8192)
        if head.contains(0) || looksLikeImage(head) { return .quickLook }
        return .text
    }

    static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true } // PNG
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true } // JPEG
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return true } // GIF
        if b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true } // WEBP
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return true } // HEIC (ftyp)
        return false
    }
}
