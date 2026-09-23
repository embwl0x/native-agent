import Foundation
import ApprovalInbox
import PersistenceCore
import Testing
@testable import ChatOrchestration

@Suite struct AgentACPApprovalTests {
    @Test func livePermissionCarriesInitiatingChatAndRetiresOnCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let peer = AgentPeerContact(name: "Fixture", endpoint: URL(string: "acp://hermes")!, transport: .acp)
        let context = ChatToolSessionContext.$verifiedSessionId.withValue("local-chat") {
            AgentACPApproval.Context.current
        }
        let events = await ApprovalLifecycleBus.shared.events()
        let task = Task {
            try await AgentACPApproval.request(.object([
                "sessionId": .string("foreign-session"),
                "toolCall": .object(["title": .string("Write a file")]),
            ]), peer: peer, context: context, inbox: inbox)
        }
        defer { task.cancel() }
        var created: ApprovalRecord?
        for await event in events where event.phase == .requested {
            guard let record = try? await inbox.get(event.record.id) else { continue }
            created = record
            break
        }
        let record = try #require(created)
        guard case .object(let payload) = record.payload,
              case .object(let origin)? = payload["origin"] else {
            Issue.record("Live ACP permission must retain its initiating origin")
            return
        }
        #expect(payload["kind"] == .string("agent_acp_live_approval"))
        #expect(origin["sessionId"] == .string("local-chat"))
        #expect(record.localOnly && !record.remoteResolvable)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Canceled permissions must not resolve as authorization")
        } catch { #expect(error is CancellationError) }
        let retired = try await inbox.get(record.id)
        #expect(retired.status == "resolved")
        #expect(retired.decision == "canceled")
    }
}
