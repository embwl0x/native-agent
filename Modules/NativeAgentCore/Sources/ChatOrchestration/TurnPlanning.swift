import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import SystemOps
import TrustCenter

public struct TurnPolicySnapshot: Equatable, Sendable {
    public let permissionLevel: String
    public let autonomyDefault: String
    public let fullMacActive: Bool
    public let developerMode: Bool
    public let remoteSurface: Bool
    public let surfaceTrusted: Bool?
    public let fileAccess: String
    public let approvalAvailable: Bool
    public let remoteIOSAllowed: Bool
    public let policyDecision: UnifiedPolicyDecision?

    public init(
        permissionLevel: String,
        autonomyDefault: String,
        fullMacActive: Bool,
        developerMode: Bool,
        remoteSurface: Bool,
        surfaceTrusted: Bool?,
        fileAccess: String,
        approvalAvailable: Bool,
        remoteIOSAllowed: Bool,
        policyDecision: UnifiedPolicyDecision? = nil
    ) {
        self.permissionLevel = permissionLevel
        self.autonomyDefault = autonomyDefault
        self.fullMacActive = fullMacActive
        self.developerMode = developerMode
        self.remoteSurface = remoteSurface
        self.surfaceTrusted = surfaceTrusted
        self.fileAccess = fileAccess
        self.approvalAvailable = approvalAvailable
        self.remoteIOSAllowed = remoteIOSAllowed
        self.policyDecision = policyDecision
    }
}

public struct TurnPlan: Equatable, Sendable {
    public let id: String
    public let messageCharCount: Int
    public let goalType: String
    public let contextMode: String
    public let recommendedSurface: String
    public let risk: String
    public let requiresApprovalHint: Bool
    public let matchedCapabilityIds: [String]
    public let preloadPrediction: ToolPreloadHeuristics.Prediction?
    public let policySnapshot: TurnPolicySnapshot
    public let receiptHints: [String]
    public let createdAt: String

    public init(
        id: String,
        messageCharCount: Int,
        goalType: String,
        contextMode: String,
        recommendedSurface: String,
        risk: String,
        requiresApprovalHint: Bool,
        matchedCapabilityIds: [String],
        preloadPrediction: ToolPreloadHeuristics.Prediction?,
        policySnapshot: TurnPolicySnapshot,
        receiptHints: [String],
        createdAt: String
    ) {
        self.id = id
        self.messageCharCount = messageCharCount
        self.goalType = goalType
        self.contextMode = contextMode
        self.recommendedSurface = recommendedSurface
        self.risk = risk
        self.requiresApprovalHint = requiresApprovalHint
        self.matchedCapabilityIds = matchedCapabilityIds
        self.preloadPrediction = preloadPrediction
        self.policySnapshot = policySnapshot
        self.receiptHints = receiptHints
        self.createdAt = createdAt
    }

    public var preloadGroupNames: [String] {
        preloadPrediction?.groupNames ?? []
    }

    var shouldInjectContextHint: Bool {
        goalType != "chat" ||
            contextMode != "minimal" ||
            requiresApprovalHint ||
            !preloadGroupNames.isEmpty ||
            !matchedCapabilityIds.isEmpty
    }

    var contextHint: String? {
        guard shouldInjectContextHint else { return nil }
        var parts = [
            "goal=\(goalType)",
            "context=\(contextMode)",
            "risk=\(risk)",
        ]
        if requiresApprovalHint {
            parts.append("approval_hint=true")
        }
        let groups = preloadGroupNames.prefix(3)
        if !groups.isEmpty {
            parts.append("preload=\(groups.joined(separator: ","))")
        }
        let caps = matchedCapabilityIds.prefix(3)
        if !caps.isEmpty {
            parts.append("capabilities=\(caps.joined(separator: ","))")
        }
        var guidance = "Keep tool and context use focused; leave receipts for meaningful actions."
        if goalType == "file_work" {
            guidance += " For file_work, when the user names a file, doc, readme, or handoff, first locate and read that artifact with file/search tools (grep, list_dir, file_excerpt, read_file) before using repo/git tools as secondary evidence. For long docs or handoffs, prefer targeted file_excerpt or grep first and read the full file only when the answer needs it. For the NativeAgent handoff, prefer the repo-relative path docs/HANDOFF_CURRENT.md. Do not answer requested files, docs, or handoffs from memory, chat history, recent traces, or runtime introspection alone; use agent_introspect only when the user asks about live runtime status."
        }
        if goalType == "research" {
            guidance += " For research, if a direct page is empty, blocked, shows a bot/challenge/login wall, or a social shortlink does not expose the requested source, try an official source, approved-domain page, or search result in the same turn before giving the final answer; state source quality and do not ask to continue while safe read-only source options remain."
        }
        if goalType == "schedule" {
            guidance += " For calendar reads about today, tomorrow, or a specific date, call mac_calendar_list_upcoming with day=today, day=tomorrow, or day=YYYY-MM-DD instead of a broad hours window."
        }
        return "Turn route: \(parts.joined(separator: "; ")). \(guidance)"
    }

