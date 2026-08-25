import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

private actor Wave9FailingActionTransport: DeviceSyncTransport {
    nonisolated let role: NADeviceRole = .mac
    func send(_ message: BridgeMessage) async throws {
        throw DeviceSyncError.transient(message: "injected action-send failure")
    }
    func observeIncoming(_ onMessage: @escaping @Sendable (BridgeMessage) async -> Bool) async {}
    func publishPairing(secret: Data) async throws {}
    func observePairing(onChange: @escaping @Sendable (Data) async -> Bool) async {}
    func setStatus(key: String, value: String) async throws {}
    func observeStatus(key: String, onChange: @escaping @Sendable (String) async -> Void) async {}
}

@Suite("Wave 9 bridge failure truth", .serialized)
struct BridgeMacBackgroundWave9FailureTests {
    @Test("a CloudKit response failure replaces prior success status with resend truth")
    @MainActor
    func cloudKitActionSendFailureDoesNotLeaveStaleSuccess() async {
        let bridge = iCloudBridge(
            testDeviceTransport: Wave9FailingActionTransport(),
            testPairingSecret: Data(repeating: 7, count: 32)
        )
        defer { bridge.tearDown() }

        await #expect(throws: DeviceSyncError.self) {
            try await bridge.sendCloudKitActionResponse(["status": "completed"], correlationID: "wave9")
        }
        #expect(bridge.syncStatus.contains("waiting to resend"))
    }

    // EVAL FENCE: app.bridges / icloud.publishPairingSecret
    @Test("each pairing publication route reports its own failure instead of a clean regeneration")
    func pairingPublicationReportsEverySingleRouteFailure() {
        #expect(PairingPublicationPresentation.error(kvsPublished: true, cloudKitPublished: true) == nil)
        #expect(PairingPublicationPresentation.error(kvsPublished: false, cloudKitPublished: true)?.contains("KVS did not accept") == true)
        #expect(PairingPublicationPresentation.error(kvsPublished: true, cloudKitPublished: false)?.contains("CloudKit did not accept") == true)
        let bothFailed = PairingPublicationPresentation.error(kvsPublished: false, cloudKitPublished: false)
        #expect(bothFailed?.contains("neither KVS nor CloudKit") == true)
    }
}
