import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

@Suite("iCloud device transport selection")
struct ICloudDeviceTransportSelectionEvalTests {
    @MainActor
    @Test("an injected transport remains usable without claiming production CloudKit selection")
    func injectedTransportDoesNotMasqueradeAsCloudKit() {
        let transport = MockDeviceSyncTransport(role: .mac)
        let bridge = iCloudBridge(testDeviceTransport: transport)
        defer { bridge.tearDown() }

        #expect(bridge.deviceTransportSelection == .injectedForTesting)
        #expect(!bridge.usesCloudKitDeviceTransport)
    }

    @MainActor
    @Test("teardown clears the selected transport origin before a later setup can resolve again")
    func teardownRestoresLegacySelection() {
        let bridge = iCloudBridge(testDeviceTransport: MockDeviceSyncTransport(role: .mac))
        #expect(bridge.deviceTransportSelection == .injectedForTesting)

        bridge.tearDown()

        #expect(bridge.deviceTransportSelection == .legacyKVS)
        #expect(!bridge.usesCloudKitDeviceTransport)
    }

    @Test("only the entitlement-checked origin is treated as CloudKit")
    func cloudKitStatusIsOriginSpecific() {
        #expect(ICloudDeviceTransportSelection.cloudKit.isCloudKit)
        #expect(!ICloudDeviceTransportSelection.legacyKVS.isCloudKit)
        #expect(!ICloudDeviceTransportSelection.injectedForTesting.isCloudKit)
    }
}
