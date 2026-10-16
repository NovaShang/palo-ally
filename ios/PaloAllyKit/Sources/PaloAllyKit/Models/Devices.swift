import Foundation

/// One of the owner's devices paired with the computer (`device.list`,
/// docs/devices-prd.md): what it's called, which app it is (once it has
/// connected since), when it was last there, and whether it's the one asking.
public struct PairedDevice: Codable, Sendable, Hashable, Identifiable {
    public var deviceId: String
    public var label: String
    /// "ios" or "mac"; nil until its app has said hello since.
    public var platform: String?
    public var pairedAt: Int64
    public var lastSeen: Int64?
    public var online: Bool
    /// This very device.
    public var current: Bool
    public var id: String { deviceId }

    public init(deviceId: String, label: String, platform: String? = nil, pairedAt: Int64, lastSeen: Int64? = nil,
                online: Bool = false, current: Bool = false) {
        self.deviceId = deviceId; self.label = label; self.platform = platform; self.pairedAt = pairedAt
        self.lastSeen = lastSeen; self.online = online; self.current = current
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        deviceId = l.string("deviceId", or: "")
        label = l.string("label", or: "设备")
        platform = l.string("platform")
        pairedAt = l.millis("pairedAt", or: 0)
        lastSeen = l.millis("lastSeen")
        online = l.bool("online", or: false)
        current = l.bool("current", or: false)
    }
}

/// `device.list` → `{devices}`.
public struct DevicesResult: Codable, Sendable {
    public var devices: [PairedDevice]
    public init(devices: [PairedDevice]) { self.devices = devices }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        devices = l.array(PairedDevice.self, "devices", or: [])
    }
}

/// `device.remove {deviceId}` → `{ok}`.
public struct DeviceRemoveParams: Codable, Sendable {
    public var deviceId: String
    public init(deviceId: String) { self.deviceId = deviceId }
}
