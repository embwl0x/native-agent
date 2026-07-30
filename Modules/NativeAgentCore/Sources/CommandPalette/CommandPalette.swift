import Foundation
import NativeAgentCore

// Canonical Swift command palette and search implementation. It builds the
// stable entry skeleton and layers bounded dynamic fields from current owners:
// persona, approvals, trust, connector health, multimodal state, Mac-assistant
// status, and self-improvement counts. `.wave2NeutralBaseline` is retained only
// for callers that intentionally have no live context; production app surfaces
// construct and pass current `CommandPaletteContext` directly.

public struct CommandPaletteEntry: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let category: String
    public let systemImage: String
    public let route: String
    public let endpoint: String
    public let keywords: [String]
    public let status: String
    public let count: Int?

    public init(
        id: String,
        title: String,
        subtitle: String,
        category: String,
        systemImage: String,
        route: String,
        endpoint: String,
        keywords: [String],
        status: String = "ready",
        count: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.systemImage = systemImage
        self.route = route
        self.endpoint = endpoint
        self.keywords = keywords
        self.status = status
        self.count = count
    }
}

public struct CommandPaletteLazyContract: Codable, Sendable, Hashable {
    public let chatInjection: String
    public let inventoryMode: String
    public let opens: String

    public init(
        chatInjection: String = "none",
        inventoryMode: String = "manifest_routed",
        opens: String = "route or endpoint only; command bodies stay lazy until selected"
    ) {
        self.chatInjection = chatInjection
        self.inventoryMode = inventoryMode
        self.opens = opens
    }
}

public struct CommandPaletteResponse: Codable, Sendable, Hashable {
    public let status: String
    public let query: String
    public let entries: [CommandPaletteEntry]
    public let lazyContract: CommandPaletteLazyContract
    public let createdAt: String

    public init(
        status: String,
        query: String,
        entries: [CommandPaletteEntry],
        lazyContract: CommandPaletteLazyContract = CommandPaletteLazyContract(),
        createdAt: String
    ) {
        self.status = status
        self.query = query
        self.entries = entries
        self.lazyContract = lazyContract
        self.createdAt = createdAt
    }
}

// MARK: - Dynamic context

/// Dynamic per-render values injected into `commandPaletteEntries(context:)`.
///
/// Each field maps 1:1 to a Python expression that the daemon's
/// `command_palette_entries()` evaluates at render time. Callers that have a
/// live Swift source-of-truth (PersonaCompiler, ApprovalInbox, TrustCenter)
/// populate the field from that source. Callers without a live runtime at
/// all should use `.wave2NeutralBaseline` (the zero-state baseline);
/// callers with a live runtime but no dynamic-status pipeline should use
/// `.lightweight(...)`, which matches the Python
/// `include_dynamic_statuses=False` branch (only connector/multimodal/
/// mac-assistant go neutral; persona / autonomy counts / trust stay live).
///
/// See the file header CAVEAT for the per-field source/fallback map.
public struct CommandPaletteContext: Sendable, Equatable {
    /// Persona display name. Python: `self.agent_display_name()` (L5814).
    /// Substituted into the `chat` entry subtitle/keyword and the
    /// `operating-map` entry title.
    public let personaName: String

    /// Telegram connector health status. Python:
    /// `connectors_by_id.get("telegram", {}).get("healthStatus") or "optional"` (L5836).
    public let telegramHealthStatus: String

    /// Connector truth summary `needsProof` flag. Python:
    /// `connector_truth_summary().needsProof` driving status="attention"
    /// vs "ready" on the `connector-proof` entry (L5869).
    public let connectorNeedsProof: Bool

    /// Mac-assistant status string. Python:
    /// `mac_assistant_status(lightweight=True).status or "ready"` (L5880).
    /// Drives the `mac-assistant-watch-setup` entry's status field.
    public let macAssistantStatus: String

    /// Mac-assistant template-attention count. Python:
    /// `mac_assistant_status(lightweight=True).templateAttentionCount` (L5881).
    /// Drives the `mac-assistant-watch-setup` entry's count badge.
    public let macAssistantTemplateAttentionCount: Int

    /// Foundry-review count. Python: `autonomy.counts.foundryReview` (L5893).
    /// Drives the `capability-foundry` entry's count badge.
    public let foundryReviewCount: Int

