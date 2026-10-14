import Privacy
import ChatOrchestration
import Foundation
import NativeAgentCore
import PersistenceCore

/// Durable state transitions for Codex completions delivered through
/// `ClaudeBridge`.
///
/// Ownership has not moved: this is still the bridge completion lifecycle.
/// The storage shape is now one atomic, flock-protected state file per stable
/// delivery id instead of repeatedly rereading and appending a mixed unbounded
/// reply JSONL. Legacy lifecycle rows are migrated on first touch.
public struct CodexCompletionLifecycle: Sendable {
    public enum ClaimDecision: Sendable, Equatable {
        case start
        case cached(ChatOrchestration.ChatResponse)
        case settled(AgentBridgeCompletionDelivery?)
        case inProgress
        case outcomeUnknown
        case conflict
    }

    enum ArtifactDecision: Sendable, Equatable {
        case send(attemptID: String)
        case settled(AgentBridgeCompletionDelivery)
        case alreadyAccepted
        case rejected
        case inProgress
        case outcomeUnknown
        case conflict
    }

    public enum LifecycleError: Error, LocalizedError {
        case claimMissing
        case corruptReceipt
        case responseMissing
        case requestConflict
        case artifactMissing
        case invalidArtifactTransition

        public var errorDescription: String? {
            switch self {
            case .claimMissing: return "Codex completion claim is missing."
            case .corruptReceipt: return "Codex completion lifecycle state is unreadable."
            case .responseMissing: return "Codex completion response is not durably cached."
            case .requestConflict: return "Codex completion id was reused for different content."
            case .artifactMissing: return "Codex completion artifact reservation is missing."
            case .invalidArtifactTransition:
                return "Codex completion artifact lifecycle transition is invalid."
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
    }

    fileprivate enum ArtifactPhase: String, Codable, Sendable, Hashable {
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
        var deliveryId: String
        var requestDigest: String
        var sessionId: String?
        var phase: CompletionPhase
        var ownerInstanceId: String
        var response: ChatOrchestration.ChatResponse?
        var artifacts: [String: ArtifactState]
        var delivery: AgentBridgeCompletionDelivery?
        var detail: String?
        var updatedAt: String
        var responseRunId: String? = nil
        var route: AgentBridgeCompletionRoute? = nil
        var principal: String? = nil
        var source: String? = nil
    }

    /// Decode-only compatibility with lifecycle rows that previously shared
    /// `message-replies.jsonl` with human-readable bridge receipts.
    private struct LegacyRow: Codable, Sendable {
        var at: String
        var kind: String
        var deliveryId: String
        var requestDigest: String
        var ownerInstanceId: String? = nil
        var response: ChatOrchestration.ChatResponse? = nil
        var artifactId: String? = nil
        var artifactKind: String? = nil
        var retrySafe: Bool? = nil
        var detail: String? = nil
        var delivery: AgentBridgeCompletionDelivery? = nil
    }

    public static let processOwnerInstanceId = UUID().uuidString
    static let retainedTerminalResponses = 256
    /// Scan only after this many newly retained terminal responses.
    static let terminalResponseCompactionSlack = 32

    let receiptURL: URL
    let ownerInstanceId: String
    let dataRoot: URL
    private let persistence: SwiftNativePersistenceCore

    private var stateDirectory: URL {
        receiptURL.deletingLastPathComponent()
            .appendingPathComponent("codex-completion-lifecycle", isDirectory: true)
    }

    private var legacyMigrationMarkerURL: URL {
        stateDirectory.appendingPathComponent(".legacy-migration-v2.json")
    }

    private var compactionMarkerURL: URL {
        stateDirectory.appendingPathComponent(".response-compaction-v3.json")
    }

    public init(
        receiptURL: URL,
        ownerInstanceId: String = CodexCompletionLifecycle.processOwnerInstanceId,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
    ) {
        self.receiptURL = receiptURL
        self.ownerInstanceId = ownerInstanceId
        self.dataRoot = dataRoot
        self.persistence = persistence
    }

    public func claim(
        deliveryId: String,
        requestDigest: String,
        sessionId: String? = nil,
        responseRunId: String,
        route: AgentBridgeCompletionRoute? = nil,
        principal: String? = nil,
        source: String? = nil
    ) async throws -> ClaimDecision {
        let path = stateURL(deliveryId)
        return try await persistence.withFileLock(path) {
            let state = try await loadOrMigrateState(
                deliveryId: deliveryId,
                requestDigest: requestDigest,
                path: path
            )
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
                    updatedAt: Self.nowISO()
                )
                created.responseRunId = responseRunId
                created.route = route
                created.principal = principal
                created.source = source
                try await write(created, to: path)
                return .start
            }
            guard state.requestDigest == requestDigest else { return .conflict }
            if let route, let saved = state.route, route != saved { return .conflict }
            // Retained answers keep their original run when older callers did not pin it.
            if state.phase == .claimed || state.phase == .notStarted || state.phase == .outcomeUnknown,
               let saved = state.responseRunId, responseRunId != saved { return .conflict }
            if let storedSession = state.sessionId,
               let sessionId,
               storedSession != sessionId { return .conflict }
            if state.route == nil, let route {
                state.route = route
                state.updatedAt = Self.nowISO()
                try await write(state, to: path)
            }
            switch state.phase {
            case .notStarted:
                state.phase = .claimed
                state.ownerInstanceId = ownerInstanceId
                state.responseRunId = responseRunId
                state.detail = nil
                state.updatedAt = Self.nowISO()
                try await write(state, to: path)
                return .start
            case .responseCached:
                guard let response = state.response else { throw LifecycleError.corruptReceipt }
                return .cached(response)
            case .settled, .failedBeforeAnswer:
                if state.delivery?.status == "let_go" { return .settled(state.delivery) }
                if let response = state.response { return .cached(response) }
                return .settled(state.delivery)
            case .outcomeUnknown:
                if let recovered = try await recoverTranscriptResponse(deliveryId: state.deliveryId, requestDigest: state.requestDigest,
                    sessionId: state.sessionId, runId: state.responseRunId) {
                    state.phase = .responseCached
                    state.response = recovered
                    state.ownerInstanceId = ownerInstanceId
                    state.updatedAt = Self.nowISO()
                    try await write(state, to: path)
                    return .cached(recovered)
                }
                if try hasReplyCheckpoint(for: state) { return .inProgress }
                state.phase = .failedBeforeAnswer
                state.delivery = AgentBridgeCompletionDelivery(status: "failed_before_answer", surface: "", delivery: "transcript",
                    artifactCount: 0, attempts: 0, reason: state.detail)
                state.updatedAt = Self.nowISO()
                try await write(state, to: path)
                return .settled(state.delivery)
            case .claimed:
                guard state.ownerInstanceId != ownerInstanceId else { return .inProgress }
                if let recovered = try await recoverTranscriptResponse(deliveryId: state.deliveryId, requestDigest: state.requestDigest,
                    sessionId: state.sessionId, runId: state.responseRunId) {
                    state.phase = .responseCached
                    state.ownerInstanceId = ownerInstanceId
                    state.response = recovered
                    state.detail = "recovered_from_canonical_assistant_transcript"
                    state.updatedAt = Self.nowISO()
                    try await write(state, to: path)
                    return .cached(recovered)
                }
                if try hasReplyCheckpoint(for: state) { return .inProgress }
                state.phase = .outcomeUnknown
                state.ownerInstanceId = ownerInstanceId
                state.detail = "interrupted_after_claim_before_cached_response"
                state.updatedAt = Self.nowISO()
                try await write(state, to: path)
                return .outcomeUnknown
            }
        }
    }

