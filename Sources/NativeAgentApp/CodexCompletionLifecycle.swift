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
struct CodexCompletionLifecycle: Sendable {
    enum ClaimDecision: Sendable, Equatable {
        case start
        case cached(ChatOrchestration.ChatResponse)
        case settled(AgentBridgeCompletionDelivery?)
        case inProgress
        case outcomeUnknown
        case conflict
    }

    enum ArtifactDecision: Sendable, Equatable {
        case send
        case alreadyAccepted
        case rejected
        case inProgress
        case outcomeUnknown
        case conflict
    }

    enum LifecycleError: Error, LocalizedError {
        case claimMissing
        case corruptReceipt
        case responseMissing
        case requestConflict
        case artifactMissing
        case invalidArtifactTransition

        var errorDescription: String? {
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

    private enum CompletionPhase: String, Codable, Sendable {
        case claimed
        case responseCached = "response_cached"
        case outcomeUnknown = "outcome_unknown"
        case settled
    }

    private enum ArtifactPhase: String, Codable, Sendable, Hashable {
        case reserved
        case preDispatchFailed = "pre_dispatch_failed"
        case dispatchStarted = "dispatch_started"
        case accepted
        case rejected
        case outcomeUnknown = "outcome_unknown"
    }

    private struct ArtifactState: Codable, Sendable {
        var id: String
        var kind: String
        var retrySafe: Bool
        var phase: ArtifactPhase
        var ownerInstanceId: String
        var detail: String?
        var updatedAt: String
    }

    private struct State: Codable, Sendable {
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

    static let processOwnerInstanceId = UUID().uuidString
    static let retainedTerminalResponses = 256
    /// Avoid a full directory/decode scan for every settlement while keeping
    /// response-bearing terminal state tightly bounded inside the marker hour.
    static let terminalResponseCompactionSlack = 32

    static var defaultReceiptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("claude-bridge", isDirectory: true)
            .appendingPathComponent("message-replies.jsonl")
    }

    static let shared = CodexCompletionLifecycle(
        receiptURL: defaultReceiptURL,
        ownerInstanceId: processOwnerInstanceId
    )

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
        stateDirectory.appendingPathComponent(".response-compaction-v2.json")
    }

    init(
        receiptURL: URL,
        ownerInstanceId: String = UUID().uuidString,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
    ) {
        self.receiptURL = receiptURL
        self.ownerInstanceId = ownerInstanceId
        self.dataRoot = dataRoot
        self.persistence = persistence
    }

    func claim(
        deliveryId: String,
        requestDigest: String,
        sessionId: String? = nil
    ) async throws -> ClaimDecision {
        let path = stateURL(deliveryId)
        return try await persistence.withFileLock(path) {
            let state = try await loadOrMigrateState(
                deliveryId: deliveryId,
                requestDigest: requestDigest,
                path: path
            )
            guard var state else {
                let created = State(
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
                try await write(created, to: path)
                return .start
            }
            guard state.requestDigest == requestDigest else { return .conflict }
            if let storedSession = state.sessionId,
               let sessionId,
               storedSession != sessionId { return .conflict }
            switch state.phase {
            case .responseCached:
                guard let response = state.response else { throw LifecycleError.corruptReceipt }
                return .cached(response)
            case .settled:
                if let response = state.response { return .cached(response) }
                return .settled(state.delivery)
            case .outcomeUnknown:
                return .outcomeUnknown
            case .claimed:
                guard state.ownerInstanceId != ownerInstanceId else { return .inProgress }
                if let recovered = try await recoverTranscriptResponse(for: state) {
                    state.phase = .responseCached
                    state.ownerInstanceId = ownerInstanceId
                    state.response = recovered
                    state.detail = "recovered_from_canonical_assistant_transcript"
                    state.updatedAt = Self.nowISO()
                    try await write(state, to: path)
                    return .cached(recovered)
                }
                state.phase = .outcomeUnknown
                state.ownerInstanceId = ownerInstanceId
                state.detail = "interrupted_after_claim_before_cached_response"
                state.updatedAt = Self.nowISO()
                try await write(state, to: path)
                return .outcomeUnknown
            }
        }
    }

    func cacheResponse(
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
            state.phase = .responseCached
            state.ownerInstanceId = ownerInstanceId
            state.response = response
            state.detail = nil
            state.updatedAt = Self.nowISO()
            try await write(state, to: path)
        }
    }

