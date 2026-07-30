import ChatOrchestration
import Foundation
import MCPDispatcher
import NativeAgentCore
import PersistenceCore
import Testing

@Suite("Opt-in live runtime gauge verification")
struct LiveRuntimeGaugeVerificationTests {
    @Test("chat and MCP projections agree with the runtime-owned stores")
    func liveRuntimeGaugeReceipt() async throws {
        guard ProcessInfo.processInfo.environment["NATIVE_AGENT_LIVE_GAUGE_VERIFY"] == "1" else {
            return
        }

        let repoRoot = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["NATIVE_AGENT_REPO_ROOT"]
                ?? FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        let dataRoot = repoRoot.appendingPathComponent("data", isDirectory: true)
        let chat = SwiftToolDispatcher(dataRoot: dataRoot)

        let traceResult = try await chat.dispatch(
            tool: "recent_trace_summary",
            input: ["limit": .int(20), "status": .string("")],
            surface: "chat"
        )
        guard case .object(let traceEnvelope) = traceResult,
              case .int(let traceCount)? = traceEnvelope["count"] else {
            Issue.record("recent_trace_summary returned an unexpected shape: \(traceResult)")
            return
        }
        #expect(traceCount > 0)

        let skillsResult = try await chat.dispatch(tool: "list_skills", input: [:], surface: "chat")
        guard case .array(let skillRows) = skillsResult else {
            Issue.record("list_skills returned an unexpected shape: \(skillsResult)")
            return
        }
        #expect(!skillRows.isEmpty)

        let mcpResult = try await SwiftNativeMCPDispatcher(root: dataRoot).callToolLive(
            forServer: "nativeagent-internal",
            toolName: "capabilities.summary"
        )
        guard case .object(let mcpEnvelope) = mcpResult,
              case .object(let mcpPayload)? = mcpEnvelope["result"],
              case .object(let summary)? = mcpPayload["summary"],
              case .object(let byKind)? = summary["byKind"],
              case .int(let mcpSkillCount)? = byKind["skill"] else {
            Issue.record("capabilities.summary returned an unexpected shape: \(mcpResult)")
            return
        }
        #expect(mcpSkillCount == skillRows.count)

        let deskStore = SwiftNativeDeskStore(dataRoot: dataRoot)
        let repairs = try await deskStore.reconcileTerminalParentsWithNonTerminalDescendants()
        let deskState = try await deskStore.liveState()
        let invalidTerminalParents = deskState.items.filter { item in
            item.status.isTerminal
                && deskState.items.contains { child in
                    child.parent == item.handle && !child.status.isTerminal
                }
        }
        #expect(invalidTerminalParents.isEmpty)

        let deskResult = try await chat.dispatch(tool: "desk_read", input: [:], surface: "chat")
        guard case .object(let deskEnvelope) = deskResult,
              case .string(let deskProjection)? = deskEnvelope["projection"] else {
            Issue.record("desk_read returned an unexpected shape: \(deskResult)")
            return
        }
        #expect(!deskProjection.isEmpty)

        print(
            "LIVE_RUNTIME_GAUGE_RECEIPT "
                + "trace_count=\(traceCount) "
                + "list_skills=\(skillRows.count) "
                + "mcp_skills=\(mcpSkillCount) "
                + "desk_repairs=\(repairs.count) "
                + "invalid_terminal_parents=\(invalidTerminalParents.count)"
        )
    }
}
