import Foundation
import Testing
@testable import NativeAgentApp

@Suite("app.runtimes · NativeClient training actions", .serialized)
struct NativeClientTrainingActionsEvalTests {
    @Test("training reads and a proposal rejection use the client's injected canonical root")
    func trainingActionsStayInsideTheClientRoot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposalURL = root
            .appendingPathComponent("training_journal/proposals/reject-me.json")
        try FileManager.default.createDirectory(
            at: proposalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try proposalJSON(status: "pending").write(to: proposalURL, options: .atomic)

        let client = NativeClient(baseURL: "http://unused", dataRootOverride: root)
        let listed = try await client.getTrainingProposals()
        #expect(listed.map(\.proposal_id) == ["reject-me"])

        let result = try await client.rejectTrainingProposal(
            id: "reject-me",
            reason: "The proposal lacks sufficient evaluation evidence."
        )
        #expect(result["status"] as? String == "rejected")
        let reloaded = try await client.getTrainingProposals()
        let rejected = try #require(reloaded.first(where: { $0.proposal_id == "reject-me" }))
        #expect(rejected.status == "rejected")
        #expect(rejected.reject_reason == "The proposal lacks sufficient evaluation evidence.")
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: proposalURL)) as? [String: Any]
        #expect(stored?["status"] as? String == "rejected")
        #expect(stored?["rejection_reason"] as? String == "The proposal lacks sufficient evaluation evidence.")
    }

    @Test("a root-scoped training gate refuses the same root's proposals before any read is presented")
    func trainingGateRemainsAtTheInjectedRoot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trust = root.appendingPathComponent("trust/policy.json")
        try FileManager.default.createDirectory(at: trust.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"trainingPolicy\": {\"autonomous_training\": false}}".utf8)
            .write(to: trust, options: .atomic)

        let client = NativeClient(baseURL: "http://unused", dataRootOverride: root)
        await #expect(throws: (any Error).self) {
            _ = try await client.getTrainingProposals()
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-client-training-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func proposalJSON(status: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "proposal_id": "reject-me",
            "staged_at": "2026-08-24T00:00:00Z",
            "source_run_id": "run-eval",
            "target_doc": "SOUL.md",
            "change_type": "append",
            "current": "",
            "proposed": "Keep decisions tied to evidence.",
            "rationale": "Training action root evaluation.",
            "status": status,
            "rejection_reason": NSNull(),
        ], options: [.sortedKeys])
    }
}
