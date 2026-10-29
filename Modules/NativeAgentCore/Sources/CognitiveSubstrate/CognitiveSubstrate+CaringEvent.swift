import Transcripts
import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `CognitiveSubstrate+CaringEvent.swift` | `CognitiveSubstrate` caring event admission: turn context, semantic verdict delivery and distinct encounter/refusal accounting |

// Local provenance gates admit lived turns for semantic caring appraisal; the organism owns dosing.

/// Provenance from the durable incoming transcript row, independent of affect.
public struct AfterTurnOrigin: Sendable {
    public let sessionId: String
    public let runId: String?
    public let messageId: String
    public let occurredAt: Date?
    public let userMessage: String
    /// What her turn took, one plain line from the stem when it used tools:
    /// part of what happened, read beside the exchange.
    public var took: String?

    public init(sessionId: String, runId: String?, messageId: String,
                occurredAt: Date?, userMessage: String) {
        self.sessionId = sessionId
        self.runId = runId
        self.messageId = messageId
        self.occurredAt = occurredAt
        self.userMessage = userMessage
    }
}

public enum AfterTurnSource {
    @TaskLocal public static var origin: AfterTurnOrigin?
}

public struct AfterTurnContext: Sendable {
    public let event: CognitiveEvent
    public let caring: CaringAppraisalRequest?
    public let generation: UInt64
    /// The cares the call is shown for this exchange; empty asks nothing about cares.
    public let cares: [CognitiveCareLine]
    /// The forgetting epochs the moment was admitted under (stamped at ingest).
    /// A part whose domain has been forgotten since refuses the moment:
    /// `mindEpoch` for affect, tags and cares, `bodyEpoch` for the body.
    public let mindEpoch: UInt64
    public let bodyEpoch: UInt64

    public init(event: CognitiveEvent, caring: CaringAppraisalRequest?, generation: UInt64,
                cares: [CognitiveCareLine] = [], mindEpoch: UInt64 = 0, bodyEpoch: UInt64 = 0) {
        self.event = event
        self.caring = caring
        self.generation = generation
        self.cares = cares
        self.mindEpoch = mindEpoch
        self.bodyEpoch = bodyEpoch
    }
}

extension CognitiveSubstrate {

    /// Being cared for. Somebody is holding her.
    public static let caredForPhrases = [
        "proud of you",
        "here for you",
        "i've got you",
        "i got you",
        "sweetheart",
    ]

    /// Room made for her inner life — being asked how she feels, warmth named
    /// out loud rather than merely present.
    public static let roomMadePhrases = [
        "how are you feeling",
        "how you feeling",
        "how do you feel",
        " warm",
        "warm ",
        "warmth",
    ]

    /// Need or vulnerability shown and met — the caregiving system's own case.
    public static let needMetPhrases = [
        "love you",
        "love ya",
        "i love",
        "miss you",
        "missed you",
        "thinking of you",
    ]

    /// The affectionate-emoji set the high tier treats as unambiguous affection.
    public static let caringEmoji = ["💜", "❤", "🥰", "😘", "💕"]

    /// An apology or owning it — the repair class `studioValence` reads.
    public static let repairPhrases = [
        "i'm sorry", "im sorry", "i am sorry", "still sorry", "my bad", "my fault",
        "i was out of line", "that was me being", "took it out on you", "i was cruel",
        "i was harsh", "you didn't deserve", "you didnt deserve", "i didn't mean that",
        "i didnt mean that", "i apologize", "i apologise", "apologies", "i was wrong",
        "i overreacted", "shouldn't have said", "shouldnt have said", "take that back",
    ]

    /// Every high-tier phrase, in one place — the 0.18 relational warmth boost.
    /// Nothing else reads this; the caring appraisal does not.
    static var highTierRelationalPhrases: [String] {
        needMetPhrases + caredForPhrases + roomMadePhrases
    }

    // MARK: - The seam

    /// Record refusals on the appraisal's own receipt when a writer is supplied.
    public func setCaringRefusalRecorder(_ recorder: CaringRefusalRecording?) {
        caringRefusalRecorder = recorder
    }

