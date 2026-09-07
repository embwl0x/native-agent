import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    public func ingest(_ event: CognitiveEvent) async {
        _ = await ingest(event, defersPersistenceToMicrocycle: false)
    }

    /// Resident hot-path admission. Canonical in-memory state and the published
    /// attention projection advance before this returns; the already-existing
    /// dirty microcycle persists the coalesced latest state. Direct library
    /// callers retain `ingest(_:)`'s synchronous durability contract.
    @discardableResult
    public func ingestResident(_ event: CognitiveEvent) async -> Bool {
        await ingest(event, defersPersistenceToMicrocycle: true)
    }

    private func ingest(
        _ event: CognitiveEvent,
        defersPersistenceToMicrocycle: Bool
    ) async -> Bool {
        await waitForMaintenanceTransition()
        guard configuration.enabled else { return false }
        // D-2 (2026-08-02) — STAKES, not event class. A felt resolution about
        // machinery she holds no concern for is not a feeling; it is her own
        // plumbing reporting in. Rejected BEFORE any state is touched (no seen
        // key consumed, no node, no affect, no attention publish), so the felt
        // layer gets quieter instead of louder. Gates this one event class only.
        guard feltResolutionIsAtStake(event) else { return false }
        // A duplicate CognitiveEvent is inert across the WHOLE cognition owner,
        // not merely ContinuityField structure. This await-free O(1) check keeps
        // affect, mood, relational-presence anchors, pending completion, revision,
        // attention publication, and persistence untouched on replay.
        guard !field.hasSeenEvent(event) else { return false }
        let now = dependencies.now()
        // One deterministic scan bundle per admitted user turn. This stays
        // inside the actor's await-free transition and owns no state: it only
        // prevents affect, semantic appraisal, and retrospective landing from
        // rescanning the same already-loaded text and standing views.
        let buildsAffectBundle = configuration.affectEnabled
            && event.turnKind.contributesToLivedState
        // Item 8 (2026-09-02) — OTHERS MOVE HER. This used to read
        // `isUserAuthored(event.kind) ? conversationalAppraisal(…) : empty`,
        // which cannot tell User from a bridge peer: both arrive as
        // `.userMessageReceived`, so another agent's words moved her at HIS
        // weight, wearing his subject. `relationalAppraisal` keeps that
        // behaviour exactly for User (and for her own output, which stays at
        // zero — Law 3) and lands a peer at half weight with its own subject.
        // Still the single pure scan per admitted event: it is threaded into
        // semanticAppraisal, emotionTag, applyAffectFromEvent and
        // reconsolidatePendingCompletion below, exactly as before.
        // See CognitiveSubstrate+AppraisalConcerns.swift.
        let userAppraisal = buildsAffectBundle
            ? relationalAppraisal(for: event)
            : AffectAppraisal()
        // Semantic relationship stake historically samples this lexical cue
        // for every lived event, while affect consumes it only for user turns.
        // Compute it once without changing either caller's gating.
        // Item 8: the same relational weight applies — warmth from a peer is
        // real warmth, at half the reach of his.
        let turnWarmthBoost = (buildsAffectBundle || event.kind == .userMessageReceived)
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
        let contributesToLivedState = event.turnKind.contributesToLivedState
        // THE ACCEPTED-TURN TICK for the Sound nudge's cadence (2026-09-01).
        // It used to advance inside the capsule render and stick only through
        // `applyCapsulePresentationCommit` — so a turn whose capsule came back
        // EMPTY (`prepareFrozenCapsulePresentation` returns nil, no commit) did
        // not count, and a stretch of those froze the "20 capsules since it
        // last spoke" hatch. A completed live assistant turn is the one
        // accepted-turn boundary the substrate owns by itself, and it happens
        // whether or not any capsule text was emitted. Free-running on purpose:
        // it is deliberately excluded from the presentation-commit equality
        // guard below so an ingest between prepare and commit cannot reject the
        // whole commit.
        if contributesToLivedState, event.kind == .assistantTurnCompleted {
            soundRutTurnsSinceSurfaced = min(soundRutTurnsSinceSurfaced + 1, Self.soundRutTurnCounterCap)
            // The reminded-of cadence counts the same boundary for the same
            // reason: it is the one accepted-turn tick the substrate owns.
            remindedOfTurnsSinceSurfaced = min(
                remindedOfTurnsSinceSurfaced + 1, Self.soundRutTurnCounterCap)
        }
        if contributesToLivedState, event.kind == .userMessageReceived {
            lastUserPresenceAt = now
            // Anchor the ambient warmth floor to genuinely warm moments only, so a pure-work
            // session followed by absence never manufactures affect-warmth (it stays content-driven).
            if turnWarmthBoost > 0 { lastWarmPresenceAt = now }
        }
        // Affect apply + emotional-tag stamp run as ONE await-free actor segment right
        // after field.ingest above, so no reentrant ingest (during a later persistence
        // await) can swap self.affect or evict/recreate the touched node between deriving
        // the tag and stamping it (gpt-5.5 concurrency review, 2026-07-02). applyAffect is
        // synchronous; the affect persistence that updateAffectFromEvent used to do is
        // moved below, after the state is already consistent.
        let updatedAffect = contributesToLivedState
            ? applyAffectFromEvent(
                event,
                precomputedAppraisal: userAppraisal,
                precomputedWarmthBoost: turnWarmthBoost
            )
            : affect
        // Stamp the tag from the affect this event just produced ("how she feels having
        // just experienced it", Wave A). Gated on affect: no affect, no live feeling.
        if contributesToLivedState, configuration.affectEnabled, let ingestOutcome {
            // R2-A/B: appraise the event's MEANING (pure, no suspension — stays inside
            // this await-free segment) so the stamped feeling is about what happened,
            // not the fact that something happened.
            // Compute the conversational appraisal ONCE and thread it through both
            // consumers — semanticAppraisal and emotionTag each used to run the
            // heavy ~10-pass lexicon scan on the identical summary (hot-path dedup).
            // Concerns depend on the post-event affect epoch, so derive them
            // once here after applyAffectFromEvent rather than before it.
            // LEANING, not just signed (2026-09-02): this is a hot-path SKIP,
            // and an empty array here is not "derive them yourself" — it is a
            // precomputed empty set that matches nothing. With held views but
            // no active one, the old test silently deleted her own views from
            // every appraisal.
            let standingViewConcerns = standingViews.values.contains { $0.isLeaning }
                ? appraisalConcerns()
                : []
            let semantic = semanticAppraisal(
                for: event,
                post: updatedAffect,
                precomputedAppraisal: userAppraisal,
                precomputedWarmthBoost: turnWarmthBoost,
                precomputedStandingViewConcerns: standingViewConcerns
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
        // U1: her work comes to feel like how it landed. Runs inside the SAME
        // await-free segment as the stamp above, and for the same reason — the
        // re-stamp reads the remembered node's tag and writes it back, so a
        // reentrant ingest suspending in between could evict/recreate that node
        // or swap the slot underneath us. Pure, synchronous, no suspension.
        if contributesToLivedState, configuration.affectEnabled {
            reconsolidatePendingCompletion(
                with: event,
                outcome: ingestOutcome,
                now: now,
                precomputedAppraisal: userAppraisal
            )
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
            return true
        }
        if contributesToLivedState, configuration.enabled, configuration.affectEnabled {
            await persistArtifact(
                kind: "affect",
                id: stableArtifactID("affect"),
                status: "current",
                score: updatedAffect.arousal,
                payload: updatedAffect.toJSON(
                    lastUserPresenceAt: lastUserPresenceAt,
                    lastWarmPresenceAt: lastWarmPresenceAt
                )
            )
        }
        if configuration.persistenceEnabled {
            if evicted > 0, let store {
                try? await store.appendReceipt(
                    kind: "workspace.verification_eviction",
                    payload: .object([
                        "evictedCount": .int(Int64(evicted)),
                        "sessionId": event.sessionId.map(JSONValue.string) ?? .null,
                    ]),
                    at: now
                )
            }
            try? await persistSnapshot()
        }
        return true
    }

    // MARK: - Affect dynamics

    /// U1 (2026-07-09): the user's reaction becomes how her work FELT.
    ///
    /// Three things happen here, in order, every ingest:
    ///   1. REMOVALS — a slot older than `pendingCompletionMaxAge` (or from a
    ///      session the app has since left) is dropped before anything reads it.
    ///   2. USE — a user-authored turn in the SAME session consumes the slot. Its
    ///      `conversationalAppraisal` valence (audit C3: this appraisal reads USER
    ///      text, which is exactly what a reaction is) shifts the remembered
    ///      completion's stored valence through `stampEmotionTag(isNewNode: false)`
    ///      — the asymmetric reconsolidation blend, which is precisely the
    ///      mechanism for "that turn turned out to have landed well/badly": praise
    ///      lifts it fast, criticism cools it slowly. Arousal and warmth are passed
    ///      back unchanged, so their blends are exact no-ops. A neutral reaction
    ///      (valence 0) consumes the slot and leaves the node untouched.
    ///   3. ADD — an `assistantTurnCompleted` remembers its node as the new slot,
    ///      replacing any older one. The latest completion is the one in the room.
    ///
    /// The incoming valence is `current + reaction`, NOT `reaction` — the blend
    /// moves the node TOWARD its target, so handing it the bare reaction would drag
    /// a strongly-positive node DOWN on praise. The shift is what gets blended.
    ///
    /// A completion whose node was evicted between the two turns simply finds
    /// nothing to re-stamp. A user turn with no session id (out-of-band) neither
    /// consumes nor applies — expiry remains its removal.
    private func reconsolidatePendingCompletion(
        with event: CognitiveEvent,
        outcome: ContinuityField.IngestOutcome?,
        now: Date,
        precomputedAppraisal: AffectAppraisal? = nil
    ) {
        if let pending = pendingCompletion {
            let age = now.timeIntervalSince(pending.recordedAt)
            let expired = age < 0 || age > Self.pendingCompletionMaxAge
            let switchedSession = event.sessionId != nil && event.sessionId != pending.sessionId
            if expired || switchedSession { pendingCompletion = nil }
        }

        // `outcome != nil` means the field ACCEPTED this turn as new. A duplicate
        // (re-observed messageId) must be wholly inert here: without this guard, a
        // user turn replayed after a later completion opened the slot would land its
        // stale reaction on a turn it never saw.
        if Self.isUserAuthored(event.kind), outcome != nil,
           let pending = pendingCompletion,
           // Non-nil session REQUIRED on both sides (gpt-5.5 review MED, 2026-07-09):
           // optional equality made nil == nil read as "same session", so two
           // unrelated session-less events could pair a reaction to a completion
           // it never saw. No session, no reaction linkage.
           let eventSession = event.sessionId,
           let pendingSession = pending.sessionId,
           eventSession == pendingSession {
            pendingCompletion = nil
            let reaction = (precomputedAppraisal ?? conversationalAppraisal(in: event.summary)).valence
            // Item 46 fix (1): the ONLY moment this pairing is visible. Stash it
            // for the after-ingest metadata hop before the slot is gone. Same
            // appraisal, same read, no second lexicon pass.
            lastSemanticReaction = SemanticReactionStash(
                sessionID: eventSession,
                turnID: pending.nodeKey,
                reaction: Self.semanticReactionLabel(fromValence: reaction),
                recordedAt: now
            )
            // A turn cannot be the reaction to ITSELF. Both kinds map to the
            // .conversationFocus node kind, so the two turns share a field key unless
            // the subjects differ per-turn (which ChatOrchestration mints — audit C2).
            // If a caller ever reverts to per-session subjects, the user turn's own
            // stamp already landed on this node and re-stamping would blend it twice.
            let reactsToItself = outcome?.key == pending.nodeKey
            // W7/P10 — the same reaction, read a second way. The emotion blend
            // below asks "how did that turn FEEL in hindsight"; this asks "did
            // that phrasing LAND", and the echo's ranking is the only consumer.
            // Same appraisal, same classes, NO new lexicon — praise / enthusiasm
            // / resolution / affection carry positive valence, dismissal and
            // criticism carry negative, everything else is exactly zero and
            // stamps nothing.
            if !reactsToItself, let landedNode = field.node(forKey: pending.nodeKey) {
                stampLandingScore(
                    Self.landingScore(fromReactionValence: reaction),
                    forNodeId: landedNode.id,
                    at: now)
            }
            if reaction != 0, !reactsToItself, let current = field.storedEmotionTag(forKey: pending.nodeKey) {
                field.stampEmotionTag(
                    key: pending.nodeKey,
                    tag: (
                        valence: Self.clampSigned(current.valence + reaction),
                        arousal: current.arousal,
                        warmth: current.warmth
                    ),
                    isNewNode: false,
                    configuration: configuration
                )
            }
        }

        if event.kind == .assistantTurnCompleted, let outcome {
            pendingCompletion = PendingCompletion(
                nodeKey: outcome.key,
                recordedAt: now,
                sessionId: event.sessionId
            )
            // W7/P6 — TELEMETRY ONLY. The completion is the first moment the
            // ACTUAL reply length exists, so this is where the envelope stashed
            // at capsule compile gets paired with what really happened. It
            // records the paired row in memory and returns; nothing here reads
            // the envelope back into the turn, and no flag exists that could.
            let replyCharacters: Int = {
                if case .int(let value)? = event.metadata[
                    Self.replyCharacterCountMetadataKey
                ], value >= 0 {
                    return Int(clamping: value)
                }
                // Backward-compatible fallback for direct library callers and
                // older persisted events that predate the count metadata.
                return event.summary.count
            }()
            consumeDeliveryEnvelopeTelemetry(
                replyCharacters: replyCharacters,
                sessionId: event.sessionId,
                at: now
            )
        }
    }
}
