import Foundation
import NativeAgentCore

// Blueprint: | `FeatureSurfaceRecords.swift` | `FeatureSurfaceRecord` and `featureSurfaceRecords`: feature surface manifest and the app actions that reach each surface |

// MARK: - Feature Surface Records
//
// Current feature surfaces and the app actions that reach them.

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
public let featureSurfaceRecordsCount: Int = 18

/// Build the 18-entry feature-surface manifest.
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
            endpoints: ["app mac.activity", "app workshop.status", "app workshop.submit"]
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
            endpoints: []
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
            endpoints: ["app chat.send", "app chat.list", "app chat.search", "app chat.message"]
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
            endpoints: ["app memory.list", "app memory.rewrite", "app memory.forget", "app memory.consolidate", "app graph.search"]
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
            endpoints: ["app persona.set", "app persona.read"]
        ),
        FeatureSurfaceRecord(
            id: "feature:skills",
            sourceId: "skills",
            name: "Abilities",
            kind: "feature",
            status: "ready",
            description: "The abilities you grow arrive as their own actions (authored.<id>); read their code with ability.read only for review.",
            triggers: ["ability", "skill", "procedure", "run a skill", "repeatable workflow"],
            permissions: [],
            riskClass: "routine",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["app ability.list", "app ability.read", "app authored.<id>", "app ability.save", "app ability.validate", "app ability.enable"]
        ),
        FeatureSurfaceRecord(
            id: "feature:runnable_tools",
            sourceId: "runnable_tools",
            name: "Sandboxed Runnable Tools",
            kind: "feature",
            status: "ready",
            description: "JavaScript tools share the ability lifecycle, exact admission, ordinary Trust gates and explicit repair obligations.",
            triggers: ["tool", "script", "parse", "convert", "validate", "automate"],
            permissions: ["app_data_read"],
            riskClass: "sandboxed_tool",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["app ability.list", "app ability.save", "app ability.validate", "app authored.<id>"]
        ),
        FeatureSurfaceRecord(
            id: "feature:capability_foundry",
            sourceId: "capability_foundry",
            name: "Capability Foundry",
            kind: "feature",
            status: "ready",
            description: "Unified index for feature surfaces, skills, tools, workflows, and catalog packs without loading all bodies into context.",
            triggers: ["capability", "what can you do", "feature", "tool list", "skill list"],
            permissions: [],
            riskClass: "read_only",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["app capabilities.lookup"]
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
            endpoints: []
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
            endpoints: []
        ),
        FeatureSurfaceRecord(
            id: "feature:agent_swarm",
            sourceId: "agent_swarm",
            name: "Bounded Agent Swarm",
            kind: "feature",
            status: "ready",
            description: "Lazy-loaded temporary swarms for bug hunts, reviews, architecture checks, UI critique, research audits, and bounded parallel work. Workers default to read-only reasoning; the agent may opt selected workers into the ordinary TrustCenter-gated NativeAgent tool path. All workers and synthesis use the provider and model configured for Work. Up to 20 workers, bounded by policy.",
            triggers: ["swarm", "subagent", "subagents", "multi-agent", "bug hunt", "parallel review", "review crew", "agent council"],
            permissions: ["provider_oauth_or_key", "trust_center_inherited_tools"],
            riskClass: "bounded_policy_gated",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["app agent.swarm"]
        ),
        FeatureSurfaceRecord(
            id: "feature:research_browser",
            sourceId: "research_browser",
            name: "Research and Browser Runtime",
            kind: "feature",
            status: "ready",
            description: "SearXNG research, URL fetch/source capture, research lab receipts, and live browser actions governed by Trust permissions and approval requirements.",
            triggers: ["research", "search", "web", "browser", "source", "fetch"],
            permissions: ["network"],
            riskClass: "network_read",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: ["app web.search", "app web.read", "app browser.status", "app browser.open", "app browser.text", "app browser.links"]
        ),
        FeatureSurfaceRecord(
            id: "feature:connectors",
            sourceId: "connectors",
            name: "Connector Registry and Actions",
            kind: "feature",
            status: "ready",
            description: "Telegram, SearXNG, local files, native surfaces, email, and calendar connector records with safe dry-run action receipts.",
            triggers: ["connector", "telegram", "calendar", "email", "workspace", "local files"],
            permissions: ["network", "workspace_read"],
            riskClass: "approval_gated",
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nowISO,
            endpoints: []
        ),
        FeatureSurfaceRecord(
            id: "feature:trust_doctor",
            sourceId: "trust_doctor",
            name: "Trust and Doctor",
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
            endpoints: ["app doctor.run", "app setting.get", "app setting.set", "app backup.now", "app doctor.support_report", "app provider.sign_in"]
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
            endpoints: []
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
            endpoints: ["app capabilities.lookup"]
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
            endpoints: []
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
            endpoints: ["app trace.recent", "app export.bundle"]
        ),
    ]
}
