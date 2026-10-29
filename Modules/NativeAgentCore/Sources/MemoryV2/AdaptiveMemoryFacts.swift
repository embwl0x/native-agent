import Transcripts
import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import CognitiveSubstrate
import ChatTurnContracts
import TurnTrace
import NativeAgentShared
// Blueprint: | `AdaptiveMemoryFacts.swift` | Fact-lane memory interpretation and supersession |
extension AdaptiveMemoryPromoter {
    // MARK: - The fact lane: the memory manager
    /// Predict before judging and label each judgment. A complete-no-op claim
    /// with standing defers a recorded turn, leaving it owed for batch judgment
    /// (docs/COGNITION_WIRING.md, "Deferral").
    func runMemoryManager(
        speaker: String? = nil, memory: SwiftNativeMemoryV2,
        userMessage: String, assistantMessage: String, sessionId: String, surface: String,
        origin: AfterTurnOrigin?, turnId: String?, standingAgent: Bool = false,
        momentID: String
    ) async -> AdaptiveMemoryObservation {
        guard let door, let moment = await door.moment(momentID),
              moment.state != .lived, moment.state != .refused else {
            return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .unavailable))
        }
        if let recorded = moment.meaning {
            guard let meaning = Self.decodedMeaning(recorded), let turn = moment.input?.turn else {
                nativeLog("MemoryV2: moment %@ has an unreadable meaning or input; left as it is", momentID)
                return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .failed))
            }
            return await replayRecorded(moment, turn: turn, memory: memory, meaning: meaning)
        }
        let turnKey = turnId ?? origin?.runId ?? origin?.messageId ?? momentID
        let root = door.dataRoot
        let check = await predictTurn(user: origin?.userMessage ?? userMessage, reply: assistantMessage,
            took: origin?.took, agent: standingAgent ? (speaker ?? "standing agent") : "resident",
            memory: memory, dataRoot: root, turn: turnKey)
        if check.standing == true {
            var outcome = AdaptiveMemoryObservation(proposals: [],
                extraction: AdaptiveExtractionReport(candidates: [], semanticStatus: .deferred))
            outcome.surprise = await AfterTurnSurpriseLedger.shared.record(
                dataRoot: root, session: sessionId, turn: turnKey, surface: surface,
                recovery: false, deferred: true, check: check, channels: nil,
                providerSeconds: 0, failure: nil, judgedBy: nil)
            Self.whyInterpretation(turn: turnKey, session: sessionId, surface: surface,
                route: TurnEnvelope.current(surface: surface).replyRoute,
                outcome: "deferred: predicted a complete no-op; left owed for a batch", check: check)
            return outcome
        }
        var result = await interpretMemoryManager(speaker: speaker, memory: memory,
            userMessage: userMessage, assistantMessage: assistantMessage, sessionId: sessionId,
            surface: surface, origin: origin, turnId: turnId, standingAgent: standingAgent,
            momentID: momentID)
        result.surprise = await AfterTurnSurpriseLedger.shared.record(
            dataRoot: root, session: sessionId, turn: turnKey, surface: surface,
            recovery: false, deferred: false, check: check,
            channels: result.judged.map { AfterTurnChannelOutcome(interpretation: $0, factsAsked: result.factsAsked) },
            providerSeconds: result.providerSeconds, failure: result.extraction.failure?.reason.rawValue,
            judgedBy: result.judged?.judgingKey)
        return result
    }
    /// The prediction for one turn, scored against this agent's record for
    /// the memory model that would judge it.
    private func predictTurn(user: String, reply: String, took: String?, agent: String,
                             memory: SwiftNativeMemoryV2, dataRoot: URL, turn: String) async -> AfterTurnMemorySurprise {
        guard let memoryManager, let model = await memoryManager.predictionModelKey() else {
            return .unsure("memory_model_unkeyed")
        }
        let scope = AfterTurnMemorySurprise.Scope(agent: agent, model: model,
                                                  detector: AfterTurnMemorySurprise.detectorVersion)
        return await AfterTurnMemorySurprise.check(texts: [user, reply] + (took.map { [$0] } ?? []),
            scope: scope, memory: memory, dataRoot: dataRoot, excluding: turn)
    }
    /// Show known facts, judge once, then gate confidence, shape, duplicates and tombstones.
    /// Accept trusted survivors with source and time; leave the others for review.
    func interpretMemoryManager(
        speaker: String? = nil,
        memory: SwiftNativeMemoryV2,
        userMessage: String,
        assistantMessage: String,
        sessionId: String,
        surface: String,
        origin: AfterTurnOrigin?,
        turnId: String?,
        standingAgent: Bool = false,
        momentID: String,
        storedMeaning: AfterTurnInterpretation? = nil,
        collect: Bool = false
    ) async -> AdaptiveMemoryObservation {
        func empty(_ status: MemorySemanticExtractionStatus) -> AdaptiveMemoryObservation {
            AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: status))
        }
        guard let momentDoor = door, let moment = await momentDoor.moment(momentID),
              moment.state != .lived, moment.state != .refused else { return empty(.unavailable) }
        func settleWhole(_ reason: String) async { await momentDoor.refuse(momentID, reason) }
        guard let memoryManager else { return empty(.unavailable) }
        guard await conversationKind(sessionId)?.isOwnWork != true else {
            await settleWhole("her own work is not a moment")
            return empty(.skipped)
        }
        let user = origin?.userMessage ?? userMessage
        let assistant = assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await settleWhole("no incoming words")
            return empty(.emptyInput)
        }
        // What is already known about this exchange. `recordingUsage: false`:
        // reading the store to decide what to keep is not the agent USING a
        // memory, and use_count is the signal that vetoes eviction.
        let context: AfterTurnContext?
        let factsOnly = moment.input?.factsOnly == true
        if factsOnly { context = nil } else {
            guard let origin, origin.sessionId == sessionId,
                  let prepared = await momentDoor.prepare(momentID, origin, assistant) else {
                return empty(.unavailable)
            }
            context = prepared
        }
        let author = MemoryMoments.author(surface: surface,
            peer: speaker != nil || context?.event.sourceClass == .imported)
        let isPeer = author != "user"
        let originalHumanName = personName?()
        // Who stands behind the incoming words. An app-authored prompt has no
        // one behind it: only what her reply said is hers to keep.
        let fromReply = author == "app"
        let incoming = fromReply ? (key: "self", trusted: false)
            : Self.incomingSpeaker(isPeer: isPeer, speaker: speaker, sessionId: sessionId, dataRoot: momentDoor.dataRoot)
        let factsEnabled = !assistant.isEmpty && (adaptivePromotionEnabled?() ?? true)
        guard factsEnabled || context != nil else {
            await settleWhole("nothing to interpret")
            return empty(.skipped)
        }
        // Include pending ids so updates can retire them; hold the turn if its memory history is unreadable.
        var existing: [MemoryManagerExistingMemory] = []
        var forgotten: [String] = []
        var pendingRows: [ProposalRecord] = []
        var factsReadable = true
        if factsEnabled {
            do {
                existing = try await memory.recall(
                    MemoryV2RecallRequest(text: "\(user)\n\(assistant)", topK: MemoryManagerLane.recallTopK),
                    recordingUsage: false
                ).scored.map {
                    MemoryManagerExistingMemory(id: $0.record.id, content: $0.record.text,
                        correctionSubject: $0.record.extras?.objectValue?["correction_subject"]?.stringValue,
                        kind: $0.record.memoryKind)
                }
                for record in try await memory.listMemory(kind: "correction")
                    .filter({ ($0.status ?? "active") == "active"
                        && !MemoryStorage.metadataFlag($0.extras, MemoryStorage.pendingAdmissionKey) })
                    .sorted(by: { ($0.createdAt ?? "") > ($1.createdAt ?? "") }).prefix(24) {
                    let subject = record.extras?.objectValue?["correction_subject"]?.stringValue
                    let known = MemoryManagerExistingMemory(id: record.id, content: record.text,
                                                            correctionSubject: subject, kind: record.memoryKind)
                    if let index = existing.firstIndex(where: { $0.id == record.id }) { existing[index] = known }
                    else { existing.append(known) }
                }
                // What she was told to forget, nearest first: a restatement is
                // the manager's to skip (the store's own gate refuses only the
                // near-verbatim, `memoryNearVerbatimSimilarity`).
                forgotten = try await memory.forgottenClaims(near: "\(user)\n\(assistant)",
                                                             limit: MemoryManagerLane.forgottenTopK)
                pendingRows = Array(try await memory.listProposals(status: "pending")
                    .filter { !MemoryMoments.isMoment($0.metadata) }
                    .sorted { $0.createdAt > $1.createdAt }
                    .prefix(MemoryManagerLane.pendingCap))
            } catch {
                factsReadable = false
                existing = []
                forgotten = []
                nativeLog("MemoryV2: fact lane held this turn, the memory store could not be read: \(error.localizedDescription)")
            }
        }
        let pending: [String] = pendingRows.map(\.content)
        // A recorded moment whose facts are asked for but unreadable records
        // NO interpretation: an empty fact judgment made blind would later be
        // reused and settle facts never judged. The whole row stays owed and
        // is judged again once the store answers.
        if storedMeaning == nil, factsEnabled, !factsReadable {
            let failure = AfterTurnMemoryFailure(reason: .provider,
                recovery: "Her memory store could not be read; this turn stays owed and is judged again once it answers.",
                model: nil, surface: surface)
            return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [],
                semanticStatus: .failed, failure: failure))
        }
        let request = MemoryManagerRequest(
            userMessage: user,
            assistantMessage: assistant,
            existing: existing,
            pendingTargets: pendingRows.map { MemoryManagerExistingMemory(id: $0.id, content: $0.content) },
            forgotten: forgotten,
            personName: author == "app" ? "NativeAgent" : speaker ?? originalHumanName,
            standingAgent: standingAgent, appAuthored: author == "app", took: origin?.took,
            occurredAt: origin?.occurredAt
        )
        // A batch takes the request as this turn would be judged alone, and
        // judges it with others (`judgeOwedBatch`).
        if collect {
            var outcome = AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .unreported))
            outcome.batchInput = MemoryBatchInput(request: request, context: context,
                                                  factsEnabled: factsEnabled && factsReadable)
            return outcome
        }
        let interpretation: AfterTurnInterpretation?
        var providerSeconds = 0.0
        do {
            // A moment already judged (`meant`) folds with its recorded meaning:
            // the model is not asked again.
            if let storedMeaning { interpretation = storedMeaning } else {
                let callStarted = ProcessInfo.processInfo.systemUptime
                let judged = try await LLMCallContext.$purpose.withValue("memory_interpret") {
                    try await memoryManager.interpret(request, context: context, factsEnabled: factsEnabled && factsReadable)
                }
                providerSeconds = max(0, ProcessInfo.processInfo.systemUptime - callStarted)
                interpretation = judged.map { MemoryManagerLane.resolvingTargets($0, request: request) }
            }
        } catch {
            // The row stays owed; a failed judgment changes nothing.
            let reason: AfterTurnMemoryFailure.Reason
            if Task.isCancelled || error is CancellationError { reason = .cancelled }
            else {
                switch error as? AfterTurnInterpretationFailure {
                case .authentication: reason = .authExpired
                case .deadline: reason = .deadline
                case .cancellation: reason = .cancelled
                case .envelope: reason = .invalidJSON
                case .caring: reason = .invalidCaring
                case .affect: reason = .invalidAffect
                case .memories: reason = .invalidMemories
                case .cares: reason = .invalidCares
                default: reason = .provider
                }
            }
            let failure = (error as? AfterTurnMemoryFailure) ?? AfterTurnMemoryFailure(
                reason: reason,
                recovery: "Check the selected memory model in Settings; the turn stays owed and is judged again after its next successful answer.",
                model: nil, surface: surface)
            return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [],
                semanticStatus: failure.reason == .deadline ? .timedOut : .failed, failure: failure))
        }
        // Written as meant BEFORE any part of her applies it, and a fold
        // begins only once that write is durable: if it fails, the row
        // stays owed, nothing applies now, and it is judged again later.
        if storedMeaning == nil, let interpretation {
            let recorded = await settle {
                guard let meaning = Self.encodedMeaning(interpretation) else { return false }
                return await momentDoor.meant(momentID, meaning)
            }
            guard recorded else {
                let failure = AfterTurnMemoryFailure(reason: .provider,
                    recovery: "Her journal could not record this interpretation; the turn stays owed and is judged again.",
                    model: interpretation.model, surface: surface)
                return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [],
                    semanticStatus: .failed, failure: failure))
            }
        }
        // Only an explicitly facts-only input can settle without a mind/body fold.
        var folded = factsOnly
        if !Task.isCancelled, let interpretation, let context {
            folded = await finishInterpretation?(context, interpretation, momentID) ?? false
        }
        guard !Task.isCancelled, let interpretation else {
            let failure = AfterTurnMemoryFailure(reason: Task.isCancelled ? .cancelled : .missingSections,
                recovery: "Check the selected memory model in Settings; the turn stays owed and is judged again after its next successful answer.",
                model: nil, surface: surface)
            return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [],
                semanticStatus: .failed, failure: failure))
        }
        let factsProcessed = factsEnabled && factsReadable && (adaptivePromotionEnabled?() ?? true)
        let decisions = factsProcessed ? interpretation.memories : []
        var staged: [ProposalRecord] = []
        var accepted: [AdaptiveCandidate] = []
        var rejected = 0
        var savedCorrections = 0
        var pendingCorrections = 0
        var failedCorrections = 0
        var stagingFailed = false
        // Everything the statement must not merely repeat: what is kept, what is
        // pending, and what this same pass already minted this turn.
        var comparisons = existing.map(\.content) + pending
        // Each fact's (life, moment, ordinal) is committed in its proposal metadata.
        // Refolding continues pending acceptance, skips resolved rows and stages missing ones.
        var priorOps: [String: ProposalRecord] = [:]
        var proposalsByID: [String: ProposalRecord] = [:]
        if !decisions.isEmpty {
            do {
                for proposal in try await memory.listProposals(status: nil) {
                    proposalsByID[proposal.id] = proposal
                    if case .object(let metadata)? = proposal.metadata,
                       case .string(let op)? = metadata[Self.momentOperationKey] { priorOps[op] = proposal }
                }
            } catch {
                // An unreadable store is never an empty one: the facts part stays owed.
                stagingFailed = true
            }
        }
        for (ordinal, raw) in decisions.enumerated() {
            let operation = "\(moment.life)|\(momentID)|\(ordinal)"
            if stagingFailed { break }
            let decision = raw
            var supersededPending: ProposalRecord?
            var updateTarget: MemoryManagerExistingMemory?
            if decision.action == .update {
                // Resolve once, before meaning is saved. Recovery reads the exact
                // identity, even outside today's recall/pending prefix, and keeps
                // the reviewed fingerprint for transactional acceptance.
                guard let target = decision.reviewedTarget, target.id == decision.updatesId else {
                    stagingFailed = true
                    nativeLog("MemoryV2: update in moment %@ has no reviewed target; left meant", momentID)
                    continue
                }
                if target.pending {
                    guard let old = proposalsByID[target.id],
                          MemoryManagerLane.contentFingerprint(old.content) == target.fingerprint else {
                        stagingFailed = true
                        continue
                    }
                    supersededPending = old
                } else {
                    do {
                        if let row = try await memory.authorityRecord(id: target.id) {
                            updateTarget = MemoryManagerExistingMemory(id: row.id, content: row.text,
                                correctionSubject: row.extras?.objectValue?["correction_subject"]?.stringValue,
                                kind: row.memoryKind)
                        }
                    } catch { stagingFailed = true; continue }
                }
            }
            guard decision.action != .skip else { continue }
            guard decision.confidence >= MemoryManagerLane.confidenceFloor else {
                rejected += 1
                continue
            }
            // Saved judgments predate attributed grounding. Absence in a
            // recorded meaning keeps its original eligibility rule; live parsing
            // requires the field for every add/update before meaning is saved.
            let legacyGrounding = storedMeaning != nil && decision.grounding == nil
            guard decision.grounding != nil || legacyGrounding else {
                stagingFailed = true
                nativeLog("MemoryV2: decision in moment %@ has no attributed grounding; left meant", momentID)
                continue
            }
            let isCorrection = decision.kind == "correction"
            if let prior = priorOps[operation] {
                // This decision already reached MemoryV2 in an earlier fold:
                // finish its pending-target retirement even when the successor
                // was already accepted, then continue any pending acceptance.
                guard await finishPendingSupersession(supersededPending, by: prior.id, memory: memory) else {
                    stagingFailed = true
                    continue
                }
                let keepsIt = fromReply
                    ? legacyGrounding || MemoryManagerLane.statementRejectionReason(decision, userMessage: "", assistantMessage: assistant) == nil
                    : incoming.trusted && (!isCorrection || incoming.key == CognitiveCare.ownerKey)
                if prior.status == "pending", keepsIt {
                    do {
                        _ = try await memory.acceptProposal(id: prior.id)
                        accepted.append(AdaptiveCandidate(content: decision.statement, score: decision.confidence,
                                                          kind: decision.kind))
                        if isCorrection { savedCorrections += 1 }
                    } catch {
                        nativeLog("MemoryV2: fact \(prior.id) left for her review, not kept: \(error)")
                    }
                }
                continue
            }
            if isCorrection, origin?.occurredAt == nil || origin?.sessionId != sessionId {
                rejected += 1
                failedCorrections += 1
                nativeLog("MemoryV2: standing correction not saved: originating turn timestamp unavailable")
                continue
            }
            if isCorrection, let updateTarget,
               updateTarget.kind != "correction"
                || (updateTarget.correctionSubject != nil && updateTarget.correctionSubject != decision.correctionSubject) {
                rejected += 1
                continue
            }
            if isCorrection, let old = supersededPending {
                guard old.metadata?.objectValue?["kind"]?.stringValue == "correction",
                      old.metadata?.objectValue?["correction_subject"]?.stringValue == decision.correctionSubject,
                      let timestamp = old.metadata?.objectValue?["observed_at"]?.stringValue,
                      let priorDate = MemoryRecallScoring.parseTimestamp(timestamp),
                      let sourceDate = origin?.occurredAt, priorDate <= sourceDate else {
                    rejected += 1
                    failedCorrections += 1
                    nativeLog("MemoryV2: standing correction not saved: pending rule chronology or subject unavailable or newer")
                    continue
                }
            }
            let refusal = legacyGrounding ? nil : isCorrection
                ? MemoryManagerLane.correctionRejectionReason(decision, userMessage: user,
                    isPeer: isPeer, personName: originalHumanName)
                : MemoryManagerLane.statementRejectionReason(decision, userMessage: fromReply ? "" : user,
                                                             assistantMessage: assistant)
            if refusal != nil {
                rejected += 1
                continue
            }
            if isCorrection, let kept = existing.first(where: {
                $0.correctionSubject == decision.correctionSubject
                    && MemoryManagerLane.contentFingerprint($0.content) == MemoryManagerLane.contentFingerprint(decision.statement)
            }) {
                // The same correction given again: its row keeps this turn as a
                // repeat, the way a collapsed commit does, so the miss counts.
                do {
                    if let row = try await memory.authorityRecord(id: kept.id) {
                        _ = try await memory.updateMemory(id: kept.id, update: .object(SwiftNativeMemoryV2.duplicateProvenancePatch(
                            existing: row, newSource: "standing-correction:\(sessionId)",
                            newMetadata: .object(MemoryMoments.turnMetadata(turnId: turnId, origin: origin)))))
                    }
                } catch {
                    stagingFailed = true
                    nativeLog("MemoryV2: repeated standing correction's turn not kept: \(error)")
                }
                continue
            }
            // Exclude the update's target from duplicate screening; all other kept and pending rows still screen.
            let replacedContent = updateTarget?.content ?? supersededPending?.content
            let screened: [String] = replacedContent.map { target in
                comparisons.filter { $0 != target }
            } ?? comparisons
            do {
                try Task.checkCancellation()
                if !isCorrection, try await Self.nearDuplicate(
                    decision.statement, of: screened, memory: memory
                ) != nil {
                    rejected += 1
                    continue
                }
                if try await memory.isRejected(content: decision.statement) {
                    rejected += 1
                    continue
                }
                // A standing rule is kept only from the owner's own words.
                let keep = fromReply
                    ? legacyGrounding || MemoryManagerLane.statementRejectionReason(decision, userMessage: "", assistantMessage: assistant) == nil
                    : incoming.trusted && (!isCorrection || incoming.key == CognitiveCare.ownerKey)
                let proposal = try await memory.propose(
                    content: decision.statement,
                    source: "\(isCorrection ? "standing-correction" : MemoryManagerLane.sourcePrefix):\(sessionId)",
                    confidence: decision.confidence,
                    kind: decision.kind,
                    supportingSessionIDs: [sessionId],
                    recurrenceCount: 1,
                    extraMetadata: MemoryManagerLane.metadata(
                        for: decision, sessionId: sessionId, surface: surface,
                        observedAt: origin?.occurredAt
                    ).merging(MemoryMoments.turnMetadata(turnId: turnId, origin: origin)) { current, _ in current }
                        .merging(MemoryMoments.sourceMetadata(sessionId: origin?.sessionId ?? sessionId,
                            messageId: origin?.messageId, turnId: turnId, at: origin?.occurredAt ?? Date(),
                            speaker: decision.grounding?.source == .reply ? "self" : incoming.key,
                            words: decision.grounding?.evidence)) { current, _ in current }
                        .merging([Self.momentOperationKey: .string(operation)]) { current, _ in current }
                )
                comparisons.append(decision.statement)
                guard await finishPendingSupersession(supersededPending, by: proposal.id, memory: memory) else {
                    stagingFailed = true
                    staged.append(proposal)
                    continue
                }
                let candidate = AdaptiveCandidate(
                    content: decision.statement,
                    score: decision.confidence,
                    kind: decision.kind
                )
                accepted.append(candidate)
                // A trusted exchange's fact is kept now, through the same
                // acceptance her review uses (quality, tombstones, the update's
                // supersession). What acceptance refuses stays with her review.
                var kept = false
                if keep {
                    do {
                        _ = try await memory.acceptProposal(id: proposal.id)
                        kept = true
                    } catch {
                        nativeLog("MemoryV2: fact \(proposal.id) left for her review, not kept: \(error)")
                    }
                }
                if !kept { staged.append(proposal) }
                if isCorrection {
                    if kept { savedCorrections += 1 } else { pendingCorrections += 1 }
                }
            } catch {
                stagingFailed = true
                if isCorrection { failedCorrections += 1 }
                continue
            }
        }
        // LIVED once the attempt reaches its end: the fold landed, and every
        // fact decision staged (or none was asked). Otherwise the row stays
        // meant and is lived again from its meaning: each piece that landed
        // skips by its stamp, each fact by its operation identity.
        let factsSettled = factsProcessed ? !stagingFailed : !(factsEnabled && !factsReadable)
        if folded, factsSettled, !Task.isCancelled { await momentDoor.lived(momentID) }
        var outcome = AdaptiveMemoryObservation(
            proposals: staged,
            extraction: AdaptiveExtractionReport(
                candidates: accepted,
                semanticStatus: .succeeded,
                semanticCandidateCount: decisions.count
            ),
            hygieneRejectedCount: rejected,
            savedCorrectionCount: savedCorrections,
            pendingCorrectionCount: pendingCorrections,
            failedCorrectionCount: failedCorrections,
            stagingFailed: stagingFailed || !factsReadable
        )
        // The label this judgment gives the record (a refold labels nothing).
        if storedMeaning == nil {
            outcome.judged = interpretation
            outcome.factsAsked = factsEnabled && factsReadable
            outcome.providerSeconds = providerSeconds
        }
        return outcome
    }
    /// The same final step for a fresh proposal and a recovered operation.
    /// A different successor is a conflict, never proof that our step landed.
    private func finishPendingSupersession(_ old: ProposalRecord?, by successor: String,
                                          memory: SwiftNativeMemoryV2) async -> Bool {
        guard let old, old.id != successor else { return true }
        do {
            if old.status == "superseded" {
                guard old.metadata?.objectValue?["supersededBy"]?.stringValue == successor else {
                    throw MemoryV2Error.recordNotFound
                }
            } else {
                guard try await memory.supersedeProposal(id: old.id, by: successor) else {
                    throw MemoryV2Error.recordNotFound
                }
            }
            return true
        } catch {
            nativeLog("MemoryV2: pending statement \(old.id) not retired by its correction: \(error)")
            return false
        }
    }
    /// First duplicate by the store's own embedder and recall comparison law.
    /// Embedding failure throws; an unperformed check never means no duplicate.
    static func nearDuplicate(
        _ statement: String,
        of others: [String],
        memory: SwiftNativeMemoryV2
    ) async throws -> Int? {
        guard !others.isEmpty else { return nil }
        let fold: (String) -> String = { MemoryMoments.wordFold($0) }
        let needle = fold(statement)
        if let exact = others.firstIndex(where: {
            fold($0) == needle && MemoryStorage.sameQuantityAndNegation(statement, $0)
        }) { return exact }
        let vectors = try await memory.embedForDerivedContext([statement] + others)
        guard vectors.count == others.count + 1, let query = vectors.first, !query.isEmpty else {
            throw MemoryV2Error.underlying("the duplicate check received \(vectors.count) of \(others.count + 1) vectors")
        }
        for (index, (other, vector)) in zip(others, vectors.dropFirst()).enumerated() {
            if MemoryStorage.semanticDuplicate(statement, other, similarity: VectorMath.cosine(query, vector)) { return index }
        }
        return nil
    }
    /// Detect the peer header stamped at bridge entry points.
    static func isAgentSeatUserMessage(_ text: String) -> Bool {
        if PeerTurnEffectPolicy.peerName(inTurnHeader: text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            return true
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.range(
            of: #"^\[from: [^\]]{1,64}, via bridge\]"#,
            options: .regularExpression
        ) != nil
    }
    /// Who said the incoming words, as the evidence keeps them, and whether the
    /// owner stands behind them: his own words, or a peer he trusts
    /// (`PeerTrust`, read through `PeerDataTaint`). The attested door in an
    /// agent or helper session id names the peer before a bridge header does,
    /// and makes the turn a peer's even when its words carried no header.
    static func incomingSpeaker(isPeer: Bool, speaker: String?, sessionId: String, dataRoot: URL = defaultDataRoot()) -> (key: String, trusted: Bool) {
        // The row's own attestation decides who spoke: the owner typing into a
        // conversation an agent started is still the owner.
        guard isPeer else { return (CognitiveCare.ownerKey, true) }
        let door = CognitiveSubstrate.peerIdentity(metadata: ["sessionId": .string(sessionId)], dataRoot: dataRoot)
        let key = PeerDataTaint.principal(door ?? speaker ?? "another agent")
        return (key, PeerDataTaint.ownerTrusts(key))
    }
    /// Read the speaker from the bridge-stamped peer header.
    static func bridgeSender(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let peer = PeerTurnEffectPolicy.peerName(inTurnHeader: t) { return peer }
        guard let match = t.range(of: #"^\[from: ([^\],]{1,64}), via bridge\]"#, options: .regularExpression) else { return nil }
        let inside = t[match].dropFirst("[from: ".count)
        let name = inside.prefix { $0 != "," }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = name.first else { return nil }
        return String(first).uppercased() + name.dropFirst()
    }
}
