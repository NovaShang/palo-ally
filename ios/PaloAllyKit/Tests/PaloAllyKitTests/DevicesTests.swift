import Foundation
import Testing
@testable import PaloAllyKit

/// 电脑与设备 (docs/devices-prd.md): the owner's devices paired with the
/// computer, this one first, and taking another off.
@Suite("Devices")
@MainActor
struct DevicesTests {
    @Test func decodesAsTheHostSendsIt() throws {
        let json = #"{"devices":[{"deviceId":"dev-a","label":"iPhone","platform":"ios","pairedAt":1,"lastSeen":2,"online":true,"current":true},{"deviceId":"dev-b","label":"Mac","pairedAt":3,"online":false,"current":false}]}"#
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let (r, issues) = try LenientDiagnostics.collect { try v.decode(DevicesResult.self) }
        #expect(issues.isEmpty)
        #expect(r.devices.map(\.deviceId) == ["dev-a", "dev-b"])
        #expect(r.devices[0].current && r.devices[0].platform == "ios" && r.devices[0].lastSeen == 2)
        #expect(r.devices[1].platform == nil && r.devices[1].lastSeen == nil)
    }

    @Test func listsThisDeviceFirstAndTakesAnotherOff() async throws {
        let host = DemoHost(speed: 0)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        let devices = try await store.listDevices()
        #expect(devices.first?.current == true)
        #expect(devices.count == 3)
        try await store.removeDevice(id: "dev-ipad")
        #expect(try await store.listDevices().map(\.deviceId) == ["dev-this", "dev-imac"])
        // Never this one: that's unpairing.
        await #expect(throws: (any Error).self) { try await store.removeDevice(id: "dev-this") }
        let params = try #require(await host.lastParams["device.remove"])
        #expect(params["deviceId"] == "dev-this")
    }
}
