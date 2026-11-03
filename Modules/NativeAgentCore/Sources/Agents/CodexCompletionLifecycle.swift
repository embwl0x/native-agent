import Privacy
import ChatTurnRuntime
import AgentConversations
import Experiences
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CodexCompletionLifecycle.swift` | `CodexCompletionLifecycle` struct; claims require the pinned response run; digest-bound answer and exact return intent; remote settlement delegates to the route journal; launch/event reconciliation isolates corrupt jobs and sends settlement candidates to codex_thread_wakeup.js, the sole reply-deliveries.jsonl writer; its existing ledger.lock protects compare-and-append and producer rotation; closed peer reply findings settle covered records as let_go; caller-result admission holds the delivery lock through the retained-task append and preserves historical artifact verdicts without writing new ones; resumable work retains DataRootLife; other-life (no stamp = first life) work reads stopped/restored and explicit resumption starts fresh |

/// Bridge completion claims and settlement live in one atomic, flock-protected
/// state file per delivery id.
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
    /// Scan only after this many newly retained terminal responses.
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
                if let recovery = try await recover(state, at: path, detail: state.detail) { return ClaimAdmission(decision: recovery, resumesNotStarted: false) }
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

    /// Only a proven pre-run failure or admission rejection can release a
    /// claim for retry. A started or uncertain turn must never use this edge.
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
        requestDigest: String
    ) async throws {
        let path = stateURL(deliveryId)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            guard var state = try await loadState(path) else { throw LifecycleError.claimMissing }
            try Self.requireDigest(state, requestDigest)
            if state.phase == .responseCached || state.phase == .settled {
                guard state.response == response else { throw LifecycleError.requestConflict }
                return
            }
            guard state.phase == .claimed else { throw LifecycleError.claimMissing }
            guard state.responseRunId == response.runId else { throw LifecycleError.requestConflict }
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

    /// Reconciles both v2 files and old mixed-feed claims. Interruption after a
    /// model turn claim can never be automatically replayed because effects or
    /// transcript rows may already exist.
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

    /// Read one delivery's current verdict without reconciliation or projection writes.
    public func savedDelivery(deliveryId: String, requestDigest: String) async throws -> AgentBridgeCompletionDelivery? {
        let path = stateURL(deliveryId)
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            guard let state = try await loadState(path) else { throw LifecycleError.claimMissing }
            guard state.requestDigest == requestDigest else { throw LifecycleError.requestConflict }
            return state.delivery
        }
    }

    public func reconciliationRows() async throws -> [(id: String, digest: String, status: String, response: ChatResponse?, route: AgentBridgeCompletionRoute?, routeSettled: Bool, principal: String?)] {
        var rows: [(String, String, String, ChatResponse?, AgentBridgeCompletionRoute?, Bool, String?)] = []
        let open = Set(try await ExperienceStore.at(dataRoot).open().map(\.id))
        for path in try stateURLs() {
            let loaded: State?
            do { loaded = try await loadState(path) } catch LifecycleError.quarantinedReceipt { continue }
            guard let state = loaded else { continue }
            let decision = CodexCompletionReadout(state)
            guard let status = decision.status else { continue }
            // One still owed from before its delivery was an experience becomes one
            // here, and an open one whose settlement was written but not projected settles.
            let terminal = ["delivered", "let_go", "stopped"].contains(status)
            if !terminal || open.contains(state.deliveryId) { try Self.project(state, dataRoot: dataRoot, born: !terminal) }
            rows.append((state.deliveryId, state.requestDigest, status, state.response, state.route, decision.routeSettled, state.principal))
        }
        return rows
    }

    public func reconcileSavedDeliveries(configRoot: URL, sender: any AgentBridgeCompletionSending, client: SwiftNativeChatOrchestrationClient,
                                        notifyRequestedResult: Bool = true) async throws {
        let ledger = configRoot.appendingPathComponent("codex-nativeagent-bridge/reply-deliveries.jsonl")
        let read = try await SwiftNativePersistenceCore.withFileLock(ledger) { try await SwiftNativePersistenceCore.readJSONLReporting(ledger) }
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
            let urls: [URL]
            do { urls = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) }
            catch { Self.logLifecycleIsolationFailure(error, url: path); continue }
            for url in urls where url.pathExtension == "json" {
                do {
                    guard case .object(let fields) = try JSONValue.parse(Data(contentsOf: url)),
                          case .string(let id)? = fields["deliveryId"] ?? fields["id"] else {
                        throw LifecycleError.corruptReceipt
                    }
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
                } catch {
                    // Retain damaged evidence; it cannot block another saved route.
                    Self.logLifecycleIsolationFailure(error, url: url)
                }
            }
        }
        for row in try await reconciliationRows() where ["owed", "sent_unconfirmed", "delivered"].contains(row.status)
            && !row.routeSettled && !row.id.hasPrefix("bridge-http.") {
            guard let response = row.response else { continue }
            guard let route = row.route else {
                // A saved answer cannot establish its destination. Keep this
                // receipt owed and expose its own repair without blocking peers.
                let path = stateURL(row.id)
                RepairOwed.owe(dataRoot, id: row.id + ":route", kind: .message,
                    evidence: [.init(source: "codex-completion-lifecycle", id: row.id)],
                    operation: "completion.route:" + row.id, owner: path.path,
                    words: "Completion \(row.id) has a saved answer but no saved return route; no delivery was attempted.",
                    lever: "Restore this receipt's exact originating route from its retained evidence before reconciling delivery.")
                continue
            }
            RepairOwed.settle(dataRoot, operation: "completion.route:" + row.id,
                evidence: .init(source: "codex-completion-lifecycle", id: row.id))
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
        let read = try await SwiftNativePersistenceCore.withFileLock(ledger) { try await SwiftNativePersistenceCore.readJSONLReporting(ledger) }
        guard read.report.malformedLineCount == 0, !read.report.trailingPartialLine,
              read.rows.allSatisfy({ if case .object = $0 { return true }; return false }) else { throw LifecycleError.corruptReceipt }
        var records: [String: [String: JSONValue]] = [:]
        for case .object(let row) in read.rows {
            if case .string(let id)? = row["jobId"], deliveryIDs.contains(id) { records[id] = row }
        }
        for directory in CodexCompletionReadout.directories(configRoot: configRoot, dataRoot: dataRoot) {
            let owner = CodexCompletionLifecycle(receiptURL: directory.deletingLastPathComponent().appendingPathComponent("receipts.jsonl"), dataRoot: dataRoot)
            for id in deliveryIDs {
                let path = owner.stateURL(id)
                guard FileManager.default.fileExists(atPath: path.path) else { continue }
                let covered = try await SwiftNativePersistenceCore.withFileLock(path) {
                    guard var state = try await owner.loadState(path) else { return true }
                    let status = CodexCompletionReadout(state).status
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
                state = try await SwiftNativePersistenceCore.withFileLock(stateURL(id)) { try await loadState(stateURL(id)) }
            } catch LifecycleError.corruptReceipt, LifecycleError.quarantinedReceipt {
                // Reconciliation owns quarantine; a damaged job stays isolated.
                continue
            }
            if let state, state.response == nil,
               try (state.phase == .claimed && state.ownerInstanceId == ownerInstanceId || hasReplyCheckpoint(for: state)) { continue }
            var bridge: [String: JSONValue] = [:]
            if case .object(let fields)? = record["bridge"] { bridge = fields }
            else if case .object(let fields)? = record["delivery"] { bridge = fields }
            let delivered = bridge["status"] == .string("delivered") || bridge["replyStatus"] == .string("ok")
                || bridge["replyPersisted"] == .bool(true) || state.map { CodexCompletionReadout($0).status == "delivered" } == true
            let outcome: String
            if state?.delivery?.status == "let_go" { outcome = "let_go" }
            else if delivered { outcome = "delivered" }
            else if let state, state.response != nil { outcome = "owed" }
            else if state?.phase == .failedBeforeAnswer { outcome = "failed_before_answer" }
            else {
                guard let state, let session = state.sessionId,
                      NativeAgentChatSessionID.normalizedPathComponent(session) == session else {
                    throw LifecycleError.responseMissing
                }
                guard try await recoverTranscriptResponse(deliveryId: id, requestDigest: state.requestDigest,
                    sessionId: session, runId: state.responseRunId) != nil else {
                    throw LifecycleError.responseMissing
                }
                outcome = "owed"
            }
            guard record["settlement"] != .string(outcome) else { continue }
            record["settlement"] = .string(outcome)
            record["settledAt"] = .string(Self.nowISO())
            settlements[id] = record
        }
        guard !settlements.isEmpty else { return }
        var environment = AgentBridgeRuntime.processEnvironment()
        environment.merge(InstallPaths.current.bridgeEnvironment(configRoot: ledger.deletingLastPathComponent().deletingLastPathComponent())) { _, scoped in scoped }
        environment["NATIVE_AGENT_CODEX_REPLY_DELIVERIES_PATH"] = ledger.path
        guard let helper = AgentBridgeRuntime.codexHelperURL(dataRoot: dataRoot),
              let node = AgentBridgeRuntime.executableURL(named: "node", environment: environment) else { throw CocoaError(.fileNoSuchFile) }
        let input = settlements.keys.sorted().map { id in
            JSONValue.object(["expected": .object(records[id]!), "record": .object(settlements[id]!)])
        }
        let result = await AgentBridgeRuntime.runBuilderWakeupHelper(node: node, helper: helper,
            inputData: try JSONValue.array(input).serializedData(pretty: false), cwd: dataRoot.deletingLastPathComponent(),
            environment: environment, timeoutSeconds: nil, arguments: ["--settle-reply-deliveries"])
        guard case .object(let fields) = result, fields["status"] == .string("ok") else { throw LifecycleError.corruptReceipt }
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

    /// Let-go and append admission share the delivery lock. Retained tasks own
    /// idempotence; historical artifact verdicts remain authoritative evidence.
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
            // This marker counts only the completions since the last compaction.
            // Validate before changing delivery state; damaged bytes stay in place.
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
                state.phase = .settled
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
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
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

    /// The reply a completion owes its asker is one experience under its
    /// delivery id, moved here at every write of its state: owed once there is
    /// an answer, accepted when delivered, let go when its owner lets it go.
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
        Owed.record(dataRoot, id: state.deliveryId, kind: .message, key: "deliver", to: who, phase: phase, evidence: evidence, born: born && status != "stopped")
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
            sessionId: state.sessionId, runId: state.responseRunId) {
            var state = state
            state.phase = .responseCached
            state.response = response
            state.ownerInstanceId = ownerInstanceId
            state.detail = detail
            state.updatedAt = Self.nowISO()
            try await write(state, to: path)
            return .cached(response)
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
