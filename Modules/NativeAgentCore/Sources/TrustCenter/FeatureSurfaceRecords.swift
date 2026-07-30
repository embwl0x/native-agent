import Foundation
import NativeAgentCore

// MARK: - Feature Surface Records (static literal port)
//
// Byte-for-byte port of `NativeAgentRuntime.feature_surface_records()` at
// the retired daemon (read 2026-05-31). The Python source is
// a 309-line static list literal of 19 feature dicts; the only runtime
// value is `updatedAt` (= `now_iso()`), which the Swift caller injects
// at build time so tests can pin a fixed timestamp.
//
// Shape note: each Python dict has the same set of keys. `lastUsedAt` is
// always `None` in the static literal so the Swift port models it as an
// optional that's always nil; the field is preserved so JSON output stays
// byte-equivalent.

public struct FeatureSurfaceRecord: Codable, Sendable, Equatable {
    public var id: String
    public var sourceId: String
    public var name: String
    public var kind: String
    public var status: String
    public var description: String
    public var triggers: [String]
    public var permissions: [String]
    public var riskClass: String
    public var autoload: Bool
    public var useCount: Int
    public var lastUsedAt: String?
    public var updatedAt: String
    public var endpoints: [String]

    public init(
        id: String, sourceId: String, name: String, kind: String,
        status: String, description: String, triggers: [String],
        permissions: [String], riskClass: String, autoload: Bool,
        useCount: Int, lastUsedAt: String?, updatedAt: String,
        endpoints: [String]
    ) {
        self.id = id; self.sourceId = sourceId; self.name = name
        self.kind = kind; self.status = status; self.description = description
        self.triggers = triggers; self.permissions = permissions
        self.riskClass = riskClass; self.autoload = autoload
        self.useCount = useCount; self.lastUsedAt = lastUsedAt
        self.updatedAt = updatedAt; self.endpoints = endpoints
    }
}

/// Number of static feature surface records. Pinned constant so tests
/// can assert parity with the Python source without recomputing the list.
public let featureSurfaceRecordsCount: Int = 19

