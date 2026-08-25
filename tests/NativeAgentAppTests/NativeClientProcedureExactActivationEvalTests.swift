import ApprovalInbox
import Foundation
import NativeAgentCore
import Testing
@testable import NativeAgentApp

@Suite("app.runtimes · NativeClient procedure exact activation", .serialized)
struct NativeClientProcedureExactActivationEvalTests {
    @Test("the real client approval route annotates an invalid exact activation at its injected root")
    func invalidActivationFailsClosedAtTheClientRoot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let pending = try await inbox.create(.object([
            "title": .string("Invalid exact activation eval"),
            "action": .string(SwiftNativeApprovalInbox.procedureExactActivationApprovalAction),
            "risk": .string("high"),
            "reason": .string("Exercise the invalid-binding failure path."),
            "payloadPreview": .string("Invalid proposal binding."),
            "payload": .object(["schema": .string("not-the-exact-activation-schema")]),
            "remoteResolvable": .bool(false),
            "localOnly": .bool(true),
        ]))
        let client = NativeClient(baseURL: "http://unused", dataRootOverride: root)

        _ = try await client.resolveApproval(id: pending.id, decision: "approved")

        let resolved = try await inbox.get(pending.id)
        #expect(resolved.status == "resolved")
        #expect(resolved.decision == ApprovalDecision.approved.rawValue)
        guard case .object(let action)? = resolved.executedAction else {
            Issue.record("invalid activation was resolved without a terminal execution annotation")
            return
        }
        #expect(action["status"] == .string("failed"))
        #expect(resolved.detail?.contains("proposal binding is invalid") == true)
    }

    @Test("a denied exact activation remains explicitly non-activated")
    func deniedActivationDoesNotInstallOrClaimSuccess() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let pending = try await inbox.create(.object([
            "title": .string("Denied exact activation eval"),
            "action": .string(SwiftNativeApprovalInbox.procedureExactActivationApprovalAction),
            "risk": .string("high"),
            "reason": .string("Exercise the denied branch."),
            "payloadPreview": .string("No activation."),
            "payload": .object([:]),
            "remoteResolvable": .bool(false),
            "localOnly": .bool(true),
        ]))
        let client = NativeClient(baseURL: "http://unused", dataRootOverride: root)

        _ = try await client.resolveApproval(id: pending.id, decision: "denied")

        let resolved = try await inbox.get(pending.id)
        guard case .object(let action)? = resolved.executedAction else {
            Issue.record("denied activation was not annotated")
            return
        }
        #expect(action["activated"] == .bool(false))
        #expect(resolved.detail?.contains("active routing unchanged") == true)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-client-procedure-activation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
