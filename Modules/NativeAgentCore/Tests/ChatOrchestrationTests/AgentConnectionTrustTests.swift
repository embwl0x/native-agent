import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

@Suite struct AgentConnectionTrustTests {
    @Test(arguments: [false, true])
    func workModeReportsNothingRan(probe: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        let peer = try store.upsert(AgentPeerContact(name: "Fixture", endpoint: URL(string: "mcp://codex")!, transport: .mcpHost))
        let before = try Data(contentsOf: store.fileURL)
        let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false,
            agentBridgeConfigRoot: root.appendingPathComponent("config"))
        let result = try await dispatcher.impl_agentCommunication(tool: "agent_message", input: [
            "agent": .string("peer:" + peer.id),
            "text": .string(probe ? AgentHostDirectory.probeText(appName: SwiftToolDispatcher.appDisplayName) : "Hello")
        ], surface: "chat")
        guard case .object(let fields) = result, case .string(let detail)? = fields["detail"] else {
            Issue.record("Missing trust result"); return
        }
        #expect(fields["reason"] == .string("trust_center_full_mac_required"))
        #expect(fields["status"] != .string("failed"))
        #expect(fields["sent"] == .bool(false))
        #expect(fields["ran"] == .bool(false))
        #expect(fields["completed"] == .bool(false))
        #expect(detail.contains("Work mode"))
        #expect(detail.contains("Builder or Full Mac"))
        #expect(detail.contains("Trust or the composer"))
        #expect(!detail.contains("restart") && !detail.contains("timed out") && !detail.contains("did not return"))
        #expect(try Data(contentsOf: store.fileURL) == before)
        #expect(try store.list().first?.state == .setUp)
        if probe {
            #expect(fields["connection_check"] == .bool(true))
            #expect(fields["connection_reply_received"] == .bool(false))
            #expect(detail.contains("entry is written"))
            #expect(detail.contains("say connect again"))
            var connection: [String: JSONValue] = ["status": .string("configured"),
                "state": .string("set up"), "restart_required": .bool(true),
                "detail": .string("Restart the other app")]
            SwiftToolDispatcher.includeConnectionProbe(result, in: &connection)
            #expect(connection["status"] == .string("configured"))
            #expect(connection["state"] == .string("set up"))
            #expect(connection["detail"] == .string(detail))
            #expect(connection["probe"] == result)
            #expect(connection["restart_required"] == nil)
            #expect(SwiftToolDispatcher.probeReason(result) == detail)
        }
    }

    @Test func genuineProbeFailuresKeepTheirCause() {
        #expect(SwiftToolDispatcher.probeReason(.object(["timed_out": .bool(true)]))
            == "The probe ran past its time limit.")
        #expect(SwiftToolDispatcher.probeReason(.object(["detail": .string("Nothing ran: the executable is missing.")] ))
            == "Nothing ran: the executable is missing.")
    }
}
