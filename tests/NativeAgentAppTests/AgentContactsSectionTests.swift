import Foundation
import Testing
import ChatOrchestration
import PersistenceCore
import ApprovalInbox
@testable import NativeAgentApp

@Suite struct AgentContactsSectionTests {
    @Test func failuresUsePlainRecoveryInstructions() {
        for code in ["missing_session_id", "unknown_internal_code"] {
            let text = AgentContactResult.text(.object(["status": .string("failed"),
                "reason": .string(code), "detail": .string(code)]))
            #expect(!text.contains(code))
            #expect(text.lowercased().contains("refresh agents"))
        }
    }
    @Test func knownAgentsDescribeTheirOwnPurposeAndDirection() {
        let rows = AgentContactRow.rows(peers: [], installed: AgentHostDirectory.rows)
        for row in rows {
            #expect(row.displayName == row.name)
            #expect(!row.route.hasPrefix(row.name))
            #expect(!row.route.contains("settings entry (MCP)"))
        }
        #expect(rows.first { $0.id == "lm-studio" }?.route.contains("local models") == true)
        #expect(rows.first { $0.id == "claude-desktop" }?.route.contains("chat app") == true)
        #expect(rows.first { $0.id == "codex" }?.route.contains("I can start a conversation") == true)
        #expect(rows.first { $0.id == "lm-studio" }?.route.contains("I cannot start a conversation") == true)
    }

    @Test func acpCardShowsCurrentBindingSeparatelyFromHistoricalProof() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let program = root.appendingPathComponent("fixture-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        var peer = AgentPeerContact(name: "Gemini", endpoint: URL(string: "acp://gemini-cli")!, transport: .acp)
        peer.acpExecutable = try AgentACPExecutable.capture(path: program.path)
        peer.approvedExecutablePath = peer.acpExecutable?.path
        peer.acpWorkingDirectory = root.path
        let row = AgentContactRow(id: "peer:" + peer.id, name: peer.name, contact: peer)
        #expect(row.route.contains("Route: ACP"))
        #expect(row.route.contains("Starts in folder: " + root.path))
        #expect(row.route.contains("Program: " + peer.approvedExecutablePath!))
        #expect(row.route.contains("Can start a turn now"))
        #expect(!row.route.contains("MCP"))
        #expect(row.status == "Set up · Nothing has crossed yet")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: program)
        #expect(row.route.contains("Cannot start a turn now"))
        #expect(!peer.isReady)
        peer.approvedExecutablePath = nil
        peer.acpWorkingDirectory = nil
        let unbound = AgentContactRow(id: row.id, name: peer.name, contact: peer)
        #expect(unbound.route.contains("Program: Not approved"))
        #expect(unbound.route.contains("Starts in folder: Not set"))
        #expect(unbound.route.contains("Cannot start a turn now"))
        let discovered = AgentContactRow(id: "gemini-cli", name: "Gemini", contact: nil)
        #expect(discovered.route.contains("Route: ACP"))
        #expect(!discovered.route.contains("MCP"))
    }

    @Test func acpProofKeepsItsTransportScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        let peer = try store.upsert(AgentPeerContact(name: "Fixture", endpoint: URL(string: "acp://gemini-cli")!, transport: .acp))
        store.recordRoundTrip(peerID: peer.id, executable: "/fixture/gemini", workspace: root.path)
        let saved = try #require(store.list().first)
        let text = AgentContactRow(id: peer.id, name: peer.name, contact: saved).status
        #expect(text.contains("Historical round trip"))
        #expect(text.contains("ACP round trip"))
        #expect(text.contains(try #require(saved.roundTripProof?.at)))
        #expect(!text.contains("MCP return path"))
    }

    @Test func commandProofShowsItsRouteAndTimeWithoutClaimingMCP() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        let peer = try store.upsert(AgentPeerContact(name: "Fixture", endpoint: URL(string: "mcp://codex")!, transport: .mcpHost))
        store.recordRoundTrip(peerID: peer.id, executable: "/fixture/codex", workspace: root.path)
        let saved = try #require(store.list().first)
        let text = AgentContactRow(id: peer.id, name: peer.name, contact: saved).status
        #expect(!text.contains("Ready"))
        #expect(text.hasPrefix(AgentPeerCredentials.unavailableDetail))
        #expect(text.contains("Historical round trip"))
        #expect(text.contains("Command-line round trip · /fixture/codex"))
        #expect(text.contains(try #require(saved.roundTripProof?.at)))
        #expect(!text.contains("MCP return path"))
    }

    @Test func contactsAndInstalledAppsShareOneRowPerConnection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        let peer = try store.upsert(AgentPeerContact(name: "Test agent", endpoint: URL(string: "mcp://codex")!, transport: .mcpHost))
        var rows = AgentContactRow.rows(peers: try store.list(), installed: AgentHostDirectory.rows)
        #expect(rows.count == AgentHostDirectory.rows.count)
        #expect(rows[0].id == "peer:" + peer.id)
        #expect(rows[0].status.hasPrefix(AgentPeerCredentials.unavailableDetail))
        #expect(rows.last?.status == "On this Mac · Not set up")
        store.recordProof(peerID: peer.id, outbound: true)
        rows = AgentContactRow.rows(peers: try store.list(), installed: [])
        #expect(rows[0].status.hasPrefix(AgentPeerCredentials.unavailableDetail))
        store.recordProof(peerID: peer.id, inbound: true)
        rows = AgentContactRow.rows(peers: try store.list(), installed: [])
        #expect(rows[0].status.contains("Historical inbound message"))
        #expect(rows[0].state == .unavailable)
        store.recordRoundTrip(peerID: peer.id, executable: "/fixture/agent", version: "1.2", workspace: "/fixture/work")
        let reloaded = AgentPeerStore(dataRoot: root)
        rows = AgentContactRow.rows(peers: try reloaded.list(), installed: [])
        #expect(rows[0].status.hasPrefix(AgentPeerCredentials.unavailableDetail))
        #expect(rows[0].status.contains("Historical round trip"))
        #expect(rows[0].status.contains("/fixture/agent · Version 1.2"))
        #expect(rows[0].status.contains("Proven "))
        store.recordUnavailable(peerID: peer.id)
        rows = AgentContactRow.rows(peers: try reloaded.list(), installed: [])
        #expect(rows[0].status.hasPrefix(AgentPeerCredentials.unavailableDetail))
        #expect(rows[0].status.contains("Historical round trip"))
        #expect(rows[0].state == .unavailable)
    }

    @Test func controlsUseChatPrompts() {
        let row = AgentContactRow(id: "codex", name: "Codex", contact: nil)
        #expect(row.prompt(.connect) == "Connect to Codex.")
        #expect(row.prompt(.disconnect) == "Disconnect the Codex agent contact.")
        #expect(row.prompt(.test) == "Send Codex a short test message and tell me what it answers.")
    }

    @Test func printedAnswerDoesNotClaimTheConnectionWorked() {
        let value: JSONValue = .object(["reply": .string("Hello"), "connection_check": .bool(true),
            "connection_reply_received": .bool(false)])
        #expect(AgentContactResult.text(value).hasPrefix("No new answer arrived"))
        #expect(AgentContactResult.text(value).contains("Hello"))
        #expect(AgentContactResult.text(.object(["reply": .string("Hello")])) == "Hello")
        #expect(AgentContactResult.text(.object(["status": .string("pending_approval")])) == "Waiting for approval.")
        let peer = AgentPeerContact(name: "Desktop agent", endpoint: URL(string: "app://test.agent")!, transport: .desktop)
        #expect(AgentContactRow(id: peer.id, name: peer.name, contact: peer).status == "Can send · Replies are not connected")
    }

    @Test func approvalReceiptKeepsAnswerWhenTheGeneralPreviewIsClipped() throws {
        let result: JSONValue = .object(["status": .string("configured"),
            "detail": .string(String(repeating: "Settings description. ", count: 200)),
            "probe": .object(["reply": .string("Hello from the test"), "connection_check": .bool(true),
                "connection_reply_received": .bool(true)])])
        let receipt = NativeClient.chatToolApprovalExecutionReceipt(toolName: "agent_connect", surface: "chat", result: result)
        guard case .object(let action) = receipt.action else { Issue.record("Missing receipt"); return }
        #expect(AgentContactResult.text(try #require(action["contactResult"])) == "Hello from the test")
        #expect(AgentContactResult.text(.object(["status": .string("waiting_approval")])) == "Waiting for approval.")
    }

    @Test func taskDeliveryAndCompletionSurviveReceipt() {
        for (status, label) in [("submitted", "Accepted"), ("working", "Working"),
                                ("input-required", "Needs input"), ("auth-required", "Needs sign-in"),
                                ("completed", "Completed"), ("failed", "Failed")] {
            let result: JSONValue = .object(["status": .string(status), "task_id": .string("task-42"),
                "completed": .bool(status == "completed"), "terminal": .bool(status == "failed"),
                "needs_input": .bool(status == "input-required"),
                "needs_authentication": .bool(status == "auth-required"),
                "read_with": .object(["task_id": .string("task-42")])])
            let receipt = AgentContactResult.receipt(result)
            #expect(receipt == result)
            let text = AgentContactResult.text(receipt)
            if status == "failed" {
                #expect(text.contains("could not be completed"))
                continue
            }
            #expect(text.contains("Result: " + label))
            #expect(text.contains("Task: task-42"))
            #expect(!text.contains("No answer came back"))
        }
    }

}
