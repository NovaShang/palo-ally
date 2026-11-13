import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Files opened from the computer, downloaded to the device's disk through
/// one downloader (`FileFetcher`) for every way in: 成果, the file page, a
/// file sent in a conversation, and the workspace's document cards
/// (docs/large-files-design.md). Never a whole file in memory: chunks go
/// straight into a file in the cache, and the cache is keyed by the file's
/// version, so opening it again needs nothing from the computer.
extension AppStore {
    /// What is known of a file on the computer before it is downloaded.
    public struct RemoteFileInfo: Sendable, Equatable {
        public var size: Int64
        public var version: String
        public init(size: Int64, version: String) { self.size = size; self.version = version }
    }

    private var cacheHost: String { (parent ?? self).fileCacheHost }
    private var fetcher: FileFetcher { (parent ?? self).fileFetcher }

    private func cacheKey(_ source: RemoteFileSource) -> String { "\(cacheHost)|\(source.cacheKey)" }

    /// A library item's file's version: when the item last changed, and the
    /// file's size (both in the list already: nothing to ask).
    public func artifactFileInfo(id: String, path: String) -> RemoteFileInfo? {
        guard let a = artifact(id: id) else { return nil }
        let size = a.files.first { $0.path == path }?.size ?? 0
        return RemoteFileInfo(size: size, version: "\(a.updatedAt):\(size)")
    }

    /// The size and version a file has on the computer now: the first byte
    /// of it is read (`files.read`), nothing more.
    public func probeFile(_ scope: FileScope, path: String) async throws -> RemoteFileInfo {
        let chunk: FileChunk = try await rpc.call(
            RPCMethod.filesRead, params: FilesReadParams(scope: scope, path: path, offset: 0, length: 1, stream: true), timeout: 60)
        if chunk.tooLarge { throw FileStreamTooLarge(size: chunk.size) }
        return RemoteFileInfo(size: chunk.size, version: chunk.version ?? "size:\(chunk.size)")
    }

    /// The file's version known to be here (nil: none, or not that one). A
    /// file sent in a conversation never changes; a library item's version is
    /// in the list; a computer file's must be asked (`probeFile`) or given.
    public func cachedFile(_ source: RemoteFileSource, name: String, version: String? = nil) -> URL? {
        let key = cacheKey(source)
        switch source {
        case .media: return fetcher.cache.cached(key: key, version: "media", name: name)
        case .artifact(let id, let path):
            guard let v = version ?? artifactFileInfo(id: id, path: path)?.version else { return nil }
            return fetcher.cache.cached(key: key, version: v, name: name)
        case .file:
            guard let version else { return nil }
            return fetcher.cache.cached(key: key, version: version, name: name)
        }
    }

    /// The newest copy of a computer file kept here, whatever its version
    /// (shown at once while the computer is asked whether it changed).
    public func latestCachedFile(_ source: RemoteFileSource) -> (url: URL, version: String)? {
        fetcher.cache.latest(key: cacheKey(source))
    }

    /// The file on the device, downloaded if it isn't here in that version:
    /// up to 1 MiB a request, 4 at once, written to disk as they come;
    /// resumed from what a stopped download left. `progress(received, total)`
    /// is called on the main actor. A computer file is asked for its version
    /// first unless `version` is given, and downloaded again if it changes
    /// meanwhile. Throws `FileStreamTooLarge` when the computer's PaloAlly is
    /// too old to send it.
    public func downloadFile(_ source: RemoteFileSource, name: String, size: Int64? = nil, version: String? = nil,
                             progress: (@MainActor (Int64, Int64) -> Void)? = nil) async throws -> URL {
        let key = cacheKey(source)
        var report: DownloadProgress?
        if let progress {
            let box = MainActorProgress(progress)
            report = { got, total in Task { @MainActor in box.call(got, total) } }
        }
        let rpc = rpc
        switch source {
        case .media(let id):
            return try await fetcher.fetch(key: key, version: "media", name: name, size: size, read: { offset, length in
                let c: ArtifactChunk = try await rpc.call(
                    RPCMethod.mediaRead, params: MediaReadParams(id: id, offset: offset, length: length, stream: true), timeout: 60)
                return RemoteChunk(data: c.data, size: c.size, eof: c.eof)
            }, progress: report)
        case .artifact(let id, let path):
            let info = artifactFileInfo(id: id, path: path)
            return try await fetcher.fetch(key: key, version: version ?? info?.version ?? "0", name: name,
                                                      size: size ?? info.flatMap { $0.size > 0 ? $0.size : nil }, read: { offset, length in
                let c: ArtifactChunk = try await rpc.call(
                    RPCMethod.artifactRead, params: ArtifactReadParams(id: id, path: path, offset: offset, length: length, stream: true), timeout: 60)
                return RemoteChunk(data: c.data, size: c.size, eof: c.eof)
            }, progress: report)
        case .file(let scope, let path):
            var known = version.map { RemoteFileInfo(size: size ?? -1, version: $0) }
            for attempt in 0..<2 {
                let info: RemoteFileInfo
                if let k = known { info = k } else { info = try await probeFile(scope, path: path) }
                do {
                    return try await fetcher.fetch(key: key, version: info.version, name: name,
                                                              size: info.size >= 0 ? info.size : nil, read: { offset, length in
                        let c: FileChunk = try await rpc.call(
                            RPCMethod.filesRead, params: FilesReadParams(scope: scope, path: path, offset: offset, length: length, stream: true), timeout: 60)
                        return RemoteChunk(data: c.data, size: c.size, eof: c.eof, version: c.version, tooLarge: c.tooLarge)
                    }, progress: report)
                } catch is RemoteFileChanged where attempt == 0 {
                    // Changed on the computer while it came: once more, as it is now.
                    debugLog("[files] \(FileCache.safeName(name)) changed while downloading, again")
                    known = nil
                }
            }
            throw RemoteFileChanged(version: nil)
        }
    }

    /// Everything downloaded and kept, in bytes (off the main actor).
    public nonisolated static func downloadedFilesBytes() async -> Int64 {
        await Task.detached(priority: .utility) { FileFetcher.shared.cache.totalBytes() }.value
    }

    /// Empties the downloaded files' cache (a download under way is left alone).
    public nonisolated static func clearDownloadedFiles() async {
        await FileFetcher.shared.clearCache()
    }

    /// A picture file made small enough to show (`maxPixels` on its longer
    /// side), decoded from the file without the whole picture in memory: a
    /// JPEG's bytes, or nil when it isn't a picture.
    public nonisolated static func thumbnailData(of url: URL, maxPixels: Int) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// A main-actor progress callback, carried to the downloader's reports.
private final class MainActorProgress: @unchecked Sendable {
    let call: @MainActor (Int64, Int64) -> Void
    init(_ call: @escaping @MainActor (Int64, Int64) -> Void) { self.call = call }
}