    /// Pending approvals count. Python: `autonomy.counts.pendingApprovals`
    /// (L5904-5905). Drives both the status flip (attention vs ready) and
    /// the count badge on the `approvals` entry.
    public let pendingApprovalsCount: Int

    /// Skill drafts count. Python: `autonomy.counts.skillDrafts` (L5939).
    /// Drives the `skills` entry's count badge.
    public let skillDraftCount: Int

    /// Multimodal workflow status. Python:
    /// `multimodal_workflow_summary().status` (L5812 / used at L5961).
    /// Drives the `screen-vision` entry's status field.
    public let multimodalStatus: String

    /// Trust policy `enableAutonomy` gate. Python:
    /// `trust.get("enableAutonomy")` (L5972). Drives the `operating-map`
    /// entry's status flip (ready vs attention).
    public let enableAutonomy: Bool

    /// Self-improvement failed-run count. Python:
    /// `autonomy.counts.improvementFailed` (L5950), sourced from
    /// `len(failed_improvements)` (runs with `status == "failed"`).
    /// Drives the `self-improvement-scoreboard` entry's status flip
    /// (attention when >0, ready otherwise). Render wiring lands with
    /// wave 10 prereq B; the field is reserved here so `.lightweight(...)`
    /// can accept it.
    public let improvementFailedCount: Int

    public init(
        personaName: String,
        telegramHealthStatus: String = "optional",
        connectorNeedsProof: Bool = false,
        macAssistantStatus: String = "ready",
        macAssistantTemplateAttentionCount: Int = 0,
        foundryReviewCount: Int = 0,
        pendingApprovalsCount: Int = 0,
        skillDraftCount: Int = 0,
        multimodalStatus: String = "ready",
        // Python defaults `attention` when trust.get("enableAutonomy") is
        // missing/false. Mirror that: default false →
        // entry renders "attention" until live trust policy says otherwise.
        enableAutonomy: Bool = false,
        improvementFailedCount: Int = 0
    ) {
        self.personaName = personaName
        self.telegramHealthStatus = telegramHealthStatus
        self.connectorNeedsProof = connectorNeedsProof
        self.macAssistantStatus = macAssistantStatus
        self.macAssistantTemplateAttentionCount = macAssistantTemplateAttentionCount
        self.foundryReviewCount = foundryReviewCount
        self.pendingApprovalsCount = pendingApprovalsCount
        self.skillDraftCount = skillDraftCount
        self.multimodalStatus = multimodalStatus
        self.enableAutonomy = enableAutonomy
        self.improvementFailedCount = improvementFailedCount
    }

    /// Zero-state baseline used by callers that have NO live SwiftNative
    /// context at all (e.g. before runtime is wired at SpotlightOverlay /
    /// MacSyncEngine). Everything neutral: statuses "ready", counts 0,
    /// persona name "NativeAgent", enableAutonomy false (→ operating-map
    /// renders "attention", matching Python's missing-policy baseline at
    /// the retired daemon). This is NOT a true Python-lightweight
    /// match — for that, use `.lightweight(...)`.
    public static let wave2NeutralBaseline = CommandPaletteContext(personaName: "NativeAgent")

    /// True Python `include_dynamic_statuses=False` match (daemon
    /// the retired daemon). Lightweight neutralizes ONLY three fields:
    ///   - `connectorNeedsProof` ← `connector_truth = {}` → false → status "ready"
    ///   - `macAssistantStatus` / `macAssistantTemplateAttentionCount` ← "ready" / 0
    ///   - `multimodalStatus` ← "ready"
    /// Everything else stays live (persona name, autonomy.counts.* quad,
    /// trust.enableAutonomy, telegram healthStatus) because the daemon's
    /// lightweight branch still computes them unconditionally at L5797-5805.
    /// Use this from callers that have a live runtime but no Swift port of
    /// the connector / mac-assistant / multimodal subsystems.
    public static func lightweight(
        personaName: String,
        telegramHealthStatus: String = "optional",
        pendingApprovalsCount: Int = 0,
        foundryReviewCount: Int = 0,
        skillDraftCount: Int = 0,
        improvementFailedCount: Int = 0,
        enableAutonomy: Bool = false
    ) -> CommandPaletteContext {
        return CommandPaletteContext(
            personaName: personaName,
            telegramHealthStatus: telegramHealthStatus,
            connectorNeedsProof: false,
            macAssistantStatus: "ready",
            macAssistantTemplateAttentionCount: 0,
            foundryReviewCount: foundryReviewCount,
            pendingApprovalsCount: pendingApprovalsCount,
            skillDraftCount: skillDraftCount,
            multimodalStatus: "ready",
            enableAutonomy: enableAutonomy,
            improvementFailedCount: improvementFailedCount
        )
    }
}

