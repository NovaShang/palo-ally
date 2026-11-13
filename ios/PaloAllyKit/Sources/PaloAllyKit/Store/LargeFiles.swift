import CryptoKit
import Foundation

// Files the app opens from the computer, downloaded to its own disk
// (docs/large-files-design.md): chunk by chunk straight into a file, a few
// chunks in flight at once, resumed where it stopped, and kept in a cache by
// the file's version so a second open needs nothing from the computer. No
// API here hands back a whole file as `Data`: what comes back is a file URL.

/// Where a file the app downloads lives on the computer.
public enum RemoteFileSource: Hashable, Sendable {
    /// A computer file (`files.read`).
    case file(scope: FileScope, path: String)
    /// A library item's file (`artifact.read`).
    case artifact(id: String, path: String)
    /// A file sent in a conversation (`media.read`).
    case media(id: String)

    /// The file's identity in the cache (with the computer's, see `AppStore.fileCacheHost`).
    var cacheKey: String {
        switch self {
        case .file(let scope, let path): "file|\(scope.kind.rawValue)|\(scope.id ?? "")|\(path)"
        case .artifact(let id, let path): "artifact|\(id)|\(path)"
        case .media(let id): "media|\(id)"
        }
    }
}

/// One chunk as the computer answers it (`files.read`, `artifact.read`, `media.read`).
public struct RemoteChunk: Sendable {
    public var data: Data
    public var size: Int64
    public var eof: Bool
    /// The file's version as it was read (`files.read`; nil for the others).
    public var version: String?
    /// The computer refused to send it (an older PaloAlly there).
    public var tooLarge: Bool
    public init(data: Data, size: Int64, eof: Bool, version: String? = nil, tooLarge: Bool = false) {
        self.data = data; self.size = size; self.eof = eof; self.version = version; self.tooLarge = tooLarge
    }
}

/// Reads `length` bytes at `offset` (the computer may send fewer).
public typealias RemoteChunkReader = @Sendable (_ offset: Int64, _ length: Int64) async throws -> RemoteChunk

/// Progress of a download: bytes on disk, and the file's size (0 while unknown).
public typealias DownloadProgress = @Sendable (_ received: Int64, _ total: Int64) -> Void

/// The file changed on the computer while it was downloaded: what was
/// fetched is dropped (the caller starts over on the new version).
public struct RemoteFileChanged: Error, Sendable, Equatable {
    public var version: String?
}

/// The computer sent less than the file's size and then nothing more.
public struct RemoteFileIncomplete: Error, Sendable, Equatable {
    public var received: Int64
    public var size: Int64
}

// MARK: - the cache

/// Downloaded files on the device: `Caches/large-files/<key>/<version>/<name>`
/// (the key a hash of the computer, the scope and the path; the version a
/// hash of the computer's version of the file). A download in progress is
/// `<name>.part` beside it, resumed from its length. Least recently opened
/// goes first once the total passes the cap; the system may also empty
/// Caches when space runs low. A single file over the cap is still kept
/// until the next download, then goes first.
public final class FileCache: @unchecked Sendable {
    public let root: URL
    public let capBytes: Int64
    private let lock = NSLock()
    private let fm = FileManager.default

    /// 1 GB on a phone or iPad, 5 GB on a Mac.
    public static var defaultCap: Int64 {
        #if targetEnvironment(macCatalyst) || os(macOS)
        5 * 1024 * 1024 * 1024
        #else
        1024 * 1024 * 1024
        #endif
    }

    public static let shared = FileCache(
        root: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("large-files", isDirectory: true),
        capBytes: defaultCap)

    public init(root: URL, capBytes: Int64) {
        self.root = root
        self.capBytes = capBytes
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// A short stable name for a string (a sandbox's, a folder's).
    public static func hashKey(_ s: String) -> String { hash(s) }

    /// A name safe to keep the file under (its own, for Quick Look and sharing).
    static func safeName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        return base.isEmpty || base == "." || base == ".." ? "file" : base
    }

    public func directory(key: String, version: String) -> URL {
        root.appendingPathComponent(Self.hash(key), isDirectory: true)
            .appendingPathComponent(Self.hash(version), isDirectory: true)
    }

    public func fileURL(key: String, version: String, name: String) -> URL {
        directory(key: key, version: version).appendingPathComponent(Self.safeName(name))
    }

    func partURL(key: String, version: String, name: String) -> URL {
        directory(key: key, version: version).appendingPathComponent(Self.safeName(name) + ".part")
    }

    /// The whole file of that version, if it is here (marked as just used).
    public func cached(key: String, version: String, name: String) -> URL? {
        let url = fileURL(key: key, version: version, name: name)
        guard fm.fileExists(atPath: url.path) else { return nil }
        touch(url.deletingLastPathComponent())
        return url
    }