    func tracePayload(runId: String?, surface: String) -> JSONValue {
        var payload: [String: JSONValue] = [
            "turnPlanId": .string(id),
            "goalType": .string(goalType),
            "contextMode": .string(contextMode),
            "recommendedSurface": .string(recommendedSurface),
            "risk": .string(risk),
            "requiresApprovalHint": .bool(requiresApprovalHint),
            "messageChars": .int(Int64(messageCharCount)),
            "matchedCapabilityIds": .array(matchedCapabilityIds.map { .string($0) }),
            "preloadGroups": .array(preloadGroupNames.map { .string($0) }),
            "preloadCandidateToolCount": .int(Int64(preloadPrediction?.candidateTools.count ?? 0)),
            "receiptHints": .array(receiptHints.prefix(6).map { .string($0) }),
            "surface": .string(surface),
            "permissionLevel": .string(policySnapshot.permissionLevel),
            "autonomyDefault": .string(policySnapshot.autonomyDefault),
            "fullMacActive": .bool(policySnapshot.fullMacActive),
            "developerMode": .bool(policySnapshot.developerMode),
            "remoteSurface": .bool(policySnapshot.remoteSurface),
            "fileAccess": .string(policySnapshot.fileAccess),
            "approvalAvailable": .bool(policySnapshot.approvalAvailable),
            "remoteIOSAllowed": .bool(policySnapshot.remoteIOSAllowed),
        ]
        payload["runId"] = runId.map { .string($0) } ?? .null
        payload["surfaceTrusted"] = policySnapshot.surfaceTrusted.map { .bool($0) } ?? .null
        payload["policyDecision"] = policySnapshot.policyDecision?.toJSONValue() ?? .null
        return .object(payload)
    }
}

