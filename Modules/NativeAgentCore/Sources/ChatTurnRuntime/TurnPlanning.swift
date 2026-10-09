import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import TurnTrace
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
        self.policySnapshot = policySnapshot
        self.receiptHints = receiptHints
        self.createdAt = createdAt
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
            dataRoot: dataRoot
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
        dataRoot: URL
    ) -> TurnPolicySnapshot {
        let macPolicy = MacControlPolicy.fromTrustPolicyObject(policy)
        let fullMacActive = macPolicy.trustPolicy.map {
            MacControlGate.fullMacActive($0)
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
            expiresAt: nil
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

    /// Match the transport's admission rule using verified identities only:
    /// chat ID in the chat allowlist OR user ID in the user allowlist.
    private nonisolated static func telegramChatAllowed(sessionId: String, dataRoot: URL) -> Bool {
        _ = sessionId
        let path = dataRoot
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONValue.parse(data),
              case .object(let obj) = json else {
            return false
        }
        func allowed(_ id: String?, key: String) -> Bool {
            guard let id, let candidate = Int64(id) else { return false }
            return stringArray(obj[key]).contains { Int64($0) == candidate }
        }
        let envelope = TurnEnvelope.current(surface: "telegram")
        return allowed(envelope.verifiedChatId, key: "allowed_chat_ids")
            || allowed(envelope.verifiedUserId, key: "allowed_user_ids")
    }

    private nonisolated static func turnPolicyActor(surface: String, sessionId: String) -> String {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return "session:\(trimmed)" }
        return "surface:\(surface)"
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
                try await appendPathOwnedJSONL(
                    row,
                    to: tracesPath,
                    using: persistence,
                    logLabel: "TurnPlanTraceRecorder.trace"
                )
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
        // W7/P13 — the cue family splits by what it regulates. Serve/rut/register
        // stay chat-gated (they are about matching a social register). Stance
        // routes through EVERY goal type: narrating your own performance is the
        // same defect on a build turn as on a chat turn, and the chat gate is
        // exactly why the cue never fired on the tic that motivated it.
        // See `NaturalExpressionGuidance.stanceOnly`.
        if let cue = context.naturalExpressionCue, let goalType = turnPlan?.goalType {
            if goalType == "chat" || goalType == "personality" {
                additions.append(cue)
            } else if let stance = NaturalExpressionGuidance.stanceOnly(cue) {
                additions.append(stance)
            }
        }
        // Always consume the request-scoped candidate here, even for a task
        // turn. It must never leak through a later context transform.
        guard !additions.isEmpty || context.naturalExpressionCue != nil else { return context }
        let appended = SwiftNativeTurnEngine.contextByAppendingRuntimeContext(
            context, runtimeContext: additions.joined(separator: "\n\n")
        )
        return TurnContext(
            surface: context.surface,
            personaID: context.personaID,
            personaDocs: context.personaDocs,
            personaFingerprint: context.personaFingerprint,
            recalled: context.recalled,
            modelId: context.modelId,
            reasoningEffort: context.reasoningEffort,
            providerId: context.providerId,
            serviceTier: context.serviceTier,
            toolsAvailable: context.toolsAvailable,
            systemPrompt: appended.systemPrompt,
            userMessage: context.userMessage,
            toolSchemas: context.toolSchemas,
            systemSegments: appended.systemSegments,
            imageBlocks: context.imageBlocks,
            fluidContextTurn: context.fluidContextTurn,
            naturalExpressionCue: nil,
            historyMessages: context.historyMessages,
            turnVolatileBlock: context.turnVolatileBlock,
            historyWindowReceipt: context.historyWindowReceipt,
            preparationMs: context.preparationMs
        )
    }
}
