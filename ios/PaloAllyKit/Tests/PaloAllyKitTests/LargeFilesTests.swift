import Darwin
import Foundation
import Testing
@testable import PaloAllyKit

/// Files downloaded to the device's disk (docs/large-files-design.md): in
/// chunks straight to a file, several at once, resumed, kept by version,
/// trimmed least recently used first; never the whole file in memory.
@Suite("Large files")
@MainActor
struct LargeFilesTests {
    /// A cache of its own in a temp folder.
    static func fetcher(cap: Int64 = 1024 * 1024 * 1024, chunk: Int64 = 1024 * 1024) -> FileFetcher {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("large-files-test-\(UUID().uuidString)", isDirectory: true)
        return FileFetcher(cache: FileCache(root: root, capBytes: cap), chunkSize: chunk, parallel: 4)
    }

    /// A file of `size` bytes, made up as it's read (byte i is i % 251), and
    /// what was asked of it.
    final class FakeFile: @unchecked Sendable {
        let size: Int64
        let hostCap: Int64
        var version: String?
        let lock = NSLock()
        var asked: [(Int64, Int64)] = []
        var inFlight = 0
        var maxInFlight = 0
        /// Fails each read at or past this offset (a dropped link).
        var failFrom: Int64?
        /// Called with each read (a memory probe).
        var onRead: (@Sendable () -> Void)?

        init(size: Int64, hostCap: Int64 = 1024 * 1024, version: String? = nil) {
            self.size = size; self.hostCap = hostCap; self.version = version
        }

        /// Byte i of any fake file is i % 251: a run of that pattern, sliced.
        static let pattern: Data = Data((0..<(2 * 1024 * 1024 + 251)).map { UInt8($0 % 251) })

        static func bytes(at offset: Int64, count: Int64) -> Data {
            var out = Data(capacity: Int(count))
            var at = offset
            while at < offset + count {
                let start = Int(at % 251)
                let n = min(Int(offset + count - at), pattern.count - start)
                out.append(pattern.subdata(in: start..<(start + n)))
                at += Int64(n)
            }
            return out
        }

        func expected() -> Data { Self.bytes(at: 0, count: size) }

        var reader: RemoteChunkReader {
            { offset, length in
                let fail: Bool = self.lock.withLock {
                    self.asked.append((offset, length))
                    self.inFlight += 1
                    self.maxInFlight = max(self.maxInFlight, self.inFlight)
                    return self.failFrom.map { offset >= $0 } ?? false
                }
                try? await Task.sleep(for: .milliseconds(2))
                self.onRead?()
                defer { self.lock.withLock { self.inFlight -= 1 } }
                if fail { throw URLError(.networkConnectionLost) }
                let n = max(0, min(length, self.hostCap, self.size - offset))
                let d = Self.bytes(at: offset, count: n)
                let version = self.lock.withLock { self.version }
                return RemoteChunk(data: d, size: self.size, eof: offset + n >= self.size, version: version)
            }
        }
    }

    @Test func downloadsInOrderWithFourInFlightAndOneMiBChunks() async throws {
        let f = Self.fetcher()
        let file = FakeFile(size: 9 * 1024 * 1024 + 123)
        let url = try await f.fetch(key: "k", version: "v1", name: "a.pdf", read: file.reader)
        #expect(url.lastPathComponent == "a.pdf")
        #expect(try Data(contentsOf: url) == file.expected())
        #expect(file.maxInFlight == 4)
        #expect(file.asked.allSatisfy { $0.1 <= 1024 * 1024 })
        #expect(file.asked.count == 10)
        // No `.part` left beside it.
        #expect(!FileManager.default.fileExists(atPath: url.path + ".part"))
    }

    @Test func anOlderHostsSmallerChunksStillMakeTheWholeFile() async throws {
        let f = Self.fetcher()
        let file = FakeFile(size: 3 * 1024 * 1024 + 5, hostCap: 256 * 1024)
        let url = try await f.fetch(key: "k", version: "v1", name: "a.bin", read: file.reader)
        #expect(try Data(contentsOf: url) == file.expected())
        // After the first answer, asked in its size.
        #expect(file.asked.dropFirst().allSatisfy { $0.1 <= 256 * 1024 })
    }