public actor TurnPlanner {
    private let dataRoot: URL
    private let router: any RouterPlanClient
    private let trustCenter: SwiftNativeTrustCenter
    private let clock: @Sendable () -> Date

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        router: any RouterPlanClient = SwiftNativeRouterPlanClient(),
        trustCenter: SwiftNativeTrustCenter? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.router = router
        self.trustCenter = trustCenter ?? SwiftNativeTrustCenter(dataRoot: dataRoot, clock: clock)
        self.clock = clock
    }

    public func plan(
        message: String,
        surface: String,
        sessionId: String,
        fileAccess: String,
        approvalAvailable: Bool
    ) async throws -> TurnPlan {
        let route = try await router.planRoute(message: message)
        let policy = await trustCenter.loadTrustPolicy()
        let policySnapshot = Self.policySnapshot(
            policy: policy,
            surface: surface,
            sessionId: sessionId,
            fileAccess: fileAccess,
            approvalAvailable: approvalAvailable,
            goalType: route.goalType,
            risk: route.risk,
            requiresApprovalHint: route.requiresApproval,
            dataRoot: dataRoot,
            now: clock()
        )
        return TurnPlan(
            id: route.id,
            messageCharCount: message.count,
            goalType: route.goalType,
            contextMode: route.contextMode,
            recommendedSurface: route.recommendedSurface,
            risk: route.risk,
            requiresApprovalHint: route.requiresApproval,
            matchedCapabilityIds: Self.meaningfulCapabilityIds(from: route.matchedCapabilities),
            preloadPrediction: ToolPreloadHeuristics.predict(
                userMessage: message,
                residentGroupHints: route.toolReadinessGroups
            ),
            policySnapshot: policySnapshot,
            receiptHints: route.nextActions,
            createdAt: route.createdAt
        )
    }

    nonisolated static func meaningfulCapabilityIds(from capabilities: [JSONValue]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for capability in capabilities {
            guard case .object(let obj) = capability,
                  case .string(let id)? = obj["id"],
                  !id.isEmpty else {
                continue
            }
            let matchedTerms = stringArray(obj["matchedTerms"])
            let selectionReasons = stringArray(obj["selectionReasons"])
            if id.hasPrefix("connector_action:x."),
               !hasExplicitXConnectorEvidence(
                   matchedTerms: matchedTerms,
                   selectionReasons: selectionReasons
               ) {
                continue
            }
            let meaningfulTerms = matchedTerms.filter {
                isMeaningfulMatchedTerm($0, capabilityId: id)
            }
            let hasRealReason = selectionReasons.contains { reason in
                isMeaningfulSelectionReason(reason, capabilityId: id)
            }
            guard !meaningfulTerms.isEmpty || hasRealReason else { continue }
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    private nonisolated static func isMeaningfulMatchedTerm(
        _ term: String,
        capabilityId: String
    ) -> Bool {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        // The SystemOps scorer intentionally preserves retired scoring semantics and treats
        // trigger substrings literally. X connector records have a single
        // letter "x" trigger, which matches words like "Codex" and
        // "exercise". For TurnPlan metadata, suppress that trace noise unless
        // a less ambiguous X/Twitter term also matched.
        if capabilityId.hasPrefix("connector_action:x.") && normalized == "x" {
            return false
        }
        if capabilityId.hasPrefix("connector_action:x.") {
            return isExplicitXConnectorTerm(normalized)
        }
        return true
    }

    private nonisolated static func isMeaningfulSelectionReason(
        _ reason: String,
        capabilityId: String
    ) -> Bool {
        let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized != "fallback ranking" else { return false }
        if capabilityId.hasPrefix("connector_action:x.") && normalized == "trigger:x" {
            return false
        }
        if capabilityId.hasPrefix("connector_action:x."),
           normalized.hasPrefix("trigger:") {
            let trigger = String(normalized.dropFirst("trigger:".count))
            return isExplicitXConnectorTerm(trigger)
        }
        return true
    }

    private nonisolated static func isExplicitXConnectorTerm(_ normalized: String) -> Bool {
        normalized == "x.com" ||
            normalized == "twitter" ||
            normalized == "tweet" ||
            normalized == "tweets" ||
            normalized == "retweet" ||
            normalized == "retweets" ||
            normalized == "timeline" ||
            normalized == "timelines" ||
            normalized == "post_tweet" ||
            normalized == "search_recent" ||
            normalized == "user_tweets"
    }

    private nonisolated static func hasExplicitXConnectorEvidence(
        matchedTerms: [String],
        selectionReasons: [String]
    ) -> Bool {
        if matchedTerms.contains(where: {
            isExplicitXConnectorTerm($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }) {
            return true
        }
        return selectionReasons.contains { reason in
            let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.hasPrefix("trigger:") else { return false }
            let trigger = String(normalized.dropFirst("trigger:".count))
            return isExplicitXConnectorTerm(trigger)
        }
    }

    private nonisolated static func policySnapshot(
        policy: [String: JSONValue],
        surface: String,
        sessionId: String,
        fileAccess: String,
        approvalAvailable: Bool,
        goalType: String,
        risk: String,
        requiresApprovalHint: Bool,
        dataRoot: URL,
        now: Date
    ) -> TurnPolicySnapshot {
        let macPolicy = MacControlPolicy.fromTrustPolicyObject(policy)
        let fullMacActive = macPolicy.trustPolicy.map {
            MacControlGate.fullMacActive($0, now: now)
        } ?? false
        let remoteSurface = isRemoteSurface(surface)
        let trusted = surfaceTrust(
            surface: surface,
            sessionId: sessionId,
            policy: policy,
            macPolicy: macPolicy,
            dataRoot: dataRoot
        )
        let surfaceTrusted = remoteSurface ? trusted : true
        let normalizedFileAccess = fileAccess.isEmpty ? "auto" : fileAccess
        let developerMode = bool(policy["developerMode"]) ?? false
        let policyDecision = UnifiedPolicyDecision.turnPlan(
            surface: surface,
            actor: turnPolicyActor(surface: surface, sessionId: sessionId),
            goalType: goalType,
            risk: risk,
            requiresApprovalHint: requiresApprovalHint,
            fileAccess: normalizedFileAccess,
            fullMacActive: fullMacActive,
            developerMode: developerMode,
            remoteSurface: remoteSurface,
            surfaceTrusted: surfaceTrusted,
            expiresAt: fullMacExpiresAt(policy: policy)
        )
        return TurnPolicySnapshot(
            permissionLevel: string(policy["permissionLevel"]) ?? "balanced",
            autonomyDefault: string(policy["autonomyDefault"]) ?? "supervised",
            fullMacActive: fullMacActive,
            developerMode: developerMode,
            remoteSurface: remoteSurface,
            surfaceTrusted: surfaceTrusted,
            fileAccess: normalizedFileAccess,
            approvalAvailable: approvalAvailable,
            remoteIOSAllowed: macPolicy.remoteFromIOSAllowed,
            policyDecision: policyDecision
        )
    }

    private nonisolated static func isRemoteSurface(_ surface: String) -> Bool {
        ConversationSurfaceProfile(surface).isRemote
    }

    private nonisolated static func surfaceTrust(
        surface: String,
        sessionId: String,
        policy: [String: JSONValue],
        macPolicy: MacControlPolicy,
        dataRoot: URL
    ) -> Bool {
        switch surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ios", "icloud", "iphone", "ipad", "mobile":
            return iosRemoteAllowed(policy: policy, macPolicy: macPolicy)
        case "slack":
            return ChatToolSessionContext.commandSignatureVerified == true
        case "telegram":
            return telegramChatAllowed(sessionId: sessionId, dataRoot: dataRoot)
        default:
            return true
        }
    }

    private nonisolated static func iosRemoteAllowed(
        policy: [String: JSONValue],
        macPolicy: MacControlPolicy
    ) -> Bool {
        if macPolicy.remoteFromIOSAllowed { return true }
        if case .object(let iosPolicy)? = policy["iosRemotePolicy"] {
            if bool(iosPolicy["remote_from_ios_allowed"]) == true { return true }
            if bool(iosPolicy["enabled"]) == true { return true }
        }
        if case .object(let macPolicyObj)? = policy["macControlPolicy"],
           bool(macPolicyObj["remote_from_ios_allowed"]) == true {
            return true
        }
        return false
    }

    private nonisolated static func telegramChatAllowed(sessionId: String, dataRoot: URL) -> Bool {
        let candidates = [
            ChatToolSessionContext.verifiedChatId,
            telegramChatIdFromSession(sessionId),
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !candidates.isEmpty else { return false }
        let allowed = telegramAllowedIds(dataRoot: dataRoot)
        guard !allowed.isEmpty else { return false }
        return candidates.contains { allowed.contains($0) }
    }

    private nonisolated static func telegramChatIdFromSession(_ sessionId: String) -> String? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("telegram:") else { return nil }
        return String(trimmed.dropFirst("telegram:".count))
    }

    private nonisolated static func telegramAllowedIds(dataRoot: URL) -> Set<String> {
        let path = dataRoot
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONValue.parse(data),
              case .object(let obj) = json else {
            return []
        }
        var ids = Set<String>()
        for key in ["allowed_chat_ids", "allowedChatIds", "allowed_user_ids", "allowedUserIds"] {
            for value in stringArray(obj[key]) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { ids.insert(trimmed) }
            }
        }
        return ids
    }

    private nonisolated static func turnPolicyActor(surface: String, sessionId: String) -> String {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return "session:\(trimmed)" }
        return "surface:\(surface)"
    }

    private nonisolated static func fullMacExpiresAt(policy: [String: JSONValue]) -> String? {
        if bool(policy["fullMacNeverExpires"]) == true {
            return "never"
        }
        guard let expiresAt = string(policy["fullMacExpiresAt"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !expiresAt.isEmpty else {
            return nil
        }
        return expiresAt
    }

    private nonisolated static func string(_ value: JSONValue?) -> String? {
        if case .string(let string)? = value { return string }
        return nil
    }

    private nonisolated static func bool(_ value: JSONValue?) -> Bool? {
        if case .bool(let bool)? = value { return bool }
        return nil
    }

    private nonisolated static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { value in
            if case .string(let string) = value { return string }
            if case .int(let int) = value { return String(int) }
            return nil
        }
    }
}

