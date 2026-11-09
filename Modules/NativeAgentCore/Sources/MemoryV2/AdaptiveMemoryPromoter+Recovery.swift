import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import CognitiveSubstrate
import ChatTurnContracts
import TurnTrace
import Transcripts
import GRDB
import NativeAgentShared
import Experiences
import CryptoKit
import Desk
// Blueprint: | `AdaptiveMemoryPromoter+Recovery.swift` | `AdaptiveMemoryPromoter`: event-owned owed-turn recovery with recorded provenance |

extension AdaptiveMemoryPromoter {
    static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError
            || (error as? AfterTurnInterpretationFailure) == .cancellation
            || (error as? AfterTurnMemoryFailure)?.reason == .cancelled
            || (error as? ToolFailureError)?.status == .cancelled
    }

    /// Recall can fail in storage, embedding or elsewhere. Only a named repair owner earns a wait.
    static func factReadCause(_ error: Error) -> OwedCause? {
        if let database = error as? DatabaseError {
            switch database.resultCode {
            case .SQLITE_CORRUPT, .SQLITE_NOTADB, .SQLITE_CANTOPEN, .SQLITE_READONLY, .SQLITE_PERM: return .memory
            default: return nil // In particular, a SQLite lock release has no file-change identity.
            }
        }
        if let storage = error as? MemoryStorageError {
            switch storage {
            case .embeddingEpochMismatch, .embeddingActivationInvalid(.corpusDrift, _): return .memory
            case .embeddingActivationInvalid(.unusableCandidate, _): return .embedding
            default: return nil
            }
        }
        if let failure = error as? ToolFailureError {
            if failure.owner == "memory search model" { return .embedding }
            if failure.code == SwiftNativeMemoryV2.recallCorpusConverging.code { return .memory }
        }
        return nil
    }

    enum OwedCause: String, Codable, Sendable { case provider, desk, record, memory, profile, embedding, trust }

    struct OwedBasis: Codable, Equatable, Sendable {
        var route: String? = nil
        var answered: String? = nil
        var desk: String? = nil
        var record: String? = nil
        var memory: String? = nil
        var profile: String? = nil
        var embedding: String? = nil
        var trust: String? = nil
    }

    struct OwedDependence: Codable, Sendable {
        let cause: OwedCause
        let words: String
        let basis: OwedBasis

        func changed(to now: OwedBasis) -> Bool {
            switch cause {
            case .provider:
                return (now.route != nil && now.route != basis.route) || (now.answered != nil && now.answered != basis.answered)
            case .desk: return now.desk != basis.desk
            case .record: return now.record != basis.record
            case .memory: return now.memory != basis.memory
            case .profile: return now.profile != basis.profile
            case .embedding: return now.embedding != nil && now.embedding != basis.embedding
            case .trust: return now.trust != nil && now.trust != basis.trust
            }
        }
    }

    struct RecoveryCheckpoint: Codable, Sendable {
        var wait: OwedDependence?
        var captures: [MemoryManagerPromiseCapture]?
        var identities: [String]?
        var judgment: AfterTurnInterpretation?
    }

    func checkpoint(_ moment: CognitiveLivedMoment) throws -> RecoveryCheckpoint {
        if let kept = recoveries[moment.id] { return kept }
        guard let value = moment.recovery else { return RecoveryCheckpoint() }
        let decoded = try JSONDecoder().decode(RecoveryCheckpoint.self, from: JSONEncoder().encode(value))
        return decoded
    }

    func keepCheckpoint(_ id: String, _ value: RecoveryCheckpoint, door: LivedMomentDoor) async throws {
        // Produced judgments remain held even when the journal itself cannot accept a write.
        recoveries[id] = value
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        try await door.saveRecovery(id, json)
        recoveries[id] = nil
    }

    /// Read only the owner named by the wait. A new row has no wait and needs no dependency read.
    func owedBasis(_ moment: CognitiveLivedMoment, cause: OwedCause, door: LivedMomentDoor) async throws -> OwedBasis {
        func signature(_ paths: [URL], accessOnly: Bool = false) throws -> String {
            try paths.map { path -> String in
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
                    let keys: [FileAttributeKey] = accessOnly
                        ? [.systemFileNumber, .posixPermissions, .ownerAccountID, .groupOwnerAccountID]
                        : [.systemFileNumber, .size, .modificationDate, .posixPermissions, .ownerAccountID, .groupOwnerAccountID]
                    return keys
                        .map {
                            if let date = attrs[$0] as? Date { return String(date.timeIntervalSince1970) }
                            return String(describing: attrs[$0])
                        }.joined(separator: ":")
                } catch CocoaError.fileReadNoSuchFile { return "missing:" + path.lastPathComponent }
            }.joined(separator: "|")
        }
        var basis = OwedBasis()
        switch cause {
        case .provider:
            basis.route = await memoryManager?.judgmentRouteKey()
            if let route = basis.route { basis.answered = try await door.routeAnswer(route) }
        case .desk:
            let store = SwiftNativeDeskStore(dataRoot: door.dataRoot)
            basis.desk = try signature([store.opsPath, store.basePath, store.archivePath])
        case .memory:
            basis.memory = try signature([door.dataRoot.appendingPathComponent("memory")], accessOnly: true)
                + "|" + signature(["memory/memory.sqlite", "memory/memory.sqlite-wal"].map {
                    door.dataRoot.appendingPathComponent($0)
                })
        case .profile:
            basis.profile = try signature([door.dataRoot.appendingPathComponent("memory")], accessOnly: true)
                + "|" + signature([door.dataRoot.appendingPathComponent("memory/profile.json")])
        case .trust:
            let policy = SwiftNativeTrustCenter.policyURL(dataRoot: door.dataRoot)
            basis.trust = try signature([policy.deletingLastPathComponent()], accessOnly: true) + "|" + signature([policy])
        case .embedding:
            guard let state = await memory?.embeddingRuntimeSnapshot() else { return basis }
            // Usage timestamps do not repair inference. Configuration, serving identity and reloads do.
            basis.embedding = AfterTurnMemorySurprise.fingerprint([
                state.requestedBackend, state.effectiveBackend, state.modelId, String(state.dimensions),
                state.embeddingEpoch ?? "", String(state.coreMLResourcesAvailable), String(state.coreMLLoaded),
                String(state.modelLoadable), state.lastLoadError ?? "", state.lastLoadedAt ?? "",
                String(state.loadCount), String(state.unloadCount),
            ])
        case .record:
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let bytes = try encoder.encode([try JSONDecoder().decode(JSONValue.self, from: encoder.encode(moment.input)), moment.meaning])
            basis.record = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        return basis
    }

    func readBasis(_ moment: CognitiveLivedMoment, cause: OwedCause, door: LivedMomentDoor) async -> OwedBasis? {
        do { return try await owedBasis(moment, cause: cause, door: door) }
        catch {
            oweRecoveryRepair(moment.id, cause: "The \(cause.rawValue) dependency could not be read: \(error.localizedDescription)", door: door)
            return nil
        }
    }

    private func needsModelWait(_ cause: OwedCause, moment: CognitiveLivedMoment, saved: RecoveryCheckpoint) -> Bool {
        guard saved.judgment == nil, saved.captures == nil else { return false }
        guard let meaning = moment.meaning else { return true }
        guard cause == .provider || cause == .desk else { return false }
        return Self.decodedMeaning(meaning)?.promises.isEmpty == false
    }

    func answered(_ id: String, route: String?, door: LivedMomentDoor) async {
        guard let route else { return }
        do { try await door.recordAnswer(id, route) }
        catch { oweRecoveryRepair(id, cause: "The route's answer could not be recorded: \(error.localizedDescription)", door: door) }
    }

    /// How many turns are owed to the agent (recorded, not yet lived) in this data root's journal; nil when its door or journal read is unavailable.
    public func owedMomentCount(dataRoot: URL) async -> Int? {
        guard let door, door.dataRoot.standardizedFileURL == dataRoot.standardizedFileURL else { return nil }
        return await door.unlived()?.count
    }

    public func drainHeldAtIdle(isIdle: @escaping @Sendable () async -> Bool) async {
        guard let door else { return }
        await drainOwedRows(door: door, isIdle: isIdle)
    }

    /// At wake, recover unfinished moments while the live owner remains idle.
    public func drainOwedMomentsAtWake() async {
        guard let door else { return }
        await drainOwedRows(door: door, isIdle: heldDrainIsIdle)
    }

    /// Before the dream reads the day, drain due moments from this root in batches while yielding to live work.
    public func drainOwedAtNight(dataRoot: URL) async {
        guard let door, door.dataRoot.standardizedFileURL == dataRoot.standardizedFileURL else { return }
        await drainOwedRows(door: door, isIdle: heldDrainIsIdle, joining: true)
    }

    /// Recovery shares the live tail and yields between passes as soon as live work arrives. A pass folds one meaning or judges up to four rows.
    private func drainOwedRows(door: LivedMomentDoor, isIdle: (@Sendable () async -> Bool)?,
                               joining: Bool = false) async {
        // Night is a barrier before the dream reads the agent's day. Join a shared flight without taking its ownership, then continue through this owner.
        while let running = owedDrain {
            guard joining else { return }
            _ = await running.value
            guard !Task.isCancelled else { return }
        }
        guard !stopped, !Task.isCancelled else { return }
        let previous = observationTail
        let id = UUID()
        observationID = id
        let operation = Task {
            defer {
                self.owedDrain = nil
                self.liveOperations[id] = nil
                if observationID == id { observationTail = nil; observationID = nil }
            }
            _ = await previous?.value
            // Failed work remains due for the next drain; successful writes may advance into the fold in this drain.
            var attempted = Set<String>()
            while true {
                guard !stopped, !Task.isCancelled, let memory else { break }
                let idle = await isIdle?() ?? true
                guard idle, pendingLiveObservations == 0 else { break }
                if !(await askOwedMoments(memory: memory, door: door, attempted: &attempted)) { break }
            }
            return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .skipped))
        }
        observationTail = operation
        liveOperations[id] = operation
        owedDrain = operation
        // Only the caller that starts this flight cancels it. A night caller joining somebody else's flight above never cancels shared work.
        _ = await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    /// Replay under recorded provenance: fold one meaning or judge one bounded batch. Meaning is saved before folding; already-lived pieces remain inert.
    @discardableResult
    private func askOwedMoments(memory: SwiftNativeMemoryV2, door: LivedMomentDoor,
                               attempted: inout Set<String>) async -> Bool {
        // Journal order selects due rows; a failed dependency holds only its own row.
        guard let unlived = await door.unlived() else { return false }
        let rows = unlived.filter { !inFlightMoments.contains($0.id) && !attempted.contains($0.id) }
        var due: [CognitiveLivedMoment] = []
        for row in rows {
            do {
                let saved = try checkpoint(row)
                if let wait = saved.wait, needsModelWait(wait.cause, moment: row, saved: saved) {
                    let basis = try await owedBasis(row, cause: wait.cause, door: door)
                    if !wait.changed(to: basis) { continue }
                }
                due.append(row)
            } catch {
                // No readable repair basis means no wait. Re-enter preparation, which will name its actual failure.
                oweRecoveryRepair(row.id, cause: error.localizedDescription, door: door)
                due.append(row)
            }
        }
        var owed: [(moment: CognitiveLivedMoment, turn: CognitiveMomentTurn)] = []
        for moment in due {
            guard !Task.isCancelled, !stopped else { return false }
            // Rows beyond the bounded batch are left for this drain's next pass.
            if owed.count == MemoryManagerLane.batchLimit { break }
            guard moment.kind == "turn", let turn = moment.input?.turn else {
                attempted.insert(moment.id)
                oweRecoveryRepair(moment.id, cause: "The owed moment has no recorded turn input.", door: door)
                continue
            }
            // Never rejudge recorded meaning: refold owed parts using watermarks and finish facts with original ordinals. Only rows without meaning return to
            // the model.
            var saved: RecoveryCheckpoint
            do {
                saved = try checkpoint(moment)
                if saved.wait != nil {
                    saved.wait = nil
                    try await keepCheckpoint(moment.id, saved, door: door)
                }
            } catch {
                attempted.insert(moment.id)
                oweRecoveryRepair(moment.id, cause: error.localizedDescription, door: door); continue
            }
            if let judgment = saved.judgment {
                attempted.insert(moment.id)
                guard let value = Self.encodedMeaning(judgment) else {
                    oweRecoveryRepair(moment.id, cause: "The retained judgment could not be encoded.", door: door)
                    continue
                }
                if await door.meant(moment.id, value) {
                    var kept = saved
                    kept.judgment = nil
                    kept.wait = nil
                    do { try await keepCheckpoint(moment.id, kept, door: door) }
                    catch { oweRecoveryRepair(moment.id, cause: error.localizedDescription, door: door) }
                    attempted.remove(moment.id)
                    return true
                }
                oweRecoveryRepair(moment.id, cause: "The retained judgment could not be written; due on the next drain.", door: door)
                continue
            }
            let stored = moment.meaning.flatMap(Self.decodedMeaning)
            if moment.meaning != nil, stored == nil {
                attempted.insert(moment.id)
                oweRecoveryRepair(moment.id, cause: "The recorded meaning is unreadable.", door: door)
                continue
            }
            if let stored {
                attempted.insert(moment.id)
                await foldOwed(moment, turn: turn, meaning: stored, memory: memory, door: door)
                return true
            }
            owed.append((moment, turn))
        }
        guard !owed.isEmpty else { return false }
        guard let memoryManager else {
            for entry in owed { oweRecoveryRepair(entry.moment.id, cause: "The memory judgment owner is unavailable.", door: door) }
            return false
        }
        let judged = Array(owed.prefix(MemoryManagerLane.batchLimit))
        for entry in judged { attempted.insert(entry.moment.id) }
        await judgeOwedBatch(judged, manager: memoryManager, memory: memory, door: door)
        // A newly durable interpretation advances to its one fold attempt now. Failed writes/calls stay attempted until the next drain.
        for entry in judged {
            if let after = await door.moment(entry.moment.id), after.state == .meant {
                attempted.remove(entry.moment.id)
            }
        }
        return true
    }

    /// Use the same recorded-turn surprise key as the live memory manager.
    private static func ledgerTurn(_ turn: CognitiveMomentTurn, moment: String) -> String {
        turn.turnId ?? turn.runId ?? turn.messageId ?? moment
    }

    func waitForChange(_ id: String, since basis: OwedBasis?, cause: OwedCause, words: String) async {
        guard let door else { return }
        do {
            guard let moment = await door.moment(id) else { return }
            var saved = try checkpoint(moment)
            // These retries already have the judgment; no model expense is being avoided.
            if !needsModelWait(cause, moment: moment, saved: saved) {
                if let prior = saved.wait, !needsModelWait(prior.cause, moment: moment, saved: saved) {
                    saved.wait = nil
                    try await keepCheckpoint(id, saved, door: door)
                }
                return
            }
            guard let basis else {
                oweRecoveryRepair(id, cause: "\(words) No readable \(cause.rawValue) repair basis was recorded; the work remains due.", door: door)
                return
            }
            saved.wait = OwedDependence(cause: cause, words: words, basis: basis)
            try await keepCheckpoint(id, saved, door: door)
        } catch { oweRecoveryRepair(id, cause: error.localizedDescription, door: door) }
    }

    /// Refold recorded meaning under its recorded provenance; local writes remain due on the next drain.
    private func foldOwed(_ moment: CognitiveLivedMoment, turn: CognitiveMomentTurn,
                          meaning: AfterTurnInterpretation,
                          memory: SwiftNativeMemoryV2, door: LivedMomentDoor) async {
        inFlightMoments.insert(moment.id)
        let result = await replayRecorded(moment, turn: turn, memory: memory, meaning: meaning)
        inFlightMoments.remove(moment.id)
        guard !Task.isCancelled, result.extraction.failure?.reason != .cancelled else { return }
        // Done means the ROW is settled. Unsaved local shares retry without another interpretation.
        let after = await door.moment(moment.id)
        let unfinished = after.map { $0.state != .lived && $0.state != .refused } ?? true
        guard result.extraction.failure != nil || result.stagingFailed || unfinished else {
            recoveries[moment.id] = nil
            RepairOwed.settle(door.dataRoot, operation: "memory.moment_recovery:" + moment.id,
                evidence: .init(source: "cognition/cognition.sqlite", id: moment.id))
            return
        }
        // Promise matching records its own dependency. A fold/write itself needs no model call.
        oweRecoveryRepair(moment.id, cause: result.extraction.failure?.localizedDescription ?? "The fold remains owed; due on the next drain.", door: door)
    }

    /// Recovery must retain the recorded turn's provenance.
    func replayRecorded(_ moment: CognitiveLivedMoment, turn: CognitiveMomentTurn,
                                memory: SwiftNativeMemoryV2,
                                meaning: AfterTurnInterpretation? = nil) async -> AdaptiveMemoryObservation {
        // The durable moment owns recovery even when its exchange has no separate act or run identity.
        let id = turn.turnId.flatMap { $0.isEmpty ? nil : $0 } ?? moment.id
        let run = turn.runId.flatMap { $0.isEmpty ? nil : $0 } ?? moment.id
        let speaker = turn.standingAgentName
            ?? (Self.isAgentSeatUserMessage(turn.user) ? Self.bridgeSender(turn.user) : nil)
        guard let carriers = turn.carriedSources else {
            if let door { oweRecoveryRepair(moment.id, cause: "The recorded turn has no carriedSources provenance.", door: door) }
            let failure = AfterTurnMemoryFailure(reason: .invalidJSON,
                recovery: "The recorded turn has no carriedSources provenance. Repair that journal row; it remains owed.",
                model: nil, surface: turn.surface)
            return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .failed, failure: failure))
        }
        let checkpoint = PeerDataTaint(restoring: carriers,
                                       elevated: turn.elevatedSources ?? [])
        // The durable moment supplies recovery authority; an absent transport envelope grants nothing.
        var held = Turn(id: id, run: run, session: turn.sessionId)
        held.peerSteering = checkpoint
        held.envelope = TurnEnvelope.fromPersistedMetadata(turn.envelope)
        held.afterTurnOrigin = turn.origin
        held.careWakes = turn.careWakes ?? []
        let recoveryTurn = held
        return await TurnTraceContext.$turnId.withValue(recoveryTurn.id) {
            await interpretMemoryManager(speaker: speaker, memory: memory,
                userMessage: turn.user, assistantMessage: turn.assistant,
                sessionId: turn.sessionId, surface: turn.surface, origin: turn.origin,
                turnId: turn.turnId, standingAgent: turn.standingAgentName != nil,
                momentID: moment.id, turn: recoveryTurn, senseReads: nil, storedMeaning: meaning, collect: meaning == nil)
        }
    }

    /// One call, one section per row; retained judgments retry their writes on the next drain.
    private func judgeOwedBatch(_ rows: [(moment: CognitiveLivedMoment, turn: CognitiveMomentTurn)],
                                manager: any MemoryManaging, memory: SwiftNativeMemoryV2,
                                door: LivedMomentDoor) async {
        var inputs: [(moment: CognitiveLivedMoment, turn: CognitiveMomentTurn, input: MemoryBatchInput, basis: OwedBasis?)] = []
        for (moment, turn) in rows {
            guard !Task.isCancelled, !stopped else { break }
            inFlightMoments.insert(moment.id)
            let prepared = await replayRecorded(moment, turn: turn, memory: memory)
            if let input = prepared.batchInput {
                let basis = await readBasis(moment, cause: .provider, door: door)
                inputs.append((moment, turn, input, basis))
            } else {
                // Only the failing owner may name a wait; an unclassified failure owes repair and remains due.
                inFlightMoments.remove(moment.id)
                guard !Task.isCancelled, prepared.extraction.failure?.reason != .cancelled else { break }
                let after = await door.moment(moment.id)
                if let after, after.state != .lived, after.state != .refused {
                    do {
                        if try checkpoint(after).wait == nil {
                            oweRecoveryRepair(moment.id,
                                cause: prepared.extraction.failure?.localizedDescription
                                    ?? "Preparation returned \(prepared.extraction.semanticStatus.rawValue) without a model input or named dependency.",
                                door: door)
                        }
                    } catch { oweRecoveryRepair(moment.id, cause: error.localizedDescription, door: door) }
                }
            }
        }
        defer { for entry in inputs { inFlightMoments.remove(entry.moment.id) } }
        guard !inputs.isEmpty, !Task.isCancelled, !stopped else { return }
        let root = await memory.surpriseDataRoot()
        let started = ProcessInfo.processInfo.systemUptime
        var providerSeconds = 0.0
        var replies: [AfterTurnInterpretation?] = []
        var failure: String?
        var cancelled = false
        if let first = inputs.first {
            TurnTraceBus.fire(TurnTraceEvent(turnId: first.input.call.turn?.id ?? first.moment.id, kind: "memory.held",
                sessionId: first.turn.sessionId, surface: first.turn.surface,
                payload: .object(["moments": .array(inputs.map { .string($0.moment.id) })]), turn: first.input.call.turn))
        }
        do {
            replies = try await manager.interpretBatch(inputs.map(\.input))
            providerSeconds = max(0, ProcessInfo.processInfo.systemUptime - started)
        } catch {
            failure = error.localizedDescription
            cancelled = Self.isCancellation(error)
        }
        // The provider answered on the route this attempt was asked under: rows whose call failed there are due again.
        if failure == nil, let first = inputs.first {
            await answered(first.moment.id, route: first.basis?.route, door: door)
        }
        let share = providerSeconds / Double(inputs.count)
        let wasCancelled = cancelled || Task.isCancelled
        // A returned judgment is produced work. Validate its target contracts, write meaning and label it outside cancellation before releasing it.
        await settle { [inputs, replies, failure, wasCancelled] in
            await self.recordBatchJudgments(inputs, replies: replies, failure: failure, cancelled: wasCancelled,
                                           share: share, root: root, door: door)
        }
    }

    /// Only a judgment writes a ledger row; an attempt that judged nothing shows once in `mind.why` and leaves the row owed.
    private func recordBatchJudgments(
        _ inputs: [(moment: CognitiveLivedMoment, turn: CognitiveMomentTurn, input: MemoryBatchInput, basis: OwedBasis?)],
        replies: [AfterTurnInterpretation?], failure: String?, cancelled: Bool, share: Double, root: URL?,
        door: LivedMomentDoor
    ) async {
        for (index, entry) in inputs.enumerated() {
            let id = entry.moment.id
            var basis = entry.basis
            if failure == nil {
                basis = await readBasis(entry.moment, cause: .provider, door: door)
            }
            let turnKey = Self.ledgerTurn(entry.turn, moment: id)
            let reply = (replies.indices.contains(index) ? replies[index] : nil)
                .map { MemoryManagerLane.resolvingTargets($0, request: entry.input.request) }
            let outcome: String
            var check: AfterTurnMemorySurprise?
            if let reply, let meaning = Self.encodedMeaning(reply), await door.meant(id, meaning) {
                recoveries[id] = nil
                outcome = "judged in a batch of \(inputs.count)"
                if let root {
                    check = await AfterTurnSurpriseLedger.shared.label(dataRoot: root, session: entry.turn.sessionId,
                        turn: turnKey, surface: entry.turn.surface,
                        channels: AfterTurnChannelOutcome(interpretation: reply, factsAsked: entry.input.factsEnabled),
                        providerSeconds: share, judgedBy: reply.judgingKey).check
                }
            } else if let reply {
                var saved: RecoveryCheckpoint
                do { saved = try checkpoint(entry.moment) }
                catch { oweRecoveryRepair(id, cause: error.localizedDescription, door: door); continue }
                saved.judgment = reply
                saved.wait = nil
                do { try await keepCheckpoint(id, saved, door: door) }
                catch { oweRecoveryRepair(id, cause: error.localizedDescription, door: door) }
                outcome = "left owed: its judgment could not be written to the agent's journal"
            } else if cancelled {
                outcome = "left owed: the batch call was cancelled; due on the next drain"
            } else if let failure {
                outcome = "left owed: the batch call failed (\(failure))"
                await waitForChange(id, since: basis, cause: .provider, words: failure)
            } else {
                outcome = "left owed: the batch reply has no usable section for this recorded turn"
                await waitForChange(id, since: basis, cause: .provider,
                                    words: "The batch reply has no usable section for this recorded turn.")
            }
            Self.whyInterpretation(turn: turnKey, session: entry.turn.sessionId,
                surface: entry.turn.surface,
                route: TurnEnvelope.fromPersistedMetadata(entry.turn.envelope)?.replyRoute,
                outcome: outcome, check: check, heldTurn: entry.input.call.turn)
        }
    }

    func oweRecoveryRepair(_ id: String, cause: String, door: LivedMomentDoor) {
        RepairOwed.owe(door.dataRoot, id: "memory-moment:" + id, kind: .act,
            evidence: [.init(source: "cognition/cognition.sqlite", id: id)], operation: "memory.moment_recovery:" + id,
            owner: "LivedMomentDoor", words: "\(cause) Repair moment \(id) in cognition/cognition.sqlite; its work remains owed.")
    }

}
