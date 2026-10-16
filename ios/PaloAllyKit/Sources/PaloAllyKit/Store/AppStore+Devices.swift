import Foundation

/// The owner's devices paired with this computer (docs/devices-prd.md):
/// listed on 电脑与设备, another one taken off there.
extension AppStore {
    /// Every device paired with this computer, this one first.
    public func listDevices() async throws -> [PairedDevice] {
        let r: DevicesResult = try await rpc.call(RPCMethod.deviceList, params: EmptyParams())
        return r.devices
    }

    /// Another of the owner's devices stops being paired with this computer.
    public func removeDevice(id: String) async throws {
        let _: OKResult = try await rpc.call(RPCMethod.deviceRemove, params: DeviceRemoveParams(deviceId: id))
    }
}