/// FIX 3 / B1.3: serializes turn-plan trace disk writes OFF the time-to-first-
/// token path. `TurnPlanTraceRecorder.append` is awaited at three call sites
/// that all sit before the first provider token streams; the file-locked disk
/// write it used to do inline added lock-contention + fsync latency to TTFT.
/// `enqueue` chains each write onto the previous one's completion so per-process
/// ordering is FIFO-preserved, then returns immediately — the actual
/// `withFileLock`/`appendJSONL` runs on the detached chained task. The caller
/// only ever awaits a cheap actor hop, never the lock or the write.
public actor TurnPlanTraceWriter {
    public static let shared = TurnPlanTraceWriter()
    private var tail: Task<Void, Never>?

    /// Chain `work` after any in-flight write and return. Never awaits `work`.
    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    /// Await the currently-enqueued write chain. Two callers: tests (assert a
    /// row landed after append() returned) and app termination (gpt-5.5 Wave-1
    /// review: fire-and-forget writes enqueued just before quit were lost —
    /// AppDelegate.applicationWillTerminate drains this under its bounded
    /// termination budget alongside the other flushes).
    public func drain() async {
        await tail?.value
    }
}

enum TurnPlanTraceRecorder {
    static func append(
        _ plan: TurnPlan,
        runId: String?,
        surface: String,
        dataRoot: URL,
        turnId: String? = TurnTraceContext.turnId,
        turnTraceBus: TurnTraceBus? = .shared,
        now: Date = Date(),
        writer: TurnPlanTraceWriter = .shared
    ) async {
        let tracesPath = dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let payload = plan.tracePayload(runId: runId, surface: surface)
        let row: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("turn.plan"),
            "title": .string("\(plan.goalType) -> \(plan.contextMode)"),
            "status": .string("ok"),
            "payload": payload,
            "createdAt": .string(ISO8601DateFormatter().string(from: now)),
        ])
        // Fire-and-forget: the row + timestamp + id are captured now (so trace
        // order matches enqueue order), but the lock + disk write run on the
        // serial writer chain, off the TTFT path. A fresh, stateless
        // SwiftNativePersistenceCore is built inside the task to avoid capturing
        // a non-Sendable instance across the actor boundary.
        await writer.enqueue {
            let persistence = SwiftNativePersistenceCore()
            do {
                try await persistence.withFileLock(tracesPath) {
                    try await persistence.appendJSONL(row, to: tracesPath)
                }
            } catch {
                FileHandle.standardError.write(
                    Data("TurnPlanTraceRecorder: trace append failed: \(error)\n".utf8)
                )
            }
        }
        if let turnId, let turnTraceBus {
            TurnTraceBus.fire(TurnTraceEvent(
                turnId: turnId,
                kind: "turn.plan",
                surface: surface,
                payload: .object([
                    "schema": .string("turn.plan.v1"),
                    "runId": runId.map(JSONValue.string) ?? .null,
                    "goalType": .string(plan.goalType),
                    "contextMode": .string(plan.contextMode),
                    "risk": .string(plan.risk),
                ])
            ), on: turnTraceBus)
        }
    }
}

