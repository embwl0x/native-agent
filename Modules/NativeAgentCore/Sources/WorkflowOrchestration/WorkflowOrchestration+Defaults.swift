import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Saved workflow templates

/// Saved planning templates. The workflow registry does not execute them.
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
                "description": .string("Saved template for research, source capture, a memory note, and a summary. Workflow execution is unavailable."),
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
                "description": .string("Saved template for proposing and validating an app-owned JSON tool with permission-gated promotion. Workflow execution is unavailable."),
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
                "description": .string("Saved template for capturing an objective as a semantic memory with a trace receipt. Workflow execution is unavailable."),
                "status": .string("template"),
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

    /// Only migrate original seeds; preserve customized rows and their stamps.
    static func migrateUnchangedSeed(_ saved: JSONValue, to current: JSONValue) -> JSONValue {
        guard case .object(var original) = current,
              case .object(var candidate) = saved else { return saved }
        switch WorkflowMerge.idKey(current) {
        case "research-to-brief":
            original["description"] = .string("Route a research objective through search, source capture, memory note, and summary receipt.")
        case "safe-tool-forge":
            original["description"] = .string("Turn repeated work into a proposed app-owned JSON tool, validate it, and leave promotion gated by permissions.")
        case "memory-capture":
            original["description"] = .string("Execute a safe app-owned workflow that routes an objective, writes a memory, and records a trace receipt.")
            original["status"] = .string("active")
        default:
            return saved
        }
        for key in ["createdAt", "updatedAt"] {
            original.removeValue(forKey: key)
            candidate.removeValue(forKey: key)
        }
        guard candidate == original, case .object(var migrated) = saved,
              case .object(let template) = current else { return saved }
        migrated["description"] = template["description"]
        migrated["status"] = template["status"]
        return .object(migrated)
    }
}
