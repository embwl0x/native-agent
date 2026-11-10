import Transcripts
import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import CognitiveSubstrate
import ChatTurnContracts
import Desk
import TurnTrace
import NativeAgentShared
import Senses
// Blueprint: | `AdaptiveMemoryFacts.swift` | shared interpretation with person words, completed acts, reply delivery and open moments; durable fact/fold settlement |
extension AdaptiveMemoryPromoter {
    // MARK: - The fact lane: the memory manager
    /// The person's own turns are judged at once; every other recorded turn stays owed and is judged when she is idle.
    func runMemoryManager(
        speaker: String? = nil, memory: SwiftNativeMemoryV2,
        userMessage: String, assistantMessage: String, sessionId: String, surface: String,
        origin: AfterTurnOrigin?, turnId: String?, standingAgent: Bool = false,
        momentID: String,
        turn: Turn,
        senseReads: SenseTurnReads?
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
        let isPersonConversation = await conversationKind(sessionId)?.isPersonConversation == true
        let isPersonTurn = speaker == nil && !standingAgent && isPersonConversation
        if !isPersonTurn {
            Self.whyInterpretation(turn: turnId ?? origin?.runId ?? origin?.messageId ?? momentID, session: sessionId, surface: surface,
                route: TurnEnvelope.current(turn: turn, surface: surface).replyRoute,
                outcome: "deferred: not the person's turn; left owed, judged when she is idle", heldTurn: turn)
            return AdaptiveMemoryObservation(proposals: [],
                extraction: AdaptiveExtractionReport(candidates: [], semanticStatus: .deferred))
        }
        // The route is read before the call, so an answer counts for the route that was asked.
        return await interpretMemoryManager(speaker: speaker, memory: memory,
            userMessage: userMessage, assistantMessage: assistantMessage, sessionId: sessionId,
            surface: surface, origin: origin, turnId: turnId, standingAgent: standingAgent,
            momentID: momentID, turn: turn, senseReads: senseReads)
    }
    /// Gate judged facts by confidence, shape, duplicates and tombstones; trusted survivors use the same acceptance as review.
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
        turn: Turn,
        senseReads: SenseTurnReads?,
        storedMeaning: AfterTurnInterpretation? = nil,
        held: Bool = false
    ) async -> AdaptiveMemoryObservation {
        func empty(_ status: MemorySemanticExtractionStatus) -> AdaptiveMemoryObservation {
            AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: status))
        }
        guard let momentDoor = door, let moment = await momentDoor.moment(momentID),
              moment.state != .lived, moment.state != .refused else { return empty(.unavailable) }
        func settleWhole(_ reason: String) async { await momentDoor.refuse(momentID, reason) }
        func beforeJudgment(_ cause: OwedCause) async -> OwedBasis? {
            guard storedMeaning == nil else { return nil }
            return await readBasis(moment, cause: cause, door: momentDoor)
        }
        let careWake = moment.input?.turn?.isCareWake == true
        // The recorded turn is the truth of its share; judgment only reads again whether it can still settle anything.
        let recordedShare: MomentShare = moment.input?.turn?.settlesOnly == true ? .settlement : .whole
        var completedActs: [MemoryManagerAct] = []
        var completedActsUnavailable: String?
        if storedMeaning == nil {
            do {
                guard let recorded = moment.input?.turn else {
                    throw ToolFailureError("The moment has no recorded turn for its completed acts.", effects: .none)
                }
                completedActs = try await Self.completedActs(recorded, dataRoot: momentDoor.dataRoot)
            } catch {
                if Self.isCancellation(error) {
                    return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .failed,
                        failure: AfterTurnMemoryFailure(reason: .cancelled,
                            recovery: error.localizedDescription, model: nil, surface: surface)))
                }
                // An unavailable act read supplies no act evidence, never a veto on the incoming words. A moment judged for settlement
                // alone has only its acts, so it stays owed until they can be read.
                if recordedShare == .settlement {
                    return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .failed,
                        failure: AfterTurnMemoryFailure(reason: .provider,
                            recovery: "Completed acts could not be read; settlement remains owed: " + error.localizedDescription,
                            model: nil, surface: surface)))
                }
                completedActsUnavailable = error.localizedDescription
                TurnTraceBus.fire(TurnTraceEvent(turnId: turnId ?? momentID, kind: "memory.promise.evidence",
                    sessionId: sessionId, surface: surface,
                    payload: .object(["unavailable": .string(error.localizedDescription)]), turn: turn))
            }
        }
        let user = origin?.userMessage ?? userMessage
        let assistant = assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a turn that can settle something reads the Desk: the person's words, a completed act, or a reply that reached a person. A moment
        // judged for settlement alone has no incoming message, so only its acts count.
        let personWords = recordedShare == .whole ? (moment.input?.turn).map(Self.settlementWords) ?? "" : ""
        var replyDelivered = false
        if storedMeaning == nil, recordedShare == .whole, let recorded = moment.input?.turn {
            replyDelivered = await self.replyDelivered(recorded)
        }
        var openMoments: [DeskItem] = []
        if storedMeaning == nil,
           !personWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !completedActs.isEmpty || replyDelivered {
            let deskBasis = await beforeJudgment(.desk)
            do {
                openMoments = try await SwiftNativeDeskStore(dataRoot: momentDoor.dataRoot).liveState().items
                    .filter { MyQueue.entry($0) != nil }
            } catch {
                let cancelled = Self.isCancellation(error)
                if !cancelled {
                    await waitForChange(momentID, since: deskBasis, cause: .desk, words: error.localizedDescription)
                }
                return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .failed,
                    failure: AfterTurnMemoryFailure(reason: cancelled ? .cancelled : .provider,
                        recovery: "Open moments could not be read; settlement remains owed: " + error.localizedDescription,
                        model: nil, surface: surface)))
            }
        }
        // The law that recorded the moment, read again on what is true now (or on the judgment already made).
        guard let share = await self.share(whole: recordedShare == .whole, settles: {
            !completedActs.isEmpty && !openMoments.isEmpty || storedMeaning?.settled.isEmpty == false
        }) else {
            await settleWhole("a turn without an incoming message settled nothing")
            return empty(.skipped)
        }
        let settlement = share == .settlement
        guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !completedActs.isEmpty
            || (replyDelivered && !openMoments.isEmpty) || storedMeaning?.settled.isEmpty == false else {
            await settleWhole("no incoming words")
            return empty(.emptyInput)
        }
        // Reading facts for retention is not memory use: disable usage recording because use_count vetoes eviction.
        let context: AfterTurnContext?
        let factsOnly = moment.input?.factsOnly == true
        if factsOnly { context = nil } else {
            guard let origin, origin.sessionId == sessionId else {
                await waitForChange(momentID, since: await beforeJudgment(.record), cause: .record,
                                    words: "The recorded moment has no matching turn origin; repair that row.")
                return empty(.unavailable)
            }
            let contextBasis = await beforeJudgment(.embedding)
            do { context = try await momentDoor.prepare(momentID, origin, assistant) }
            catch {
                if Self.isCancellation(error) {
                    return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .failed,
                        failure: AfterTurnMemoryFailure(reason: .cancelled, recovery: "Context preparation was cancelled; due on the next drain.",
                            model: nil, surface: surface)))
                }
                switch error as? LivedMomentPreparationFailure {
                case .embedding:
                    await waitForChange(momentID, since: contextBasis, cause: .embedding, words: error.localizedDescription)
                case .record:
                    await waitForChange(momentID, since: await beforeJudgment(.record), cause: .record, words: error.localizedDescription)
                default:
                    oweRecoveryRepair(momentID, cause: error.localizedDescription, door: momentDoor)
                }
                return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .failed,
                    failure: AfterTurnMemoryFailure(reason: .provider, recovery: error.localizedDescription, model: nil, surface: surface)))
            }
        }
        let author = MemoryDataProvenance.author(surface: surface,
            peer: speaker != nil || context?.event.sourceClass == .imported)
        let isPeer = author != "user"
        let originalHumanName: String?
        let profileBasis: OwedBasis?
        if personName != nil { profileBasis = await beforeJudgment(.profile) } else { profileBasis = nil }
        do { originalHumanName = try personName?() }
        catch {
            await waitForChange(momentID, since: profileBasis, cause: .profile, words: error.localizedDescription)
            let failure = AfterTurnMemoryFailure(reason: .provider,
                recovery: """
                    The person's saved profile could not be read: \(error.localizedDescription). Repair memory/profile.json; this turn stays owed until it can \
                    be read.
                    """,
                model: nil, surface: surface)
            return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [],
                semanticStatus: .failed, failure: failure))
        }
        // App-authored prompts, care wakes and turns without an incoming message have no speaker to retain; only the agent's reply is its own.
        let fromReply = author == "app" || careWake || settlement
        let incoming = fromReply ? (key: "self", trusted: false)
            : Self.incomingSpeaker(isPeer: isPeer, speaker: speaker, sessionId: sessionId, dataRoot: momentDoor.dataRoot)
        // The speaker its evidence records is the root's teller: the agent's own words it noticed, the person told it by name, and a peer told it
        // by its contact name (in a turn that peer steered, the store builds that root itself).
        func told(fromReply reply: Bool) -> MemoryRoot.Telling {
            if reply || incoming.key == "self" { return MemoryRoot.Telling(how: .noticed) }
            if incoming.key == CognitiveCare.ownerKey { return MemoryDataProvenance.toldByPerson(dataRoot: momentDoor.dataRoot) }
            return MemoryRoot.Telling(how: .told, by: PeerDataTaint.sourceName(incoming.key) ?? incoming.key)
        }
        var factsEnabled = false
        if share == .whole, !careWake, !assistant.isEmpty {
            let authorityBasis = await beforeJudgment(.trust)
            do { factsEnabled = try await promotionPolicyEnabled() }
            catch { return await unavailablePromotionPolicy(error, surface: surface, momentID: momentID, basis: authorityBasis) }
        }
        guard factsEnabled || context != nil || settlement else {
            await settleWhole("nothing to interpret")
            return empty(.skipped)
        }
        // Include pending ids so updates can retire them; hold the turn if its memory history is unreadable.
        var existing: [MemoryManagerExistingMemory] = []
        var forgotten: [String] = []
        var pendingRows: [ProposalRecord] = []
        var factsReadable = true
        var factsBasis: OwedBasis?
        var factEmbeddingBasis: OwedBasis?
        var factsFailure: Error?
        if factsEnabled {
            factsBasis = await beforeJudgment(.memory)
            factEmbeddingBasis = await beforeJudgment(.embedding)
            do {
                existing = try await memory.recall(
                    MemoryV2RecallRequest(text: "\(user)\n\(assistant)", topK: MemoryManagerLane.recallTopK),
                    recordingUsage: false
                ).scored.map {
                    MemoryManagerExistingMemory(id: $0.record.id, content: $0.record.text,
                        correctionSubject: $0.record.extras?.objectValue?["correction_subject"]?.stringValue,
                        kind: $0.record.memoryKind)
                }
                // A newer ruling must be judged against every current pin, even when recall ranks its old wording elsewhere.
                let now = Date()
                for record in try await memory.listMemory(kind: nil).filter({
                    $0.pinned == true && $0.status == "active"
                        && !MemoryStorage.metadataFlag($0.extras, MemoryStorage.pendingAdmissionKey)
                        && MemoryRecordDisclosurePolicy.classify($0, at: now)?.permits(surface: surface, personaID: nil) == true
                }) where !existing.contains(where: { $0.id == record.id }) {
                    existing.append(MemoryManagerExistingMemory(id: record.id, content: record.text,
                        correctionSubject: record.extras?.objectValue?["correction_subject"]?.stringValue, kind: record.memoryKind))
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
                // The manager must judge restated forgotten claims; the store gate only refuses near-verbatim matches.
                forgotten = try await memory.forgottenClaims(near: "\(user)\n\(assistant)",
                                                             limit: MemoryManagerLane.forgottenTopK)
                pendingRows = Array(try await memory.listProposals(status: "pending")
                    .filter { !MemoryMoments.isMoment($0.metadata) }
                    .sorted { $0.createdAt > $1.createdAt }
                    .prefix(MemoryManagerLane.pendingCap))
            } catch {
                factsFailure = error
                factsReadable = false
                existing = []
                forgotten = []
                nativeLog("MemoryV2: fact lane held this turn, the memory store could not be read: \(error.localizedDescription)")
            }
        }
        let pending: [String] = pendingRows.map(\.content)
        // Unreadable requested facts leave the whole moment owed; saving an empty judgment would settle facts never judged.
        if storedMeaning == nil, factsEnabled, !factsReadable {
            let words = factsFailure?.localizedDescription ?? "The requested facts could not be read; their failure has no cause."
            let cancelled = factsFailure.map(Self.isCancellation) == true
            if !cancelled, let error = factsFailure, let cause = Self.factReadCause(error) {
                await waitForChange(momentID, since: cause == .embedding ? factEmbeddingBasis : factsBasis, cause: cause, words: words)
            } else if !cancelled {
                oweRecoveryRepair(momentID, cause: words, door: momentDoor)
            }
            let failure = AfterTurnMemoryFailure(reason: cancelled ? .cancelled : .provider,
                recovery: words,
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
            personName: fromReply ? "NativeAgent" : speaker ?? originalHumanName,
            standingAgent: standingAgent, appAuthored: fromReply, took: origin?.took,
            occurredAt: origin?.occurredAt,
            personWords: personWords, openMoments: openMoments, completedActs: completedActs,
            completedActsUnavailable: completedActsUnavailable, replyDelivered: replyDelivered, settlesOnly: settlement
        )
        let interpretation: AfterTurnInterpretation?
        let attemptBasis = await beforeJudgment(.provider)
        do {
            // A moment already judged (`meant`) folds with its recorded meaning: the model is not asked again.
            if let storedMeaning { interpretation = storedMeaning } else {
                guard let memoryManager else {
                    let words = "The memory judgment owner is unavailable."
                    oweRecoveryRepair(momentID, cause: words, door: momentDoor)
                    return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [], semanticStatus: .failed,
                        failure: AfterTurnMemoryFailure(reason: .provider, recovery: words, model: nil, surface: surface)))
                }
                let judged = try await memoryManager.interpret(request, context: context,
                    factsEnabled: factsEnabled && factsReadable,
                    call: LLMCall(turn: turn, surface: surface, purpose: held ? "memory_held" : "memory_interpret"))
                if judged != nil { await answered(momentID, route: attemptBasis?.route, door: momentDoor) }
                interpretation = judged.map { MemoryManagerLane.resolvingTargets($0, request: request) }
            }
        } catch {
            // The row stays owed; a failed judgment changes nothing.
            let reason: AfterTurnMemoryFailure.Reason
            if Self.isCancellation(error) { reason = .cancelled }
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
            if reason != .cancelled {
                await waitForChange(momentID, since: attemptBasis, cause: .provider, words: failure.localizedDescription)
            }
            return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [],
                semanticStatus: failure.reason == .deadline ? .timedOut : .failed, failure: failure))
        }
        // Persist meaning before folding; an unwritten judgment remains held for its journal repair.
        if storedMeaning == nil, let interpretation {
            let recorded = await settle {
                guard let meaning = Self.encodedMeaning(interpretation) else { return false }
                return await momentDoor.meant(momentID, meaning)
            }
            guard recorded else {
                do {
                    var saved = try checkpoint(moment)
                    saved.judgment = interpretation
                    saved.wait = nil
                    try await keepCheckpoint(momentID, saved, door: momentDoor)
                } catch { oweRecoveryRepair(momentID, cause: error.localizedDescription, door: momentDoor) }
                let failure = AfterTurnMemoryFailure(reason: .provider,
                    recovery: "The journal could not record this interpretation; its retained judgment retries on the next drain without a model call.",
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
            if !Task.isCancelled {
                await waitForChange(momentID, since: attemptBasis, cause: .provider,
                                    words: "The judgment returned no usable section.")
            }
            let failure = AfterTurnMemoryFailure(reason: Task.isCancelled ? .cancelled : .missingSections,
                recovery: "Check the selected memory model in Settings; the turn stays owed and is judged again after its next successful answer.",
                model: nil, surface: surface)
            return AdaptiveMemoryObservation(proposals: [], extraction: .init(candidates: [],
                semanticStatus: .failed, failure: failure))
        }
        let promisesSettled: Bool
        switch await applyPromises(interpretation, turn: moment.input?.turn,
                                   momentID: momentID, dataRoot: momentDoor.dataRoot, heldTurn: turn) {
        case .success: promisesSettled = true
        case .failure: promisesSettled = false
        }
        var factsProcessed = false
        if factsEnabled, factsReadable {
            do { factsProcessed = try await promotionPolicyEnabled() }
            catch { return await unavailablePromotionPolicy(error, surface: surface, momentID: momentID, basis: nil) }
        }
        let decisions = factsProcessed ? interpretation.memories : []
        var staged: [ProposalRecord] = []
        var accepted: [AdaptiveCandidate] = []
        var rejected = 0
        var savedCorrections = 0
        var pendingCorrections = 0
        var failedCorrections = 0
        var stagingFailed = false
        // Screen against kept, pending and same-pass facts so staging cannot introduce repeats.
        var comparisons = existing.map(\.content) + pending
        // Each fact's (life, moment, ordinal) is committed in its proposal metadata. Refolding continues pending acceptance, skips resolved rows and stages
        // missing ones.
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
                // Resolve exact targets before saving meaning; recovery uses their identity and reviewed fingerprint even outside the current recall prefix.
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
            guard decision.grounding != nil else {
                stagingFailed = true
                nativeLog("MemoryV2: decision in moment %@ has no attributed grounding; left meant", momentID)
                continue
            }
            let isCorrection = decision.kind == "correction"
            if let prior = priorOps[operation] {
                // An accepted successor still needs pending-target retirement; recovery must finish both steps.
                guard await finishPendingSupersession(supersededPending, by: prior.id, memory: memory) else {
                    stagingFailed = true
                    continue
                }
                let keepsIt = fromReply
                    ? MemoryManagerLane.statementRejectionReason(decision, userMessage: "", assistantMessage: assistant) == nil
                    : incoming.trusted && (!isCorrection || incoming.key == CognitiveCare.ownerKey)
                if prior.status == "pending", keepsIt {
                    do {
                        _ = try await memory.acceptProposal(id: prior.id, context: MemoryWriteContext(turn: turn, senseReads: senseReads, telling: nil))
                        accepted.append(AdaptiveCandidate(content: decision.statement, score: decision.confidence,
                                                          kind: decision.kind))
                        if isCorrection { savedCorrections += 1 }
                    } catch {
                        nativeLog("MemoryV2: fact \(prior.id) left for the agent's review, not kept: \(error)")
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
            let refusal = isCorrection
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
                // Keep the repeat's full turn identity in the canonical write; the bounded provenance preview is only presentation.
                do {
                    try await memory.repeatCorrection(id: kept.id, source: "standing-correction:\(sessionId)",
                        turnMetadata: MemoryDataProvenance.turnMetadata(turnId: turnId, origin: origin),
                        context: MemoryWriteContext(turn: turn, senseReads: senseReads, telling: told(fromReply: decision.grounding?.source == .reply)))
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
                    ? MemoryManagerLane.statementRejectionReason(decision, userMessage: "", assistantMessage: assistant) == nil
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
                    ).merging(MemoryDataProvenance.turnMetadata(turnId: turnId, origin: origin)) { current, _ in current }
                        .merging(MemoryDataProvenance.sourceMetadata(sessionId: origin?.sessionId ?? sessionId,
                            messageId: origin?.messageId, turnId: turnId, at: origin?.occurredAt ?? Date(),
                            speaker: decision.grounding?.source == .reply ? "self" : incoming.key,
                            words: decision.grounding?.evidence)) { current, _ in current }
                        .merging([Self.momentOperationKey: .string(operation)]) { current, _ in current },
                    context: MemoryWriteContext(turn: turn, senseReads: senseReads, telling: told(fromReply: decision.grounding?.source == .reply))
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
                // Use review's quality, tombstone and supersession gates for trusted facts; refusals stay for review.
                var kept = false
                if keep {
                    do {
                        _ = try await memory.acceptProposal(id: proposal.id, context: MemoryWriteContext(turn: turn, senseReads: senseReads, telling: nil))
                        kept = true
                    } catch {
                        nativeLog("MemoryV2: fact \(proposal.id) left for the agent's review, not kept: \(error)")
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
        // Mark lived only after the fold, promises and facts settle. Refolding skips landed pieces by stamp and facts by operation identity.
        let factsSettled = factsProcessed ? !stagingFailed : !(factsEnabled && !factsReadable)
        if folded, factsSettled, promisesSettled, !Task.isCancelled { await momentDoor.lived(momentID) }
        return AdaptiveMemoryObservation(
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
            stagingFailed: stagingFailed || !factsReadable || !promisesSettled
        )
    }
    /// The same final step for a fresh proposal and a recovered operation. A different successor is a conflict, never proof that our step landed.
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
    /// First duplicate by the store's own embedder and recall comparison law. Embedding failure throws; an unperformed check never means no duplicate.
    static func nearDuplicate(
        _ statement: String,
        of others: [String],
        memory: SwiftNativeMemoryV2
    ) async throws -> Int? {
        guard !others.isEmpty else { return nil }
        let fold: (String) -> String = { MemoryDataProvenance.wordFold($0) }
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
    /// Recorded provenance identifies the speaker and owner-backed authority. Session attestation precedes bridge headers, so a headerless attested peer still
    /// speaks as that peer.
    static func incomingSpeaker(isPeer: Bool, speaker: String?, sessionId: String, dataRoot: URL = defaultDataRoot()) -> (key: String, trusted: Bool) {
        // The row's own attestation decides who spoke: the owner typing into a conversation an agent started is still the owner.
        guard isPeer else { return (CognitiveCare.ownerKey, true) }
        let door = CognitiveSubstrate.peerIdentity(metadata: ["sessionId": .string(sessionId)], dataRoot: dataRoot)
        let key = PeerDataTaint.principal(door ?? speaker ?? "another agent")
        return (key, PeerDataTaint.ownerTrusts(key))
    }
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
