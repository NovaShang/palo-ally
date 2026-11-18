import CryptoKit
import Foundation
#if targetEnvironment(macCatalyst)
import IOKit
#endif

/// The Mac: which machine the app runs on, hashed exactly as the host hashes
/// its own (host/src/machine.ts), so a computer whose host runs on this Mac
/// is told apart from the others and listed first in the sidebar.
///
/// The identity is the hardware UUID (IOPlatformUUID), read from the I/O
/// Registry: the sandbox lets an app read IOPlatformExpertDevice's
/// properties (no entitlement), it doesn't change with the computer's name
/// or network, and it is the same value `ioreg` gives the host. Should the
/// read fail, `matches` falls back to the computer's name as the host
/// reports it, which is its network name unless the owner renamed it.
/// Phones and iPads have none (no computer of theirs runs a host).
enum MachineIdentity {
    /// The hash both sides make: hex SHA-256 of a fixed prefix and the id, 32 characters.
    static func hash(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data("paloally-machine:\(raw)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// This Mac's hashed hardware UUID (nil on phones and iPads, or if it can't be read).
    static let local: String? = platformUUID().map(hash)

    /// Whether a computer (its hashed machine id from `hello`, its name)
    /// is this one.
    @MainActor static func matches(machineID: String?, hostName: String) -> Bool {
        guard Platform.isMac else { return false }
        if let local, let machineID, !machineID.isEmpty { return machineID == local }
        // No hardware id on one side: the name, as the host's default has it.
        let name = normalized(hostName)
        return !name.isEmpty && name == localName
    }

    /// The computer's name, lowercased and without `.local` (the host's default name).
    static func normalized(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if n.hasSuffix(".local") { n.removeLast(6) }
        return n
    }

    /// This Mac's network name, read off the main thread at launch
    /// (`ProcessInfo.hostName` can wait on DNS); empty until then.
    @MainActor private(set) static var localName = ""

    @MainActor static func loadName() async {
        guard Platform.isMac, localName.isEmpty else { return }
        let name = await Task.detached(priority: .utility) { ProcessInfo.processInfo.hostName }.value
        localName = normalized(name)
    }

    private static func platformUUID() -> String? {
        #if targetEnvironment(macCatalyst)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        return value?.uppercased()
        #else
        return nil
        #endif
    }
}