    @Test func aSecondOpenOfTheSameVersionAsksNothing() async throws {
        let f = Self.fetcher()
        let file = FakeFile(size: 2 * 1024 * 1024)
        let first = try await f.fetch(key: "k", version: "v1", name: "a.pdf", read: file.reader)
        let asked = file.asked.count
        let again = try await f.fetch(key: "k", version: "v1", name: "a.pdf", read: file.reader)
        #expect(again == first)
        #expect(file.asked.count == asked)
        // A new version: downloaded again, and the old one goes.
        let second = try await f.fetch(key: "k", version: "v2", name: "a.pdf", read: file.reader)
        #expect(second != first)
        #expect(file.asked.count > asked)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(f.cache.latest(key: "k")?.version == "v2")
    }

    @Test func aStoppedDownloadResumesFromTheBytesOnDisk() async throws {
        let f = Self.fetcher()
        let file = FakeFile(size: 6 * 1024 * 1024)
        file.failFrom = 3 * 1024 * 1024
        await #expect(throws: URLError.self) {
            try await f.fetch(key: "k", version: "v1", name: "a.bin", read: file.reader)
        }
        // What came in order before the failure is kept (at least the first chunk).
        let kept = f.cache.partialLength(key: "k", version: "v1", name: "a.bin")
        #expect(kept >= 1024 * 1024 && kept <= 3 * 1024 * 1024 && kept % (1024 * 1024) == 0)
        file.failFrom = nil
        file.asked = []
        let url = try await f.fetch(key: "k", version: "v1", name: "a.bin", read: file.reader)
        #expect(try Data(contentsOf: url) == file.expected())
        // Nothing before what was kept was asked again.
        #expect(file.asked.allSatisfy { $0.0 >= kept })
    }

    @Test func aFileChangedMidwayIsDroppedNotMixed() async throws {
        let f = Self.fetcher()
        let file = FakeFile(size: 4 * 1024 * 1024, version: "v2")
        await #expect(throws: RemoteFileChanged.self) {
            try await f.fetch(key: "k", version: "v1", name: "a.bin", read: file.reader)
        }
        #expect(f.cache.partialLength(key: "k", version: "v1", name: "a.bin") == 0)
    }

    @Test func leastRecentlyUsedGoesFirstAndOneOverTheCapStaysUntilTheNext() async throws {
        let mb: Int64 = 1024 * 1024
        let f = Self.fetcher(cap: 5 * mb)
        let a = try await f.fetch(key: "a", version: "1", name: "a", read: FakeFile(size: 2 * mb).reader)
        try await Task.sleep(for: .milliseconds(20))
        let b = try await f.fetch(key: "b", version: "1", name: "b", read: FakeFile(size: 2 * mb).reader)
        try await Task.sleep(for: .milliseconds(20))
        // a is opened again: b is now the least recently used.
        #expect(f.cache.cached(key: "a", version: "1", name: "a") == a)
        try await Task.sleep(for: .milliseconds(20))
        let c = try await f.fetch(key: "c", version: "1", name: "c", read: FakeFile(size: 2 * mb).reader)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(FileManager.default.fileExists(atPath: c.path))
        #expect(f.cache.totalBytes() <= 5 * mb + 4096)
        // One file bigger than the whole cap: kept and opened all the same...
        try await Task.sleep(for: .milliseconds(20))
        let huge = try await f.fetch(key: "h", version: "1", name: "h", read: FakeFile(size: 7 * mb).reader)
        #expect(FileManager.default.fileExists(atPath: huge.path))
        // ...and the first to go at the next download.
        try await Task.sleep(for: .milliseconds(20))
        let d = try await f.fetch(key: "d", version: "1", name: "d", read: FakeFile(size: 1 * mb).reader)
        #expect(!FileManager.default.fileExists(atPath: huge.path))
        #expect(FileManager.default.fileExists(atPath: d.path))
    }

    @Test func clearingLeavesADownloadUnderWayAlone() async throws {
        let f = Self.fetcher()
        _ = try await f.fetch(key: "a", version: "1", name: "a", read: FakeFile(size: 1024).reader)
        let slow = FakeFile(size: 3 * 1024 * 1024)
        let gate = AsyncStream<Void>.makeStream()
        slow.onRead = { gate.continuation.yield() }
        let running = Task { try await f.fetch(key: "s", version: "1", name: "s", read: slow.reader) }
        var it = gate.stream.makeAsyncIterator()
        _ = await it.next()
        await f.clearCache()
        #expect(f.cache.cached(key: "a", version: "1", name: "a") == nil)
        let url = try await running.value
        #expect(try Data(contentsOf: url) == slow.expected())
    }

    /// The process's memory footprint (what iOS counts against an app).
    nonisolated static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// The footprint is the whole process's (other tests run beside this
    /// one): the least growth over a few runs is this download's own. A file
    /// held whole would add its 30 MB on every run.
    @Test func aThirtyMegabyteFileNeverSitsInMemory() async throws {
        let size: Int64 = 30 * 1024 * 1024
        _ = FakeFile.pattern
        final class Peak: @unchecked Sendable { var value: Int64 = 0; let lock = NSLock() }
        var least = Int64.max
        for run in 0..<3 {
            let f = Self.fetcher()
            let file = FakeFile(size: size)
            let base = Self.footprint()
            let peak = Peak()
            file.onRead = { let now = Self.footprint(); peak.lock.withLock { peak.value = max(peak.value, now) } }
            let url = try await f.fetch(key: "big", version: "\(run)", name: "big.pdf", read: file.reader)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attrs[.size] as? NSNumber)?.int64Value == size)
            least = min(least, peak.value - base)
            try? FileManager.default.removeItem(at: f.cache.root)
        }
        print("[large-files] 30 MB download: peak extra footprint \(least / 1024) KiB")
        // A few 1 MiB chunks in flight at most, never the 30 MB.
        #expect(least < 20 * 1024 * 1024, "peak extra memory \(least) bytes")
    }

    @Test func throughTheDemoHostAFileAnItemAndASentFile() async throws {
        let host = DemoHost(speed: 0, pals: true)
        let store = AppStore(transport: host.transport)
        store.fileFetcher = Self.fetcher()
        store.fileCacheHost = "demo"
        store.start()
        #expect(await until { store.connection == .online && store.pals.count == 4 && !store.artifacts.isEmpty })
        let pal = try #require(await host.pals.first)
        // A computer file over 5 MB: asked for its version, then downloaded.
        let source = RemoteFileSource.file(scope: .pal(pal.id), path: "docs/大文件示例.pdf")
        var seen: [(Int64, Int64)] = []
        let url = try await store.downloadFile(source, name: "大文件示例.pdf") { seen.append(($0, $1)) }
        #expect(url.lastPathComponent == "大文件示例.pdf")
        #expect(try Data(contentsOf: url) == DemoHost.bigDemoPDF)
        let reads = await host.requestLog.filter { $0 == RPCMethod.filesRead }.count
        #expect(reads == 1 + (DemoHost.bigDemoPDF.count + 1024 * 1024 - 1) / (1024 * 1024))
        #expect(await until { seen.last?.0 == Int64(DemoHost.bigDemoPDF.count) })
        // Again: one probe, no download; with its version known, nothing at all.
        let latest = try #require(store.latestCachedFile(source))
        #expect(try await store.downloadFile(source, name: "大文件示例.pdf") == url)
        #expect(await host.requestLog.filter { $0 == RPCMethod.filesRead }.count == reads + 1)
        #expect(store.cachedFile(source, name: "大文件示例.pdf", version: latest.version) == url)
        // A library item: its version from the list, so a second open asks nothing.
        let ar = try #require(store.artifact(id: "ar10"))
        let item = RemoteFileSource.artifact(id: ar.id, path: ar.mainFile)
        let itemURL = try await store.downloadFile(item, name: ar.mainFile)
        let itemReads = await host.requestLog.filter { $0 == RPCMethod.artifactRead }.count
        #expect(store.cachedFile(item, name: ar.mainFile) == itemURL)
        #expect(try await store.downloadFile(item, name: ar.mainFile) == itemURL)
        #expect(await host.requestLog.filter { $0 == RPCMethod.artifactRead }.count == itemReads)
        #expect(await host.lastParams[RPCMethod.artifactRead]?["stream"]?.boolValue == true)
    }

    @Test func streamParamsEncodeOnlyWhenSet() throws {
        let plain = String(decoding: try JSONEncoder().encode(ArtifactReadParams(id: "a", path: nil, offset: 0, length: 1)), as: UTF8.self)
        #expect(!plain.contains("stream"))
        let streamed = String(decoding: try JSONEncoder().encode(MediaReadParams(id: "m", offset: 0, length: 1, stream: true)), as: UTF8.self)
        #expect(streamed.contains(#""stream":true"#))
    }
}
