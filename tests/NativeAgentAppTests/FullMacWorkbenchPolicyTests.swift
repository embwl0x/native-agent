import Foundation
import Testing
import MacControl
import TrustCenter
@testable import NativeAgentApp

@Suite("Full Mac local workbench policy")
struct FullMacWorkbenchPolicyTests {
    @Test func localOperatorProjectionDoesNotUpgradeRawRemoteProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trust = root.appendingPathComponent("trust")
        try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
        let file = trust.appendingPathComponent("policy.json")
        try Data(#"{"permissionLevel":"full_mac_os","developerMode":false,"macControlPolicy":{"enabled":false,"shell_allowed":false,"accessibility_allowed":false,"remote_from_ios_allowed":false}}"#.utf8).write(to: file)
        let raw = try #require(await TrustCenterMacControlPolicyProvider(dataRoot: root).currentPolicy())
        let local = try #require(await TrustCenterMacControlPolicyProvider(
            dataRoot: root, operatorOrigin: SecurityOriginContext(surface: "native_actions")
        ).currentPolicy())
        let remote = try #require(await TrustCenterMacControlPolicyProvider(
            dataRoot: root, operatorOrigin: SecurityOriginContext(surface: "ios", isRemote: true)
        ).currentPolicy())
        #expect(!MacControlGate.gate(raw, category: "shell").allowed)
        #expect(MacControlGate.gate(local, category: "shell").allowed)
        #expect(MacControlGate.destructiveActionsAllowed(local.trustPolicy))
        #expect(remote == raw)
        try Data("not json".utf8).write(to: file)
        #expect(await TrustCenterMacControlPolicyProvider(dataRoot: root).currentPolicy() == nil)
    }
}
