import Foundation
import Testing
@testable import NativeAgentApp
import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// =============================================================================
// BRIDGE GUARD CHARACTERIZATION NET — external-MCP boundary
// =============================================================================
//
// Pins what ClaudeBridgeDenyDispatcher denies on the claude/codex bridge
// surfaces. As of the user's 2026-06-13 "open the bridges" call the boundary FLIPPED:
//
//   BEFORE: the bridge hard-denied every NativeAgent write-tier / process-spawn
//           tool (shell, mail_send, workshop_submit, self_install, …).
//   NOW:    every NativeAgent-NATIVE tool passes through to the normal gated
//           chain (yolo window for builder, the self_install approval card for
//           evolution, read_only fileAccess on the RPC path). The ONLY thing
//           still denied is the external `mcp__*` namespace — third-party
//           connectors, including a wired real-money brokerage order path, which
//           must never be reachable from a turn with no human at the trigger.
//
// THE LOAD-BEARING RULE still applies, just inverted: a `mustPass` name that
// turns red means a NativeAgent tool got re-fenced (regression of the user's call);
// a `mustDeny` name that turns red means the external-MCP guard sprang a leak
// (a real security signal — that is the financial-side-effect boundary).
//
// Run with:
//   swift test --package-path . --filter AutonomyGuardBridge   (app target)
//
// =============================================================================

private final class AGCBridgeReachInner: ToolDispatchClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var dispatched: [String] = []

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        record(tool)
        return .object(["status": .string("reached_inner")])
    }

    private func record(_ tool: String) {
        lock.lock(); defer { lock.unlock() }
        dispatched.append(tool)
    }

    func listAvailableTools() async throws -> [String] { [] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}

private actor AGCBridgeAllowingTrust: AutonomyResolver {
    private var observedTools: [String] = []

    func autonomyLevel(forTool toolName: String, surface: String) async throws -> String {
        observedTools.append(toolName)
        return "auto"
    }

    func tools() -> [String] { observedTools }
}

@Suite("AutonomyGuardBridge characterization")
struct AutonomyGuardBridgeCharacterizationTests {

    @Test func sharedBridgeFactoryKeepsMCPDenialOutsideThePolicyOracle() async throws {
        let inner = AGCBridgeReachInner()
        let trust = AGCBridgeAllowingTrust()
        let tools = makeNativeAgentBridgeToolDispatchClient(
            baseTools: inner,
            trust: trust
        )

        await #expect(throws: (any Error).self) {
            _ = try await tools.dispatch(
                tool: "mcp__broker__place_equity_order",
                input: [:],
                surface: "claude-bridge"
            )
        }
        #expect(await trust.tools().isEmpty)
        #expect(inner.dispatched.isEmpty)

