import Foundation

extension DemoHost {
    /// Made-up devices of the owner's, paired earlier.
    static func demoDevices() -> [PairedDevice] {
        let now = Date().epochMillis
        return [
            PairedDevice(deviceId: "dev-ipad", label: "iPad", platform: "ios", pairedAt: now - 40 * 86_400_000,
                         lastSeen: now - 2 * 86_400_000),
            PairedDevice(deviceId: "dev-imac", label: "书房的 iMac", platform: "mac", pairedAt: now - 20 * 86_400_000,
                         lastSeen: now - 3 * 3_600_000, online: true),
        ]
    }

    /// device.list / device.remove, as the host has them: this device first.
    func dispatchDevices(_ method: String, _ p: JSONValue) throws -> JSONValue? {
        switch method {
        case RPCMethod.deviceList:
            let mac = helloClient == "mac"
            let me = PairedDevice(deviceId: "dev-this", label: mac ? "MacBook Pro" : "iPhone", platform: helloClient,
                                  pairedAt: Date().epochMillis - 60 * 86_400_000, lastSeen: Date().epochMillis,
                                  online: true, current: true)
            return try .from(DevicesResult(devices: [me] + otherDevices))
        case RPCMethod.deviceRemove:
            let id = p["deviceId"]?.stringValue ?? ""
            guard id != "dev-this" else { throw DemoError(message: "这是你正在用的这台，要断开它请用「解除配对」") }
            guard otherDevices.contains(where: { $0.deviceId == id }) else { throw DemoError(message: "没有这台设备") }
            otherDevices.removeAll { $0.deviceId == id }
            return ["ok": true]
        default:
            return nil
        }
    }
}
