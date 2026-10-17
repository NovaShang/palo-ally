import Foundation

/// Version strings, for telling the Mac app it is behind the computer's host.
///
/// The host updates itself to each release, so the version it reports is the
/// latest release in practice. It reports a bare `0.1.9`, or `0.1.9+4` / `0.1.9-dev`
/// on a development checkout. Only plain x.y.z (an optional leading `v`
/// tolerated) is compared; anything else is ignored.
public enum AppVersion {
    /// The numbers of a plain `x.y.z` (or `vx.y.z`), else nil.
    public static func parse(_ s: String) -> [Int]? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    /// `a` is semver-greater than `b`; false when either isn't plain x.y.z.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        return x.lexicographicallyPrecedes(y) ? false : x != y
    }

    /// The host's version when the app (`app`) is behind it and the owner hasn't
    /// dismissed that version (or a newer one); else nil. Returned without a "v".
    public static func updateHint(app: String, host: String, dismissed: String = "") -> String? {
        guard isNewer(host, than: app), let h = parse(host) else { return nil }
        if !dismissed.isEmpty, parse(dismissed) != nil, !isNewer(host, than: dismissed) { return nil }
        return h.map(String.init).joined(separator: ".")
    }
}
