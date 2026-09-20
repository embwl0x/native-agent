import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Trust access mode policies")
struct TrustAccessModePolicyTests {
    private func policy(mode: String, developerMode: Bool) throws -> TrustMacControlPolicy {
        let wire = NativeClient.macControlPolicyForAccessMode(
            mode,
            remoteFromIosAllowed: false,
            developerMode: developerMode
        )
        let data = try JSONSerialization.data(withJSONObject: wire)
        return try JSONDecoder().decode(TrustMacControlPolicy.self, from: data)
    }

    @Test("Full Mac keeps shell and system control behind Developer Mode")
    func fullMacDeveloperPermissions() throws {
        let ordinary = try policy(mode: "full", developerMode: false)
        #expect(ordinary.enabled)
        #expect(ordinary.accessibilityAllowed)
        #expect(ordinary.remoteFromIosAllowed)
        #expect(!ordinary.shellAllowed)
        #expect(!ordinary.systemControlAllowed)
        let developer = try policy(mode: "full", developerMode: true)
        #expect(developer.shellAllowed)
        #expect(developer.systemControlAllowed)
    }

    @Test("Restricted modes do not inherit Full Mac permissions")
    func restrictedPermissions() throws {
        for mode in ["auto", "read_only", "unknown"] {
            let restricted = try policy(mode: mode, developerMode: true)
            #expect(!restricted.enabled)
            #expect(!restricted.shellAllowed)
            #expect(!restricted.accessibilityAllowed)
            #expect(!restricted.remoteFromIosAllowed)
        }
        let workspace = try policy(mode: "workspace", developerMode: true)
        #expect(workspace.enabled)
        #expect(workspace.fileOpsAllowed)
        #expect(!workspace.shellAllowed)
        #expect(!workspace.accessibilityAllowed)
        #expect(!workspace.remoteFromIosAllowed)
    }
}
