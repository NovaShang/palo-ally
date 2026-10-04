import Foundation

extension Data {
    /// base64url without padding (RFC 4648 §5).
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes base64url OR standard base64, with or without padding.
    public init?(base64URLEncoded s: String) {
        var b64 = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64) else { return nil }
        self = d
    }

    public init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func nib(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nib(chars[i]), let lo = nib(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }

    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// SSH wire-format helpers. An Ed25519 public key on the wire is
/// `[u32 11]"ssh-ed25519"[u32 32][raw 32 bytes]` (51 bytes).
public enum SSHWire {
    public static func ed25519PublicKey(raw: Data) -> Data {
        var out = Data()
        out.append(string(Data("ssh-ed25519".utf8)))
        out.append(string(raw))
        return out
    }

    /// Inverse of `ed25519PublicKey`. Returns nil on any malformation.
    public static func rawEd25519(fromWire wire: Data) -> Data? {
        let b = [UInt8](wire)
        guard b.count >= 51 else { return nil }
        func u32(_ at: Int) -> Int { Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) }
        guard u32(0) == 11, String(bytes: b[4..<15], encoding: .ascii) == "ssh-ed25519", u32(15) == 32 else { return nil }
        return Data(b[19..<51])
    }

    private static func string(_ d: Data) -> Data {
        var out = Data()
        let n = UInt32(d.count)
        out.append(contentsOf: [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        out.append(d)
        return out
    }
}
