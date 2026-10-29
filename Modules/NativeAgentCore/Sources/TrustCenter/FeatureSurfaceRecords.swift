import Foundation
import NativeAgentCore
import PersistenceCore

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
        sourceId: String, name: String, description: String, triggers: [String],
        permissions: [String], riskClass: String, updatedAt: String,
        endpoints: [String]
    ) {
        self.id = "feature:\(sourceId)"; self.sourceId = sourceId; self.name = name
        self.kind = "feature"; self.status = "ready"; self.description = description
        self.triggers = triggers; self.permissions = permissions
        self.riskClass = riskClass; self.autoload = false
        self.useCount = 0; self.lastUsedAt = nil
        self.updatedAt = updatedAt; self.endpoints = endpoints
    }
}

extension FeatureSurfaceRecord {
    /// Shared feature JSON; an unused record emits an explicit null lastUsedAt.
    public func contextLookupJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "sourceId": .string(sourceId),
            "name": .string(name),
            "kind": .string(kind),
            "status": .string(status),
            "description": .string(description),
            "triggers": .array(triggers.map { .string($0) }),
            "permissions": .array(permissions.map { .string($0) }),
            "riskClass": .string(riskClass),
            "autoload": .bool(autoload),
            "useCount": .int(Int64(useCount)),
            "lastUsedAt": lastUsedAt.map { JSONValue.string($0) } ?? .null,
            "updatedAt": .string(updatedAt),
            "endpoints": .array(endpoints.map { .string($0) }),
        ])
    }
}

