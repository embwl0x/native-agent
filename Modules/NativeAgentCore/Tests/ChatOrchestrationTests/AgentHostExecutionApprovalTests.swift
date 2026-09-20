import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ApprovalInbox
@testable import ChatOrchestration

@Suite struct AgentHostExecutionApprovalTests {
    @Test func cardDisclosesExactResolvedPathAndArgumentsStayWhole() throws {
        let row = try #require(AgentHostDirectory.rows.first { $0.commandLine != nil })
        let path = "/tmp/agent folder/agent'$(touch nope)"
        let proposal = AgentHostConnection.Proposal(row: row, command: "/tmp/link",
            descriptorPath: "/tmp/bridge.json", existing: nil, executablePath: path)
        #expect(AgentHostConnection.cardText(proposal, appName: "Fixture").contains("Executable: " + path))
        let line = try #require(row.commandLine)
        let message = "--flag ; $(touch nope) ' \""
        #expect(line.argv(message: message, session: "fixture", resuming: false, replyFilePath: nil).last == message)
        var contact = AgentPeerContact(name: row.displayName, endpoint: URL(string: "mcp://fixture")!, transport: .mcpHost)
        contact.approvedExecutablePath = path
        #expect(try JSONDecoder().decode(AgentPeerContact.self, from: JSONEncoder().encode(contact)).approvedExecutablePath == path)
    }

    @Test(arguments: [false, true])
    func connectionHonorsApprovalPolicyWithAutoAutonomy(fullMac: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-denial-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let trust = root.appendingPathComponent("trust")
        try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
        try JSONValue.object(fullMac ? [
            "permissionLevel": .string("full_mac_os"), "fullMacNeverExpires": .bool(true),
            "enableAutonomy": .bool(true)
        ] : [:]).serializedData(pretty: false).write(to: trust.appendingPathComponent("policy.json"))
        let sentinel = root.appendingPathComponent("effect")
        let filer = DenyingAgentFiler()
        let dispatcher = AutonomyGatedDispatcher(inner: AgentEffectFixture(sentinel: sentinel),
            gate: AutonomyGate(trust: AutoAgentResolver(), approvalFiler: filer),
            approvalFiler: filer, securityCenter: SwiftNativeSecurityCenter(dataRoot: root),
            hasFiler: true, verifiedSessionId: "fixture")
        if fullMac {
            _ = try await dispatcher.dispatch(tool: "agent_connect", input: ["name": .string("Fixture agent")], surface: "chat")
        } else {
            await #expect(throws: AutonomyGateError.notRun(.personDenied)) {
                _ = try await dispatcher.dispatch(tool: "agent_connect", input: ["name": .string("Fixture agent")], surface: "chat")
            }
        }
        #expect(await filer.filed == !fullMac)
        #expect(FileManager.default.fileExists(atPath: sentinel.path) == fullMac)
    }
}

private struct AutoAgentResolver: AutonomyResolver {
    func autonomyLevel(forTool toolName: String, surface: String) async throws -> String { "auto" }
}

private actor DenyingAgentFiler: ApprovalFiler {
    var filed = false
    func fileApprovalRequest(toolName: String, surface: String, payload: JSONValue, reason: String) async throws -> String {
        filed = true
        return "fixture-denied"
    }
    func awaitResolution(id: String) async throws -> ApprovalDecision { .denied }
}

private struct AgentEffectFixture: ToolDispatchClient {
    let sentinel: URL
    func listAvailableTools() async throws -> [String] { ["agent_connect"] }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        try Data("effect".utf8).write(to: sentinel)
        return .object([:])
    }
}
