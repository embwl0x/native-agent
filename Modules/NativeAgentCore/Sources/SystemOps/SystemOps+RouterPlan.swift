import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - SwiftNative — RouterPlan

public struct SwiftNativeRouterPlanClient: RouterPlanClient {
    private let now: @Sendable () -> Date
    private let idFactory: @Sendable () -> String

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        idFactory: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.now = now
        self.idFactory = idFactory
    }

    public func planRoute(message: String) async throws -> RoutePlanResult {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw SystemOpsError.missingMessage }
        let tokens = keywordTokens(trimmed)
        let lower = trimmed.lowercased()
        let webAddressRequest = Self.containsWebAddress(trimmed)
        let toolTokenRequestsCreation = tokens.contains("tool") &&
            (!UserMessageIntentSignals.explicitlyProhibitsToolUse(trimmed) ||
             UserMessageIntentSignals.explicitlyRequestsToolCreation(trimmed))

        let goalType: String
        let repoStateRequest = !tokens.isDisjoint(with: ["git", "repo", "repository"]) &&
            (!tokens.isDisjoint(with: [
                "status", "diff", "log", "commit", "branch", "stash",
                "checkout", "merge", "rebase", "changes", "changed",
                "state", "stands", "standing",
            ]) ||
            lower.contains("where the repo stands") ||
            lower.contains("where the repository stands") ||
            lower.contains("where nativeagent repo stands") ||
            lower.contains("where the nativeagent repo stands"))
        let calendarReadRequest = !tokens.isDisjoint(with: [
            "calendar", "calendars", "meeting", "meetings", "appointment",
            "appointments", "event", "events",
        ]) && !tokens.isDisjoint(with: [
            "today", "tomorrow", "upcoming", "anything", "have", "busy",
            "free", "coding", "block", "blocks",
        ])
        let fileNounRequest = !tokens.isDisjoint(with: [
            "file", "files", "folder", "folders", "filename", "filenames",
            "handoff", "readme", "docs", "doc", "document", "documents",
            "documentation",
        ])
        let explicitResearchReadiness = tokens.contains("research") ||
            lower.contains("search the web") ||
            lower.contains("search online")

        // FIX 2 / B1.2: connector-target detection. A github (or other
        // connector) -shaped request was falling through to `chat`/`minimal`,
        // so the plan surfaced no connector capabilities and — worse — a
        // MUTATING connector action inherited the chat default of risk=low with
        // no approval hint. Route these to a `connector` goal on a `capability`
        // context (the capability matcher surfaces connector_action records in
        // that mode), and below give mutations their real risk tier. This is a
        // routing HINT only — TrustCenter already gates github_mutate as
        // `confirm`; SecurityCenter/TrustCenter are untouched. Detection is
        // deliberately conservative (bare "github"/"gh" token or the exact
        // "pull request" phrase) so ordinary local-git and build turns keep
        // their existing routes.
        let connectorTargetRequest = tokens.contains("github") ||
            tokens.contains("gh") ||
            lower.contains("pull request") ||
            lower.contains("pull-request")
        // Mutating connector verbs. "open"/"request"/"update" are deliberately
        // OMITTED — they collide with read phrasings ("open PRs", "the pull
        // request"), and under-tagging a mutation as read is a safer miss than
        // over-tagging a read as a high-risk mutation (the plan caveat below).
        let connectorMutateRequest = connectorTargetRequest && !tokens.isDisjoint(with: [
            "create", "merge", "close", "comment", "approve", "reopen",
            "delete", "edit", "assign", "label", "push", "rename",
        ])

        if !tokens.isDisjoint(with: ["approve", "approval", "deny", "permission", "gate"]) {
            goalType = "approval"
        } else if !tokens.isDisjoint(with: ["telegram", "bot", "group", "chatid", "slash"]) {
            goalType = "telegram"
        } else if calendarReadRequest {
            goalType = "schedule"
        } else if !tokens.isDisjoint(with: ["watch", "monitor", "watching"]) &&
                  !tokens.isDisjoint(with: ["email", "mail", "inbox", "calendar", "reminder", "reminders"]) {
            goalType = "schedule"
        } else if !tokens.isDisjoint(with: ["schedule", "scheduler", "remind", "recurring", "automation", "cron"]) {
            goalType = "schedule"
        } else if !tokens.isDisjoint(with: ["memory", "remember", "forget", "recall", "consolidate", "stale", "confidence"]) {
            goalType = "memory_update"
        } else if !tokens.isDisjoint(with: ["control", "mac", "shortcut", "spotlight", "window", "screen", "file", "folder"]) &&
                  (tokens.contains("mac") || tokens.contains("shortcut") || tokens.contains("spotlight") || tokens.contains("screen")) {
            goalType = "mac_control"
        } else if connectorTargetRequest {
            // Ahead of research so "search github issues" routes to the connector
            // (github.search) rather than the web research lab. A bare github URL
            // carries no standalone "github" token, so it still falls to research
            // via webAddressRequest below.
            goalType = "connector"
        } else if webAddressRequest || !tokens.isDisjoint(with: ["research", "search", "source", "find", "web"]) {
            goalType = "research"
        } else if !tokens.isDisjoint(with: ["workflow", "automate", "steps", "repeat"]) {
            goalType = "workflow"
        } else if toolTokenRequestsCreation ||
                  !tokens.isDisjoint(with: ["script", "parse", "convert", "calculate"]) {
            goalType = "tool_creation"
        } else if !tokens.isDisjoint(with: ["improve", "self", "autonomy", "train"]) ||
                  lower.contains("self-improvement") || lower.contains("self improvement") {
            goalType = "self_improvement"
        } else if repoStateRequest {
            goalType = "build_task"
        } else if !tokens.isDisjoint(with: ["build", "code", "implement", "fix", "test", "xcode", "swift", "python"]) {
            goalType = "build_task"
        } else if !tokens.isDisjoint(with: ["personality", "voice", "male", "female", "human"]) {
            goalType = "personality"
        } else if UserMessageIntentSignals.containsLikelyLocalPath(in: trimmed) ||
                  fileNounRequest {
            goalType = "file_work"
        } else {
            goalType = "chat"
        }

        let routeMode: String = {
            switch goalType {
            case "approval": return "ops"
            case "telegram": return "capability"
            case "schedule": return "ops"
            case "memory_update": return "memory"
            case "mac_control": return "ops"
            case "build_task": return "capability"
            case "research": return "research"
            case "workflow": return "workflow"
            case "tool_creation": return "workflow"
            case "self_improvement": return "ops"
            case "personality": return "personality"
            case "file_work": return "capability"
            case "connector": return "capability"
            case "chat": return "minimal"
            default: return "capability"
            }
        }()

        // Conservative policy_simulate stand-in (see RESIDUAL CAVEATS).
        var risk = "low"
        var requiresApproval = false
        switch goalType {
        case "file_work":
            risk = "low"; requiresApproval = false
        case "build_task":
            risk = "low"; requiresApproval = false
        case "tool_creation":
            // Matches Python's policy_simulate({action:"tool_run",
            // permissions:["shell"]}) — `shell` is in RISKY_TOOL_PERMISSIONS,
            // which sets risk=high + requires_approval=true
            //.
            risk = "high"; requiresApproval = true
        case "mac_control":
            risk = "medium"; requiresApproval = true
        case "approval":
            risk = "low"; requiresApproval = false
        case "connector":
            // Read-only connector actions (list/get/status/search) are low risk;
            // a mutation override below raises writes to their real tier.
            risk = "low"; requiresApproval = false
        default:
            break
        }

        let watchSetupRequest = (goalType == "schedule") &&
            !tokens.isDisjoint(with: ["watch", "monitor", "watching"]) &&
            !tokens.isDisjoint(with: ["email", "mail", "inbox", "calendar", "reminder", "reminders"])
        if watchSetupRequest {
            risk = "medium"
        }
        let calendarMutationRequest = tokens.contains("calendar") &&
            !tokens.isDisjoint(with: [
                "add", "book", "cancel", "create", "delete", "invite",
                "move", "reschedule", "schedule", "send", "update",
            ])
        let communicationRequest = !tokens.isDisjoint(with: [
            "email", "emails", "message", "messages", "post", "posts",
        ])
        if (communicationRequest || calendarMutationRequest) &&
            !watchSetupRequest {
            risk = "high"
            requiresApproval = true
        }
        // FIX 2 / B1.2(b): a MUTATING connector action (merge/close/comment/…)
        // carries a real write risk tier and an approval hint — it must not
        // inherit the connector read default of risk=low/no-approval. Mirrors
        // the communication/calendar-mutation override above.
        if connectorMutateRequest {
            risk = "high"
            requiresApproval = true
        }

        let recommendedSurface: String = {
            switch goalType {
            case "research": return "research_lab"
            case "workflow": return "workflow"
            case "tool_creation": return "workflow"
            case "self_improvement": return "self_improvement"
            case "approval": return "activity"
            case "telegram": return "telegram"
            case "schedule": return "scheduler"
            case "memory_update": return "memories"
            case "mac_control": return "mac_control"
            case "build_task": return "chat"
            case "connector": return "chat"
            default: return "chat"
            }
        }()

        let createdAt = Self.isoTimestamp(now())
        let matched = selectContextCapabilities(
            records: swiftNativeCapabilityRecords(nowISO: createdAt),
            message: trimmed,
            mode: routeMode,
            limit: 8
        )
        let hasMatch = !matched.isEmpty
        let nextActions = Self.routeNextActions(
            goalType: goalType,
            hasMatch: hasMatch,
            requiresApproval: requiresApproval
        )
        // Route-owned readiness is deliberately narrower than goalType. A
        // generic mention of Swift or code may be conversational, while a
        // repo-state request already proved it needs repository inspection.
        // Readiness exposes schemas only; every call still crosses the normal
        // TrustCenter, approval, and effect-time gates.
        let toolReadinessGroups: [String]
        if repoStateRequest {
            toolReadinessGroups = ["builder"]
        } else if goalType == "file_work" {
            toolReadinessGroups = ["files"]
        } else if webAddressRequest {
            toolReadinessGroups = ["browser"]
        } else if goalType == "research", explicitResearchReadiness {
            toolReadinessGroups = ["research"]
        } else {
            toolReadinessGroups = []
        }

        return RoutePlanResult(
            id: idFactory(),
            message: trimmed,
            goalType: goalType,
            recommendedSurface: recommendedSurface,
            contextMode: routeMode,
            risk: risk,
            requiresApproval: requiresApproval,
            matchedCapabilities: matched,
            toolReadinessGroups: toolReadinessGroups,
            nextActions: nextActions,
            createdAt: createdAt
        )
    }

    /// Port of `route_next_actions` byte-for-byte.
    public static func routeNextActions(goalType: String, hasMatch: Bool, requiresApproval: Bool) -> [String] {
        if requiresApproval {
            return ["Create an approval receipt before external or risky actions run."]
        }
        switch goalType {
        case "research":
            return ["Run Research Lab", "Capture sources", "Write a brief"]
        case "workflow":
            return ["Create or select a workflow", "Dry-run steps", "Record receipts"]
        case "tool_creation":
            return ["Propose app-owned tool", "Validate in sandbox", "Promote only if safe"]
        case "build_task":
            return ["Inspect workspace state", "Apply focused edits", "Run targeted verification", "Record receipt if behavior changes"]
        case "memory_update":
            return ["Check memory confidence and provenance", "Write, correct, consolidate, or tombstone through memory endpoints"]
        case "mac_control":
            return ["Check Mac Control policy", "Dry-run where possible", "Execute through native action/Mac Control receipt path"]
        case "approval":
            return ["Open approval queue", "Resolve the exact pending item once", "Record decision receipt"]
        case "schedule":
            return ["Inspect Mac Assistant watch templates", "Inspect scheduler state", "Create or update the job", "Leave a notification/receipt trail"]
        case "telegram":
            return ["Check Telegram config and allowed chat IDs", "Use local transcription for voice", "Record Telegram receipt"]
        case "self_improvement":
            return ["Start app-owned improvement worktree", "Run tests", "Stage receipt-backed diff"]
        case "connector":
            return ["Confirm the connector is authorized", "Read current state first (list/get/status)", "Record a connector receipt for any action"]
        default:
            if hasMatch {
                return ["Load matched capability only for this turn", "Record usage metadata"]
            }
            return ["Answer in chat", "Distill a reusable skill if the task repeats"]
        }
    }

    /// ISO-8601 with fractional seconds + `+00:00` — matches the retired
    /// `now_iso()` (same convention as SwiftNativeResearchClient).
    public static func isoTimestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let zulu = fmt.string(from: date)
        if zulu.hasSuffix("Z") { return String(zulu.dropLast()) + "+00:00" }
        return zulu
    }

    private static func containsWebAddress(_ message: String) -> Bool {
        let trimChars = CharacterSet(charactersIn: ".,!?;:)('\"`<>")
        for raw in message.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            let token = raw.trimmingCharacters(in: trimChars)
            if token.hasPrefix("http://") || token.hasPrefix("https://") { return true }
            if token.contains("://") { return true }
            guard token.rangeOfCharacter(from: .letters) != nil else { continue }
            let host = String(token.split(separator: "/", maxSplits: 1).first ?? "")
            guard host.contains(".") else { continue }
            let parts = host.split(separator: ".")
            guard parts.count >= 2, let tld = parts.last, tld.count >= 2 else { continue }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
            if host.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                return true
            }
        }
        return false
    }
}
