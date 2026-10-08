import Foundation

/// The app's debug.log in the simulator (each launch starts a new one).
struct AppLog {
    let url: URL?

    init() {
        let fm = FileManager.default
        let root = ProcessInfo.processInfo.environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("Containers/Data/Application")
        }
        let logs = (root.flatMap { try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? [])
            .map { $0.appendingPathComponent("Documents/debug.log") }
            .filter { fm.fileExists(atPath: $0.path) }
        url = logs.max { a, b in
            let da = (try? fm.attributesOfItem(atPath: a.path)[.modificationDate] as? Date) ?? .distantPast
            let db = (try? fm.attributesOfItem(atPath: b.path)[.modificationDate] as? Date) ?? .distantPast
            return da < db
        }
    }

    var text: String { url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "" }

    func count(_ s: String) -> Int { text.components(separatedBy: s).count - 1 }

    func lines(containing any: [String]) -> [String] {
        text.split(separator: "\n").map(String.init).filter { l in any.contains { l.contains($0) } }
    }

    func wait(timeout: TimeInterval, until ok: (AppLog) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok(self) { return true }
            usleep(50_000)
        }
        return false
    }

    // MARK: timed entries

    struct Entry {
        let time: Date
        let line: String
    }

    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Lines with their time stamps (`[2026-10-08T05:59:35.585Z] [File:1] …`).
    func entries(containing any: [String]) -> [Entry] {
        lines(containing: any).compactMap { l in
            guard l.hasPrefix("["), let close = l.firstIndex(of: "]"),
                  let t = Self.stamp.date(from: String(l[l.index(after: l.startIndex)..<close]))
            else { return nil }
            return Entry(time: t, line: l)
        }
    }

    /// The first number before " ms" / " pt" in a line.
    static func number(before unit: String, in line: String) -> Int? {
        guard let r = line.range(of: #"-?\d+ "# + unit, options: .regularExpression) else { return nil }
        return Int(line[r].split(separator: " ")[0])
    }

    // MARK: scroll

    /// `[top] mN` lines (`-topRowTrace YES`): the message under the top of the view.
    func topRows() -> [Int] {
        lines(containing: ["[top] m"]).compactMap { l in
            l.range(of: #"\[top\] m\d+$"#, options: .regularExpression).flatMap { Int(l[$0].dropFirst(7)) }
        }
    }

    func topRow() -> Int? { topRows().last }

    /// The distance from the end in the last `[pin]` line (`-pinTrace YES`).
    func distance() -> Int? {
        guard let l = lines(containing: ["[pin]"]).last else { return nil }
        return Self.number(before: "pt from the end", in: l)
    }

    /// The last `[jump] <when>: N pt from the end[ (gliding, closest M in
    /// 0.5 s)], pinned B` line. On the end: within 13 pt, or, while a reply
    /// streaming in has the view gliding onto the end, within two lines (60
    /// pt) at some point in the last half second: at the stress demo's pace
    /// (150 characters a second) new lines come faster than a glide ends,
    /// and following trails the end by a line or two all along.
    func lastJump(_ when: String) -> (distance: Int, pinned: Bool, onTheEnd: Bool)? {
        guard let l = lines(containing: ["[jump] \(when):"]).last,
              let d = Self.number(before: "pt from the end", in: l)
        else { return nil }
        guard let r = l.range(of: #"closest \d+"#, options: .regularExpression), let closest = Int(l[r].dropFirst(8)) else {
            return (d, l.hasSuffix("pinned true"), d <= 13)
        }
        return (d, l.hasSuffix("pinned true"), min(d, closest) <= 60)
    }

    /// `[stall] main thread was stuck N ms` entries.
    func stalls() -> [(time: Date, ms: Int)] {
        entries(containing: ["[stall] main thread was stuck"]).compactMap { e in
            Self.number(before: "ms", in: e.line).map { (e.time, $0) }
        }
    }

    /// `[geo] h=… y=… vis=a-b inset=t,b` lines (`-scrollTrace YES`) as
    /// (height, offset, distance from the end).
    func geometry() -> [(h: Int, y: Int, distance: Int)] {
        lines(containing: ["[geo] h="]).compactMap { l in
            func int(_ pattern: String, drop: Int) -> Int? {
                l.range(of: pattern, options: .regularExpression).flatMap { Int(l[$0].dropFirst(drop)) }
            }
            guard let h = int(#"h=-?\d+"#, drop: 2), let y = int(#" y=-?\d+"#, drop: 3),
                  let visMax = int(#"-\d+ inset"#, drop: 1),
                  let insetBottom = int(#",\d+$"#, drop: 1)
            else { return nil }
            return (h, y, h - (visMax - insetBottom))
        }
    }
}
