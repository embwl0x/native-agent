import CryptoKit
import Foundation
import Testing
import NativeAgentShared
@testable import NativeAgentApp

@Suite("Phone approval identity", .serialized)
@MainActor
struct PairedPhoneStoreTests {
    private func signed(_ key: Curve25519.Signing.PrivateKey) throws -> InboxAction {
        var action = InboxAction(
            msgId: UUID().uuidString,
            clientId: DeviceApprovalSignature.deviceID(publicKey: key.publicKey.rawRepresentation),
            action: "approveApproval", payload: ["approvalId": "approval-one"],
            createdAt: ISO8601DateFormatter().string(from: Date()),
            devicePublicKey: key.publicKey.rawRepresentation.base64EncodedString()
        )
        action.deviceSignature = try key.signature(for: DeviceApprovalSignature.canonicalBody(JSONEncoder().encode(action))).base64EncodedString()
        return action
    }

    @Test func pairingTamperingAndRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("phones.json")
        let store = PairedPhoneStore(url: url)
        let action = try signed(Curve25519.Signing.PrivateKey())
        #expect(store.authorize(action, requiresPairing: true) != nil)
        #expect(store.phones.first?.status == .pending)
        store.setStatus(.paired, id: action.clientId)
        let reloaded = PairedPhoneStore(url: url)
        #expect(reloaded.authorize(action, requiresPairing: true) == nil)
        var changed = action
        changed.payload["approvalId"] = "another-approval"
        #expect(reloaded.authorize(changed, requiresPairing: true) != nil)
        changed = action
        changed.action = "rejectApproval"
        #expect(reloaded.authorize(changed, requiresPairing: true) != nil)
        changed = action
        changed.deviceSignature = nil
        #expect(reloaded.authorize(changed, requiresPairing: true) != nil)
        let stranger = try signed(Curve25519.Signing.PrivateKey())
        #expect(reloaded.authorize(stranger, requiresPairing: true) != nil)
        reloaded.setStatus(.removed, id: action.clientId)
        #expect(PairedPhoneStore(url: url).authorize(action, requiresPairing: true) != nil)
        #expect(PairedPhoneStore(url: url).phones.first?.status == .removed)
    }

    @Test func damagedRegistryIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("phones.json")
        let bytes = Data("broken".utf8)
        try bytes.write(to: url)
        let store = PairedPhoneStore(url: url)
        let action = try signed(Curve25519.Signing.PrivateKey())
        #expect(store.authorize(action, requiresPairing: true) != nil)
        store.setStatus(.paired, id: action.clientId)
        #expect(try Data(contentsOf: url) == bytes)
    }
}