/// Build the feature-surface manifest with the supplied ISO8601 UTC timestamp.
public func featureSurfaceRecords(nowISO: String) -> [FeatureSurfaceRecord] {
    return [
        FeatureSurfaceRecord(
            sourceId: "command_center",
            name: "Command Center",
            description: "System overview, Workshop task counts, recent activity, connector/trust summary, and quick task creation.",
            triggers: ["status", "overview", "task", "mission", "what is running", "command center"],
            permissions: [],
            riskClass: "read_only",
            updatedAt: nowISO,
            endpoints: ["app mac.activity", "app workshop.status", "app workshop.submit"]
        ),
        FeatureSurfaceRecord(
            sourceId: "mac_assistant_watch_setup",
            name: "Mac Assistant Watch Setup",
            description: "Manifest-routed access map and scheduler templates for email, calendar, reminders, Mac notifications, and iPhone receipts. Rendering the surface does not create jobs.",
            triggers: ["watch email", "watch calendar", "watch reminders", "monitor inbox", "assistant jobs", "mac assistant"],
            permissions: ["mac_control", "connector_read", "scheduler"],
            riskClass: "manifest_setup",
            updatedAt: nowISO,
            endpoints: []
        ),
        FeatureSurfaceRecord(
            sourceId: "chat_sessions",
            name: "Persistent Multi-Session Chat",
            description: "Restart-safe chat sessions with history, context receipts, Telegram session mapping, and typing state.",
            triggers: ["chat", "conversation", "session", "telegram chat"],
            permissions: [],
            riskClass: "app_data",
            updatedAt: nowISO,
            endpoints: ["app chat.send", "app chat.list", "app chat.search", "app chat.message"]
        ),
        FeatureSurfaceRecord(
            sourceId: "memory_system",
            name: "Layered Memory and Skill Memory Graph",
            description: "Layered memory retrieval, pin/delete controls, graph search, entity memory, vector status, and memory governance actions.",
            triggers: ["remember", "memory", "recall", "graph search", "knowledge"],
            permissions: [],
            riskClass: "app_data",
            updatedAt: nowISO,
            endpoints: ["app memory.list", "app memory.rewrite", "app memory.forget", "app graph.search"]
        ),
        FeatureSurfaceRecord(
            sourceId: "personality_engine",
            name: "Persona Engine 2.0",
            description: "Selectable persona mode, trait sliders, compiled prompt packets, and living SOUL/VOICE/GROWTH/USER documents.",
            triggers: ["personality", "voice", "soul", "female", "male", "AI"],
            permissions: [],
            riskClass: "instruction",
            updatedAt: nowISO,
            endpoints: ["app persona.set", "app persona.read"]
        ),
        FeatureSurfaceRecord(
            sourceId: "skills",
            name: "Abilities",
            description: "The abilities you grow arrive as their own actions (authored.<id>); read their code with ability.read only for review.",
            triggers: ["ability", "skill", "procedure", "run a skill", "repeatable workflow"],
            permissions: [],
            riskClass: "routine",
            updatedAt: nowISO,
            endpoints: ["app ability.list", "app ability.read", "app authored.<id>", "app ability.save", "app ability.validate", "app ability.enable"]
        ),
        FeatureSurfaceRecord(
            sourceId: "runnable_tools",
            name: "Sandboxed Runnable Tools",
            description: "JavaScript tools share the ability lifecycle, exact admission, ordinary Trust gates and explicit repair obligations.",
            triggers: ["tool", "script", "parse", "convert", "validate", "automate"],
            permissions: ["app_data_read"],
            riskClass: "sandboxed_tool",
            updatedAt: nowISO,
            endpoints: ["app ability.list", "app ability.save", "app ability.validate", "app authored.<id>"]
        ),
        FeatureSurfaceRecord(
            sourceId: "capability_foundry",
            name: "Capability Foundry",
            description: "Unified index for feature surfaces, skills, tools, workflows, and catalog packs without loading all bodies into context.",
            triggers: ["capability", "what can you do", "feature", "tool list", "skill list"],
            permissions: [],
            riskClass: "read_only",
            updatedAt: nowISO,
            endpoints: ["app capabilities.lookup"]
        ),
        FeatureSurfaceRecord(
            sourceId: "proactive_autonomy",
            name: "Proactive Autonomy",
            description: "Durable goals, opportunity scoring, shadow/notify canaries, outcome receipts, and iOS inbox surfacing for the agent's own ideas.",
            triggers: ["proactive", "ideas", "autonomy", "open loops", "help without asking"],
            permissions: [],
            riskClass: "notify_or_shadow",
            updatedAt: nowISO,
            endpoints: []
        ),
        FeatureSurfaceRecord(
            sourceId: "workflows",
            name: "Saved Workflows",
            description: "Saved planning templates for tasks with several steps.",
            triggers: ["workflow", "orchestrate", "steps", "approval", "rollback"],
            permissions: [],
            riskClass: "approval_gated",
            updatedAt: nowISO,
            endpoints: []
        ),
        FeatureSurfaceRecord(
            sourceId: "agent_swarm",
            name: "Bounded Agent Swarm",
            description: "Lazy-loaded temporary swarms for bug hunts, reviews, architecture checks, UI critique, research audits, and bounded parallel work. Workers default to read-only reasoning; the agent may opt selected workers into the ordinary TrustCenter-gated NativeAgent tool path. All workers and synthesis use the provider and model configured for Work. Up to 20 workers, bounded by policy.",
            triggers: ["swarm", "subagent", "subagents", "multi-agent", "bug hunt", "parallel review", "review crew", "agent council"],
            permissions: ["provider_oauth_or_key", "trust_center_inherited_tools"],
            riskClass: "bounded_policy_gated",
            updatedAt: nowISO,
            endpoints: ["app agent.swarm"]
        ),
        FeatureSurfaceRecord(
            sourceId: "research_browser",
            name: "Research and Browser Runtime",
            description: "SearXNG research, URL fetch/source capture, research lab receipts, and live browser actions governed by Trust permissions and approval requirements.",
            triggers: ["research", "search", "web", "browser", "source", "fetch"],
            permissions: ["network"],
            riskClass: "network_read",
            updatedAt: nowISO,
            endpoints: ["app web.search", "app web.read", "app browser.status", "app browser.open", "app browser.text", "app browser.links"]
        ),
        FeatureSurfaceRecord(
            sourceId: "connectors",
            name: "Connector Registry and Actions",
            description: "Telegram, SearXNG, local files, native surfaces, email, and calendar connector records with safe dry-run action receipts.",
            triggers: ["connector", "telegram", "calendar", "email", "workspace", "local files"],
            permissions: ["network", "workspace_read"],
            riskClass: "approval_gated",
            updatedAt: nowISO,
            endpoints: []
        ),
        FeatureSurfaceRecord(
            sourceId: "trust_doctor",
            name: "Trust and Doctor",
            description: "Policy simulation, backups, provider repair, SearXNG autodetect, OAuth browser login, support diagnostics, and release checks.",
            triggers: ["doctor", "repair", "safe", "permission", "trust", "backup", "oauth"],
            permissions: [],
            riskClass: "safety_surface",
            updatedAt: nowISO,
            endpoints: ["app doctor.run", "app setting.get", "app setting.set", "app backup.now", "app doctor.support_report", "app provider.sign_in"]
        ),
        FeatureSurfaceRecord(
            sourceId: "auto_improvement",
            name: "Self-Improvement Center",
            description: "Directed and recurring app-owned self-improvement, autonomous Codex worktrees, cleanup, gauntlet, and staged receipts.",
            triggers: ["improve", "self improve", "autonomy", "train", "gauntlet"],
            permissions: ["app_owned_worktree"],
            riskClass: "guardrailed_autonomy",
            updatedAt: nowISO,
            endpoints: []
        ),
        FeatureSurfaceRecord(
            sourceId: "native_mac_power",
            name: "Native macOS Power",
            description: "App-owned runtime, native actions, notification readiness, App Intent registry, browser readiness, and local app state.",
            triggers: ["mac", "native", "notification", "app intent", "daemon"],
            permissions: ["macos"],
            riskClass: "approval_gated",
            updatedAt: nowISO,
            endpoints: []
        ),
        FeatureSurfaceRecord(
            sourceId: "eval_release_ops",
            name: "Evals, Release, and Agent Ops",
            description: "Eval harness, release checklist, watchdog, runtime traces, production support exports, and ops health snapshots.",
            triggers: ["eval", "test", "release", "watchdog", "ops", "trace", "support export"],
            permissions: [],
            riskClass: "read_only",
            updatedAt: nowISO,
            endpoints: ["app trace.recent", "app export.bundle"]
        ),
    ]
}
