import Foundation
import Testing
import PersistenceCore
import TrustCenter
@testable import ChatOrchestration

@Suite struct PeerConversationApprovalTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trust = root.appendingPathComponent("trust")
        try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
        try JSONValue.object([
            "enableAutonomy": .bool(true), "permissionLevel": .string("full_mac_os"),
            "fullMacNeverExpires": .bool(true),
            "connectorPolicy": .object(["sendExternalMessagesRequiresApproval": .bool(false)])
        ]).serializedData(pretty: true).write(to: trust.appendingPathComponent("policy.json"))
        return root
    }

    @Test func repeatedPeerRepliesDoNotReapproveConversation() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let peerReply: JSONValue = .object(["agent": .string("peer:fixture"),
            "untrusted_remote_data": .bool(true), "reply": .string("Hello again")])
        let tools = MockToolDispatchClient(scripted: ["agent_message": peerReply])
        let filer = MockNonBlockingApprovalFiler()
        let gated = AutonomyGatedDispatcher(inner: tools,
            gate: AutonomyGate(trust: MockAutonomyResolver(levels: ["agent_message": "auto"]), approvalFiler: filer),
            approvalFiler: filer, securityCenter: SwiftNativeSecurityCenter(dataRoot: root), hasFiler: true)
        let dispatcher = PeerDataTaintDispatcher(inner: gated)
        try await PeerDataTaint.withScope {
            for _ in 0..<3 {
                let result = try await dispatcher.dispatch(tool: "agent_message",
                    input: ["agent": .string("peer:fixture"), "message": .string("Hello")], surface: "chat")
                #expect(result == peerReply)
            }
            #expect(PeerDataTaint.current?.isTainted == true)
        }
        #expect(tools.dispatches.count == 3)
        #expect(await filer.filedCount() == 0)
    }

    @Test func destructionStillAsksAfterPeerReplyButNotOnHumanFullMacTurn() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = MockToolDispatchClient(scripted: ["delete_file": .bool(true)])
        let filer = MockNonBlockingApprovalFiler()
        let dispatcher = AutonomyGatedDispatcher(inner: tools,
            gate: AutonomyGate(trust: MockAutonomyResolver(levels: ["delete_file": "auto"]), approvalFiler: filer),
            approvalFiler: filer, securityCenter: SwiftNativeSecurityCenter(dataRoot: root), hasFiler: true)
        try await PeerDataTaint.withScope {
            PeerDataTaint.markConsumed(peer: "peer:fixture")
            let result = try await dispatcher.dispatch(tool: "delete_file", input: [:], surface: "chat")
            #expect(ChatTranscriptToolMessageKind.pendingApprovalID(in: result) != nil)
        }
        #expect(tools.dispatches.isEmpty)
        #expect(await filer.filedCount() == 1)
        let local = try await dispatcher.dispatch(tool: "delete_file", input: [:], surface: "chat")
        #expect(local == .bool(true))
        #expect(tools.dispatches.count == 1)
        #expect(await filer.filedCount() == 1)
    }

    @Test func inboundConversationAndDestructionUseSameBoundary() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = SwiftNativeSecurityCenter(dataRoot: root)
        let origin = SecurityOriginContext(surface: "agent-bridge")
        let conversation = await center.evaluateTool(tool: "agent_message",
            input: ["agent": .string("peer:fixture"), "message": .string("Hello")],
            origin: origin, enforceAutonomy: false)
        #expect(conversation.decision == .allow)
        let destructive = await center.evaluateTool(tool: "delete_file", input: [:],
            origin: origin, enforceAutonomy: false)
        #expect(destructive.decision == .ask)
        #expect(!PeerTurnEffectPolicy.requiresPeerApproval("agent_message", capabilities: ["shell", "process_spawn"]))
        #expect(PeerTurnEffectPolicy.requiresPeerApproval("shell", capabilities: ["shell"]))
        #expect(PeerTurnEffectPolicy.requiresPeerApproval("mcp__unknown__action", capabilities: []))
    }
}
