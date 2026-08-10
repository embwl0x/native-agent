import Foundation
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

enum ExperienceReadinessState: String, CaseIterable, Codable, Sendable {
    case unavailable
    case needsSetup = "needs_setup"
    case awaitingTrust = "awaiting_trust"
    case ready
    case degraded

    var title: String {
        switch self {
        case .unavailable: "Unavailable"
        case .needsSetup: "Needs setup"
        case .awaitingTrust: "Awaiting trust"
        case .ready: "Ready"
        case .degraded: "Degraded"
        }
    }

    var rank: Int {
        switch self {
        case .unavailable: 0
        case .needsSetup: 1
        case .awaitingTrust: 2
        case .degraded: 3
        case .ready: 4
        }
    }
}

struct ExperienceReadinessItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let category: String
    let state: ExperienceReadinessState
    let reason: String
    let fixDestination: SidebarItem?
    let checkedAt: String?
}

enum ExperienceDiagnosticKind: String, Codable, Sendable, CaseIterable {
    case turn
    case provider
    case tool
    case memory
    case backgroundJob = "background_job"
    case swarm
    case context
    case cognition
    case unknown
}

struct ExperienceDiagnosticEvent: Identifiable, Hashable, Sendable {
    let id: String
    let turnId: String
    let date: Date
    let kind: ExperienceDiagnosticKind
    let phase: String
    let status: String
    let title: String
    let sessionId: String?
    let surface: String?
    let sourceKind: String
    let fields: [String: String]

    static func project(_ event: TurnTraceEvent, ordinal: Int) -> Self {
        let object: [String: JSONValue]
        if case .object(let value) = event.payload { object = value } else { object = [:] }
        let phase = string(object["phase"])
            ?? string(object["stage"])
            ?? defaultPhase(for: event.kind)
        let status = string(object["status"])
            ?? string(object["resultClass"])
            ?? "observed"
        let title = string(object["name"])
            ?? string(object["tool"])
            ?? string(object["model"])
            ?? event.kind
        var fields: [String: String] = [:]
        for key in [
            "provider", "model", "tool", "durationMs", "inputTokens",
            "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens",
            "toolSchemaCount", "toolSchemaMaterialBytes", "resultClass"
        ] {
            if let value = scalar(object[key]) { fields[key] = value }
        }
        return ExperienceDiagnosticEvent(
            id: "\(event.turnId):\(event.ts.timeIntervalSince1970):\(ordinal)",
            turnId: event.turnId,
            date: event.ts,
            kind: diagnosticKind(for: event.kind),
            phase: phase,
            status: status,
            title: title,
            sessionId: event.sessionId,
            surface: event.surface,
            sourceKind: event.kind,
            fields: fields
        )
    }

    private static func diagnosticKind(for source: String) -> ExperienceDiagnosticKind {
        if source == "llm.call" || source.hasPrefix("provider.") { return .provider }
        if source.hasPrefix("tool.") || source == "file.touch" { return .tool }
        if source.hasPrefix("memory.") { return .memory }
        if source.hasPrefix("background.") || source.hasPrefix("scheduler.") { return .backgroundJob }
        if source.hasPrefix("swarm.") { return .swarm }
        if source.hasPrefix("context.") || source == "assembly.stage" { return .context }
        if source.hasPrefix("cognition.") || source.hasPrefix("organism.") { return .cognition }
        if source.hasPrefix("turn.") || source == "stream.tick" { return .turn }
        return .unknown
    }

    private static func defaultPhase(for source: String) -> String {
        if source.hasSuffix(".started") { return "started" }
        if source.hasSuffix(".completed") { return "completed" }
        return "observed"
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value, !string.isEmpty else { return nil }
        return string
    }

    private static func scalar(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): String(value)
        default: nil
        }
    }
}

struct ExperienceContextSource: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let kind: String
    let characters: Int
    let cached: Bool?
}

struct ExperienceContextEconomics: Hashable, Sendable {
    let turnId: String?
    let sessionId: String
    let provider: String?
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let estimatedCostUSD: Double?
    let contextCharacters: Int?
    let contextBudget: Int?
    let contextRemaining: Int?
    let toolSchemaCount: Int?
    let toolSchemaBytes: Int?
    let cacheStatus: String?
    let sources: [ExperienceContextSource]
    let selectedMemoryCount: Int
    let selectedSkillCount: Int
    let selectedToolCount: Int
    let routeReasons: [String]
    let omittedReasons: [String]