    /// The newest whole copy of the file kept, whatever its version (shown at
    /// once while the computer is asked whether it changed).
    public func latest(key: String) -> (url: URL, version: String)? {
        let dir = root.appendingPathComponent(Self.hash(key), isDirectory: true)
        guard let versions = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let found = versions.compactMap { v -> (URL, String, Date)? in
            guard let info = Self.readInfo(v) else { return nil }
            let url = v.appendingPathComponent(info.name)
            guard fm.fileExists(atPath: url.path) else { return nil }
            let date = (try? v.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, info.version, date)
        }.max { $0.2 < $1.2 }
        return found.map { ($0.0, $0.1) }
    }

    /// Bytes already downloaded of that version (a download stopped midway).
    public func partialLength(key: String, version: String, name: String) -> Int64 {
        let url = partURL(key: key, version: version, name: name)
        return ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    struct Info: Codable { let version: String; let name: String; let size: Int64 }

    static func readInfo(_ dir: URL) -> Info? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("info.json")) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    /// The download is whole: `.part` becomes the file, older versions of it
    /// go, and the cache is trimmed (never what is being downloaded now).
    func complete(key: String, version: String, name: String, size: Int64, keep: Set<String>) throws -> URL {
        let dir = directory(key: key, version: version)
        let url = fileURL(key: key, version: version, name: name)
        lock.lock(); defer { lock.unlock() }
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        try fm.moveItem(at: partURL(key: key, version: version, name: name), to: url)
        let info = try JSONEncoder().encode(Info(version: version, name: Self.safeName(name), size: size))
        try info.write(to: dir.appendingPathComponent("info.json"), options: .atomic)
        touch(dir)
        // An older version of the same file is never opened again.
        let keyDir = dir.deletingLastPathComponent()
        for other in (try? fm.contentsOfDirectory(at: keyDir, includingPropertiesForKeys: nil)) ?? []
        where other.standardizedFileURL != dir.standardizedFileURL && !keep.contains(other.standardizedFileURL.path) {
            try? fm.removeItem(at: other)
        }
        evictLocked(keep: keep.union([dir.standardizedFileURL.path]))
        return url
    }

    private func touch(_ dir: URL) {
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
    }

    /// Every version folder: its path, bytes and when it was last used.
    private func entries() -> [(dir: URL, bytes: Int64, used: Date)] {
        var out: [(URL, Int64, Date)] = []
        let keys = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for k in keys {
            for v in (try? fm.contentsOfDirectory(at: k, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                var bytes: Int64 = 0
                for f in (try? fm.contentsOfDirectory(at: v, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                    bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                let used = (try? v.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                out.append((v, bytes, used))
            }
        }
        return out
    }

    /// Everything kept, in bytes (downloads midway included).
    public func totalBytes() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return entries().reduce(0) { $0 + $1.bytes }
    }

    /// Least recently used first, until the total is under the cap; `keep`
    /// (folders by path) are never removed.
    public func evict(keep: Set<String> = []) {
        lock.lock(); defer { lock.unlock() }
        evictLocked(keep: keep)
    }

    private func evictLocked(keep: Set<String>) {
        var all = entries()
        var total = all.reduce(0) { $0 + $1.bytes }
        guard total > capBytes else { return }
        all.sort { $0.used < $1.used }
        for e in all where total > capBytes && !keep.contains(e.dir.standardizedFileURL.path) {
            try? fm.removeItem(at: e.dir)
            total -= e.bytes
            debugLog("[files] cache: evicted \(e.dir.lastPathComponent) (\(e.bytes) bytes), \(total) left of \(capBytes)")
        }
        // Folders of files left empty.
        for k in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where ((try? fm.contentsOfDirectory(atPath: k.path)) ?? []).isEmpty {
            try? fm.removeItem(at: k)
        }
    }

    /// Everything kept goes, except the folders in `keep` (downloads under way).
    public func clear(keep: Set<String> = []) {
        lock.lock(); defer { lock.unlock() }
        for k in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let versions = (try? fm.contentsOfDirectory(at: k, includingPropertiesForKeys: nil)) ?? []
            if versions.contains(where: { keep.contains($0.standardizedFileURL.path) }) {
                for v in versions where !keep.contains(v.standardizedFileURL.path) { try? fm.removeItem(at: v) }
            } else {
                try? fm.removeItem(at: k)
            }
        }
    }
}

// MARK: - the downloader

/// Downloads a file into the cache: the first chunk alone (it tells the
/// size and how big a chunk the computer sends), then up to `parallel`
/// chunks in flight, written to the file in order as they come, so at most
/// a few chunks are ever in memory. Two openers of one file share one
/// download; it stops when the last of them stops waiting.
public actor FileFetcher {
    public static let shared = FileFetcher(cache: .shared)

    public nonisolated let cache: FileCache
    /// Bytes asked for per request (the computer sends up to 1 MiB with `stream`).
    public var chunkSize: Int64
    /// Requests in flight at once.
    public var parallel: Int

    private final class Job {
        var task: Task<URL, Error>?
        var observers: [UUID: DownloadProgress] = [:]
        var last: (Int64, Int64) = (0, 0)
    }
    private var jobs: [String: Job] = [:]

    public init(cache: FileCache, chunkSize: Int64 = 1024 * 1024, parallel: Int = 4) {
        self.cache = cache
        self.chunkSize = chunkSize
        self.parallel = parallel
    }

    public func configure(chunkSize: Int64, parallel: Int) {
        self.chunkSize = max(1, chunkSize)
        self.parallel = max(1, parallel)
    }

    /// The folders being downloaded into now (kept by `clear`).
    public func downloading() -> Set<String> { Set(jobs.keys) }

    /// Clears the cache, leaving downloads under way alone.
    public func clearCache() {
        cache.clear(keep: downloading())
    }

    /// The file of that version on the device: from the cache at once, or
    /// downloaded (resuming a download stopped midway). `size`: when known
    /// beforehand (the first chunk says it otherwise).
    public func fetch(key: String, version: String, name: String, size: Int64? = nil,
                      read: @escaping RemoteChunkReader, progress: DownloadProgress? = nil) async throws -> URL {
        if let url = cache.cached(key: key, version: version, name: name) { return url }
        let id = cache.directory(key: key, version: version).standardizedFileURL.path
        let job: Job
        if let j = jobs[id] {
            job = j
        } else {
            job = Job()
            jobs[id] = job
            job.task = Task { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.run(id: id, key: key, version: version, name: name, size: size, read: read)
            }
        }
        let token = UUID()
        if let progress {
            job.observers[token] = progress
            if job.last.1 > 0 { progress(job.last.0, job.last.1) }
        }
        defer { leave(id, token, cancel: false) }
        guard let task = job.task else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.leave(id, token, cancel: true) }
        }
    }