/// Build the 19-entry feature-surface manifest.
///
/// `nowISO` is injected so tests can pin the timestamp (mirrors the Python
/// `now = now_iso()` line at the retired daemon). Production callers
/// should pass an ISO8601 UTC timestamp matching Python's now_iso().
public func featureSurfaceRecords(nowISO: String) -> [FeatureSurfaceRecord] {
    return [
        FeatureSurfaceRecord(
            id: "feature:command_center",
            sourceId: "command_center",
            name: "Command Center",
            kind: "feature",
            status: "ready",
            description: "System overview, Workshop task counts, recent activity, connector/trust summary, and quick task creation.",
            triggers: ["status", "overview", "task", "mission", "what is running", "command center"],
            permissions: [],
            riskClass: "read_only",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/command/summary", "/v1/activity", "/v1/missions"]
        ),
        FeatureSurfaceRecord(
            id: "feature:mac_assistant_watch_setup",
            sourceId: "mac_assistant_watch_setup",
            name: "Mac Assistant Watch Setup",
            kind: "feature",
            status: "ready",
            description: "Manifest-routed access map and scheduler templates for email, calendar, reminders, Mac notifications, and iPhone receipts. Rendering the surface does not create jobs.",
            triggers: ["watch email", "watch calendar", "watch reminders", "monitor inbox", "assistant jobs", "mac assistant"],
            permissions: ["mac_control", "connector_read", "scheduler"],
            riskClass: "manifest_setup",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/mac-assistant/status", "/v1/connectors/actions"]
        ),
        FeatureSurfaceRecord(
            id: "feature:chat_sessions",
            sourceId: "chat_sessions",
            name: "Persistent Multi-Session Chat",
            kind: "feature",
            status: "ready",
            description: "Restart-safe chat sessions with history, context receipts, Telegram session mapping, and typing state.",
            triggers: ["chat", "conversation", "session", "telegram chat"],
            permissions: [],
            riskClass: "app_data",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/chat", "/v1/chat/sessions", "/v1/chat/messages", "/v1/context/latest"]
        ),
        FeatureSurfaceRecord(
            id: "feature:memory_system",
            sourceId: "memory_system",
            name: "Layered Memory and Skill Memory Graph",
            kind: "feature",
            status: "ready",
            description: "Layered memory retrieval, pin/delete/consolidate controls, graph search, entity memory, vector status, and memory governance actions.",
            triggers: ["remember", "memory", "recall", "graph search", "knowledge"],
            permissions: [],
            riskClass: "app_data",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/memory", "/v1/memory/update", "/v1/memory/delete", "/v1/memory/consolidate", "/v1/graph", "/v1/graph/search", "/v1/memory/vector/status"]
        ),
        FeatureSurfaceRecord(
            id: "feature:personality_engine",
            sourceId: "personality_engine",
            name: "Persona Engine 2.0",
            kind: "feature",
            status: "ready",
            description: "Selectable persona mode, trait sliders, compiled prompt packets, and living SOUL/VOICE/GROWTH/USER documents.",
            triggers: ["personality", "voice", "soul", "female", "male", "AI"],
            permissions: [],
            riskClass: "instruction",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/personality", "/v1/personality/docs", "/v1/personality/compiled"]
        ),
        FeatureSurfaceRecord(
            id: "feature:skills",
            sourceId: "skills",
            name: "Lazy-Loaded Skills",
            kind: "feature",
            status: "ready",
            description: "Reusable instruction skills are indexed by trigger and only full-loaded when relevant.",
            triggers: ["skill", "procedure", "learn this workflow", "repeatable instruction"],
            permissions: [],
            riskClass: "instruction",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/skills", "/v1/skills/update", "/v1/skills/delete"]
        ),
        FeatureSurfaceRecord(
            id: "feature:runnable_tools",
            sourceId: "runnable_tools",
            name: "Sandboxed Runnable Tools",
            kind: "feature",
            status: "ready",
            description: "Signed JSON stdin/stdout tools with manifests, validation, tests, sandbox execution, quarantine, and lazy auto-routing.",
            triggers: ["tool", "script", "parse", "convert", "validate", "automate"],
            permissions: ["app_data_read"],
            riskClass: "sandboxed_tool",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/tools", "/v1/tools/propose", "/v1/tools/validate", "/v1/tools/run"]
        ),
        FeatureSurfaceRecord(
            id: "feature:capability_foundry",
            sourceId: "capability_foundry",
            name: "Capability Foundry",
            kind: "feature",
            status: "ready",
            description: "Unified index for feature surfaces, skills, tools, workflows, MCP servers, and catalog packs without loading all bodies into context.",
            triggers: ["capability", "what can you do", "feature", "tool list", "skill list"],
            permissions: [],
            riskClass: "read_only",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/capabilities", "/v1/agent/map"]
        ),
        FeatureSurfaceRecord(
            id: "feature:proactive_autonomy",
            sourceId: "proactive_autonomy",
            name: "Proactive Autonomy",
            kind: "feature",
            status: "ready",
            description: "Durable goals, opportunity scoring, shadow/notify canaries, outcome receipts, and iOS inbox surfacing for the agent's own ideas.",
            triggers: ["proactive", "ideas", "autonomy", "open loops", "help without asking"],
            permissions: [],
            riskClass: "notify_or_shadow",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/proactive/summary", "/v1/proactive/scan", "/v1/proactive/goals", "/v1/proactive/outcome", "/v1/inbox"]
        ),
        FeatureSurfaceRecord(
            id: "feature:workflows",
            sourceId: "workflows",
            name: "Workflow Orchestrator",
            kind: "feature",
            status: "ready",
            description: "Dry-run and executable workflows with approvals, resume, cancel, rollback, traces, and receipts.",
            triggers: ["workflow", "orchestrate", "steps", "approval", "rollback"],
            permissions: [],
            riskClass: "approval_gated",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/workflows", "/v1/workflows/run", "/v1/workflows/resume", "/v1/workflows/cancel", "/v1/workflows/rollback", "/v1/approvals"]
        ),
        FeatureSurfaceRecord(
            id: "feature:agent_swarm",
            sourceId: "agent_swarm",
            name: "Bounded Agent Swarm",
            kind: "feature",
            status: "ready",
            description: "Lazy-loaded temporary swarms for bug hunts, reviews, architecture checks, UI critique, research audits, and bounded parallel work. Workers default to read-only reasoning; the agent may opt selected workers into the ordinary TrustCenter-gated NativeAgent tool path. The Swarms provider/model is the default and explicit per-worker models may route elsewhere. Up to 20 workers, bounded by policy.",
            triggers: ["swarm", "subagent", "subagents", "multi-agent", "bug hunt", "parallel review", "review crew", "agent council"],
            permissions: ["provider_oauth_or_key", "trust_center_inherited_tools"],
            riskClass: "bounded_policy_gated",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/agent/swarms", "/v1/agent/swarms/run"]
        ),
        FeatureSurfaceRecord(
            id: "feature:mcp_runtime",
            sourceId: "mcp_runtime",
            name: "MCP Runtime",
            kind: "feature",
            status: "ready",
            description: "Internal, stdio, and HTTP MCP discovery/invocation with session warming and consent ledger.",
            triggers: ["mcp", "server", "resource", "tool call", "connector tool"],
            permissions: ["network_localhost"],
            riskClass: "consent_gated",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/mcp/servers", "/v1/mcp/tools", "/v1/mcp/tools/call", "/v1/mcp/sessions", "/v1/mcp/consent"]
        ),
        FeatureSurfaceRecord(
            id: "feature:research_browser",
            sourceId: "research_browser",
            name: "Research and Browser Runtime",
            kind: "feature",
            status: "ready",
            description: "SearXNG research, URL fetch/source capture, research lab receipts, and dry-run browser actions.",
            triggers: ["research", "search", "web", "browser", "source", "fetch"],
            permissions: ["network"],
            riskClass: "network_read",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/research/lab/run", "/v1/research/fetch", "/v1/browser/status", "/v1/browser/run"]
        ),
        FeatureSurfaceRecord(
            id: "feature:connectors",
            sourceId: "connectors",
            name: "Connector Registry and Actions",
            kind: "feature",
            status: "ready",
            description: "Telegram, SearXNG, local files, native surfaces, GitHub, email, and calendar connector records with safe dry-run action receipts.",
            triggers: ["connector", "telegram", "github", "calendar", "email", "workspace", "local files"],
            permissions: ["network", "workspace_read"],
            riskClass: "approval_gated",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/connectors", "/v1/connectors/actions", "/v1/connectors/actions/run", "/v1/connectors/workspaces"]
        ),
        FeatureSurfaceRecord(
            id: "feature:trust_doctor",
            sourceId: "trust_doctor",
            name: "Trust Center and Doctor",
            kind: "feature",
            status: "ready",
            description: "Policy simulation, backups, provider repair, SearXNG autodetect, OAuth browser login, support diagnostics, and release checks.",
            triggers: ["doctor", "repair", "safe", "permission", "trust", "backup", "oauth"],
            permissions: [],
            riskClass: "safety_surface",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/doctor", "/v1/trust", "/v1/trust/simulate", "/v1/backups", "/v1/support/diagnostics", "/v1/auth/login/browser"]
        ),
        FeatureSurfaceRecord(
            id: "feature:auto_improvement",
            sourceId: "auto_improvement",
            name: "Self-Improvement Center",
            kind: "feature",
            status: "ready",
            description: "Directed and recurring app-owned self-improvement, autonomous Codex worktrees, cleanup, gauntlet, and staged receipts.",
            triggers: ["improve", "self improve", "autonomy", "train", "gauntlet"],
            permissions: ["app_owned_worktree"],
            riskClass: "guardrailed_autonomy",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/improvements/summary", "/v1/improvements", "/v1/improvements/recurring", "/v1/improvements/gauntlet", "/v1/improvements/gauntlet/run"]
        ),
        FeatureSurfaceRecord(
            id: "feature:nextgen_runtime",
            sourceId: "nextgen_runtime",
            name: "Next-Gen Runtime Phases 52-112",
            kind: "feature",
            status: "ready",
            description: "Consolidated roadmap/runtime surface with truth audits, durable Workshop tasks, context routing, connector/browser/Mac-control, memory vault, provider router, SDK, release, multimodal, interoperability, and autonomous promotion phases.",
            triggers: ["next gen", "phase", "roadmap", "agent ops", "simulation", "learning loop", "context router"],
            permissions: [],
            riskClass: "receipt_backed",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/nextgen/summary", "/v1/nextgen/phases", "/v1/nextgen/action", "/v1/context/preview", "/v1/context/lookup"]
        ),
        FeatureSurfaceRecord(
            id: "feature:native_mac_power",
            sourceId: "native_mac_power",
            name: "Native macOS Power",
            kind: "feature",
            status: "ready",
            description: "App-owned runtime, native actions, notification readiness, App Intent registry, browser readiness, and local app state.",
            triggers: ["mac", "native", "notification", "app intent", "daemon"],
            permissions: ["macos"],
            riskClass: "approval_gated",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/native-power", "/v1/native-actions", "/v1/native/intents", "/v1/notifications/status"]
        ),
        FeatureSurfaceRecord(
            id: "feature:eval_release_ops",
            sourceId: "eval_release_ops",
            name: "Evals, Release, and Agent Ops",
            kind: "feature",
            status: "ready",
            description: "Eval harness, release checklist, watchdog, runtime traces, production support exports, and ops health snapshots.",
            triggers: ["eval", "test", "release", "watchdog", "ops", "trace", "support export"],
            permissions: [],
            riskClass: "read_only",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["/v1/evals/run", "/v1/release/checklist", "/v1/watchdog", "/v1/traces", "/v1/production/export"]
        ),
    ]
}
