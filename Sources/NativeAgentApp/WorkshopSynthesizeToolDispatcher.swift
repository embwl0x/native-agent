import Foundation
import NativeAgentCore
import ChatOrchestration
import PersistenceCore

// Synthesize-quality fix (2026-06-11, found live by Agent on execution 752636c5).
//
// A `chat.synthesize` execution step used to run a BARE LLM completion with NO
// tool access — so the model couldn't read the files/memory it was asked to
// summarize and refused ("I can't access your filesystem, here's some jq").
// The refusal was scored `succeeded`.
//
// The fix routes synthesize steps through a tool-capable chat turn (see
// BackgroundLoopsAssembly.makeMissionExecutor). This wrapper is the RESTRICTED,
// READ-ONLY tool surface that turn is allowed to use: a hard allowlist over the
// real SwiftToolDispatcher. Defense-in-depth — even if the system prompt or the
// model tries a write/shell/execution tool, the dispatcher refuses by NAME before
// the call reaches any backend. The autonomy gate (AutonomyGatedDispatcher,
// wired by makeChatOrchestrationClient) still applies ON TOP of this for the
// read tools that survive the allowlist.
//
// Allowlist rationale (task fence — NO shell, NO write, NO workshop_submit):
//   read_file / list_dir            — the filesystem reads the step needs
//   search_chat_history / session_search — prior-conversation lookups
//   recall_memory / recall_search / search_kg / context_lookup — memory reads
//   read_skill / list_skills / tool_catalog / list_tools — harmless discovery
//   time_now / agent_introspect / daemon_introspect — read-only introspection
// Explicitly EXCLUDED: write_file, commit_memory, persona_write/append,
// every Full-Mac shell/builder/restart tool, mail/messages/notes *send*,
// workshop_submit / workshop_status (recursion + state mutation), invoke_claude
// / invoke_codex (sub-agent spawn), agent_swarm.
struct WorkshopSynthesizeReadOnlyToolDispatcher: ToolDispatchClient {
    let inner: any ToolDispatchClient

    /// The hard read-only allowlist. Snake_case to match the dispatcher's
    /// built-in tool names. Kept conservative on purpose: anything not here is
    /// refused, so a future tool is unavailable to synthesize until someone
    /// deliberately adds it (no silent privilege creep).
    static let allowed: Set<String> = [
        "read_file", "list_dir",
        "search_chat_history", "session_search",
        "recall_memory", "recall_search", "search_kg", "context_lookup",
        "read_skill", "list_skills",
        "tool_catalog", "list_tools",
        "time_now", "agent_introspect", "daemon_introspect",
    ]

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        guard Self.allowed.contains(tool) else {
            throw NSError(domain: "WorkshopSynthesize", code: 403, userInfo: [
                NSLocalizedDescriptionKey:
                    "tool '\(tool)' is not permitted in a Workshop synthesis step "
                    + "(read-only surface: \(Self.allowed.sorted().joined(separator: ", ")))",
            ])
        }
        return try await inner.dispatch(tool: tool, input: input, surface: surface)
    }

    func listAvailableTools() async throws -> [String] {
        let names = try await inner.listAvailableTools()
        return names.filter { Self.allowed.contains($0) }
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        let schemas = try await inner.listAvailableToolSchemas()
        return schemas.filter { Self.allowed.contains($0.name) }
    }
}