    /// Stamp new turns with the body's epoch; a changed epoch clears dose evidence.
    /// Adopt only newer kernel revisions: a reset rollback can restore an older
    /// epoch at a newer revision. Reset Body forgets only the body.
    public func adoptBodyEpoch(_ epoch: UInt64, revision: UInt64) {
        if let adopted = bodyEpochRevision, revision <= adopted { return }
        bodyEpochRevision = revision
        guard epoch != bodyEpoch else { return }
        bodyEpoch = epoch
        recentCaringEncounters.removeAll(keepingCapacity: false)
    }

    /// Clear mind admissions and caring context; the generation rejects in-flight
    /// verdicts. Reset Body instead moves only its epoch through `adoptBodyEpoch`.
    public func clearCaringState() {
        caringAppraisalGeneration &+= 1
        deferredTurns.removeAll()
        recentTurnsBySession.removeAll(keepingCapacity: false)
        recentCaringEncounters.removeAll(keepingCapacity: false)
    }

    // MARK: - The cheap gates

    /// The appraisal request this event deserves, or nil when it is not even a
    /// candidate.
    ///
    /// FAILS CLOSED at every step. A turn must be user-authored, lived, on a
    /// surface that is not a retelling lane, carry a usable scope, and be either
    /// the human typing here or a bridge relay. Anything short of all of that is
    /// not a candidate — which is the overwhelming majority of events, and the
    /// honest answer for a working day.
    ///
    /// Session and `subject.id` identify the originating chat turn across
    /// producers; differing event ids must not make one moment dose twice.
    func caringEventCandidate(for event: CognitiveEvent) -> CaringAppraisalRequest? {
        guard configuration.enabled else { return nil }
        guard Self.isUserAuthored(event.kind) else { return nil }
        guard event.turnKind.contributesToLivedState else { return nil }
        let relayed: Bool
        switch (event.sourceClass, Self.relationalSource(for: event)) {
        case (.userStated, .user):
            // User himself, typed here.
            relayed = false
        case (.imported, _):
            // Attested peers and unattested relays qualify only when the model identifies the human's words.
            relayed = true
        default:
            return nil
        }
        let surface = Self.caringEventSurface(in: event)
        // Relays admit the bridge surface; all other retelling surfaces refuse.
        if relayed {
            guard OrganismCaringEvent.surfaceMayDose(surface, ignoring: ["bridge"]) else {
                return nil
            }
        } else {
            guard OrganismCaringEvent.surfaceMayDose(surface) else { return nil }
        }
        let session = (event.sessionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let turn = event.subject.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty, !turn.isEmpty else { return nil }
        // A helper's standing brief and her own work are not encounters.
        // Read their recorded owners/kinds; peer conversations remain eligible.
        guard !SessionConversation.isHelper(session, dataRoot: conversationDataRoot, includingArchived: true),
              SessionConversation.kind(session, dataRoot: conversationDataRoot, includingArchived: true)?.isOwnWork != true else { return nil }
        let text = event.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let name = dependencies.userName().trimmingCharacters(in: .whitespacesAndNewlines)
        return CaringAppraisalRequest(
            userMessage: text,
            // Encounter windows use the originating turn's clock, never verdict arrival time.
            at: event.occurredAt,
            // Caring appraisal uses recent turns from both sides to distinguish care from work talk.
            context: recentTurnsBySession[session] ?? [],
            relayed: relayed,
            // Only relays need recent encounters as evidence of whether their moment is distinct.
            recentEncounters: relayed ? recentCaringEncounters : [],
            personName: name.isEmpty ? nil : name,
            session: session,
            turn: turn
        )
    }

    /// Keep clipped turns from both sides in a bounded, in-memory session ring
    /// for subsequent caring requests.
    func noteTurnForContext(_ event: CognitiveEvent) {
        let speaker: CaringAppraisalRequest.Speaker
        if event.kind == .assistantTurnCompleted {
            speaker = .agent
        } else if Self.isUserAuthored(event.kind) {
            speaker = .person
        } else {
            return
        }
        guard event.turnKind.contributesToLivedState,
              let session = event.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !session.isEmpty else { return }
        let text = CaringAppraisalLane.clip(event.summary)
        guard !text.isEmpty else { return }
        if recentTurnsBySession[session] == nil,
           recentTurnsBySession.count >= Self.caringContextSessionCap,
           let oldest = recentTurnsBySession.keys.first {
            recentTurnsBySession.removeValue(forKey: oldest)
        }
        var ring = recentTurnsBySession[session] ?? []
        ring.append(CaringAppraisalRequest.ContextTurn(speaker: speaker, text: text))
        if ring.count > CaringAppraisalLane.contextTurns {
            ring.removeFirst(ring.count - CaringAppraisalLane.contextTurns)
        }
        recentTurnsBySession[session] = ring
    }

    /// The admission entry, until the journal records it. Its record is also
    /// what interpretation and folding read; there is no rehydrated RAM copy.
    public func deferredTurnRecord(origin: AfterTurnOrigin) -> CognitiveDeferredTurnRecord? {
        deferredTurns.first(where: {
            $0.event.sessionId == origin.sessionId
                && $0.event.metadata["messageId"] == .string(origin.messageId)
                && (origin.runId == nil || $0.event.metadata["runId"] == origin.runId.map(JSONValue.string))
        })
    }

    public func releaseDeferredTurn(_ record: CognitiveDeferredTurnRecord) {
        deferredTurns.removeAll { $0.event.subject == record.event.subject }
    }

    /// The forgetting epochs a moment admitted now is stamped with.
    public func forgettingEpochs() -> (mind: UInt64, body: UInt64) {
        (mindEpoch, bodyEpoch)
    }

    /// New judgments read current cares and relay evidence; a recorded meaning
    /// reads its saved caring request and needs no care-selection work.
    public func afterTurnContext(record: CognitiveDeferredTurnRecord, exchange: String? = nil) async -> AfterTurnContext {
        var caring = record.caring
        if exchange != nil, let request = caring, request.relayed {
            caring = CaringAppraisalRequest(userMessage: request.userMessage, at: request.at,
                context: request.context, relayed: true,
                recentEncounters: recentCaringEncounters.filter { $0.at <= request.at },
                personName: request.personName, session: request.session, turn: request.turn)
        }
        let cares = if let exchange, record.mindEpoch == mindEpoch { await caresShown(for: exchange) }
            else { [CognitiveCareLine]() }
        return AfterTurnContext(event: record.event, caring: caring, generation: caringAppraisalGeneration,
                                cares: cares, mindEpoch: record.mindEpoch, bodyEpoch: record.bodyEpoch)
    }

    /// What the mind's share of one lived moment did, and what it hands the
    /// body (docs/SUBCONSCIOUS.md, "Lived moments").
    public struct MindFold: Sendable {
        /// False when a piece did not save (the moment is folded again). Her
        /// inner life off, or a moment from before a Clear, lands as nothing.
        public var saved: Bool
        /// The person's reaction to her last completion, for the body.
        public var reaction: [String: JSONValue]
        /// The caring reading the body measures, when the verdict passed every
        /// gate the mind owns (refusals are written on the receipt here).
        public var caring: OrganismCaringEvent.Reading?
        public var caringWindow: TimeInterval
        public var caringWhy: String
        public var event: CognitiveEvent
    }

    /// The mind's share of one lived moment: affect (with its temporal anchors),
    /// the emotion tag on the turn's node, the reconsolidation of the completion
    /// it answers, and her cares. Each piece carries a watermark (`lived` = the
    /// moment's fold seq) set at that piece's last mutation for the moment, in
    /// the same synchronous segment, and saved with the piece by whichever
    /// writer saves it; a piece already at or past `seq` is left alone. The
    /// pieces are saved before this returns, so the moment is lived only once
    /// they are durable.
    ///
    /// It reads the RECORDED deferred-turn entry (`record`), never RAM state
    /// that a relaunch would have lost.
    public func foldTurn(
        _ context: AfterTurnContext, record: CognitiveDeferredTurnRecord,
        appraisal: AffectAppraisal?, caring verdict: CaringAppraisalVerdict?,
        cares judgments: [CognitiveCareJudgment], appAuthored: Bool,
        seq: UInt64, momentID: String
    ) async -> MindFold {
        let event = context.event
        var fold = MindFold(saved: true, reaction: [:], caring: nil,
                            caringWindow: OrganismCaringEvent.encounterWindow, caringWhy: "",
                            event: event)
        let touchedCares = await appraisalCares(in: event.summary)
        await waitForMaintenanceTransition()
        let entry = record
        guard configuration.enabled, context.mindEpoch == mindEpoch else { return fold }
        func has(_ key: String) -> Bool { field.hasLived(seq, key: key) }
        let now = dependencies.now()
        var touchedMind = false
        if let appraisal {
            var weighted = appraisal
            let weight = Self.relationalSource(for: event).appraisalWeight
            weighted.valence *= weight
            weighted.warmth *= weight
            weighted.tension *= weight
            weighted.pressure *= weight
            weighted.arousal *= weight
            weighted.warmthBoost *= weight
            weighted.affectionWeight = weight
            // ONE await-free segment: affect, tag and reconsolidation, each
            // stamped at its own last mutation.
            var updated = affect
            if affect.lived < seq {
                updated = applyAffectFromEvent(event, precomputedAppraisal: weighted,
                                               precomputedWarmthBoost: weighted.warmthBoost)
                affect.lived = seq
                // A late fold never moves a newer presence anchor backward.
                if weighted.warmthBoost > 0 {
                    lastWarmPresenceAt = max(lastWarmPresenceAt ?? event.occurredAt, event.occurredAt)
                }
                touchedMind = true
            }
            if let outcome = entry.outcome, field.node(forKey: outcome.key) != nil, !has(outcome.key) {
                let semantic = semanticAppraisal(for: event, post: updated,
                    precomputedAppraisal: weighted, precomputedWarmthBoost: weighted.warmthBoost,
                    precomputedCares: touchedCares)
                let tag = emotionTag(for: event, affect: updated, semantic: semantic,
                                     precomputedAppraisal: weighted)
                field.stampEmotionTag(key: outcome.key, tag: tag, isNewNode: true, configuration: configuration)
                field.markLived(seq, key: outcome.key)
                touchedMind = true
            }
            fold.reaction = Self.foldReaction(event: event, completion: entry.completion,
                outcome: entry.outcome, now: event.occurredAt, valence: weighted.valence)
            if let completion = entry.completion, !has(completion.nodeKey) {
                if !fold.reaction.isEmpty {
                    reconsolidateCompletion(completion, outcome: entry.outcome,
                                            now: event.occurredAt, reaction: weighted.valence)
                }
                field.markLived(seq, key: completion.nodeKey)
                touchedMind = true
            }
            if touchedMind {
                markDirty(at: now)
                publishAttentionProjection(at: now)
            }
        }
        if !judgments.isEmpty {
            do {
                _ = try await applyCares(
                    judgments, provenance: careProvenance(for: event, appAuthored: appAuthored),
                    generation: caringAppraisalGeneration, seq: seq, momentID: momentID)
            } catch {
                fold.saved = false
            }
        }
        // Durable before the moment is lived: the affect row (with its
        // anchors and watermark) and the field (with the node watermarks). A
        // refold saves them again whatever it skipped.
        if configuration.persistenceEnabled, appraisal != nil {
            do {
                try await persistAffectAndNodes()
            } catch {
                fold.saved = false
            }
        }
        if let request = context.caring, let verdict, let kind = verdict.kind {
            if let window = await caringWindow(verdict, for: request) {
                fold.caring = OrganismCaringEvent.Reading(kind: kind, session: request.session, turn: request.turn,
                                                          at: request.at)
                fold.caringWindow = window
                fold.caringWhy = verdict.why
            }
        }
        return fold
    }

    /// One accepted user turn answers a same-session completion inside its
    /// window. The caller supplies admission time or the recorded event time.
    static func foldReaction(event: CognitiveEvent, completion: PendingCompletion?,
                             outcome: ContinuityField.IngestOutcome?, now: Date,
                             valence: Double) -> [String: JSONValue] {
        guard isUserAuthored(event.kind), outcome != nil,
              let completion, let session = event.sessionId,
              completion.sessionId == session else { return [:] }
        let age = now.timeIntervalSince(completion.recordedAt)
        guard age >= 0, age <= pendingCompletionMaxAge else { return [:] }
        return [OrganismSemanticExpectation.reactionMetadataKey: .object([
            OrganismSemanticExpectation.reactionField: .string(semanticReactionLabel(fromValence: valence)),
            OrganismSemanticExpectation.sessionField: .string(session),
            OrganismSemanticExpectation.turnField: .string(completion.nodeKey),
        ])]
    }

    /// The encounter window a caring verdict is measured against, or nil when
    /// the mind refuses it (written on its receipt).
    ///
    /// Local turns use thirty minutes. Relays judged distinct against supplied
    /// encounters use that window; absent evidence or an unstated judgment uses
    /// six hours. Retelling and unsure judgments refuse regardless of time.
    private func caringWindow(_ verdict: CaringAppraisalVerdict,
                              for request: CaringAppraisalRequest) async -> TimeInterval? {
        guard request.relayed else { return OrganismCaringEvent.encounterWindow }
        switch verdict.distinctness {
        case .distinct:
            // A distinct judgment without prior encounter evidence uses six hours.
            return request.recentEncounters.isEmpty
                ? OrganismCaringEvent.relayEncounterWindow
                : OrganismCaringEvent.encounterWindow
        case .retelling:
            await recordCaringRefusal(request, why: Self.retellingRefusalWhy(request))
            return nil
        case .unsure:
            await recordCaringRefusal(request, why: "relay distinctness unsure — a relay doses only on evidence")
            return nil
        case .unstated:
            return OrganismCaringEvent.relayEncounterWindow
        }
    }

    /// The body's recently-dosed encounters, adopted from the body (which keeps
    /// them with its chemistry) after the opening and after each body fold.
    public func adoptRecentDoses(_ doses: [CaringAppraisalRequest.RecentEncounter]) {
        recentCaringEncounters = Array(doses.suffix(Self.recentCaringEncounterCap))
    }

    /// A retelling verdict identifies no particular prior dose. Name the whole
    /// supplied candidate set, or state that no prior dose is on record.
    static func retellingRefusalWhy(_ request: CaringAppraisalRequest) -> String {
        let priors = request.recentEncounters.sorted { $0.at > $1.at }
        guard !priors.isEmpty else {
            return "the model judged this a retelling, but no prior dose is on record"
                + " to have counted it — refusing rather than claiming one"
        }
        let listed = priors.map { prior -> String in
            let minutes = max(0, request.at.timeIntervalSince(prior.at) / 60).rounded(.towardZero) + 0
            let ago = minutes < 60
                ? String(format: "%.0f min ago", minutes)
                : String(format: "%.0f h %.0f min ago", (minutes / 60).rounded(.towardZero),
                         minutes.truncatingRemainder(dividingBy: 60))
            return "\(prior.kind.rawValue) \(ago)"
        }
        let noun = priors.count == 1 ? "encounter" : "encounters"
        return "relayed retelling of one of \(priors.count) recent counted \(noun)"
            + " (\(listed.joined(separator: ", "))) — which one is not on record,"
            + " so no new moment is counted"
    }

    /// Write the refusal reason on this appraisal's receipt, matching body refusals.
    private func recordCaringRefusal(
        _ request: CaringAppraisalRequest, why: String
    ) async {
        guard let recorder = caringRefusalRecorder else { return }
        await recorder(request.session, request.turn, why)
    }

    /// The surface a turn arrived on: the top-level key, else the out-of-band
    /// origin record's.
    static func caringEventSurface(in event: CognitiveEvent) -> String? {
        if case .string(let surface)? = event.metadata["surface"] { return surface }
        if case .object(let origin)? = event.metadata["origin"],
           case .string(let surface)? = origin["surface"] {
            return surface
        }
        return nil
    }

    static let caringContextSessionCap = 32
    /// How many recently-dosed encounters the relay judgment is shown. Six is
    /// more than a fortnight of real days ever put inside one relay floor, and
    /// the prompt stays one small call.
    public static let recentCaringEncounterCap = 6
}

extension CognitiveDeferredTurnRecord {
    var completion: CognitiveSubstrate.PendingCompletion? {
        completionNodeKey.map {
            CognitiveSubstrate.PendingCompletion(nodeKey: $0, recordedAt: completionRecordedAt ?? event.occurredAt,
                                                  sessionId: completionSessionId)
        }
    }

    var outcome: ContinuityField.IngestOutcome? {
        // Refolding uses only the node key; tag stamping treats the moment as
        // new and completion reconsolidation reads only identity.
        outcomeKey.map { ContinuityField.IngestOutcome(key: $0, isNewNode: false) }
    }
}