// MARK: - Entries

/// Builds the 14-entry command palette manifest, injecting dynamic per-entry
/// fields from `context`. Mirrors `command_palette_entries()` at
/// the retired daemon — same ids, titles, subtitles,
/// categories, systemImages, routes, endpoints, keywords. Status and count
/// fields use the values from `context` so the static manifest looks alive
/// (badge counts, attention flips) instead of the wave-2 dormant skeleton.
public func commandPaletteEntries(
    context: CommandPaletteContext = .wave2NeutralBaseline
) -> [CommandPaletteEntry] {
    let nameLower = context.personaName.lowercased()
    return [
        CommandPaletteEntry(
            id: "chat",
            title: "Chat",
            // L5819: f"Talk to {agent_name} with routed context and lazy tools."
            subtitle: "Talk to \(context.personaName) with routed context and lazy tools.",
            category: "core",
            systemImage: "bubble.left.and.bubble.right",
            route: "sidebar:chat",
            endpoint: "/v1/chat",
            // L5824: ["ask", "agent", "message", "conversation", agent_name.lower()]
            keywords: ["ask", "agent", "message", "conversation", nameLower]
        ),
        CommandPaletteEntry(
            id: "telegram-config",
            title: "Telegram Config",
            subtitle: "Bot token, allowed chat IDs, group IDs, commands, and local voice transcription.",
            category: "settings",
            systemImage: "paperplane",
            route: "sidebar:telegram",
            endpoint: "/v1/telegram/status",
            keywords: ["telegram", "bot", "group", "chat id", "slash", "voice"],
            // L5836: connectors_by_id.get("telegram", {}).get("healthStatus") or "optional"
            status: context.telegramHealthStatus
        ),
        CommandPaletteEntry(
            id: "memory-hygiene",
            title: "Memory Hygiene",
            subtitle: "Review confidence, stale facts, consolidation, tombstones, KG/vector status.",
            category: "memory",
            systemImage: "brain.head.profile",
            route: "sidebar:memories",
            endpoint: "/v1/memory/v2/status",
            keywords: ["memory", "kg", "graph", "consolidate", "stale", "confidence", "hygiene"]
        ),
        CommandPaletteEntry(
            id: "provider-settings",
            title: "Provider Settings",
            subtitle: "Model routing, local/API providers, keys, tests, and active provider.",
            category: "settings",
            systemImage: "server.rack",
            route: "sidebar:providers",
            endpoint: "/v1/providers",
            keywords: ["provider", "model", "openai", "anthropic", "local", "api key"]
        ),
        CommandPaletteEntry(
            id: "connector-proof",
            title: "Connector Proof",
            subtitle: "Shows which OAuth connectors are token-only versus account-proven.",
            category: "settings",
            systemImage: "checkmark.seal",
            route: "sidebar:connectors",
            endpoint: "/v1/connectors/proof",
            keywords: ["connector", "oauth", "proof", "gmail", "calendar", "github", "real"],
            // L5869: "attention" if connector_truth.get("needsProof") else "ready"
            status: context.connectorNeedsProof ? "attention" : "ready"
        ),
        CommandPaletteEntry(
            id: "mac-assistant-watch-setup",
            title: "Mac Assistant Watch Setup",
            subtitle: "Access readiness and scheduler templates for email, calendar, reminders, Mac notifications, and iPhone receipts.",
            category: "ops",
            systemImage: "eye",
            route: "sidebar:trust",
            endpoint: "/v1/mac-assistant/status",
            keywords: ["watch", "monitor", "email", "mail", "calendar", "reminders", "assistant", "mac control", "jobs", "scheduler"],
            // L5880: mac_assistant_status.get("status") or "ready"
            status: context.macAssistantStatus,
            // L5881: int(mac_assistant_status.get("templateAttentionCount") or 0)
            count: context.macAssistantTemplateAttentionCount
        ),
        CommandPaletteEntry(
            id: "capability-foundry",
            title: "Capability Foundry",
            subtitle: "Build lazy skills, tools, workflows, plugins, and MCP manifests without prompt bloat.",
            category: "capabilities",
            systemImage: "shippingbox",
            route: "sidebar:capabilities",
            endpoint: "/v1/capability-foundry",
            keywords: ["capability", "foundry", "skill", "tool", "plugin", "mcp", "workflow"],
            // L5893: int(counts.get("foundryReview") or 0)
            count: context.foundryReviewCount
        ),
        CommandPaletteEntry(
            id: "approvals",
            title: "Approvals",
            subtitle: "Resolve policy gates and pending remote approvals.",
            category: "activity",
            systemImage: "checkmark.shield",
            route: "sidebar:activity/approvals",
            endpoint: "/v1/approvals",
            keywords: ["approval", "approve", "deny", "permission", "gate", "inbox"],
            // L5904: "attention" if int(counts.get("pendingApprovals") or 0) else "ready"
            status: context.pendingApprovalsCount > 0 ? "attention" : "ready",
            // L5905: int(counts.get("pendingApprovals") or 0)
            count: context.pendingApprovalsCount
        ),
        CommandPaletteEntry(
            id: "doctor",
            title: "Doctor",
            subtitle: "Diagnostics, logs, readiness checks, repair actions, and support exports.",
            category: "ops",
            systemImage: "stethoscope",
            route: "sidebar:diagnostics",
            endpoint: "/v1/doctor",
            keywords: ["doctor", "diagnostics", "health", "repair", "status", "logs"]
        ),
        CommandPaletteEntry(
            id: "logs",
            title: "Logs and Receipts",
            subtitle: "Activity, traces, action receipts, harness learning, and next-gen receipts.",
            category: "ops",
            systemImage: "doc.text.magnifyingglass",
            route: "sidebar:command",
            endpoint: "/v1/activity",
            keywords: ["logs", "receipts", "trace", "activity", "what happened", "proof"]
        ),
        CommandPaletteEntry(
            id: "skills",
            title: "Skills",
            subtitle: "Lazy skill inventory, drafts, activation, usage evidence, and skill bodies.",
            category: "capabilities",
            systemImage: "puzzlepiece.extension",
            route: "sidebar:skills",
            endpoint: "/v1/skills",
            keywords: ["skills", "draft", "activate", "procedure", "ability"],
            // L5939: int(counts.get("skillDrafts") or 0)
            count: context.skillDraftCount
        ),
        CommandPaletteEntry(
            id: "self-improvement-scoreboard",
            title: "Self-Improvement Scoreboard",
            subtitle: "Tracks whether upgrades helped before making them permanent.",
            category: "autonomy",
            systemImage: "chart.line.uptrend.xyaxis",
            route: "sidebar:activity/self-improvement",
            endpoint: "/v1/coordination/summary",
            keywords: ["self improvement", "scoreboard", "faster", "retries", "corrections", "permanent"],
            // L5950: "attention" if int(counts.get("improvementFailed") or 0) else "ready"
            status: context.improvementFailedCount > 0 ? "attention" : "ready"
        ),
        CommandPaletteEntry(
            id: "screen-vision",
            title: "Screen and Vision",
            subtitle: "Screen capture, photo vision, file ingest, and voice workflow readiness.",
            category: "multimodal",
            systemImage: "camera.viewfinder",
            route: "sidebar:command",
            endpoint: "/v1/multimodal/status",
            keywords: ["screen", "vision", "photo", "image", "voice", "multimodal", "screenshot"],
            // L5961: status = multimodal_status
            status: context.multimodalStatus
        ),
        CommandPaletteEntry(
            id: "operating-map",
            // L5965: f"{agent_name} Operating Map"
            title: "\(context.personaName) Operating Map",
            subtitle: "Compact map of abilities, policy, recent learning, broken/disabled areas, and build options.",
            category: "autonomy",
            systemImage: "map",
            route: "sidebar:command",
            endpoint: "/v1/agent/map",
            keywords: ["operating map", "what can you do", "allowed", "broken", "disabled"],
            // L5972: "ready" if trust.get("enableAutonomy") else "attention"
            status: context.enableAutonomy ? "ready" : "attention"
        ),
    ]
}

