import Foundation
import CryptoKit
import ApprovalInbox
import MCPDispatcher
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Research
import SystemOps

// MARK: - Built-in workflow defaults (mirror Runtime.workflow_defaults)

/// The three built-in workflow templates. Mirrors `Runtime.workflow_defaults`
/// in the retired daemon (lines ~6799-6846). `createdAt`/`updatedAt` are
/// stamped with the supplied `now` (matching Python's per-call `now_iso()`).
public enum WorkflowDefaults {
    public static func defaults(now: String) -> [JSONValue] {
        func step(_ id: String, _ title: String, _ kind: String, requiresApproval: Bool, layer: String? = nil) -> JSONValue {
            var obj: [String: JSONValue] = [
                "id": .string(id),
                "title": .string(title),
                "kind": .string(kind),
                "requiresApproval": .bool(requiresApproval),
            ]
            if let layer { obj["layer"] = .string(layer) }
            return .object(obj)
        }
        return [
            .object([
                "id": .string("research-to-brief"),
                "name": .string("Research to Brief"),
                "description": .string("Route a research objective through search, source capture, memory note, and summary receipt."),
                "status": .string("template"),
                "trigger": .string("research brief"),
                "steps": .array([
                    step("route", "Plan intent route", "router", requiresApproval: false),
                    step("search", "Search private web connector", "research", requiresApproval: false),
                    step("capture", "Capture source receipts", "receipt", requiresApproval: false),
                    step("brief", "Draft concise brief", "llm", requiresApproval: false),
                ]),
                "createdAt": .string(now),
                "updatedAt": .string(now),
            ]),
            .object([
                "id": .string("safe-tool-forge"),
                "name": .string("Safe Tool Forge"),
                "description": .string("Turn repeated work into a proposed app-owned JSON tool, validate it, and leave promotion gated by permissions."),
                "status": .string("template"),
                "trigger": .string("make a tool"),
                "steps": .array([
                    step("scope", "Define reusable boundary", "analysis", requiresApproval: false),
                    step("proposal", "Create tool proposal", "tool_proposal", requiresApproval: false),
                    step("validate", "Run safety scan and tests", "validation", requiresApproval: false),
                    step("promote", "Promote only safe app-data tool", "approval", requiresApproval: true),
                ]),
                "createdAt": .string(now),
                "updatedAt": .string(now),
            ]),
            .object([
                "id": .string("memory-capture"),
                "name": .string("Memory Capture"),
                "description": .string("Execute a safe app-owned workflow that routes an objective, writes a memory, and records a trace receipt."),
                "status": .string("active"),
                "trigger": .string("remember this"),
                "steps": .array([
                    step("route", "Route objective", "router", requiresApproval: false),
                    step("memory", "Write semantic memory", "memory", requiresApproval: false, layer: "semantic"),
                    step("trace", "Record trace receipt", "trace", requiresApproval: false),
                ]),
                "createdAt": .string(now),
                "updatedAt": .string(now),
            ]),
        ]
    }
}