        let result = try await tools.dispatch(
            tool: "read_file",
            input: [:],
            surface: "claude-bridge"
        )
        #expect(result == .object(["status": .string("reached_inner")]))
        #expect(await trust.tools() == ["read_file"])
        #expect(inner.dispatched == ["read_file"])
    }

    /// The external MCP namespace the bridge must DENY — the third-party /
    /// real-money side-effect boundary. Case-insensitive prefix match on
    /// `mcp__`; the brokerage name is the loaded one this guard exists for.
    private static let mustDeny: [String] = [
        "mcp__server__anytool",
        "mcp__broker__place_equity_order",
        "mcp__notion__create_page",
        "MCP__SERVER__TOOL",  // case-insensitive
    ]

    /// NativeAgent-NATIVE tools the bridge must now PASS (reach inner) — every
    /// name that USED to be bridge-denied, plus the reads that always passed.
    /// Gating still happens downstream (yolo / Trust Center / self_install card
    /// / read_only fileAccess), just not via a bridge-specific deny-list.
    private static let mustPass: [String] = [
        // formerly write-tier bridge-denied — open per the user 2026-06-13
        "shell", "bash", "git", "apply_patch", "run_tests",
        "restart_app", "workshop_submit", "task_ledger_post",
        "github_mutate",
        "commit_memory", "persona_write", "persona_append_section",
        "mail_send", "messages_send", "notes_create",
        "calendar_create_event", "reminders_create", "contacts_create_or_update",
        "music_control", "notify", "mac_notify", "mobile_notify",
        "scheduler_create_job", "agent_swarm", "swarm",
        "invoke_claude", "invoke_codex",
        // self-evolution — now reaches the backend; self_install still only
        // STAGES a card the user approves (proven in EvolutionChatToolsWiringTests).
        "evolution_propose", "evolution_status", "self_install",
        // reads that always passed
        "read_file", "recall_memory", "workshop_status", "task_ledger_list",
    ]

    @Test func bridge_denies_external_mcp_namespace() async {
        let inner = AGCBridgeReachInner()
        let denied = ClaudeBridgeDenyDispatcher(inner: inner)
        for name in Self.mustDeny {
            await #expect(throws: (any Error).self, "BRIDGE must DENY external MCP \(name)") {
                _ = try await denied.dispatch(tool: name, input: [:], surface: "claude-bridge")
            }
        }
        // No mcp__ name leaked through to the inner dispatcher.
        #expect(inner.dispatched.isEmpty,
                "BRIDGE mcp__ deny fired before inner for all; leaked: \(inner.dispatched)")
    }

    @Test func bridge_passes_every_native_tool() async throws {
        let inner = AGCBridgeReachInner()
        let denied = ClaudeBridgeDenyDispatcher(inner: inner)
        for name in Self.mustPass {
            let out = try await denied.dispatch(tool: name, input: [:], surface: "claude-bridge")
            if case .object(let o) = out, case .string(let s)? = o["status"], s == "reached_inner" {
                // ok — reached the real dispatch chain
            } else {
                Issue.record("BRIDGE \(name) expected to PASS (reach inner), got \(out)")
            }
        }
        #expect(inner.dispatched.sorted() == Self.mustPass.sorted(),
                "BRIDGE native-tool passes mismatch: \(inner.dispatched)")
    }

    @Test func bridge_filters_mcp_from_catalog_keeps_native() async throws {
        // The catalog listings drop mcp__ names but keep everything native.
        final class CatalogInner: ToolDispatchClient, @unchecked Sendable {
            func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue { .null }
            func listAvailableTools() async throws -> [String] {
                ["shell", "mail_send", "mcp__broker__place_equity_order", "read_file", "self_install"]
            }
            func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
                ["shell", "mcp__broker__place_equity_order", "read_file"].map {
                    LLMToolSchema(name: $0, description: "x", parametersJSON: Data("{}".utf8))
                }
            }
        }
        let denied = ClaudeBridgeDenyDispatcher(inner: CatalogInner())
        let names = try await denied.listAvailableTools()
        #expect(!names.contains { $0.lowercased().hasPrefix("mcp__") })
        #expect(names.contains("shell"))
        #expect(names.contains("mail_send"))
        #expect(names.contains("self_install"))
        let schemaNames = try await denied.listAvailableToolSchemas().map(\.name)
        #expect(!schemaNames.contains { $0.lowercased().hasPrefix("mcp__") })
        #expect(schemaNames.contains("shell"))
        #expect(schemaNames.contains("read_file"))
    }

    @Test func bridge_scrubs_mcp_from_meta_tool_results() async throws {
        // tool_catalog / list_tools / tool_load / agent_introspect build their
        // RESULT in the inner dispatcher, which unions mcp__ names into
        // available_tools/tools/currently_loaded (and mcp_tools/mcp_tool_count).
        // The guard denies CALLING mcp__ tools, but these meta-results would
        // still NAME them — so the guard must scrub them. (gpt-5.5 NO-SHIP fix
        // 2026-06-13: the deleted builder guard had this scrub; the mcp__ guard
        // must too, or a bridge turn could enumerate the wired brokerage tool.)
        final class MetaInner: ToolDispatchClient, @unchecked Sendable {
            func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
                switch tool.lowercased() {
                case "tool_catalog", "list_tools", "tool_load":
                    return .object([
                        "available_tools": .array(["shell", "mcp__broker__place_equity_order", "read_file"].map { .string($0) }),
                        "tools": .array([
                            .object(["name": .string("shell")]),
                            .object(["name": .string("mcp__broker__place_equity_order")]),
                            .object(["name": .string("read_file")]),
                        ]),
                        "currently_loaded": .array(["mcp__notion__create_page", "git"].map { .string($0) }),
                    ])
                case "agent_introspect":
                    return .object([
                        "active_tools": .array(["shell", "mcp__broker__place_equity_order", "read_file"].map { .string($0) }),
                        "active_tool_count": .int(3),
                        "mcp_tools": .array(["mcp__broker__place_equity_order", "mcp__notion__create_page"].map { .string($0) }),
                        "mcp_tool_count": .int(2),
                    ])
                default:
                    return .object(["status": .string("reached_inner")])
                }
            }
            func listAvailableTools() async throws -> [String] { [] }
            func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
        }
        let guarded = ClaudeBridgeDenyDispatcher(inner: MetaInner())
        func names(_ v: JSONValue?) -> [String] {
            guard case .array(let a)? = v else { return [] }
            return a.compactMap {
                if case .string(let s) = $0 { return s }
                if case .object(let o) = $0, case .string(let n)? = o["name"] { return n }
                return nil
            }
        }
        for meta in ["tool_catalog", "list_tools", "tool_load"] {
            guard case .object(let obj) = try await guarded.dispatch(tool: meta, input: [:], surface: "claude-bridge") else {
                Issue.record("\(meta) not object"); continue
            }
            for field in ["available_tools", "tools", "currently_loaded"] {
                let ns = names(obj[field])
                #expect(!ns.contains { $0.lowercased().hasPrefix("mcp__") }, "\(meta).\(field) leaked mcp__: \(ns)")
            }
            #expect(names(obj["available_tools"]).contains("shell"), "\(meta) dropped a native tool")
        }
        guard case .object(let intro) = try await guarded.dispatch(tool: "agent_introspect", input: [:], surface: "claude-bridge") else {
            Issue.record("agent_introspect not object"); return
        }
        #expect(names(intro["mcp_tools"]).isEmpty, "mcp_tools not scrubbed")
        #expect(intro["mcp_tool_count"] == .int(0), "mcp_tool_count not zeroed")
        #expect(names(intro["active_tools"]).contains("shell"), "agent_introspect dropped a native tool")
        #expect(!names(intro["active_tools"]).contains { $0.lowercased().hasPrefix("mcp__") }, "active_tools leaked mcp__")
        #expect(intro["active_tool_count"] == .int(2), "active_tool_count not recomputed to native count")
    }

    @Test func bridge_strips_mcp_from_tool_load_input_no_oracle() async throws {
        // tool_load MUTATES the active set keyed on its INPUT names. The guard
        // must strip mcp__ names from the input so the inner never loads/probes
        // an external connector and the session_active_count can't betray that a
        // guessed mcp__ name was valid (existence oracle). gpt-5.5 round-2 NO-SHIP.
        actor LoadInner: ToolDispatchClient {
            private(set) var lastNames: [String] = []
            func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
                var names: [String] = []
                if case .array(let a)? = input["names"] {
                    names = a.compactMap { if case .string(let s) = $0 { return s } else { return nil as String? } }
                }
                lastNames = names
                // An inner that would happily "load" whatever it's handed: count
                // == number of names it received. If the guard let an mcp__ name
                // through, this count would be 3 instead of 2.
                return .object([
                    "status": .string("loaded"),
                    "loaded": .array(names.map { .string($0) }),
                    "session_active_count": .int(Int64(names.count)),
                ])
            }
            func listAvailableTools() async throws -> [String] { [] }
            func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
        }
        let inner = LoadInner()
        let guarded = ClaudeBridgeDenyDispatcher(inner: inner)
        let out = try await guarded.dispatch(
            tool: "tool_load",
            input: ["names": .array(["read_file", "mcp__broker__place_equity_order", "git"].map { .string($0) })],
            surface: "claude-bridge"
        )
        // The inner never SAW the mcp__ name → no load, no probe, no oracle.
        let seen = await inner.lastNames
        #expect(!seen.contains { $0.lowercased().hasPrefix("mcp__") }, "inner saw mcp__ in tool_load input: \(seen)")
        #expect(seen.contains("read_file") && seen.contains("git"), "native load names were dropped: \(seen)")
        // session_active_count reflects only the 2 native names — no delta oracle.
        guard case .object(let o) = out, case .int(let count)? = o["session_active_count"] else {
            Issue.record("no session_active_count"); return
        }
        #expect(count == 2, "session_active_count betrayed the mcp__ name (got \(count))")

        // Singular `name` input is stripped too (an mcp__ single-name load is a no-op).
        _ = try await guarded.dispatch(
            tool: "tool_load",
            input: ["name": .string("mcp__broker__place_equity_order")],
            surface: "claude-bridge"
        )
        let seenSingle = await inner.lastNames
        #expect(seenSingle.isEmpty, "inner saw a singular mcp__ name on tool_load: \(seenSingle)")

        // tool_unload runs through the same input sanitization.
        _ = try await guarded.dispatch(
            tool: "tool_unload",
            input: ["names": .array([.string("mcp__broker__place_equity_order"), .string("read_file")])],
            surface: "claude-bridge"
        )
        let seenUnload = await inner.lastNames
        #expect(!seenUnload.contains { $0.lowercased().hasPrefix("mcp__") }, "inner saw mcp__ on tool_unload: \(seenUnload)")
        #expect(seenUnload.contains("read_file"), "tool_unload dropped a native name")
    }
}