    /// An opener stopped waiting: the download stops with the last one.
    private func leave(_ id: String, _ token: UUID, cancel: Bool) {
        guard let job = jobs[id] else { return }
        job.observers[token] = nil
        if cancel, job.observers.isEmpty {
            job.task?.cancel()
            jobs[id] = nil
        }
    }

    private func report(_ id: String, _ received: Int64, _ total: Int64) {
        guard let job = jobs[id] else { return }
        job.last = (received, total)
        for o in job.observers.values { o(received, total) }
    }

    private func run(id: String, key: String, version: String, name: String, size: Int64?,
                     read: @escaping RemoteChunkReader) async throws -> URL {
        defer { jobs[id] = nil }
        let fm = FileManager.default
        let dir = cache.directory(key: key, version: version)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let part = cache.partURL(key: key, version: version, name: name)
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        var written = Int64(try handle.seekToEnd())
        let resumedAt = written
        var total = size ?? -1
        let began = Date()
        if total >= 0 { report(id, written, total) }

        func check(_ c: RemoteChunk) throws {
            if c.tooLarge { throw FileStreamTooLarge(size: c.size) }
            if let v = c.version, v != version {
                try? fm.removeItem(at: dir)
                throw RemoteFileChanged(version: v)
            }
        }

        // The first chunk alone: it gives the size, and how much the
        // computer sends at a time (an older one: 256 KiB, whatever is asked).
        var step = chunkSize
        if total < 0 || written < total {
            try Task.checkCancellation()
            let first = try await read(written, chunkSize)
            try check(first)
            total = first.size
            if !first.data.isEmpty { try handle.write(contentsOf: first.data) }
            written += Int64(first.data.count)
            if Int64(first.data.count) < chunkSize, written < total, !first.data.isEmpty { step = Int64(first.data.count) }
            report(id, written, total)
            if first.data.isEmpty, written < total { throw RemoteFileIncomplete(received: written, size: total) }
        }

        // The rest: several in flight, written in order.
        if written < total {
            let parallel = parallel
            let start = written
            try await withThrowingTaskGroup(of: (Int64, Int64, RemoteChunk).self) { group in
                var next = start
                var pending: [Int64: Data] = [:]
                func ask() {
                    guard next < total else { return }
                    let offset = next
                    let length = min(step, total - offset)
                    next += length
                    group.addTask { (offset, length, try await read(offset, length)) }
                }
                for _ in 0..<parallel { ask() }
                while let (offset, length, chunk) = try await group.next() {
                    try Task.checkCancellation()
                    try check(chunk)
                    var data = chunk.data
                    // Fewer bytes than asked: the rest of this span, here.
                    while Int64(data.count) < length {
                        let more = try await read(offset + Int64(data.count), length - Int64(data.count))
                        try check(more)
                        if more.data.isEmpty { throw RemoteFileIncomplete(received: written, size: total) }
                        data.append(more.data)
                    }
                    pending[offset] = data
                    while let d = pending.removeValue(forKey: written) {
                        try handle.write(contentsOf: d)
                        written += Int64(d.count)
                    }
                    report(id, written, total)
                    ask()
                }
            }
        }
        guard written == total else { throw RemoteFileIncomplete(received: written, size: total) }
        try handle.close()
        let url = try cache.complete(key: key, version: version, name: name, size: total, keep: Set(jobs.keys))
        let seconds = Date().timeIntervalSince(began)
        debugLog("[files] downloaded \(FileCache.safeName(name)): \(total - resumedAt) bytes in \(String(format: "%.2f", seconds)) s"
                 + (resumedAt > 0 ? " (resumed at \(resumedAt))" : "") + ", chunk \(step), \(parallel) at once")
        return url
    }
}