// MARK: - Search

/// Mirrors `keyword_tokens(value)` at the retired daemon.
/// Regex `[a-zA-Z0-9_][a-zA-Z0-9_-]{2,}` over the lowercased input, minus the
/// fixed stopword set the daemon uses. Returned as a sorted array for
/// deterministic scoring order; the daemon uses a Python set but iterates it
/// per entry and the score is order-independent.
public func commandPaletteKeywordTokens(_ value: String) -> [String] {
    let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into",
        "your", "you", "are", "how", "what",
    ]
    let lower = value.lowercased()
    // [a-zA-Z0-9_][a-zA-Z0-9_-]{2,} === one leading word char, then 2+ word-or-dash chars.
    // After lowercasing the alpha range collapses to [a-z0-9_].
    guard let regex = try? NSRegularExpression(
        pattern: "[a-z0-9_][a-z0-9_-]{2,}",
        options: []
    ) else {
        return []
    }
    let nsLower = lower as NSString
    let matches = regex.matches(in: lower, options: [], range: NSRange(location: 0, length: nsLower.length))
    var seen: Set<String> = []
    var result: [String] = []
    for match in matches {
        let tok = nsLower.substring(with: match.range)
        if stopwords.contains(tok) { continue }
        if seen.insert(tok).inserted {
            result.append(tok)
        }
    }
    return result
}

