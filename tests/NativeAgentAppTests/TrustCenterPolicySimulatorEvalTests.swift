import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
import TrustCenter
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.TrustCenter.policySimulator
@Suite("Trust Center policy simulator", .serialized)
struct TrustCenterPolicySimulatorEvalTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trust-simulator-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func persistPolicy(
        outsideWorkspaceDefault: String,
        workspace: URL,
        root: URL
    ) async throws {
        _ = try await NativeClient.applyTrustPolicyPatch(
            body: [
                "permissionLevel": "balanced",
                "autonomyDefault": "workspace_autonomous",
                "filePolicy": [
                    "workspaceRoots": [workspace.path],
                    "outsideWorkspaceDefault": outsideWorkspaceDefault,
                ],
                "toolAutonomy": ["default": "auto", "write_file": "auto"],
            ],
            dataRoot: root
        )
    }

    /// The mounted panel calls NativeClient.simulatePolicy.  Compare that
    /// result to the actual SecurityCenter decision for each real path shape;
    /// do not encode a second, drift-prone policy implementation in the test.
    @Test("simulator verdicts equal the real file gate for each outside-policy and path shape")
    func matrixMatchesEffectTimeFileGate() async throws {
        for outsideDefault in ["deny", "ask", "allow"] {
            let root = try root(outsideDefault)
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try await persistPolicy(
                outsideWorkspaceDefault: outsideDefault,
                workspace: workspace,
                root: root
            )

            let paths = [
                workspace.appendingPathComponent("inside.txt").path,
                root.appendingPathComponent("outside.txt").path,
                "/Users/nativeagent-simulator/Library/Mail/TCC-protected.mbox",
            ]
            let gate = SwiftNativeSecurityCenter(dataRoot: root)
            for path in paths {
                let simulation = try await NativeClient.simulatePolicy(
                    action: "file_write",
                    path: path,
                    dataRoot: root
                )
                let actual = await gate.evaluateTool(
                    tool: "write_file",
                    input: ["path": .string(path)],
                    origin: SecurityOriginContext(surface: "mac_ui_policy_preview"),
                    enforceAutonomy: true
                )

                #expect(simulation.allowed == actual.allowed, "\(outsideDefault) / \(path)")
                #expect(simulation.requiresApproval == actual.requiresApproval, "\(outsideDefault) / \(path)")
                #expect(simulation.risk == actual.risk, "\(outsideDefault) / \(path)")
                #expect(simulation.reasons == actual.reasons, "\(outsideDefault) / \(path)")
            }
        }
    }

    @Test("presentation keeps allowed, approval, denial, and unavailable distinct")
    func presentationDoesNotTurnApprovalOrUnavailableIntoDenied() {
        #expect(PolicySimulationVerdict(simulation: PolicySimulation(
            allowed: true, requiresApproval: false, risk: "low", action: "file_write", reasons: []
        )) == .allowed)
        #expect(PolicySimulationVerdict(simulation: PolicySimulation(
            allowed: false, requiresApproval: true, risk: "medium", action: "file_write", reasons: []
        )) == .approvalRequired)
        #expect(PolicySimulationVerdict(simulation: PolicySimulation(
            allowed: false, requiresApproval: false, risk: "high", action: "file_write", reasons: ["policy denies this write"]
        )) == .denied)
        #expect(PolicySimulationVerdict(simulation: PolicySimulation(
            allowed: false, requiresApproval: false, risk: "critical", action: "file_write",
            reasons: ["saved trust policy is unavailable: malformed JSON"]
        )) == .unavailable)
    }

    @Test("malformed policy is displayed as unavailable, never as an ordinary denial")
    func malformedAuthorityFailsClosedAndHonestly() async throws {
        let root = try root("malformed")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = root.appendingPathComponent("trust/policy.json")
        try FileManager.default.createDirectory(
            at: authority.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{broken".utf8).write(to: authority)

        let simulation = try await NativeClient.simulatePolicy(
            action: "file_write",
            path: root.appendingPathComponent("notes.txt").path,
            dataRoot: root
        )
        #expect(!simulation.allowed)
        #expect(PolicySimulationVerdict(simulation: simulation) == .unavailable)
        #expect(try Data(contentsOf: authority) == Data("{broken".utf8))
    }
}