    /// Only admission rejection before the model closure runs can release a
    /// claim for retry. A started or uncertain turn must never use this edge.
    public func markNotStarted(deliveryId: String, requestDigest: String) async throws {
        let path = stateURL(deliveryId)
        try await persistence.withFileLock(path) {
            guard var state = try await loadState(path) else { throw LifecycleError.claimMissing }
            try Self.requireDigest(state, requestDigest)
            guard state.phase == .claimed, state.ownerInstanceId == ownerInstanceId,
                  state.response == nil, state.artifacts.isEmpty else { throw LifecycleError.requestConflict }
            state.phase = .notStarted
            state.detail = "bridge_admission_full_before_model_start"
            state.updatedAt = Self.nowISO()
            try await write(state, to: path)
        }
    }

    public func cacheResponse(
        _ response: ChatOrchestration.ChatResponse,
        deliveryId: String,
        requestDigest: String
    ) async throws {
        let path = stateURL(deliveryId)
        try await persistence.withFileLock(path) {
            guard var state = try await loadState(path) else { throw LifecycleError.claimMissing }
            try Self.requireDigest(state, requestDigest)
            if state.phase == .responseCached || state.phase == .settled {
                guard state.response == response else { throw LifecycleError.requestConflict }
                return
            }
            guard state.phase == .claimed else { throw LifecycleError.claimMissing }
            guard state.responseRunId == nil || state.responseRunId == response.runId else { throw LifecycleError.requestConflict }
            state.phase = .responseCached
            state.ownerInstanceId = ownerInstanceId
            state.response = response
            state.responseRunId = response.runId
            state.detail = nil
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
        try await persistence.withFileLock(path) {
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

    /// Reconciles both v2 files and old mixed-feed claims. Interruption after a
    /// model turn claim can never be automatically replayed because effects or
    /// transcript rows may already exist.
    public func reconcileInterruptedClaims() async throws -> [String] {
        try await migrateAllLegacyStates()
        let urls = try stateURLs()
        var reconciled: [String] = []
        for url in urls {
            if Self.isCorruptTombstone(url) { continue }
            do {
                let reconciledId: String? = try await persistence.withFileLock(url) { () async throws -> String? in
                    guard var state = try await loadState(url),
                          state.phase == .outcomeUnknown || state.phase == .claimed && state.ownerInstanceId != ownerInstanceId else { return nil }
                    if let recovered = try await recoverTranscriptResponse(deliveryId: state.deliveryId, requestDigest: state.requestDigest,
                        sessionId: state.sessionId, runId: state.responseRunId) {
                        state.phase = .responseCached
                        state.ownerInstanceId = ownerInstanceId
                        state.response = recovered
                        state.detail = "recovered_from_canonical_assistant_transcript"
                        state.updatedAt = Self.nowISO()
                        try await write(state, to: url)
                        return nil
                    }
                    if try hasReplyCheckpoint(for: state) { return nil }
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
            } catch LifecycleError.corruptReceipt {
                // One damaged delivery must remain fail-closed without blocking
                // every unrelated completion from being reconciled on launch.
                do {
                    try await quarantineCorruptState(at: url)
                } catch {
                    Self.logLifecycleIsolationFailure(error, url: url)
                }
            } catch {
                // Permissions, transient I/O, and malformed filesystem entries
                // are isolated per delivery. They remain untouched/fail-closed;
                // later healthy claims still reconcile in the same launch pass.
                Self.logLifecycleIsolationFailure(error, url: url)
            }
        }
        return reconciled.sorted()
    }

    public func reconciliationRows() async throws -> [(id: String, digest: String, status: String, response: ChatResponse?, route: AgentBridgeCompletionRoute?, routeSettled: Bool)] {
        var rows: [(String, String, String, ChatResponse?, AgentBridgeCompletionRoute?, Bool)] = []
        for path in try stateURLs() where !Self.isCorruptTombstone(path) {
            guard let state = try await loadState(path) else { continue }
            let decision = CodexCompletionLifecycleProjection(state)
            guard let status = decision.status else { continue }
            rows.append((state.deliveryId, state.requestDigest, status, state.response, state.route, decision.routeSettled))
        }
        return rows
    }

    public func reconcileSavedDeliveries(configRoot: URL, sender: any AgentBridgeCompletionSending, client: any ChatOrchestrationClient,
                                        notifyRequestedResult: Bool = true) async throws {
        let ledger = configRoot.appendingPathComponent("codex-nativeagent-bridge/reply-deliveries.jsonl")
        let read = try await persistence.withFileLock(ledger) { try await persistence.readJSONLReporting(ledger) }
        guard read.report.malformedLineCount == 0, !read.report.trailingPartialLine,
              read.rows.allSatisfy({ if case .object = $0 { return true }; return false }) else { throw LifecycleError.corruptReceipt }
        let ledgerRows = read.rows
        var records: [String: [String: JSONValue]] = [:]
        for row in ledgerRows {
            if case .object(let fields) = row, case .string(let id)? = fields["jobId"] { records[id] = fields }
        }
        for directory in ["codex-nativeagent-bridge/reply-jobs", "codex-nativeagent-bridge/reply-jobs/undelivered", "omp-bridge/wake-jobs"] {
            let path = configRoot.appendingPathComponent(directory)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            for url in try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
                where url.pathExtension == "json" {
                guard case .object(let fields) = try JSONValue.parse(Data(contentsOf: url)),
                      case .string(let id)? = fields["deliveryId"] ?? fields["id"] else { continue }
                if directory.hasPrefix("codex-nativeagent-bridge/") {
                    if records[id] != nil { continue }
                    guard case .object(let execution)? = fields["completedExecution"], fields["delivery"] != nil,
                          case .array(let entries)? = fields["entries"] else { continue }
                    var record = fields
                    record["jobId"] = .string(id)
                    record["jobPath"] = .string(url.path)
                    record["messageIds"] = .array(entries.compactMap { entry in
                        guard case .object(let entry) = entry, case .object(let payload)? = entry["payload"] else { return nil }
                        return payload["messageId"]
                    })
                    record["sessionId"] = entries.compactMap { entry -> JSONValue? in
                        guard case .object(let entry) = entry, case .object(let payload)? = entry["payload"] else { return nil }
                        return payload["sessionId"]
                    }.first
                    record["turnResult"] = execution["turnResult"]
                    record["threadId"] = execution["threadId"]
                    record["turnId"] = execution["turnId"]
                    records[id] = record
                } else { records[id] = fields }
            }
        }
        for row in try await reconciliationRows() where ["owed", "sent_unconfirmed", "delivered"].contains(row.status)
            && !row.routeSettled && !row.id.hasPrefix("bridge-http.") {
            guard let response = row.response else { continue }
            let route: AgentBridgeCompletionRoute
            if let saved = row.route { route = saved }
            else {
                guard let record = records[row.id] else { continue }
                var payloads: [[String: JSONValue]] = [record]
                if case .object(let payload)? = record["payload"] { payloads.append(payload) }
                if case .array(let entries)? = record["entries"] {
                    payloads += entries.compactMap { entry in
                        if case .object(let fields) = entry, case .object(let payload)? = fields["payload"] { return payload }
                        return nil
                    }
                }
                guard let origin = payloads.compactMap({ payload -> [String: JSONValue]? in
                    if case .object(let origin)? = payload["origin"] { return origin }; return nil
                }).first else { continue }
                guard case .string? = origin["surface"],
                      let object = try JSONSerialization.jsonObject(with: JSONValue.object(origin).serializedData(pretty: false)) as? [String: Any] else { continue }
                route = AgentBridgeCompletionRoute(origin: object, sessionId: response.sessionId)
            }
            let answer = ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters)
            _ = await AgentBridgeCompletionRouter.deliverAnswer(deliveryId: row.id, requestDigest: row.digest, text: answer,
                attachments: response.attachments ?? [], route: route, client: client, sender: sender, lifecycle: self,
                notifyRequestedResult: notifyRequestedResult)
        }
        if receiptURL.standardizedFileURL == configRoot.appendingPathComponent("claude-bridge/message-replies.jsonl").standardizedFileURL {
            try await settleReplyJobs(records: records, ledger: ledger)
        }
    }

    public static func letGoReplies(deliveryIDs: Set<String>, outcome: String, dataRoot: URL, configRoot: URL) async throws {
        let lifecycle = CodexCompletionLifecycle(receiptURL: configRoot.appendingPathComponent("claude-bridge/message-replies.jsonl"), dataRoot: dataRoot)
        let ledger = configRoot.appendingPathComponent("codex-nativeagent-bridge/reply-deliveries.jsonl")
        let read = try await lifecycle.persistence.withFileLock(ledger) { try await lifecycle.persistence.readJSONLReporting(ledger) }
        guard read.report.malformedLineCount == 0, !read.report.trailingPartialLine,
              read.rows.allSatisfy({ if case .object = $0 { return true }; return false }) else { throw LifecycleError.corruptReceipt }
        var records: [String: [String: JSONValue]] = [:]
        for case .object(let row) in read.rows {
            if case .string(let id)? = row["jobId"], deliveryIDs.contains(id) { records[id] = row }
        }
        for directory in CodexCompletionLifecycleProjection.directories(configRoot: configRoot, dataRoot: dataRoot) {
            let owner = CodexCompletionLifecycle(receiptURL: directory.deletingLastPathComponent().appendingPathComponent("receipts.jsonl"), dataRoot: dataRoot)
            for id in deliveryIDs {
                let path = owner.stateURL(id)
                guard FileManager.default.fileExists(atPath: path.path) else { continue }
                let covered = try await owner.persistence.withFileLock(path) {
                    guard var state = try await owner.loadState(path) else { return true }
                    let status = CodexCompletionLifecycleProjection(state).status
                    if status == "let_go" { return true }
                    guard ["owed", "sent_unconfirmed", "failed_before_answer"].contains(status ?? "") else { return false }
                    state.phase = .settled
                    state.delivery = AgentBridgeCompletionDelivery(status: "let_go", surface: state.route?.surface ?? "", delivery: "desk",
                        artifactCount: 0, attempts: 0, reason: outcome)
                    state.updatedAt = Self.nowISO()
                    try await owner.write(state, to: path)
                    return true
                }
                if !covered { records.removeValue(forKey: id) }
            }
        }
        try await lifecycle.settleReplyJobs(records: records, ledger: ledger, letGo: outcome)
    }

    private func settleReplyJobs(records: [String: [String: JSONValue]], ledger: URL, letGo: String? = nil) async throws {
        func text(_ value: JSONValue?) -> String? {
            guard case .string(let value)? = value, !value.isEmpty else { return nil }
            return value
        }
        var settlements: [String: [String: JSONValue]] = [:]
        for (id, var record) in records where record["jobId"] == .string(id) {
            guard case .array(let ids)? = record["messageIds"], !ids.isEmpty else { continue }
            if let letGo {
                guard record["settlement"] == nil || ["owed", "sent_unconfirmed", "failed_before_answer"].contains(text(record["settlement"]) ?? "") else { continue }
                record["settlement"] = .string("let_go")
                record["settledAt"] = .string(Self.nowISO())
                record["settlementNote"] = .string(letGo)
                settlements[id] = record
                continue
            }
            guard record["settlement"] == nil || record["settlement"] == .string("owed") else { continue }
            let state: State?
            do {
                state = try await persistence.withFileLock(stateURL(id)) { try await loadState(stateURL(id)) }
            } catch LifecycleError.corruptReceipt {
                // Reconciliation owns quarantine; a damaged job stays isolated.
                continue
            }
            if let state, state.response == nil,
               try (state.phase == .claimed && state.ownerInstanceId == ownerInstanceId || hasReplyCheckpoint(for: state)) { continue }
            var bridge: [String: JSONValue] = [:]
            if case .object(let fields)? = record["bridge"] { bridge = fields }
            else if case .object(let fields)? = record["delivery"] { bridge = fields }
            let delivered = bridge["status"] == .string("delivered") || bridge["replyStatus"] == .string("ok")
                || bridge["replyPersisted"] == .bool(true) || state.map { CodexCompletionLifecycleProjection($0).status == "delivered" } == true
            let outcome: String
            if state?.delivery?.status == "let_go" { outcome = "let_go" }
            else if delivered { outcome = "delivered" }
            else if let state, state.response != nil { outcome = "owed" }
            else if state?.phase == .failedBeforeAnswer { outcome = "failed_before_answer" }
            else {
                let raw = bridge["rawPreview"].flatMap { value -> [String: JSONValue]? in
                    guard case .string(let text) = value, let parsed = try? JSONValue.parse(Data(text.utf8)),
                          case .object(let fields) = parsed else { return nil }
                    return fields
                } ?? [:]
                let session = state?.sessionId ?? text(raw["sessionId"]) ?? text(record["sessionId"]) ?? text(bridge["sessionId"])
                let run = state?.responseRunId ?? text(bridge["nativeAgentRunId"]) ?? text(raw["runId"])
                if let session, NativeAgentChatSessionID.normalizedPathComponent(session) == session {
                    outcome = try await recoverTranscriptResponse(deliveryId: id, requestDigest: state?.requestDigest,
                        sessionId: session, runId: run) == nil ? "failed_before_answer" : "owed"
                } else { outcome = "legacy_before_receipts" }
            }
            guard record["settlement"] != .string(outcome) else { continue }
            record["settlement"] = .string(outcome)
            record["settledAt"] = .string(Self.nowISO())
            settlements[id] = record
        }
        guard !settlements.isEmpty else { return }
        let candidates = settlements
        // JS append and rotation hold this same ledger.lock flock.
        try await persistence.withFileLock(ledger) {
            let read = try await persistence.readJSONLReporting(ledger)
            guard read.report.malformedLineCount == 0, !read.report.trailingPartialLine,
                  read.rows.allSatisfy({ if case .object = $0 { return true }; return false }) else { throw LifecycleError.corruptReceipt }
            var latest: [String: [String: JSONValue]] = [:]
            for case .object(let row) in read.rows {
                if case .string(let id)? = row["jobId"] { latest[id] = row }
            }
            let rows = candidates.keys.sorted().compactMap { id -> JSONValue? in
                guard latest[id] == nil || latest[id] == records[id] else { return nil }
                return candidates[id].map(JSONValue.object)
            }
            try await persistence.appendJSONLDurable(rows, to: ledger)
        }
    }

    func deliveryAdmission(deliveryId: String, requestDigest: String) async throws
        -> (response: ChatResponse?, priorVerdict: String?, letGo: AgentBridgeCompletionDelivery?) {
        guard let state = try await loadState(stateURL(deliveryId)) else { throw LifecycleError.claimMissing }
        try Self.requireDigest(state, requestDigest)
        let decision = CodexCompletionLifecycleProjection(state)
        return (state.response,
            decision.status == "delivered" ? "completed" : decision.status == "sent_unconfirmed" ? "sent_unconfirmed" : nil,
            decision.permitsDelivery ? nil : state.delivery)
    }

    func cachedRequestDigest(deliveryId: String) async throws -> String? {
        guard let state = try await loadState(stateURL(deliveryId)), state.response != nil else { return nil }
        return state.requestDigest
    }

    /// Reserve is intentionally before transport preflight. It records no
    /// dispatch claim; a crash or preflight failure remains safely retryable.
    func beginArtifact(
        deliveryId: String,
        requestDigest: String,
        artifactId: String,
        artifactKind: String,
        retrySafe: Bool
    ) async throws -> ArtifactDecision {
        let path = stateURL(deliveryId)
        let attemptID = UUID().uuidString
        return try await persistence.withFileLock(path) {
            guard var state = try await loadState(path) else { throw LifecycleError.responseMissing }
            try Self.requireDigest(state, requestDigest)
            if let delivery = state.delivery, delivery.status == "let_go" { return .settled(delivery) }
            guard state.response != nil,
                  state.phase == .responseCached || state.phase == .settled else {
                throw LifecycleError.responseMissing
            }
            if var artifact = state.artifacts[artifactId] {
                guard artifact.kind == artifactKind, artifact.retrySafe == retrySafe else {
                    return .conflict
                }
                switch artifact.phase {
                case .accepted: return .alreadyAccepted
                case .rejected, .outcomeUnknown:
                    guard retrySafe else { return artifact.phase == .rejected ? .rejected : .outcomeUnknown }
                case .dispatchStarted:
                    if artifact.ownerInstanceId == ownerInstanceId { return .inProgress }
                    guard retrySafe else {
                        artifact.phase = .outcomeUnknown
                        artifact.ownerInstanceId = ownerInstanceId
                        artifact.detail = "relaunch_after_non_idempotent_dispatch"
                        artifact.updatedAt = Self.nowISO()
                        state.artifacts[artifactId] = artifact
                        state.updatedAt = artifact.updatedAt
                        try await write(state, to: path)
                        return .outcomeUnknown
                    }
                case .reserved:
                    if artifact.ownerInstanceId == ownerInstanceId { return .inProgress }
                case .preDispatchFailed:
                    break
                }
                artifact.phase = .reserved
                artifact.ownerInstanceId = ownerInstanceId
                artifact.attemptID = attemptID
                artifact.detail = nil
                artifact.updatedAt = Self.nowISO()
                state.artifacts[artifactId] = artifact
            } else {
                state.artifacts[artifactId] = ArtifactState(
                    id: artifactId,
                    kind: artifactKind,
                    retrySafe: retrySafe,
                    phase: .reserved,
                    ownerInstanceId: ownerInstanceId,
                    attemptID: attemptID,
                    detail: nil,
                    updatedAt: Self.nowISO()
                )
            }
            state.updatedAt = Self.nowISO()
            try await write(state, to: path)
            return .send(attemptID: attemptID)
        }
    }

    func markArtifactDispatchStarted(
        deliveryId: String,
        requestDigest: String,
        artifactId: String,
        attemptID: String
    ) async throws {
        try await transitionArtifact(
            deliveryId: deliveryId,
            requestDigest: requestDigest,
            artifactId: artifactId,
            attemptID: attemptID,
            allowed: [.reserved],
            to: .dispatchStarted,
            detail: nil
        )
    }

    func markArtifactAccepted(
        deliveryId: String,
        requestDigest: String,
        artifactId: String,
        attemptID: String
    ) async throws {
        try await transitionArtifact(
            deliveryId: deliveryId,
            requestDigest: requestDigest,
            artifactId: artifactId,
            attemptID: attemptID,
            allowed: [.dispatchStarted],
            to: .accepted,
            detail: nil
        )
    }

    func markArtifactRejected(
        deliveryId: String,
        requestDigest: String,
        artifactId: String,
        attemptID: String,
        detail: String
    ) async throws {
        try await transitionArtifact(
            deliveryId: deliveryId,
            requestDigest: requestDigest,
            artifactId: artifactId,
            attemptID: attemptID,
            allowed: [.dispatchStarted],
            to: .rejected,
            detail: detail
        )
    }

    func markArtifactPreDispatchFailed(
        deliveryId: String,
        requestDigest: String,
        artifactId: String,
        attemptID: String,
        detail: String
    ) async throws {
        try await transitionArtifact(
            deliveryId: deliveryId,
            requestDigest: requestDigest,
            artifactId: artifactId,
            attemptID: attemptID,
            allowed: [.reserved, .preDispatchFailed],
            to: .preDispatchFailed,
            detail: detail
        )
    }

    func markArtifactOutcomeUnknown(
        deliveryId: String,
        requestDigest: String,
        artifactId: String,
        attemptID: String,
        detail: String
    ) async throws {
        try await transitionArtifact(
            deliveryId: deliveryId,
            requestDigest: requestDigest,
            artifactId: artifactId,
            attemptID: attemptID,
            allowed: [.dispatchStarted],
            to: .outcomeUnknown,
            detail: detail
        )
    }

    public func recordDelivery(
        _ delivery: AgentBridgeCompletionDelivery,
        deliveryId: String,
        requestDigest: String
    ) async throws {
        let path = stateURL(deliveryId)
        try await persistence.withFileLock(compactionMarkerURL) {
            var retained = 0
            let initialized = FileManager.default.fileExists(atPath: compactionMarkerURL.path)
            if initialized {
                retained = try JSONDecoder().decode(Int.self, from: Data(contentsOf: compactionMarkerURL))
            }
            let newlyRetained = try await persistence.withFileLock(path) { () async throws -> Bool? in
                guard var state = try await loadState(path) else { throw LifecycleError.responseMissing }
                try Self.requireDigest(state, requestDigest)
                guard state.delivery?.status != "let_go" else { return nil }
                guard state.delivery?.status != "completed" || delivery.status != "owed" else { return nil }
                guard state.phase != .settled || state.delivery != delivery else { return nil }
                let newlyRetained = state.phase != .settled && state.response != nil
                state.phase = .settled
                state.delivery = delivery
                state.ownerInstanceId = ownerInstanceId
                state.updatedAt = Self.nowISO()
                try await write(state, to: path)
                return newlyRetained
            }
            guard let newlyRetained else { return }
            if newlyRetained { retained += 1 }
            if !initialized || retained >= Self.terminalResponseCompactionSlack {
                try await compactOldTerminalResponses()
                retained = 0
            }
            try await persistence.writeJSON(.int(Int64(retained)), to: compactionMarkerURL)
        }
    }

    private func transitionArtifact(
        deliveryId: String,
        requestDigest: String,
        artifactId: String,
        attemptID: String,
        allowed: Set<ArtifactPhase>,
        to phase: ArtifactPhase,
        detail: String?
    ) async throws {
        let path = stateURL(deliveryId)
        try await persistence.withFileLock(path) {
            guard var state = try await loadState(path) else { throw LifecycleError.responseMissing }
            try Self.requireDigest(state, requestDigest)
            guard phase != .dispatchStarted || state.delivery?.status != "let_go" else { throw LifecycleError.invalidArtifactTransition }
            guard var artifact = state.artifacts[artifactId] else {
                throw LifecycleError.artifactMissing
            }
            guard artifact.ownerInstanceId == ownerInstanceId, artifact.attemptID == attemptID else {
                throw LifecycleError.invalidArtifactTransition
            }
            if artifact.phase == phase, phase != .dispatchStarted { return }
            guard allowed.contains(artifact.phase) else {
                throw LifecycleError.invalidArtifactTransition
            }
            artifact.phase = phase
            artifact.detail = detail.map(Self.safeDetail)
            artifact.updatedAt = Self.nowISO()
            state.artifacts[artifactId] = artifact
            state.updatedAt = artifact.updatedAt
            try await write(state, to: path)
        }
    }

    private func stateURL(_ deliveryId: String) -> URL {
        stateDirectory.appendingPathComponent(
            "\(CausalTransitionEvidence.opaqueIdentity(deliveryId)).json"
        )
    }

    private func loadState(_ url: URL) async throws -> State? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let state = try? JSONDecoder().decode(State.self, from: data),
              state.schema == State.schema,
              stateURL(state.deliveryId).lastPathComponent == url.lastPathComponent else {
            throw LifecycleError.corruptReceipt
        }
        return state
    }

    private func write(_ state: State, to url: URL) async throws {
        guard state.schema == State.schema,
              stateURL(state.deliveryId).lastPathComponent == url.lastPathComponent else {
            throw LifecycleError.corruptReceipt
        }
        let value = try JSONValue.parse(JSONEncoder().encode(state))
        try await persistence.writeJSON(value, to: url)
    }

    private static func requireDigest(_ state: State, _ digest: String) throws {
        guard state.requestDigest == digest else { throw LifecycleError.requestConflict }
    }

    private func loadOrMigrateState(
        deliveryId: String,
        requestDigest: String,
        path: URL
    ) async throws -> State? {
        if let state = try await loadState(path) { return state }
        if FileManager.default.fileExists(atPath: legacyMigrationMarkerURL.path) {
            return nil
        }
        let rows = try Self.readLegacyRows(from: receiptURL, deliveryId: deliveryId)
        guard !rows.isEmpty else { return nil }
        guard rows.allSatisfy({ $0.requestDigest == requestDigest }) else {
            return State(
                deliveryId: deliveryId,
                requestDigest: rows[0].requestDigest,
                sessionId: nil,
                phase: .outcomeUnknown,
                ownerInstanceId: ownerInstanceId,
                response: nil,
                artifacts: [:],
                delivery: nil,
                detail: "legacy_request_digest_conflict",
                updatedAt: Self.nowISO()
            )
        }
        let migrated = Self.state(fromLegacyRows: rows, ownerInstanceId: ownerInstanceId)
        try await write(migrated, to: path)
        return migrated
    }

    private func migrateAllLegacyStates() async throws {
        if FileManager.default.fileExists(atPath: legacyMigrationMarkerURL.path) { return }
        let rows = try Self.readLegacyRows(from: receiptURL)
        for (deliveryId, group) in Dictionary(grouping: rows, by: \.deliveryId) {
            let path = stateURL(deliveryId)
            try await persistence.withFileLock(path) {
                guard try await loadState(path) == nil else { return }
                let state: State
                if Set(group.map(\.requestDigest)).count == 1 {
                    state = Self.state(fromLegacyRows: group, ownerInstanceId: ownerInstanceId)
                } else {
                    state = State(
                        deliveryId: deliveryId,
                        requestDigest: group[0].requestDigest,
                        sessionId: nil,
                        phase: .outcomeUnknown,
                        ownerInstanceId: ownerInstanceId,
                        response: nil,
                        artifacts: [:],
                        delivery: nil,
                        detail: "legacy_request_digest_conflict",
                        updatedAt: Self.nowISO()
                    )
                }
                try await write(
                    state,
                    to: path
                )
            }
        }
        try await persistence.writeJSON(.object([
            "schema": .string("codex-completion-legacy-migration.v2"),
            "completedAt": .string(Self.nowISO()),
            "migratedDeliveryCount": .int(Int64(Set(rows.map(\.deliveryId)).count)),
        ]), to: legacyMigrationMarkerURL)
    }

    private static func state(
        fromLegacyRows rows: [LegacyRow],
        ownerInstanceId: String
    ) -> State {
        let last = rows.last!
        let cached = rows.last(where: { $0.kind == "codex_completion_response_cached" })
        let unknown = rows.last(where: { $0.kind == "codex_completion_outcome_unknown" })
        let settled = rows.last(where: { $0.kind == "codex_completion_delivery_settled" })
        let claim = rows.last(where: { $0.kind == "codex_completion_claimed" })
        var artifacts: [String: ArtifactState] = [:]
        for row in rows where row.artifactId != nil {
            guard let id = row.artifactId else { continue }
            let phase: ArtifactPhase? = switch row.kind {
            case "codex_completion_artifact_started": .dispatchStarted
            case "codex_completion_artifact_pre_dispatch_failed": .preDispatchFailed
            case "codex_completion_artifact_accepted": .accepted
            case "codex_completion_artifact_rejected": .rejected
            case "codex_completion_artifact_outcome_unknown": .outcomeUnknown
            default: nil
            }
            guard let phase else { continue }
            artifacts[id] = ArtifactState(
                id: id,
                kind: row.artifactKind ?? "unknown",
                retrySafe: row.retrySafe ?? false,
                phase: phase,
                ownerInstanceId: row.ownerInstanceId ?? ownerInstanceId,
                detail: row.detail.map(safeDetail),
                updatedAt: row.at
            )
        }
        let phase: CompletionPhase
        if settled != nil { phase = .settled }
        else if unknown != nil { phase = .outcomeUnknown }
        else if cached != nil { phase = .responseCached }
        else { phase = .claimed }
        return State(
            deliveryId: last.deliveryId,
            requestDigest: last.requestDigest,
            sessionId: nil,
            phase: phase,
            ownerInstanceId: claim?.ownerInstanceId ?? ownerInstanceId,
            response: cached?.response,
            artifacts: artifacts,
            delivery: settled?.delivery,
            detail: unknown?.detail.map(safeDetail),
            updatedAt: last.at
        )
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
            if Self.isCorruptTombstone(url) { continue }
            do {
                guard let state = try await loadState(url),
                      state.phase == .settled,
                      state.delivery?.status == "completed",
                      state.response != nil else { continue }
                terminal.append((url, state))
            } catch LifecycleError.corruptReceipt {
                // Reconciliation owns quarantine. Compaction skips the damaged
                // state so a healthy delivery can still settle.
                continue
            }
        }
        if terminal.count > Self.retainedTerminalResponses {
            let excess = terminal.sorted { $0.1.updatedAt < $1.1.updatedAt }
                .prefix(terminal.count - Self.retainedTerminalResponses)
            for (url, old) in excess {
                try await persistence.withFileLock(url) {
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

    private func hasReplyCheckpoint(for state: State) throws -> Bool {
        guard let sessionId = state.sessionId, let runId = state.responseRunId else { return false }
        return try SwiftNativeChatOrchestrationClient.hasReplyCheckpoint(dataRoot: dataRoot, sessionId: sessionId, runId: runId)
    }

    private func recoverTranscriptResponse(
        deliveryId: String, requestDigest: String?, sessionId: String?, runId: String?
    ) async throws -> ChatOrchestration.ChatResponse? {
        guard let sessionId,
              let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId)
        else { return nil }
        if let run = runId {
            return try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: sessionId, runId: run)
        }
        let transcript = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        let read = try await persistence.withFileLock(transcript) {
            try await persistence.readJSONLReporting(transcript)
        }
        guard read.report.malformedLineCount == 0, !read.report.trailingPartialLine,
              read.rows.allSatisfy({ if case .object = $0 { return true }; return false }) else { throw LifecycleError.corruptReceipt }
        guard let runId = try CodexCompletionTranscriptEvidence.recoverRunId(
            from: read.rows,
            deliveryId: deliveryId,
            requestDigest: requestDigest,
            sessionId: sessionId
        ) else { return nil }
        return try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: sessionId, runId: runId)
    }

    private func quarantineCorruptState(at url: URL) async throws {
        try await persistence.withFileLock(url) {
            if Self.isCorruptTombstone(url) { return }
            let quarantineDirectory = stateDirectory.appendingPathComponent(
                "quarantine", isDirectory: true
            )
            try FileManager.default.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
            let quarantineURL = quarantineDirectory.appendingPathComponent(
                "\(url.lastPathComponent).\(UUID().uuidString).corrupt"
            )
            try FileManager.default.copyItem(at: url, to: quarantineURL)
            try await persistence.writeJSON(.object([
                "schema": .string("codex-completion-lifecycle.corrupt.v1"),
                "quarantinedAt": .string(Self.nowISO()),
                "quarantineFile": .string(quarantineURL.lastPathComponent),
            ]), to: url)
        }
    }

    private static func isCorruptTombstone(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["schema"] as? String == "codex-completion-lifecycle.corrupt.v1"
    }

    private static func readLegacyRows(
        from url: URL,
        deliveryId: String? = nil
    ) throws -> [LegacyRow] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LifecycleError.corruptReceipt
        }
        let decoder = JSONDecoder()
        var rows: [LegacyRow] = []
        let hasTrailingNewline = text.hasSuffix("\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() where !line.isEmpty {
            if let row = try? decoder.decode(LegacyRow.self, from: Data(line.utf8)) {
                if deliveryId == nil || row.deliveryId == deliveryId { rows.append(row) }
                continue
            }
            if index == lines.count - 1 && !hasTrailingNewline {
                // Snapshot raced a legacy JSONL append. The writer always adds
                // a newline, so an unterminated tail is not committed evidence.
                continue
            }
            if isLifecycleLookingLine(line) { throw LifecycleError.corruptReceipt }
        }
        return rows
    }

    private static func isLifecycleLookingLine(_ line: Substring) -> Bool {
        let data = Data(line.utf8)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (object["kind"] as? String)?.hasPrefix("codex_completion_") == true
        }
        return line.contains("\"kind\":\"codex_completion_")
    }

    private static func safeDetail(_ raw: String) -> String {
        String(NativeAppSecretRedactor.redactText(raw)
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(500))
    }

    private static func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

private extension CodexCompletionLifecycleProjection {
    init(_ state: CodexCompletionLifecycle.State) {
        self.init(deliveryId: state.deliveryId, principal: state.principal, source: state.source,
            updatedAt: state.updatedAt, phase: state.phase.rawValue,
            response: state.response.map { ($0.runId, $0.sessionId, $0.output, ($0.attachments ?? []).map(\.id)) }, responseRunId: state.responseRunId,
            sessionId: state.sessionId, delivery: state.delivery.map { ($0.status, $0.delivery) },
            artifacts: state.artifacts.mapValues { $0.phase.rawValue })
    }
}