/// Pure search-over-context-rendered entries. Mirrors `command_palette(q, limit)`
/// at the retired daemon. Scoring:
///   * Empty token set => return entries[:limit] unchanged.
///   * Otherwise per entry build `haystack = title + " " + subtitle + " " +
///     category + " " + keywords.joined(" ")` lowercased; for each token in the
///     query, if token is in haystack add 3 if token also appears in title,
///     else 1. Drop entries with score 0. Sort by (score desc, title desc).
///     Return top-limit entries.
/// The daemon's clamp `limit = max(1, min(limit, 100))` is replicated.
public func searchCommandPalette(
    _ query: String,
    limit: Int = 50,
    context: CommandPaletteContext = .wave2NeutralBaseline
) -> [CommandPaletteEntry] {
    let entries = commandPaletteEntries(context: context)
    let clampedLimit = max(1, min(limit, 100))
    let tokens = commandPaletteKeywordTokens(query)
    if tokens.isEmpty {
        return Array(entries.prefix(clampedLimit))
    }
    var scored: [(Int, CommandPaletteEntry)] = []
    scored.reserveCapacity(entries.count)
    for entry in entries {
        let titleLower = entry.title.lowercased()
        let haystack = [
            entry.title,
            entry.subtitle,
            entry.category,
            entry.keywords.joined(separator: " "),
        ].joined(separator: " ").lowercased()
        var score = 0
        for token in tokens where haystack.contains(token) {
            score += titleLower.contains(token) ? 3 : 1
        }
        if score > 0 {
            scored.append((score, entry))
        }
    }
    scored.sort { lhs, rhs in
        if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
        return lhs.1.title > rhs.1.title
    }
    return Array(scored.prefix(clampedLimit).map { $0.1 })
}

/// Wraps the search result in the daemon's `/v1/command/palette` response envelope.
/// `createdAt` is RFC3339 (matches `now_iso()` in the daemon). Provided so callers
/// who want byte-similar parity can use it; the in-app HTTP-bypass path actually
/// only needs `[CommandPaletteEntry]` and constructs no envelope.
public func commandPaletteResponse(
    query: String,
    limit: Int = 50,
    context: CommandPaletteContext = .wave2NeutralBaseline,
    now: Date = Date()
) -> CommandPaletteResponse {
    let result = searchCommandPalette(query, limit: limit, context: context)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return CommandPaletteResponse(
        status: "ready",
        query: query,
        entries: result,
        createdAt: formatter.string(from: now)
    )
}
