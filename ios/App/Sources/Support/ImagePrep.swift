import Foundation
import ImageIO
import PaloAllyKit
import UniformTypeIdentifiers

/// Downscales / re-encodes picked images, ported from bento's
/// `ImageAttachmentProcessor`: Claude only ingests PNG, JPEG, GIF and WebP
/// (HEIC from the camera roll or TIFF off the Mac pasteboard must be
/// re-encoded, or the agent can't read the header), and 1568 px is the
/// largest edge the model uses. PaloAlly addition: each image goes over the
/// relay in one frame (1 MiB cap), so the encoded size is kept under ~700 KB.
enum ImagePrep {
    static let maxPixelSize = 1568
    static let passthroughBytes = 700_000
    static let safeTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    static func process(_ data: Data) -> AppStore.OutgoingImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let sourceMIME = (CGImageSourceGetType(source) as String?).flatMap { UTType($0)?.preferredMIMEType }
        if let sourceMIME, safeTypes.contains(sourceMIME), max(width, height) <= maxPixelSize, data.count <= passthroughBytes {
            return AppStore.OutgoingImage(data: data, mediaType: sourceMIME)
        }
        // Re-encode as JPEG, stepping down until it fits one relay frame.
        for (edge, quality) in [(maxPixelSize, 0.85), (maxPixelSize, 0.7), (1200, 0.7), (1000, 0.6)] {
            if let jpeg = jpeg(source, edge: edge, quality: quality), jpeg.count <= passthroughBytes {
                return AppStore.OutgoingImage(data: jpeg, mediaType: "image/jpeg")
            }
        }
        return nil
    }

    private static func jpeg(_ source: CGImageSource, edge: Int, quality: Double) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