    func markOutcomeUnknown(
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
    func reconcileInterruptedClaims() async throws -> [String] {
        try await migrateAllLegacyStates()
        let urls = try stateURLs()
        var reconciled: [String] = []
        for url in urls {
            if Self.isCorruptTombstone(url) { continue }
            do {
                let reconciledId: String? = try await persistence.withFileLock(url) { () async throws -> String? in
                    guard var state = try await loadState(url),
                          state.phase == .claimed,
                          state.ownerInstanceId != ownerInstanceId else { return nil }
                    if let recovered = try await recoverTranscriptResponse(for: state) {
                        state.phase = .responseCached
                        state.ownerInstanceId = ownerInstanceId
                        state.response = recovered
                        state.detail = "recovered_from_canonical_assistant_transcript"
                        state.updatedAt = Self.nowISO()
                        try await write(state, to: url)
                        return nil
                    }
                    state.phase = .outcomeUnknown
                    state.ownerInstanceId = ownerInstanceId
                    state.detail = "app_relaunch_after_claim_before_cached_response"
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
        return try await persistence.withFileLock(path) {
            guard var state = try await loadState(path) else { throw LifecycleError.responseMissing }
            try Self.requireDigest(state, requestDigest)
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
                case .rejected: return .rejected
                case .outcomeUnknown: return .outcomeUnknown
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
                case .reserved, .preDispatchFailed:
                    break
                }
                artifact.phase = .reserved
                artifact.ownerInstanceId = ownerInstanceId
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
                    detail: nil,
                    updatedAt: Self.nowISO()
                )
            }
            state.updatedAt = Self.nowISO()
            try await write(state, to: path)
            return .send
        }
    }

    func markArtifactDispatchStarted(
        deliveryId: String,
        requestDigest: String,
        artifactId: String
    ) async throws {
        try await transitionArtifact(
            deliveryId: deliveryId,
            requestDigest: requestDigest,
            artifactId: artifactId,
            allowed: [.reserved, .preDispatchFailed],
            to: .dispatchStarted,
            detail: nil
        )
    }

    func markArtifactAccepted(
        deliveryId: String,
        requestDigest: String,
        artifactId: String
    ) async throws {
        try await transitionArtifact(
            deliveryId: deliveryId,
            requestDigest: requestDigest,
            artifactId: artifactId,
            allowed: [.dispatchStarted],
            to: .accepted,
            detail: nil
        )
    }

    func markArtifactRejected(
        deliveryId: String,
        requestDigest: String,
        artifactId: String,
        detail: String
    ) async throws {
        try await transitionArtifact(
            deliveryId: deliveryId,
            requestDigest: requestDigest,
            artifactId: artifactId,
            allowed: [.dispatchStarted],
            to: .rejected,
            detail: detail
        )
    }

    func markArtifactPreDispatchFailed(
        deliveryId: String,
        requestDigest: String,
        artifactId: String,
        detail: String
    ) async throws {
        try await transitionArtifact(
            deliveryId: deliveryId,
            requestDigest: requestDigest,
            artifactId: artifactId,
            allowed: [.reserved, .preDispatchFailed],
            to: .preDispatchFailed,
            detail: detail
        )
    }

    func markArtifactOutcomeUnknown(
        deliveryId: String,
        requestDigest: String,
        artifactId: String,
        detail: String
    ) async throws {
        try await transitionArtifact(
            deliveryId: deliveryId,
            requestDigest: requestDigest,
            artifactId: artifactId,
            allowed: [.dispatchStarted],
            to: .outcomeUnknown,
            detail: detail
        )
    }

    func recordDelivery(
        _ delivery: AgentBridgeCompletionDelivery,
        deliveryId: String,
        requestDigest: String
    ) async throws {
        let path = stateURL(deliveryId)
        try await persistence.withFileLock(path) {
            guard var state = try await loadState(path) else { throw LifecycleError.responseMissing }
            try Self.requireDigest(state, requestDigest)
            state.phase = .settled
            state.delivery = delivery
            state.ownerInstanceId = ownerInstanceId
            state.updatedAt = Self.nowISO()
            try await write(state, to: path)
        }
        try await compactOldTerminalResponsesIfNeeded()
    }

    private func transitionArtifact(
        deliveryId: String,
        requestDigest: String,
        artifactId: String,
        allowed: Set<ArtifactPhase>,
        to phase: ArtifactPhase,
        detail: String?
    ) async throws {
        let path = stateURL(deliveryId)
        try await persistence.withFileLock(path) {
            guard var state = try await loadState(path) else { throw LifecycleError.responseMissing }
            try Self.requireDigest(state, requestDigest)
            guard var artifact = state.artifacts[artifactId] else {
                throw LifecycleError.artifactMissing
            }
            if artifact.phase == phase { return }
            guard allowed.contains(artifact.phase),
                  artifact.ownerInstanceId == ownerInstanceId else {
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

    private func compactOldTerminalResponsesIfNeeded() async throws {
        if let attributes = try? FileManager.default.attributesOfItem(
            atPath: compactionMarkerURL.path
        ), let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 60 * 60 {
            let stateCount = try stateURLs().count
            if stateCount <= Self.retainedTerminalResponses + Self.terminalResponseCompactionSlack {
                return
            }
        }
        var terminal: [(URL, State)] = []
        for url in try stateURLs() {
            if Self.isCorruptTombstone(url) { continue }
            do {
                guard let state = try await loadState(url),
                      state.phase == .settled,
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
                          current.updatedAt == old.updatedAt else { return }
                    current.response = nil
                    try await write(current, to: url)
                }
            }
        }
        try await persistence.writeJSON(.object([
            "schema": .string("codex-completion-response-compaction.v2"),
            "completedAt": .string(Self.nowISO()),
            "retainedResponseCount": .int(Int64(min(
                terminal.count, Self.retainedTerminalResponses
            ))),
        ]), to: compactionMarkerURL)
    }

    private nonisolated static func logLifecycleIsolationFailure(_ error: Error, url: URL) {
        let line = "[CodexCompletionLifecycle] isolated \(url.lastPathComponent): \(error)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func recoverTranscriptResponse(
        for state: State
    ) async throws -> ChatOrchestration.ChatResponse? {
        guard let sessionId = state.sessionId,
              let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId)
        else { return nil }
        let transcript = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        let rows = try await persistence.withFileLock(transcript) {
            try await persistence.readJSONL(transcript)
        }
        return try CodexCompletionTranscriptEvidence.recoverResponse(
            from: rows,
            deliveryId: state.deliveryId,
            requestDigest: state.requestDigest,
            sessionId: sessionId
        )
    }

    private func quarantineCorruptState(at url: URL) async throws {
        try await persistence.withFileLock(url) {
            if Self.isCorruptTombstone(url) { return }
            let quarantineDirectory = stateDirectory.appendingPathComponent(
                "quarantine", isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: quarantineDirectory, withIntermediateDirectories: true
            )
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
