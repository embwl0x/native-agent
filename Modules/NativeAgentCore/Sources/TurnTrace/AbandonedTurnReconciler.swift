import Experiences
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AbandonedTurnReconciler.swift` | `TurnCheckpoint`: Life-bound checkpoint recovery and guarded retirement |

/// The conversation is rebuilt from the transcript; only in-flight state lives here.
public struct TurnCheckpoint: Codable, Sendable, Equatable {
    public let runId: String
    public var lifeID: String?
    public var stoppedReason: String?
    public let turnId: String
    public let sessionId: String
    public let surface: String
    public let userMessage: String
    public let acceptedAt: Date
    public var updatedAt = Date()
    public let envelope: [String: JSONValue]
    public let replyRoute: [String: JSONValue]
    public let fileAccess: String
    public let capabilityProfile: String?
    public var peerSources: [String]?
    /// The steering peers the person's card answered in this run: a resume continues under that one card, never a second.
    public var answeredPeers: [String]?
    /// What the agent attached to this reply with `reply.attach`, in order: a resume chooses them again, each behind the attachment fence once more.
    public var replyChoices: [String]?
    public let commandSignatureVerified: Bool?
    public let declaredRemote: Bool?
    public let helperDefinition: JSONValue?
    public var keptProse = ""
    public var workingCommentaryCharacters = 0
    /// Persisted sentinel: 1 while a call awaits its receipt, nil otherwise; never a step index.
    public var runningStep: Int?
    public var deliveryPending = false
    /// Input events and started-effect identities. Relaunch reruns `step` to reconstruct state and effects; returned effect bodies are not stored.
    public var log: [JSONValue]?

    public var hasRedeliveryOwner: Bool {
        guard stoppedReason == nil, helperDefinition == nil,
              case .string(let surface)? = replyRoute["surface"] else { return false }
        return AgentBridgeCompletionRoute.Kind(surface: surface)?.hasRedeliveryOwner == true
    }

    /// Retain replies until a capable door acknowledges delivery; absent delivery support must not create an obligation that can never settle.
    public func owedDelivery(status: String) -> (key: String, to: String)? {
        guard hasRedeliveryOwner, status == "completed" || status == "waiting",
              case .string(let surface)? = replyRoute["surface"],
              AgentBridgeCompletionRoute.Kind(surface: surface)?.acceptsDurably == true else { return nil }
        let at = ["destinationId", "sourceKey", "threadId"].compactMap { key -> String? in
            if case .string(let value)? = replyRoute[key] { value } else { nil }
        }
        return ("deliver:" + surface, ([surface] + at).joined(separator: ":"))
    }

    public init(runId: String, turnId: String, sessionId: String, surface: String, userMessage: String,
                envelope: [String: JSONValue], replyRoute: [String: JSONValue], fileAccess: String,
                capabilityProfile: String?, peerSources: [String]?, commandSignatureVerified: Bool?,
                declaredRemote: Bool?, helperDefinition: JSONValue?, lifeID: String? = nil) {
        self.lifeID = lifeID
        self.runId = runId; self.turnId = turnId; self.sessionId = sessionId; self.surface = surface
        self.userMessage = userMessage; self.acceptedAt = Date()
        self.envelope = envelope; self.replyRoute = replyRoute; self.fileAccess = fileAccess
        self.capabilityProfile = capabilityProfile; self.peerSources = peerSources
        self.commandSignatureVerified = commandSignatureVerified; self.declaredRemote = declaredRemote
        self.helperDefinition = helperDefinition
    }

    public static func path(dataRoot: URL, sessionId: String, turnId: String) throws -> URL {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionId) == sessionId,
              NativeAgentChatSessionID.normalizedPathComponent(turnId) == turnId else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return dataRoot.appendingPathComponent("chat/session_state/\(sessionId)/turn-\(turnId).json")
    }

    public func write(dataRoot: URL) throws {
        let path = try Self.path(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var record = self
        record.updatedAt = Date()
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(record), to: path)
    }

    public static func read(dataRoot: URL, sessionId: String, turnId: String) throws -> Self? {
        let path = try path(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        var record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
        guard record.sessionId == sessionId, record.turnId == turnId else { throw CocoaError(.fileReadCorruptFile) }
        if try !DataRootLife.isCurrent(record.lifeID, in: dataRoot) { record.stoppedReason = DataRootLife.stoppedReason }
        return record
    }

    public static func forSession(dataRoot: URL, sessionId: String) throws -> [Self] {
        try turnIds(dataRoot: dataRoot, sessionId: sessionId).compactMap {
            try read(dataRoot: dataRoot, sessionId: sessionId, turnId: $0)
        }
    }

    /// The turns a session holds checkpoints for, each readable on its own.
    public static func turnIds(dataRoot: URL, sessionId: String) throws -> [String] {
        let directory = try path(dataRoot: dataRoot, sessionId: sessionId, turnId: "checkpoint").deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("turn-") && $0.pathExtension == "json" }
            .map { String($0.deletingPathExtension().lastPathComponent.dropFirst(5)) }
    }

    public func remove(dataRoot: URL) throws {
        let path = try Self.path(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

}

/// Checkpointed turns resume; a missing checkpoint keeps recovery owed.
public struct AbandonedTurnReconciler: Sendable {
    /// Bound incremental discovery; checkpoints are discovered independently of this record window.
    public static let maximumAcceptedPerPass = 2_000
    public static let maximumWritesPerPass = 25

    /// Pinned at launch; only a previous process's turns are candidates.
    public static let processEpoch = Date()

    private static let cursorKind = "turn.reconciliation.cursor"
    private let dataRoot: URL
    private let lane: TurnTracePersistLane
    private let now: @Sendable () -> Date
    private let processEpoch: Date

    public init(
        dataRoot: URL? = nil,
        lane: TurnTracePersistLane = TurnTracePersistLane(),
        now: @escaping @Sendable () -> Date = { Date() },
        processEpoch: Date = AbandonedTurnReconciler.processEpoch
    ) {
        let root = dataRoot ?? lane.resolvedDataRoot()
        self.dataRoot = root
        self.lane = TurnTracePersistLane(dataRootOverride: root)
        self.now = now
        self.processEpoch = processEpoch
    }

    public struct Outcome: Sendable, Equatable {
        public let acceptedScanned: Int
        public let reconciled: [String]
        /// Turns accepted in this process are left alone.
        public let tooRecentToJudge: Int
        public let resumable: [TurnCheckpoint]
        /// A failed or unreadable record/checkpoint, or an unconfirmed write. Nil reports no failure in this sweep.
        public let failure: String?

        public init(acceptedScanned: Int, reconciled: [String], tooRecentToJudge: Int,
                    resumable: [TurnCheckpoint] = [], failure: String? = nil) {
            self.acceptedScanned = acceptedScanned
            self.reconciled = reconciled
            self.tooRecentToJudge = tooRecentToJudge
            self.resumable = resumable
            self.failure = failure
        }
    }

    private struct Accepted {
        let ts: Date
        let sessionId: String?
    }

    private static func isSettled(_ event: TurnTraceEvent) -> Bool {
        guard TurnTraceEvent.isTerminalKind(event.kind) else { return false }
        if case .object(let payload) = event.payload,
           payload["status"] == .string("abandoned") || payload["repairPending"] == .bool(true) { return false }
        return true
    }

    /// Discover accepted turns by sequence and checkpoints independently of age. Each turn's terminal evidence is read by its own subject.
    @discardableResult
    public func sweep(inFlightTurnIds: Set<String> = []) async -> Outcome {
        let today = now()
        var accepted: [String: Accepted] = [:]
        var terminalIndex: [String: TraceRead] = [:]
        var persistenceFailures: [String] = []
        var scannedSeq: Int64?
        do {
            let cursor = try await persistedCursor()
            let read = try await lane.events(.init(kinds: ["turn.accepted"], after: cursor, limit: Self.maximumAcceptedPerPass))
            if !read.isClean {
                persistenceFailures.append("Turn recovery discovery has \(read.unreadable) unreadable accepted details.")
            }
            for event in read.events {
                guard !event.turnId.isEmpty, event.turnId != "unknown" else {
                    persistenceFailures.append("An accepted detail has no turn identity.")
                    continue
                }
                if accepted[event.turnId] == nil { accepted[event.turnId] = Accepted(ts: event.ts, sessionId: event.sessionId) }
            }
            scannedSeq = read.lastSeq
        } catch {
            persistenceFailures.append("Turn recovery scan coverage is unavailable: \(error.localizedDescription)")
        }

        func readTurn(_ turnId: String) async throws -> TraceRead {
            if let read = terminalIndex[turnId] { return read }
            let read = try await lane.events(.init(subjects: [turnId]))
            guard read.isClean else {
                throw PersistenceCoreError.ioFailure("Turn \(turnId) has \(read.unreadable) unreadable details.")
            }
            terminalIndex[turnId] = read
            return read
        }

        var tooRecent = 0
        var written: [String] = []
        var writeAttempts = 0
        var deferred = false
        var resumable: [TurnCheckpoint] = []
        var checkpoints: [String: TurnCheckpoint] = [:]
        var unreadable: Set<String> = []
        // Unreadable checkpoints owe their own repair; their siblings still resume.
        do {
            let root = dataRoot.appendingPathComponent("chat/session_state")
            if FileManager.default.fileExists(atPath: root.path) {
                for session in try FileManager.default.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                    let sessionId = session.lastPathComponent
                    do {
                        let values = try session.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                        for turnId in try TurnCheckpoint.turnIds(dataRoot: dataRoot, sessionId: sessionId) {
                            do {
                                guard let checkpoint = try TurnCheckpoint.read(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId)
                                else { continue }
                                checkpoints[turnId] = checkpoint
                                if accepted[turnId] == nil {
                                    accepted[turnId] = Accepted(ts: checkpoint.acceptedAt, sessionId: checkpoint.sessionId)
                                }
                            } catch {
                                unreadable.insert(turnId)
                                let detail = """
                                    Turn checkpoint is unreadable; repair chat/session_state/\(sessionId)/turn-\(turnId).json before \
                                    resuming: \(error)
                                    """
                                persistenceFailures.append(detail)
                                Self.owe(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId, detail: detail)
                            }
                        }
                    } catch {
                        unreadable.insert(sessionId)
                        let detail = "Turn checkpoint is unreadable; repair chat/session_state/\(sessionId) before resuming: \(error)"
                        persistenceFailures.append(detail)
                        Self.owe(dataRoot: dataRoot, sessionId: sessionId, turnId: "", detail: detail)
                    }
                }
            }
        } catch {
            let detail = "Turn checkpoint is unreadable; repair chat/session_state before resuming: \(error)"
            Self.owe(dataRoot: dataRoot, sessionId: "", turnId: "", detail: detail)
            return Outcome(acceptedScanned: accepted.count, reconciled: [], tooRecentToJudge: 0, failure: detail)
        }
        let candidates = accepted
            .filter { !inFlightTurnIds.contains($0.key)
                && !unreadable.contains($0.key) && !unreadable.contains($0.value.sessionId ?? "") }
            .sorted {
                if (checkpoints[$0.key] != nil) != (checkpoints[$1.key] != nil) { return checkpoints[$0.key] != nil }
                return $0.value.ts < $1.value.ts
            }
        // An active turn's accepted row must remain before the cursor, ready for the next process to judge.
        if accepted.keys.contains(where: { inFlightTurnIds.contains($0) }) { deferred = true }
        for (turnId, row) in candidates {
            guard !Task.isCancelled else { deferred = true; break }
            guard row.ts < processEpoch || checkpoints[turnId]?.stoppedReason != nil else {
                tooRecent += 1
                continue
            }
            let read: TraceRead
            do { read = try await readTurn(turnId) }
            catch {
                let detail = "Cannot check turn \(turnId)'s terminal: \(error)"
                persistenceFailures.append(detail)
                Self.owe(dataRoot: dataRoot, sessionId: row.sessionId ?? "unknown", turnId: turnId, detail: detail)
                continue
            }
            let hasTerminal = read.events.contains(where: Self.isSettled)
            if let checkpoint = checkpoints[turnId] {
                do {
                    if let reason = checkpoint.stoppedReason {
                        let terminal = TurnTraceEvent(turnId: turnId, ts: checkpoint.updatedAt, kind: "turn.cancelled",
                            sessionId: checkpoint.sessionId, surface: checkpoint.surface,
                            payload: .object(["status": .string("stopped"), "terminalReason": .string(reason)]), turn: nil)
                        let result: Result<Void, any Error> = await settle { [lane, dataRoot] in
                            do {
                                _ = try await lane.appendGuarded(terminal, unless: { events in
                                    events.contains(where: Self.isSettled)
                                })
                                try checkpoint.remove(dataRoot: dataRoot)
                                return .success(())
                            } catch { return .failure(error) }
                        }
                        try result.get()
                        written.append(turnId)
                        continue
                    }
                    if hasTerminal, checkpoint.deliveryPending, !checkpoint.hasRedeliveryOwner {
                        // The retirement detail lands before the checkpoint goes; a kill between them cannot lose the detail.
                        let retired = TurnTraceEvent(turnId: turnId, kind: "turn.checkpoint_retired",
                            sessionId: checkpoint.sessionId, surface: checkpoint.surface,
                            payload: .object(["reason": .string("no_redelivery_owner")]), turn: nil)
                        let wrote = try await lane.appendGuarded(retired, unless: { events in
                            events.contains { $0.kind == "turn.checkpoint_retired" && $0.turnId == turnId }
                        })
                        if wrote { await TurnTraceBus.shared.deliverToSubscribers(retired) }
                        try checkpoint.remove(dataRoot: dataRoot)
                        continue
                    }
                    let replyReady = checkpoint.deliveryPending && read.events.contains { event in
                        guard Self.isSettled(event), case .object(let payload) = event.payload else { return false }
                        return payload["status"] == .string("completed") || payload["status"] == .string("waiting")
                    }
                    if !hasTerminal || replyReady { resumable.append(checkpoint) }
                    else { try checkpoint.remove(dataRoot: dataRoot) }
                } catch {
                    let detail = "Cannot reconcile checkpoint \(turnId): \(error)"
                    persistenceFailures.append(detail)
                    Self.owe(dataRoot: dataRoot, sessionId: checkpoint.sessionId, turnId: turnId, detail: detail)
                }
                continue
            }
            guard !hasTerminal else { continue }
            let id = "turn-recovery:" + turnId
            do {
                if try await ExperienceStore.at(dataRoot).experience(id) != nil {
                    written.append(turnId)
                    continue
                }
            } catch {
                persistenceFailures.append("Turn \(turnId)'s recovery obligation is unreadable: \(error)")
                continue
            }
            guard writeAttempts < Self.maximumWritesPerPass else { deferred = true; break }
            writeAttempts += 1
            await Self.owe(dataRoot: dataRoot, sessionId: row.sessionId ?? "unknown", turnId: turnId,
                detail: """
                    The accepted turn has no saved checkpoint or confirmed terminal. Restore its checkpoint from retained evidence before resuming; do not \
                    repeat uncertain effects.
                    """, id: id).value
            do {
                guard try await ExperienceStore.at(dataRoot).experience(id) != nil else { throw CocoaError(.fileWriteUnknown) }
                written.append(turnId)
            } catch { persistenceFailures.append("Turn recovery could not keep its repair obligation: \(error)") }
        }
        // A failed read/write, deferred work or a current-process turn leaves its accepted sequence pending.
        if persistenceFailures.isEmpty, !deferred, tooRecent == 0, let scannedSeq {
            do { try await writeCursor(seq: scannedSeq, at: today) }
            catch { persistenceFailures.append("Turn recovery cursor could not be recorded: \(error.localizedDescription)") }
        }
        return Outcome(acceptedScanned: accepted.count, reconciled: written, tooRecentToJudge: tooRecent, resumable: resumable,
                       failure: persistenceFailures.isEmpty ? nil : persistenceFailures.joined(separator: "\n"))
    }

    static func operation(sessionId: String, turnId: String) -> String {
        "turn.reconcile:" + (turnId.isEmpty ? "session:" + sessionId : turnId)
    }

    static func owner(sessionId: String, turnId: String) -> String {
        "chat/session_state/" + sessionId + (turnId.isEmpty ? "" : "/turn-\(turnId).json")
    }

    public static func repairCall(sessionId: String, turnId: String) -> String {
        ToolFailureError.call("app", ["action": .string("turn.reconcile"),
            "args": .object(["session_id": .string(sessionId), "turn_id": .string(turnId)])])
    }

    @discardableResult
    static func owe(dataRoot: URL, sessionId: String, turnId: String, detail: String, id: String = UUID().uuidString) -> Task<Void, Never> {
        RepairOwed.owe(dataRoot, id: id, kind: .run,
            evidence: [.init(source: "experiences/experiences.sqlite", id: turnId)], operation: operation(sessionId: sessionId, turnId: turnId),
            owner: owner(sessionId: sessionId, turnId: turnId), words: detail,
            nextCall: repairCall(sessionId: sessionId, turnId: turnId))
    }

    /// The cursor is a detail in the record it describes; no second state store or day file is read.
    private func persistedCursor() async throws -> Int64? {
        let read = try await lane.events(.init(subjects: [""], kinds: [Self.cursorKind], limit: 1, newestFirst: true))
        guard read.isClean else { throw CocoaError(.fileReadCorruptFile) }
        guard let event = read.events.first else { return nil }
        guard case .object(let fields) = event.payload, case .int(let seq)? = fields["lastSeq"] else {
            throw PersistenceCoreError.ioFailure("Turn recovery cursor has no readable lastSeq; unreviewed work remains pending.")
        }
        return seq
    }

    private func writeCursor(seq: Int64, at: Date) async throws {
        try await lane.appendChecked(TurnTraceEvent(turnId: "unknown", ts: at, kind: Self.cursorKind,
            payload: .object(["lastSeq": .int(seq)]), turn: nil))
    }
}