extension SwiftNativeTurnEngine {
    nonisolated static func contextByAppendingTurnPlanHint(
        _ context: TurnContext,
        turnPlan: TurnPlan?
    ) -> TurnContext {
        var additions: [String] = []
        if let hint = turnPlan?.contextHint { additions.append(hint) }
        if let cue = context.naturalExpressionCue,
           let goalType = turnPlan?.goalType,
           goalType == "chat" || goalType == "personality" {
            additions.append(cue)
        }
        // Always consume the request-scoped candidate here, even for a task
        // turn. It must never leak through a later context transform.
        guard !additions.isEmpty || context.naturalExpressionCue != nil else { return context }
        let addition = additions.joined(separator: "\n\n")
        let segments: SystemPromptSegments?
        let systemPrompt: String?
        if let existingSegments = context.systemSegments {
            let dynamic: String
            if addition.isEmpty {
                dynamic = existingSegments.dynamic
            } else {
                dynamic = existingSegments.dynamic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? addition
                    : existingSegments.dynamic + "\n\n" + addition
            }
            segments = SystemPromptSegments(stable: existingSegments.stable, dynamic: dynamic)
            systemPrompt = segments?.combined
        } else {
            segments = nil
            let existing = context.systemPrompt?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if addition.isEmpty {
                systemPrompt = context.systemPrompt
            } else {
                systemPrompt = existing.isEmpty
                    ? addition
                    : existing + "\n\n" + addition
            }
        }
        return TurnContext(
            surface: context.surface,
            personaID: context.personaID,
            personaDocs: context.personaDocs,
            recalled: context.recalled,
            modelId: context.modelId,
            reasoningEffort: context.reasoningEffort,
            providerId: context.providerId,
            serviceTier: context.serviceTier,
            toolsAvailable: context.toolsAvailable,
            systemPrompt: systemPrompt,
            userMessage: context.userMessage,
            toolSchemas: context.toolSchemas,
            systemSegments: segments,
            imageBlocks: context.imageBlocks,
            fluidContextTurn: context.fluidContextTurn,
            naturalExpressionCue: nil
        )
    }
}
