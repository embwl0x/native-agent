import Transcripts
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Ingest.swift` | `CognitiveSubstrate`: `ingest`, `ingestResident`, `reconsolidateCompletion` |

extension CognitiveSubstrate {
    /// The full redacted reply length and tail let Sound inspect text beyond
    /// the bounded event summary without retaining another complete reply.
    public static let replyCharacterCountMetadataKey = "replyCharacterCount"
    public static let replyTailMetadataKey = "replyTail"

    public func ingest(_ event: CognitiveEvent) async {
        _ = await ingest(event, defersPersistenceToMicrocycle: false)
    }

    /// Resident hot-path admission. Canonical in-memory state and the published
    /// attention projection advance with semantic metadata before this returns; the
    /// dirty microcycle persists the coalesced latest state. Direct library
    /// callers retain `ingest(_:)`'s synchronous durability contract.
    @discardableResult
    public func ingestResident(_ event: CognitiveEvent) async -> (accepted: Bool, semanticMetadata: [String: JSONValue]) {
        await ingest(event, defersPersistenceToMicrocycle: true)
    }

    private func ingest(
        _ event: CognitiveEvent,
        defersPersistenceToMicrocycle: Bool
    ) async -> (accepted: Bool, semanticMetadata: [String: JSONValue]) {
        guard configuration.enabled, !field.hasSeenEvent(event) else { return (false, [:]) }
        let aboutness = event.kind == .organismResolutionFelt
            ? "\(event.summary) \(event.subject.id) \(event.subject.label ?? "")"
            : event.summary
        let touchedCares = event.turnKind.contributesToLivedState
            ? await appraisalCares(in: aboutness) : []
        // Only a caller that commits inline must not interleave with the
        // maintenance commit. Resident admission marks the state dirty, which
        // tells a suspended maintenance pass not to revert over it, and the
        // microcycle persists it after maintenance ends.
        if !(defersPersistenceToMicrocycle && configuration.backgroundMicrocyclesEnabled) {
            await waitForMaintenanceTransition()
        }
        guard configuration.enabled else { return (false, [:]) }
        // Felt resolutions without personal stakes are rejected before any state changes.
        guard feltResolutionIsAtStake(event, cares: touchedCares) else { return (false, [:]) }
        // A duplicate CognitiveEvent is inert across the WHOLE cognition owner,
        // not merely ContinuityField structure. This await-free O(1) check keeps
        // affect, mood, relational-presence anchors, pending completion, revision,
        // attention publication, and persistence untouched on replay.
        guard !field.hasSeenEvent(event) else { return (false, [:]) }
        let now = dependencies.now()
        if event.kind == .assistantTurnCompleted || event.kind == .providerFailure,
           let run = event.metadata["runId"], case .string = run {
            for index in deferredTurns.indices where deferredTurns[index].event.metadata["runId"] == run {
                deferredTurns[index].endedAt = event.occurredAt
            }
            // Keep each live turn's input until journal recording releases it.
            var excess = max(0, deferredTurns.filter { $0.endedAt != nil }.count - 32)
            deferredTurns.removeAll { record in
                guard excess > 0, record.endedAt != nil else { return false }
                excess -= 1
                return true
            }
        }
        // One deterministic scan bundle per admitted user turn. This stays
        // inside the actor's await-free transition and owns no state: it only
        // prevents affect, semantic appraisal, and retrospective landing from
        // rescanning the same already-loaded text and cares.
        let buildsAffectBundle = configuration.enabled
            && event.turnKind.contributesToLivedState
        let defersInterpretation = buildsAffectBundle && Self.isUserAuthored(event.kind)
            && event.sessionId != nil && !SessionConversation.isHelper(event.sessionId, dataRoot: conversationDataRoot, includingArchived: true)
        let userAppraisal = AffectAppraisal()
        // Semantic relationship stake reads warmth for every lived event;
        // affect consumes it only for user turns. A peer carries half User's reach.
        let turnWarmthBoost = !defersInterpretation && (buildsAffectBundle || event.kind == .userMessageReceived)
            ? relationalWarmthBoost(
                for: event,
                precomputed: relationalWarmthBoost(in: event.summary)
              )
            : 0
        let evicted = evictSpentVerificationNodes(before: event, at: now)
        let ingestOutcome = field.ingest(
            event,
            now: now,
            makeUUID: dependencies.makeUUID,
            configuration: configuration
        )
        if event.turnKind == .verification {
            verificationNodeMayExist = true
        }
        markDirty(at: now)
        if defersInterpretation, !deferredTurns.contains(where: { $0.event.subject == event.subject }) {
            deferredTurns.append(CognitiveDeferredTurnRecord(
                event: event, caring: caringEventCandidate(for: event),
                completionNodeKey: pendingCompletion?.nodeKey, completionRecordedAt: pendingCompletion?.recordedAt,
                completionSessionId: pendingCompletion?.sessionId,
                outcomeKey: ingestOutcome?.key,
                mindEpoch: mindEpoch, bodyEpoch: bodyEpoch))
            pendingCompletion = nil
        }
        noteTurnForContext(event)
        let contributesToLivedState = event.turnKind.contributesToLivedState
        // Accepted live completions advance cadence even when no cue was emitted.
        // Commits preserve these counters across a suspended frozen render.
        if contributesToLivedState, event.kind == .assistantTurnCompleted {
            capsulePresentationState.soundRutTurnsSinceSurfaced = min(capsulePresentationState.soundRutTurnsSinceSurfaced + 1, Self.soundRutTurnCounterCap)
            // The reminded-of cadence counts the same boundary for the same
            // reason: it is the one accepted-turn tick the substrate owns.
            capsulePresentationState.remindedOfTurnsSinceSurfaced = min(
                capsulePresentationState.remindedOfTurnsSinceSurfaced + 1, Self.soundRutTurnCounterCap)
            // The tick is durable state: a restart must not restore the rut
            // counter one turn behind. Written with this ingest's persistence
            // (below, or the resident microcycle's transaction).
            capsulePresentationDirty = true
        }
        if contributesToLivedState, event.kind == .userMessageReceived {
            lastUserPresenceAt = now
            // Anchor the ambient warmth floor to genuinely warm moments only, so a pure-work
            // session followed by absence never manufactures affect-warmth (it stays content-driven).
            if turnWarmthBoost > 0 { lastWarmPresenceAt = now }
        }
        // Affect application and emotional-tag stamping share one await-free segment before persistence.
        let updatedAffect = contributesToLivedState && !defersInterpretation
            ? applyAffectFromEvent(
                event,
                precomputedAppraisal: userAppraisal,
                precomputedWarmthBoost: turnWarmthBoost
            )
            : affect
        // Stamp the feeling produced by this event only when affect is enabled.
        if contributesToLivedState, configuration.enabled, let ingestOutcome {
            // Appraise the event's meaning (pure, no suspension — stays inside
            // this await-free segment) so the stamped feeling is about what happened,
            // not the fact that something happened.
            // Semantic appraisal and emotion tagging share the admitted appraisal.
            let semantic = semanticAppraisal(
                for: event,
                post: updatedAffect,
                precomputedAppraisal: userAppraisal,
                precomputedWarmthBoost: turnWarmthBoost,
                precomputedCares: touchedCares
            )
            let tag = emotionTag(
                for: event,
                affect: updatedAffect,
                semantic: semantic,
                precomputedAppraisal: userAppraisal
            )
            field.stampEmotionTag(
                key: ingestOutcome.key,
                tag: tag,
                isNewNode: ingestOutcome.isNewNode,
                configuration: configuration
            )
        }
        // Completion matching, node reconsolidation and resident-slot updates
        // share this await-free admission transition.
        var semanticMetadata: [String: JSONValue] = [:]
        if contributesToLivedState && configuration.enabled && !defersInterpretation {
            semanticMetadata = Self.foldReaction(event: event, completion: pendingCompletion,
                outcome: ingestOutcome, now: now, valence: userAppraisal.valence)
            if let pending = pendingCompletion {
                let age = now.timeIntervalSince(pending.recordedAt)
                let expired = age < 0 || age > Self.pendingCompletionMaxAge
                let switchedSession = event.sessionId != nil && event.sessionId != pending.sessionId
                if expired || switchedSession || !semanticMetadata.isEmpty { pendingCompletion = nil }
                if !semanticMetadata.isEmpty {
                    reconsolidateCompletion(pending, outcome: ingestOutcome, now: now,
                                            reaction: userAppraisal.valence)
                }
            }
            if event.kind == .assistantTurnCompleted, let outcome = ingestOutcome {
                pendingCompletion = PendingCompletion(nodeKey: outcome.key, recordedAt: now,
                                                      sessionId: event.sessionId)
                if let matchedCareID = touchedCares.first?.id, let care = cares[matchedCareID], care.fadedAt == nil,
                   let session = event.sessionId, !outcome.key.isEmpty {
                    semanticMetadata[OrganismSemanticExpectation.mintMetadataKey] = .object([
                        OrganismSemanticExpectation.concernField: .string("care:" + care.id.uuidString),
                        OrganismSemanticExpectation.sessionField: .string(session),
                        OrganismSemanticExpectation.turnField: .string(outcome.key),
                    ])
                }
            }
        }
        // Publish before persistence awaits. The owner transition is already
        // internally consistent, and a slow SQLite write must not delay the
        // resident attention available to the next turn.
        publishAttentionProjection(at: now)
        if defersPersistenceToMicrocycle, configuration.backgroundMicrocyclesEnabled {
            // Verification evictions are rare and their receipt is diagnostic;
            // keep it off the sensory admission path without losing the fact.
            if evicted > 0, configuration.persistenceEnabled {
                let sessionId = event.sessionId
                Task { [weak self] in
                    await self?.recordReceipt(
                        kind: "workspace.verification_eviction",
                        payload: .object([
                            "evictedCount": .int(Int64(evicted)),
                            "sessionId": sessionId.map(JSONValue.string) ?? .null,
                        ])
                    )
                }
            }
            return (true, semanticMetadata)
        }
        if configuration.persistenceEnabled {
            await notingPersistence("snapshot") { try await persistAffectAndNodes() }
            if evicted > 0 {
                await recordReceipt(kind: "workspace.verification_eviction", payload: .object([
                    "evictedCount": .int(Int64(evicted)),
                    "sessionId": event.sessionId.map(JSONValue.string) ?? .null,
                ]))
            }
            await flushCapsulePresentationIfNeeded(at: now)
        }
        return (true, semanticMetadata)
    }

    // MARK: - Affect dynamics

    /// A matched reaction changes only its completion node, never the resident slot.
    func reconsolidateCompletion(
        _ completion: PendingCompletion,
        outcome: ContinuityField.IngestOutcome?,
        now: Date,
        reaction: Double
    ) {
        // A user turn sharing its completion's field key has already stamped
        // that node; blending its own reaction would count the feeling twice.
        guard outcome?.key != completion.nodeKey else { return }
        if let landedNode = field.node(forKey: completion.nodeKey) {
            stampLandingScore(Self.landingScore(fromReactionValence: reaction),
                              forNodeId: landedNode.id, at: now)
        }
        if reaction != 0, let current = field.storedEmotionTag(forKey: completion.nodeKey) {
            field.stampEmotionTag(
                key: completion.nodeKey,
                tag: (valence: (current.valence + reaction).clampedSigned(),
                      arousal: current.arousal, warmth: current.warmth),
                isNewNode: false,
                configuration: configuration
            )
        }
    }
}