    static func project(
        receipt: ContextReceipt?,
        sessionId: String,
        events: [TurnTraceEvent],
        providers: [ProviderInfo]
    ) -> Self {
        let relevant = events.filter { event in
            if let run = receipt?.runId, event.turnId == run { return true }
            return event.sessionId == sessionId
        }
        let llm = relevant.last(where: { $0.kind == "llm.call" })
        let snapshot = relevant.last(where: { $0.kind == "context.snapshot" })
            ?? relevant.last(where: { $0.kind == "assembly.stage" })
        let llmObject = object(llm?.payload)
        let snapshotObject = object(snapshot?.payload)
        let provider = string(llmObject["provider"])
        let model = string(llmObject["model"])
        let input = int(llmObject["inputTokens"])
        let output = int(llmObject["outputTokens"])
        let cacheRead = int(llmObject["cacheReadInputTokens"])
        let cacheWrite = int(llmObject["cacheCreationInputTokens"])
        let pricing = providers
            .first(where: { $0.provider_id == provider })?
            .models.first(where: { $0.id == model })
        let cost: Double? = {
            guard input != nil || output != nil else { return nil }
            let inputCost = Double(input ?? 0) / 1_000 * (pricing?.cost_per_1k_in ?? 0)
            let outputCost = Double(output ?? 0) / 1_000 * (pricing?.cost_per_1k_out ?? 0)
            guard pricing?.cost_per_1k_in != nil || pricing?.cost_per_1k_out != nil else { return nil }
            return inputCost + outputCost
        }()
        let budget = receipt?.budgetTotals ?? receipt?.budgets
        let sources = (receipt?.injectedSections ?? []).map {
            ExperienceContextSource(
                id: $0.id,
                title: $0.displayTitle,
                kind: $0.kind ?? "context",
                characters: max(0, $0.chars ?? 0),
                cached: $0.cached
            )
        }
        let routeReasons = receipt?.routeReasons ?? []
        let omitted = routeReasons.filter {
            let lower = $0.lowercased()
            return lower.contains("omit") || lower.contains("budget")
                || lower.contains("truncate") || lower.contains("degraded")
        }
        return ExperienceContextEconomics(
            turnId: receipt?.runId ?? llm?.turnId,
            sessionId: sessionId,
            provider: provider,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            estimatedCostUSD: cost,
            contextCharacters: budget?.displayTotal,
            contextBudget: budget?.maxChars,
            contextRemaining: budget?.remainingChars,
            toolSchemaCount: int(snapshotObject["toolSchemaCount"]),
            toolSchemaBytes: int(snapshotObject["toolSchemaMaterialBytes"]),
            cacheStatus: receipt?.cacheState?.status ?? budget?.cacheStatus,
            sources: sources,
            selectedMemoryCount: receipt?.selectedMemories?.count ?? 0,
            selectedSkillCount: receipt?.selectedSkills?.count ?? 0,
            selectedToolCount: receipt?.selectedTools?.count ?? 0,
            routeReasons: routeReasons,
            omittedReasons: omitted
        )
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue] {
        guard case .object(let object)? = value else { return [:] }
        return object
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let value): Int(value)
        case .double(let value): Int(value)
        case .string(let value): Int(value)
        default: nil
        }
    }
}

enum ExperienceBlueprintID: String, CaseIterable, Identifiable, Sendable {
    case morningBriefing = "morning-briefing"
    case projectStatus = "project-status"
    case repositoryMaintenance = "repository-maintenance"
    case calendarPreparation = "calendar-preparation"
    case serviceWatch = "service-watch"
    case weeklyMemoryReview = "weekly-memory-review"
    case deliveredReport = "delivered-report"

    var id: String { rawValue }
}

struct ExperienceAutomationBlueprint: Identifiable, Sendable {
    let id: ExperienceBlueprintID
    let title: String
    let summary: String
    let kind: String
    let schedule: [String: JSONValue]
    let payload: [String: JSONValue]
    let modelLabel: String
    let estimatedCost: String
    let requiredTools: [String]
    let delivery: [String]
    let trustImplications: String
    let expectedEvidence: String
}

struct ExperienceCapabilityKit: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let systemImage: String
    let toolNames: Set<String>
    let destinations: [SidebarItem]
}

struct ExperienceProjectSpace: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let permissions: [String]
    let branch: String?
    let head: String?
    let dirtyFileCount: Int?
    let gitAvailable: Bool
    let sessions: [ExperienceSessionBranch]
    let workshopExecutions: [String]
    let lastUsedAt: String?
    let readError: String?
}

struct ExperienceSessionBranch: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let parentSessionId: String?
    let rootSessionId: String
    let forkedAtMessageId: String?
    let projectSpaceId: String?
    let worktreePath: String?
    let model: String?
    let messageCount: Int
    let createdAt: String
}

struct ExperienceSessionComparison: Hashable, Sendable {
    let leftSessionId: String
    let rightSessionId: String
    let commonMessageCount: Int
    let leftOnly: [ChatMessage]
    let rightOnly: [ChatMessage]
}

struct ExperienceSkillVersion: Identifiable, Hashable, Sendable {
    let id: String
    let skillId: String
    let reason: String
    let createdAt: String
    let bodySHA256: String
    let status: String?
    let name: String

    static func decode(_ value: JSONValue) -> Self? {
        guard case .object(let row) = value,
              case .string(let id)? = row["versionId"],
              case .string(let skillId)? = row["skillId"],
              case .string(let createdAt)? = row["createdAt"],
              case .object(let skill)? = row["skill"] else { return nil }
        func string(_ value: JSONValue?) -> String? {
            guard case .string(let result)? = value else { return nil }
            return result
        }
        return .init(
            id: id,
            skillId: skillId,
            reason: string(row["reason"]) ?? "versioned",
            createdAt: createdAt,
            bodySHA256: string(row["bodySHA256"]) ?? "",
            status: string(skill["status"]),
            name: string(skill["name"]) ?? skillId
        )
    }
}

typealias ExperienceRemoteNode = TrustedRemoteEffectNode
