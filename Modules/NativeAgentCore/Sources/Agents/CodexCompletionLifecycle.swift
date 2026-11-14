import Privacy
import ChatTurnRuntime
import AgentConversations
import Experiences
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CodexCompletionLifecycle.swift` | `CodexCompletionLifecycle` |

/// Claim and settlement must share one atomic, flock-protected delivery state file.
public struct CodexCompletionLifecycle: Sendable {
    public enum ClaimDecision: Sendable, Equatable {
        case start
        case cached(ChatTurnRuntime.ChatResponse)
        case settled(AgentBridgeCompletionDelivery?)
        case inProgress
        case outcomeUnknown
        case conflict
    }

    public enum LifecycleError: Error, LocalizedError {
        case claimMissing
        case corruptReceipt
        case quarantinedReceipt
        case responseMissing
        case requestConflict

        public var errorDescription: String? {
            switch self {
            case .claimMissing: return "Codex completion claim is missing."
            case .corruptReceipt: return "Codex completion lifecycle state is unreadable."
            case .quarantinedReceipt: return "Codex completion lifecycle state is quarantined."
            case .responseMissing: return "Codex completion response is not durably cached."
            case .requestConflict: return "Codex completion id was reused for different content."
            }
        }
    }

    fileprivate enum CompletionPhase: String, Codable, Sendable {
        case notStarted = "not_started"
        case claimed
        case responseCached = "response_cached"
        case outcomeUnknown = "outcome_unknown"
        case settled
        case failedBeforeAnswer = "failed_before_answer"
        case stopped
    }

    enum ArtifactPhase: String, Codable, Sendable, Hashable {
        case reserved
        case preDispatchFailed = "pre_dispatch_failed"
        case dispatchStarted = "dispatch_started"
        case accepted
        case rejected
        case outcomeUnknown = "outcome_unknown"
    }

    fileprivate struct ArtifactState: Codable, Sendable {
        var id: String
        var kind: String
        var retrySafe: Bool
        var phase: ArtifactPhase
        var ownerInstanceId: String
        var attemptID: String? = nil
        var detail: String?
        var updatedAt: String
    }

    fileprivate struct State: Codable, Sendable {
        static let schema = "codex-completion-lifecycle.v2"

        var schema: String = Self.schema
        var lifeID: String? = nil
        var deliveryId: String
        var requestDigest: String
        var sessionId: String?
        var phase: CompletionPhase
        var ownerInstanceId: String
        var response: ChatTurnRuntime.ChatResponse?
        var artifacts: [String: ArtifactState]
        var delivery: AgentBridgeCompletionDelivery?
        var detail: String?
        var updatedAt: String
        var responseRunId: String
        var route: AgentBridgeCompletionRoute? = nil
        var principal: String? = nil
        var source: String? = nil
    }


    public static let processOwnerInstanceId = UUID().uuidString
    static let retainedTerminalResponses = 256
    static let terminalResponseCompactionSlack = 32

    let receiptURL: URL
    let ownerInstanceId: String
    let dataRoot: URL

    private var stateDirectory: URL {
        receiptURL.deletingLastPathComponent()
            .appendingPathComponent("codex-completion-lifecycle", isDirectory: true)
    }


    private var compactionMarkerURL: URL {
        stateDirectory.appendingPathComponent(".response-compaction-v3.json")
    }

    public init(
        receiptURL: URL,
        ownerInstanceId: String = CodexCompletionLifecycle.processOwnerInstanceId,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        self.receiptURL = receiptURL
        self.ownerInstanceId = ownerInstanceId
        self.dataRoot = dataRoot
    }

    /// Resume permission comes from the same locked read that claims the turn.
    public struct ClaimAdmission: Sendable {
        public let decision: ClaimDecision
        public let resumesNotStarted: Bool
    }

    public func claim(deliveryId: String, requestDigest: String, sessionId: String? = nil,
                      responseRunId: String, route: AgentBridgeCompletionRoute? = nil,
                      principal: String? = nil, source: String? = nil) async throws -> ClaimDecision {
        (try await claimAdmission(deliveryId: deliveryId, requestDigest: requestDigest, sessionId: sessionId,
            responseRunId: responseRunId, route: route, principal: principal, source: source)).decision
    }

    public func claimAdmission(
        deliveryId: String,
        requestDigest: String,
        sessionId: String? = nil,
        responseRunId: String,
        route: AgentBridgeCompletionRoute? = nil,
        principal: String? = nil,
        source: String? = nil
    ) async throws -> ClaimAdmission {
        let path = stateURL(deliveryId)
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            let state = try await loadState(path)
            guard var state else {
                var created = State(
                    deliveryId: deliveryId,
                    requestDigest: requestDigest,
                    sessionId: sessionId,
                    phase: .claimed,
                    ownerInstanceId: ownerInstanceId,
                    response: nil,
                    artifacts: [:],
                    delivery: nil,
                    detail: nil,
                    updatedAt: Self.nowISO(),
                    responseRunId: responseRunId
                )
                created.lifeID = try DataRootLife.current(in: dataRoot)
                created.route = route
                created.principal = principal
                created.source = source
                try await write(created, to: path)
                return ClaimAdmission(decision: .start, resumesNotStarted: false)
            }
            guard state.requestDigest == requestDigest else { return ClaimAdmission(decision: .conflict, resumesNotStarted: false) }
            if let route, let saved = state.route, route != saved { return ClaimAdmission(decision: .conflict, resumesNotStarted: false) }
            // Every accepted operation carries its original pinned run.
            if state.phase == .claimed || state.phase == .notStarted || state.phase == .outcomeUnknown,
               responseRunId != state.responseRunId { return ClaimAdmission(decision: .conflict, resumesNotStarted: false) }
            if let storedSession = state.sessionId,
               let sessionId,
               storedSession != sessionId { return ClaimAdmission(decision: .conflict, resumesNotStarted: false) }
            guard state.route == route else { return ClaimAdmission(decision: .conflict, resumesNotStarted: false) }
            switch state.phase {
            case .notStarted:
                state.phase = .claimed
                state.ownerInstanceId = ownerInstanceId
                state.responseRunId = responseRunId
                state.detail = nil
                state.updatedAt = Self.nowISO()
                try await write(state, to: path)
                return ClaimAdmission(decision: .start, resumesNotStarted: true)
            case .responseCached:
                guard let response = state.response else { throw LifecycleError.corruptReceipt }
                return ClaimAdmission(decision: .cached(response), resumesNotStarted: false)
            case .stopped:
                return ClaimAdmission(decision: .settled(state.delivery), resumesNotStarted: false)
            case .settled, .failedBeforeAnswer:
                if state.delivery?.status == "let_go" { return ClaimAdmission(decision: .settled(state.delivery), resumesNotStarted: false) }
                if let response = state.response { return ClaimAdmission(decision: .cached(response), resumesNotStarted: false) }
                return ClaimAdmission(decision: .settled(state.delivery), resumesNotStarted: false)
            case .outcomeUnknown:
                if let recovery = try await recover(state, at: path, detail: state.detail) { return ClaimAdmission(decision: recovery,
                    resumesNotStarted: false) }
                state.phase = .failedBeforeAnswer
                state.delivery = AgentBridgeCompletionDelivery(status: "failed_before_answer", surface: "", delivery: "transcript",
                    artifactCount: 0, attempts: 0, reason: state.detail)
                state.updatedAt = Self.nowISO()
                try await write(state, to: path)
                return ClaimAdmission(decision: .settled(state.delivery), resumesNotStarted: false)
            case .claimed:
                guard state.ownerInstanceId != ownerInstanceId else { return ClaimAdmission(decision: .inProgress, resumesNotStarted: false) }
                if let recovery = try await recover(state, at: path) { return ClaimAdmission(decision: recovery, resumesNotStarted: false) }
                state.phase = .outcomeUnknown
                state.ownerInstanceId = ownerInstanceId
                state.detail = "interrupted_after_claim_before_cached_response"
                state.updatedAt = Self.nowISO()
                try await write(state, to: path)
                return ClaimAdmission(decision: .outcomeUnknown, resumesNotStarted: false)
            }
        }
    }

    /// Only a proven pre-run failure or admission rejection can release a claim for retry. A started or uncertain turn must never use this edge.
    public func markNotStarted(deliveryId: String, requestDigest: String,
                               detail: String = "bridge_admission_full_before_model_start") async throws {
        let path = stateURL(deliveryId)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            guard var state = try await loadState(path) else { throw LifecycleError.claimMissing }
            try Self.requireDigest(state, requestDigest)
            guard state.phase == .claimed, state.ownerInstanceId == ownerInstanceId,
                  state.response == nil, state.artifacts.isEmpty else { throw LifecycleError.requestConflict }
            state.phase = .notStarted
            state.detail = Self.safeDetail(detail)
            state.updatedAt = Self.nowISO()
            try await write(state, to: path)
        }
    }

    public func cacheResponse(
        _ response: ChatTurnRuntime.ChatResponse,
        deliveryId: String,
        requestDigest: String,
        stopped: Bool = false
    ) async throws {
        let path = stateURL(deliveryId)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            guard var state = try await loadState(path) else { throw LifecycleError.claimMissing }
            try Self.requireDigest(state, requestDigest)
            let wasStopped = state.phase == .stopped
            let stopping = stopped || wasStopped || response.terminalState == .stopped
            // Only a Stop may move a saved outcome; delivery that has finished keeps it.
            if state.phase == .responseCached || state.phase == .settled,
               !stopping || ["completed", "let_go"].contains(state.delivery?.status ?? "") {
                guard state.response == response else { throw LifecycleError.requestConflict }
                return
            }
            guard [.claimed, .responseCached, .settled, .stopped].contains(state.phase) else { throw LifecycleError.claimMissing }
            guard state.responseRunId == response.runId else { throw LifecycleError.requestConflict }
            if let saved = state.response, saved != response { throw LifecycleError.requestConflict }
            state.ownerInstanceId = ownerInstanceId
            state.response = response
            state.responseRunId = response.runId
            if stopping {
                Self.stop(&state, detail: "turn_stopped")
            } else {
                state.phase = .responseCached
                state.detail = nil
            }
            state.updatedAt = Self.nowISO()
            try await write(state, to: path)
        }
    }

    public func markOutcomeUnknown(
        deliveryId: String,
        requestDigest: String,
        detail: String
    ) async throws {
        let path = stateURL(deliveryId)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            guard var state = try await loadState(path) else { throw LifecycleError.claimMissing }
            try Self.requireDigest(state, requestDigest)
            guard state.phase == .claimed else { return }
            state.phase = .outcomeUnknown
            state.ownerInstanceId = ownerInstanceId
            state.detail = Self.safeDetail(detail)
            state.updatedAt = Self.nowISO()
            try await write(state, to: path)
        }
    }

    /// A claimed model turn may already have effects or transcript rows; interruption cannot authorize automatic replay.
    public func reconcileInterruptedClaims() async throws -> [String] {
        let urls = try stateURLs()
        var reconciled: [String] = []
        for url in urls {
            do {
                let reconciledId: String? = try await SwiftNativePersistenceCore.withFileLock(url) { () async throws -> String? in
                    guard var state = try await loadState(url),
                          state.phase == .outcomeUnknown || state.phase == .claimed && state.ownerInstanceId != ownerInstanceId else { return nil }
                    if try await recover(state, at: url) != nil { return nil }
                    state.phase = .failedBeforeAnswer
                    state.delivery = AgentBridgeCompletionDelivery(status: "failed_before_answer", surface: "", delivery: "transcript",
                        artifactCount: 0, attempts: 0, reason: state.detail)
                    state.ownerInstanceId = ownerInstanceId
                    state.detail = "failed_before_answer"
                    state.updatedAt = Self.nowISO()
                    try await write(state, to: url)
                    return state.deliveryId
                }
                if let reconciledId { reconciled.append(reconciledId) }
            } catch LifecycleError.quarantinedReceipt {
                continue
            } catch LifecycleError.corruptReceipt {
                // One damaged delivery must fail closed without blocking reconciliation of unrelated completions.
                do {
                    try await quarantineCorruptState(at: url)
                } catch {
                    Self.logLifecycleIsolationFailure(error, url: url)
                }
            } catch {
                // Isolate filesystem failures per delivery, preserving damaged bytes while healthy claims reconcile.
                Self.logLifecycleIsolationFailure(error, url: url)
            }
        }
        return reconciled.sorted()
    }

    /// Verdict reads cannot reconcile or write projections.
    public func savedDelivery(deliveryId: String, requestDigest: String) async throws -> AgentBridgeCompletionDelivery? {
        let path = stateURL(deliveryId)
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            guard let state = try await loadState(path) else { throw LifecycleError.claimMissing }
            guard state.requestDigest == requestDigest else { throw LifecycleError.requestConflict }
            return state.delivery
        }
    }

    /// Read/recover one accepted return without admitting work. A recovered partial remains stopped, never owed for delivery.
    func attentionReturnState(_ batch: Attention.Batch) async throws -> Attention.BatchEnd.Status? {
        let path = stateURL(batch.deliveryID)
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            guard var state = try await loadState(path) else { return nil }
            try Self.requireDigest(state, batch.digest)
            if state.phase == .outcomeUnknown || state.phase == .claimed && state.ownerInstanceId != ownerInstanceId {
                _ = try await recover(state, at: path)
                guard let recovered = try await loadState(path) else { throw LifecycleError.claimMissing }
                state = recovered
            }
            if state.response?.terminalState == .stopped, state.phase != .stopped {
                Self.stop(&state, detail: "turn_stopped")
                try await write(state, to: path)
            }
            return state.phase == .stopped ? .stopped : .completed
        }
    }

    /// Stop is terminal even if it won before the lifecycle claim. Retained transcript output can only enrich this stopped record.
    func stopReturn(_ batch: Attention.Batch) async throws -> Attention.BatchEnd.Status {
        let path = stateURL(batch.deliveryID)
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            let existing = try await loadState(path)
            var state = existing ?? State(deliveryId: batch.deliveryID, requestDigest: batch.digest, sessionId: batch.route,
                phase: .stopped, ownerInstanceId: ownerInstanceId, response: nil, artifacts: [:], delivery: nil, detail: nil,
                updatedAt: Self.nowISO(), responseRunId: CausalTransitionEvidence.opaqueIdentity(batch.deliveryID))
            try Self.requireDigest(state, batch.digest)
            guard state.sessionId == batch.route else { throw LifecycleError.requestConflict }
            if ["completed", "let_go"].contains(state.delivery?.status ?? "") { return .completed }
            if existing == nil {
                state.lifeID = try DataRootLife.current(in: dataRoot)
                state.source = Attention.stream
                state.principal = "self"
            }
            Self.stop(&state, detail: "turn_stopped")
            state.ownerInstanceId = ownerInstanceId
            try await write(state, to: path)
            // First block all delivery, then retain any already-produced answer. A failed read cannot reopen this delivery.
            if state.response == nil, let response = try await recoverTranscriptResponse(deliveryId: batch.deliveryID,
                requestDigest: batch.digest, sessionId: state.sessionId, runId: state.responseRunId) {
                state.response = response
                try await write(state, to: path)
            }
            return .stopped
        }
    }

    private static func stop(_ state: inout State, detail: String) {
        state.phase = .stopped
        state.detail = Self.safeDetail(detail)
        state.delivery = AgentBridgeCompletionDelivery(status: "stopped", surface: state.route?.surface ?? "",
            delivery: "transcript", artifactCount: state.artifacts.values.filter { $0.phase == .accepted }.count,
            attempts: state.delivery?.attempts ?? 0, reason: state.detail)
        state.updatedAt = Self.nowISO()
    }

    /// Older attention claims predate batch rows. The caller records their existing route grouping once; no claim is replayed.
    func attentionReturns(in session: String, excluding recorded: Set<String>) async throws -> [(id: String, digest: String)] {
        var claims: [(String, String)] = []
        let recordedFiles = Set(recorded.map { stateURL($0).lastPathComponent })
        for path in try stateURLs() where !recordedFiles.contains(path.lastPathComponent) {
            guard let state = try await loadState(path), state.source == Attention.stream, state.sessionId == session,
                  state.deliveryId.hasPrefix("return:happening:"),
                  state.phase != .settled || !["completed", "let_go"].contains(state.delivery?.status ?? "") else { continue }
            claims.append((state.deliveryId, state.requestDigest))
        }
        return claims
    }

    public func reconciliationRows() async throws -> [(id: String, digest: String, status: String, response: ChatResponse?,
        route: AgentBridgeCompletionRoute?, routeSettled: Bool, principal: String?)] {
        var rows: [(String, String, String, ChatResponse?, AgentBridgeCompletionRoute?, Bool, String?)] = []
        let open = Set(try await ExperienceStore.at(dataRoot).open().map(\.id))
        for path in try stateURLs() {
            let loaded: State?
            do {
                loaded = try await SwiftNativePersistenceCore.withFileLock(path) {
                    guard var state = try await loadState(path) else { return nil as State? }
                    if state.response?.terminalState == .stopped, state.phase != .stopped {
                        Self.stop(&state, detail: "turn_stopped")
                        try await write(state, to: path)
                    }
                    return state
                }
            } catch LifecycleError.quarantinedReceipt { continue }
            guard let state = loaded else { continue }
            let decision = CodexCompletionReadout(state)
            guard let status = decision.status else { continue }
            // Reconcile owed experiences and committed settlements without starting work.
            let terminal = ["delivered", "let_go", "stopped"].contains(status)
            if !terminal || open.contains(state.deliveryId) { try Self.project(state, dataRoot: dataRoot, born: !terminal) }
            rows.append((state.deliveryId, state.requestDigest, status, state.response, state.route, decision.routeSettled, state.principal))
        }
        return rows
    }

    public func reconcileSavedDeliveries(sender: any AgentBridgeCompletionSending, client: SwiftNativeChatOrchestrationClient,
                                        notifyRequestedResult: Bool = true) async throws {
        for row in try await reconciliationRows() where ["owed", "sent_unconfirmed", "delivered"].contains(row.status) && !row.routeSettled {
            guard let response = row.response else { continue }
            guard let route = row.route else {
                // A saved answer cannot establish its destination. Keep this receipt owed and expose its own repair without blocking peers.
                let path = stateURL(row.id)
                RepairOwed.owe(dataRoot, id: row.id + ":route", kind: .message,
                    evidence: [.init(source: "codex-completion-lifecycle", id: row.id)],
                    operation: "completion.route:" + row.id, owner: path.path,
                    words: "Completion \(row.id) has a saved answer but no saved return route; no delivery was attempted.",
                    lever: "Restore this receipt's exact originating route from its retained evidence before reconciling delivery.")
                continue
            }
            if route.surface == AgentConversationStore.heldReplySurface {
                // Completion ends at the handoff to the held owner. Recovery repairs that handoff, never dispatches a second send.
                if row.status == "delivered" { continue }
                do {
                    guard let session = route.sessionId, let owner = route.destinationId,
                          let peer = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == owner }) else {
                        throw AgentConversationStore.Failure(message: "The saved held-answer route has no available contact identity or conversation.")
                    }
                    let turn = TurnRequest(message: "", sessionID: session, surface: "chat",
                        envelope: .native("completion.hold"), pinnedRunID: response.runId).turn()
                    try await AgentContactHeldAnswer.complete(dataRoot: dataRoot, peer: peer, session: session,
                        deliveryID: row.id, requestDigest: row.digest, response: response, client: client, turn: turn, lifecycle: self)
                    RepairOwed.settle(dataRoot, operation: "completion.hold:" + row.id,
                        evidence: .init(source: "codex-completion-lifecycle", id: row.id))
                } catch {
                    RepairOwed.owe(dataRoot, id: row.id + ":hold", kind: .message, operation: "completion.hold:" + row.id,
                        owner: stateURL(row.id).path, words: "The contact answer could not be held: " + error.localizedDescription,
                        lever: "Repair the saved contact, answer or held exchange; do not repeat its work or send it through another door.")
                }
                continue
            }
            // A delivered answer is revisited only to settle its route's journal. A door on this Mac keeps none, so delivered is its end:
            // revisiting it would read the asking conversation whole, every pass, for every answer ever delivered.
            if row.status == "delivered", route.kind == .local || route.kind == .callerResult { continue }
            RepairOwed.settle(dataRoot, operation: "completion.route:" + row.id,
                evidence: .init(source: "codex-completion-lifecycle", id: row.id))
            let answer = ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters)
            let deliveryTurn = TurnRequest(message: answer, sessionID: response.sessionId, surface: route.surface,
                envelope: .native("completion.delivery"), pinnedRunID: response.runId).turn()
            _ = await AgentBridgeCompletionRouter.deliverAnswer(turn: deliveryTurn, deliveryId: row.id, requestDigest: row.digest, text: answer,
                attachments: response.attachments ?? [], route: route, client: client, sender: sender, lifecycle: self,
                notifyRequestedResult: notifyRequestedResult)
        }
    }

    @discardableResult
    public static func letGoReplies(deliveryIDs: Set<String>, outcome: String, dataRoot: URL, configRoot: URL) async throws -> Set<String> {
        var released: Set<String> = []
        for directory in CodexCompletionReadout.directories(configRoot: configRoot, dataRoot: dataRoot) {
            let owner = CodexCompletionLifecycle(receiptURL: directory.deletingLastPathComponent().appendingPathComponent("receipts.jsonl"), dataRoot: dataRoot)
            for id in deliveryIDs {
                let path = owner.stateURL(id)
                do { _ = try FileManager.default.attributesOfItem(atPath: path.path) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { continue }
                let didRelease = try await SwiftNativePersistenceCore.withFileLock(path) {
                    guard var state = try await owner.loadState(path) else { return false }
                    let status = CodexCompletionReadout(state).status
                    guard CodexCompletionReadout.replyIsOwed(status) || status == "failed_before_answer" else { return false }
                    state.phase = .settled
                    state.delivery = AgentBridgeCompletionDelivery(status: "let_go", surface: state.route?.surface ?? "", delivery: "desk",
                        artifactCount: 0, attempts: 0, reason: outcome)
                    state.updatedAt = Self.nowISO()
                    try await owner.write(state, to: path)
                    return true
                }
                if didRelease { released.insert(id) }
            }
        }
        return released
    }

    func deliveryAdmission(deliveryId: String, requestDigest: String) async throws
        -> (response: ChatResponse?, priorVerdict: String?, letGo: AgentBridgeCompletionDelivery?) {
        guard let state = try await loadState(stateURL(deliveryId)) else { throw LifecycleError.claimMissing }
        try Self.requireDigest(state, requestDigest)
        let decision = CodexCompletionReadout(state)
        return (state.response,
            decision.status == "delivered" ? "completed" : decision.status == "sent_unconfirmed" ? "sent_unconfirmed" : nil,
            decision.permitsDelivery ? nil : state.delivery)
    }

    func cachedRequestDigest(deliveryId: String) async throws -> String? {
        guard let state = try await loadState(stateURL(deliveryId)), state.response != nil else { return nil }
        return state.requestDigest
    }

    /// Let-go and append admission share the delivery lock. Retained tasks own idempotence; historical artifact verdicts remain authoritative evidence.
    func admitCallerResult(
        deliveryId: String, requestDigest: String, artifact: AgentBridgeCompletionArtifact,
        append: @Sendable () async -> AgentBridgeTransportResult
    ) async throws -> AgentBridgeTransportResult {
        let path = stateURL(deliveryId)
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            guard let state = try await loadState(path) else { throw LifecycleError.responseMissing }
            try Self.requireDigest(state, requestDigest)
            if let delivery = state.delivery, ["let_go", "stopped"].contains(delivery.status) { return .settled(delivery) }
            guard state.response != nil,
                  state.phase == .responseCached || state.phase == .settled else {
                throw LifecycleError.responseMissing
            }
            if let retained = state.artifacts[artifact.id] {
                guard retained.kind == artifact.kind, retained.retrySafe else { return .outcomeUnknown(reason: "conflict") }
                if retained.phase == .accepted { return .alreadyAccepted }
            }
            return await append()
        }
    }


    public func recordDelivery(
        _ delivery: AgentBridgeCompletionDelivery,
        deliveryId: String,
        requestDigest: String
    ) async throws {
        let path = stateURL(deliveryId)
        try await SwiftNativePersistenceCore.withFileLock(compactionMarkerURL) {
            var retained = 0
            let initialized = FileManager.default.fileExists(atPath: compactionMarkerURL.path)
            if initialized {
                retained = try JSONDecoder().decode(Int.self, from: Data(contentsOf: compactionMarkerURL))
            }
            // This marker counts only the completions since the last compaction. Validate before changing delivery state; damaged bytes stay in place.
            let next = retained.addingReportingOverflow(1)
            guard (0..<Self.terminalResponseCompactionSlack).contains(retained), !next.overflow else {
                throw ToolFailureError("Completion compaction counter is outside its retained range.", effects: .none,
                    owner: compactionMarkerURL.path, code: "completion_compaction_counter_invalid",
                    instruction: "Preserve and repair the counter from retained completion evidence before settling delivery.")
            }
            let newlyRetained = try await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> Bool? in
                guard var state = try await loadState(path) else { throw LifecycleError.responseMissing }
                try Self.requireDigest(state, requestDigest)
                guard !["let_go", "stopped"].contains(state.delivery?.status ?? "") else { return nil }
                guard state.delivery?.status != "completed" || delivery.status != "owed" else { return nil }
                guard state.phase != .settled || state.delivery != delivery else { return nil }
                let newlyRetained = state.phase != .settled && state.response != nil
                state.phase = delivery.status == "stopped" ? .stopped : .settled
                state.delivery = delivery
                state.ownerInstanceId = ownerInstanceId
                state.updatedAt = Self.nowISO()
                try await write(state, to: path)
                return newlyRetained
            }
            guard let newlyRetained else { return }
            if newlyRetained { retained = next.partialValue }
            if !initialized || retained >= Self.terminalResponseCompactionSlack {
                try await compactOldTerminalResponses()
                retained = 0
            }
            try await SwiftNativePersistenceCore.writeJSON(.int(Int64(retained)), to: compactionMarkerURL)
        }
    }

    private func stateURL(_ deliveryId: String) -> URL {
        stateDirectory.appendingPathComponent(
            "\(CausalTransitionEvidence.opaqueIdentity(deliveryId)).json"
        )
    }

    private func loadState(_ url: URL) async throws -> State? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        guard var state = try? JSONDecoder().decode(State.self, from: data),
              state.schema == State.schema,
              stateURL(state.deliveryId).lastPathComponent == url.lastPathComponent else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["schema"] as? String == "codex-completion-lifecycle.corrupt.v1" { throw LifecycleError.quarantinedReceipt }
            throw LifecycleError.corruptReceipt
        }
        if try !DataRootLife.isCurrent(state.lifeID, in: dataRoot),
           !["delivered", "let_go"].contains(CodexCompletionReadout(state).status ?? "") {
            state.phase = .stopped
            state.detail = DataRootLife.stoppedReason
            state.delivery = AgentBridgeCompletionDelivery(status: "stopped", surface: state.route?.surface ?? "",
                delivery: state.delivery?.delivery ?? "", artifactCount: state.delivery?.artifactCount ?? 0,
                attempts: state.delivery?.attempts ?? 0, reason: DataRootLife.stoppedReason)
        }
        return state
    }

    private func write(_ state: State, to url: URL) async throws {
        guard state.schema == State.schema,
              stateURL(state.deliveryId).lastPathComponent == url.lastPathComponent else {
            throw LifecycleError.corruptReceipt
        }
        let value = try JSONValue.parse(JSONEncoder().encode(state))
        try await SwiftNativePersistenceCore.writeJSON(value, to: url)
        try Self.project(state, dataRoot: dataRoot)
    }

    /// Project each delivery’s state into one experience: answer owed, delivered or explicitly released.
    private static func project(_ state: State, dataRoot: URL, born: Bool = true) throws {
        let status = try CodexCompletionReadout(state).reading(life: DataRootLife.current(in: dataRoot)).status
        guard let status, state.response != nil || ["failed_before_answer", "let_go", "delivered", "stopped"].contains(status) else { return }
        let phase: Owed.Phase = switch status {
        case "delivered": .accepted
        case "let_go", "stopped": .letGo(.abandoned)
        default: .owed
        }
        let who = state.principal.map { "agent:" + $0 }
            ?? state.route.map { "route:" + $0.surface } ?? "route:unknown"
        var evidence = [Experience.Ref(source: "codex-completion-lifecycle", id: state.deliveryId)]
        evidence.append(.init(source: "run", id: state.response?.runId ?? state.responseRunId))
        Owed.record(dataRoot, id: state.deliveryId, kind: .message, key: "deliver", to: who, phase: phase, evidence: evidence, born: born
            && status != "stopped")
    }

    private static func requireDigest(_ state: State, _ digest: String) throws {
        guard state.requestDigest == digest else { throw LifecycleError.requestConflict }
    }


    private func stateURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: stateDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: stateDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func compactOldTerminalResponses() async throws {
        var terminal: [(URL, State)] = []
        for url in try stateURLs() {
            do {
                guard let state = try await loadState(url),
                      state.phase == .settled,
                      state.delivery?.status == "completed",
                      state.response != nil else { continue }
                terminal.append((url, state))
            } catch LifecycleError.corruptReceipt, LifecycleError.quarantinedReceipt {
                // Reconciliation owns quarantine; compaction skips unavailable state.
                continue
            }
        }
        if terminal.count > Self.retainedTerminalResponses {
            let excess = terminal.sorted { $0.1.updatedAt < $1.1.updatedAt }
                .prefix(terminal.count - Self.retainedTerminalResponses)
            for (url, old) in excess {
                try await SwiftNativePersistenceCore.withFileLock(url) {
                    guard var current = try await loadState(url),
                          current.phase == .settled,
                          current.delivery?.status == "completed",
                          current.updatedAt == old.updatedAt else { return }
                    current.response = nil
                    try await write(current, to: url)
                }
            }
        }
    }

    private nonisolated static func logLifecycleIsolationFailure(_ error: Error, url: URL) {
        let line = "[CodexCompletionLifecycle] isolated \(url.lastPathComponent): \(error)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Promote saved answers or retain checkpointed turns without starting work.
    private func recover(_ state: State, at path: URL,
                         detail: String? = "recovered_from_canonical_assistant_transcript") async throws -> ClaimDecision? {
        if let response = try await recoverTranscriptResponse(deliveryId: state.deliveryId, requestDigest: state.requestDigest,
            sessionId: state.sessionId, runId: state.responseRunId),
            // A failed turn's saved words are not an answer for a caller.
            response.terminalState != .failed {
            var state = state
            state.response = response
            state.ownerInstanceId = ownerInstanceId
            if response.terminalState == .stopped {
                Self.stop(&state, detail: "turn_stopped")
            } else {
                state.phase = .responseCached
                state.detail = detail
            }
            state.updatedAt = Self.nowISO()
            try await write(state, to: path)
            return state.phase == .stopped ? .settled(state.delivery) : .cached(response)
        }
        return try hasReplyCheckpoint(for: state) ? .inProgress : nil
    }

    private func hasReplyCheckpoint(for state: State) throws -> Bool {
        guard let sessionId = state.sessionId else { return false }
        let runId = state.responseRunId
        return try SwiftNativeChatOrchestrationClient.hasReplyCheckpoint(dataRoot: dataRoot, sessionId: sessionId, runId: runId)
    }

    private func recoverTranscriptResponse(
        deliveryId: String, requestDigest: String?, sessionId: String?, runId: String
    ) async throws -> ChatTurnRuntime.ChatResponse? {
        guard let sessionId,
              NativeAgentChatSessionID.normalizedPathComponent(sessionId) != nil
        else { return nil }
        return try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: sessionId,
            runId: runId, deliveryId: deliveryId, requestDigest: requestDigest)
    }

    private func quarantineCorruptState(at url: URL) async throws {
        try await SwiftNativePersistenceCore.withFileLock(url) {
            do { _ = try await loadState(url); return }
            catch LifecycleError.corruptReceipt { }
            catch LifecycleError.quarantinedReceipt { return }
            let quarantineDirectory = stateDirectory.appendingPathComponent(
                "quarantine", isDirectory: true
            )
            try FileManager.default.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
            let quarantineURL = quarantineDirectory.appendingPathComponent(
                "\(url.lastPathComponent).\(UUID().uuidString).corrupt"
            )
            try FileManager.default.copyItem(at: url, to: quarantineURL)
            try await SwiftNativePersistenceCore.writeJSON(.object([
                "schema": .string("codex-completion-lifecycle.corrupt.v1"),
                "quarantinedAt": .string(Self.nowISO()),
                "quarantineFile": .string(quarantineURL.lastPathComponent),
            ]), to: url)
        }
    }


    private static func safeDetail(_ raw: String) -> String {
        String(NativeAppSecretRedactor.redactText(raw)
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(500))
    }

    private static func nowISO() -> String {
        NativeTimestampFormat.plainZulu(Date())
    }
}

private extension CodexCompletionReadout {
    init(_ state: CodexCompletionLifecycle.State) {
        self.init(deliveryId: state.deliveryId, lifeID: state.lifeID, principal: state.principal, source: state.source,
            updatedAt: state.updatedAt, phase: state.phase.rawValue,
            response: state.response.map { ($0.runId, $0.sessionId, $0.output, ($0.attachments ?? []).map(\.id)) }, responseRunId: state.responseRunId,
            sessionId: state.sessionId, delivery: state.delivery.map { ($0.status, $0.delivery) },
            artifacts: state.artifacts.mapValues { $0.phase.rawValue })
    }
}
