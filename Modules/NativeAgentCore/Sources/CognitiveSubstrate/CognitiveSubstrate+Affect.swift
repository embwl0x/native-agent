// CognitiveSubstrate+Affect.swift

import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Affect.swift` | `CognitiveSubstrate`: `canonicalAffectProjection`, `decayAffectInMemory`, `applyAffectFromEvent` |

extension CognitiveSubstrate {
    /// One fixed-time affect projection for sibling organs. Warmth and pressure
    /// must cross together so the organism cannot observe two decay epochs.
    public func canonicalAffectProjection(at fixedAt: Date) -> CognitiveAffectState? {
        guard configuration.enabled else { return nil }
        return projectedAffect(at: fixedAt)
    }

    @discardableResult
    func decayAffectInMemory(to now: Date) -> Bool {
        guard configuration.enabled,
              now.timeIntervalSince(affect.updatedAt) > 0 else { return false }
        affect = projectedAffect(at: now)
        return true
    }

    /// Decays and applies affect without suspension so ingest can stamp the same state atomically.
    @discardableResult
    func applyAffectFromEvent(
        _ event: CognitiveEvent,
        precomputedAppraisal: AffectAppraisal,
        precomputedWarmthBoost: Double
    ) -> CognitiveAffectState {
        guard configuration.enabled,
              event.turnKind.contributesToLivedState else { return affect }
        // An event whose OWNER measured its feeling takes no additional flat
        // per-kind delta: the per-kind arms below are inferences for events that
        // arrived without one, and applying both would stack an inferred delta
        // on a measured one. Byte-identical for `.organismResolutionFelt`, which
        // already `break`s below for exactly this reason; what it adds is the
        // same guarantee for the studio journal, where the agent's own
        // requirement is that the delta come from the ENTRY and never from the
        // act of filing one.
        guard !event.carriesMeasuredFeltValence else { return affect }
        let now = dependencies.now()
        // Settle elapsed quiet time on a copy before folding in the new event.
        // This keeps the merge boundary correct even when no maintenance tick
        // occurred during the gap; the projection itself never mutates state.
        var next = projectedAffect(at: now)
        let importance = event.importance
        switch event.kind {
        case .toolFailed, .providerFailure:
            next.arousal = saturatingApproach(next.arousal, 0.25 + importance * 0.25)
            next.uncertainty = saturatingApproach(next.uncertainty, 0.3 + importance * 0.2)
            next.taskPressure = saturatingApproach(next.taskPressure, 0.2)
        case .toolStarted:
            next.arousal = saturatingApproach(next.arousal, 0.05 + importance * 0.05)
            next.taskPressure = saturatingApproach(next.taskPressure, importance * 0.05)
        case .toolCancelled:
            break
        case .providerVitalsShift:
            // Graded sibling of `.providerFailure`. The somatic/organism path is
            // the primary consequence (chemistry → mood → capsule); if a shift is
            // ever folded into affect too, a worsening band lifts arousal/
            // uncertainty in proportion to its importance (sluggish < degraded)
            // and a recovery eases uncertainty. Direction travels in metadata.
            if case .string("recovering")? = event.metadata[CognitiveSomaticSignals.vitalsDirectionMetadataKey] {
                next.uncertainty = saturatingApproach(next.uncertainty, -0.1)
            } else {
                next.arousal = saturatingApproach(next.arousal, 0.15 + importance * 0.2)
                next.uncertainty = saturatingApproach(next.uncertainty, 0.2 + importance * 0.15)
            }
        case .organismResolutionFelt:
            // The organism's chemistry already carries this exhale (Wave A1);
            // the substrate remembers it as a NODE, not a second affect hit.
            break
        case .userCorrection:
            next.arousal = saturatingApproach(next.arousal, 0.15)
            next.uncertainty = saturatingApproach(next.uncertainty, 0.25)
            next.taskPressure = saturatingApproach(next.taskPressure, 0.1)
            next.socialWarmth = saturatingApproach(next.socialWarmth, precomputedWarmthBoost * 0.5)
        case .toolSucceeded:
            next.uncertainty = saturatingApproach(next.uncertainty, -0.15)
            next.taskPressure = saturatingApproach(next.taskPressure, -0.15)
        case .workshopExecutionCompleted:
            if event.isPositiveTerminalOutcome {
                next.uncertainty = saturatingApproach(next.uncertainty, -0.15)
                next.taskPressure = saturatingApproach(next.taskPressure, -0.15)
            } else if event.isNegativeTerminalOutcome {
                next.arousal = saturatingApproach(next.arousal, 0.25 + importance * 0.25)
                next.uncertainty = saturatingApproach(next.uncertainty, 0.3 + importance * 0.2)
                next.taskPressure = saturatingApproach(next.taskPressure, 0.2)
            }
        case .userMessageReceived:
            next.arousal = saturatingApproach(next.arousal, 0.05 + importance * 0.07)
            // Affect-warmth is ADDITIVE to Agent's persona, which is already naturally warm
            // with User. There is no flat per-message base, so the affect layer rises only on
            // genuine warmth in the exchange and eases back down during focused work (just
            // decay, no boost) — a modulation on top of her baseline, never the whole of it.
            // This lets her get crisp and businesslike heads-down while staying fundamentally
            // warm via the persona; genuine warm/affectionate moments still lift it high.
            next.socialWarmth = saturatingApproach(next.socialWarmth, precomputedWarmthBoost)
            next.taskPressure = saturatingApproach(next.taskPressure, importance * 0.06)
            // Conversational appraisal moves felt signals for good and bad exchanges; dismissal can make warmth negative.
            let appraisal = precomputedAppraisal
            if appraisal.isActive {
                if appraisal.warmth != 0 { next.socialWarmth = saturatingApproach(next.socialWarmth, appraisal.warmth) }
                if appraisal.tension != 0 { next.uncertainty = saturatingApproach(next.uncertainty, appraisal.tension) }
                if appraisal.pressure != 0 { next.taskPressure = saturatingApproach(next.taskPressure, appraisal.pressure) }
                if appraisal.arousal != 0 { next.arousal = saturatingApproach(next.arousal, appraisal.arousal) }
            }
        case .assistantTurnCompleted:
            next.taskPressure = saturatingApproach(next.taskPressure, -0.1)
            // NO warmth boost from her own reply. Agent is warm by persona, so every
            // completion carries warm tokens — boosting off her own output is a
            // self-reinforcing ratchet that pegged warmth at "deeply warm" all day.
            // Relational warmth tracks USER's warmth toward her (userMessageReceived),
            // not her own routine voice; between genuine warm moments, warmth eases.
        case .appWake:
            next.arousal = saturatingApproach(next.arousal, 0.05)
        case .appSleep:
            next.arousal = saturatingApproach(next.arousal, -0.1)
            next.taskPressure = saturatingApproach(next.taskPressure, -0.1)
        }
        // Re-feel and dream residue share this await-free state update.
        next = refelt(next, for: event, at: now)
        // RESIDUE (item 7). The night colors the first turns after waking.
        next = colored(next, byResidueAt: now)
        affect = next
        if event.kind == .assistantTurnCompleted {
            // One accepted turn spent. Counted on HER completed turn (the same
            // boundary the Sound cadence counts), so a residue lasts two real
            // exchanges rather than two events.
            consumeDreamResidueTurn(at: now)
        }
        // Persistence is intentionally NOT here — this function must stay synchronous so
        // callers can apply affect and stamp a node tag in one await-free segment. The
        // affect artifact is persisted by the async caller (updateAffectFromEvent, or
        // ingest after it stamps the tag).
        return next
    }

    // MARK: - Re-feeling a remembered feeling

    /// The strongest nudge one re-touched memory may apply to current affect.
    /// Small by design: recall COLORS the present, it does not replace it.
    static let refeelNudge = 0.08
    /// One nudge per node per hour. A memory re-served three times in a turn is
    /// one act of remembering, not three feelings.
    static let refeelRefractory: TimeInterval = 60 * 60
    /// A tag this flat is not a feeling worth re-feeling.
    static let refeelValenceFloor = 0.12
    /// How many re-touched nodes may contribute to one turn.
    static let refeelNodesPerTurn = 2

    /// Nudge current affect toward the feeling of the memories this turn
    /// actually pulled in. Saturating (the affect layer's own law), bounded, and
    /// rate-limited per node.
    ///
    /// Deliberately NOT a mood write and NOT a re-stamp: the node's own tag is
    /// untouched, so re-feeling cannot ratchet a memory warmer every time it is
    /// recalled (the reconsolidation asymmetry already owns that lane, and only
    /// on genuine re-encounter).
    private func refelt(
        _ state: CognitiveAffectState,
        for event: CognitiveEvent,
        at now: Date
    ) -> CognitiveAffectState {
        let servedIDs = Self.memoryRecordIDs(fromEventMetadata: event.metadata)
        guard !servedIDs.isEmpty else { return state }
        let served = Set(servedIDs)
        var next = state
        var applied = 0
        for node in field.peekNodes()
            .sorted(by: { $0.lastActivatedAt > $1.lastActivatedAt }) {
            guard applied < Self.refeelNodesPerTurn else { break }
            guard abs(node.emotionalValence) >= Self.refeelValenceFloor else { continue }
            let ids = Self.memoryRecordIDs(from: node)
            guard !ids.isEmpty,
                  ids.contains(where: { served.contains($0) })
            else { continue }
            // ONE act of remembering, not two feelings: the refractory is
            // keyed by the RECORD as well as the node, because every recall
            // turn mints a fresh node naming the same record, and a per-node
            // key let the same memory move her again sixty seconds later.
            let servedHere = ids.filter { served.contains($0) }
            if let last = lastRefeltAt[node.id],
               now.timeIntervalSince(last) < Self.refeelRefractory { continue }
            if servedHere.contains(where: {
                guard let last = lastRefeltRecordAt[$0] else { return false }
                return now.timeIntervalSince(last) < Self.refeelRefractory
            }) { continue }
            lastRefeltAt[node.id] = now
            for id in servedHere { lastRefeltRecordAt[id] = now }
            applied += 1
            let pull = Self.refeelNudge * node.emotionalValence.clampedSigned()
            if pull > 0 {
                next.socialWarmth = saturatingApproach(next.socialWarmth, pull * node.emotionalWarmth)
                next.uncertainty = saturatingApproach(next.uncertainty, -pull * 0.5)
            } else {
                next.uncertainty = saturatingApproach(next.uncertainty, -pull * 0.6)
                next.arousal = saturatingApproach(next.arousal, -pull * 0.5)
            }
        }
        if applied > 0 { pruneRefeelLedger(at: now) }
        return next
    }

    private func pruneRefeelLedger(at now: Date) {
        guard lastRefeltAt.count > 64 || lastRefeltRecordAt.count > 64 else { return }
        lastRefeltRecordAt = lastRefeltRecordAt.filter {
            now.timeIntervalSince($0.value) < Self.refeelRefractory
        }
        lastRefeltAt = lastRefeltAt.filter {
            now.timeIntervalSince($0.value) < Self.refeelRefractory
        }
    }

    /// Decode metadata record ids once for events and nodes, preserving first-seen order.
    static func memoryRecordIDs(fromEventMetadata metadata: [String: JSONValue]) -> [String] {
        var ids: [String] = []
        if case .array(let values)? = metadata["memoryRecordIds"] {
            for value in values {
                if case .string(let id) = value {
                    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { ids.append(trimmed) }
                }
            }
        }
        if case .string(let id)? = metadata["memoryRecordId"] {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { ids.append(trimmed) }
        }
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }

    /// The night's lean, spent on this turn. Zero once the residue is used up.
    private func colored(_ state: CognitiveAffectState, byResidueAt now: Date) -> CognitiveAffectState {
        let lean = dreamResidueLean(at: now)
        guard lean != 0 else { return state }
        var next = state
        if lean > 0 {
            next.socialWarmth = saturatingApproach(next.socialWarmth, lean)
            next.uncertainty = saturatingApproach(next.uncertainty, -lean * 0.5)
        } else {
            next.uncertainty = saturatingApproach(next.uncertainty, -lean)
            next.taskPressure = saturatingApproach(next.taskPressure, -lean * 0.5)
        }
        return next
    }

    /// Stamp measured feeling as given; otherwise combine the exact post-event
    /// affect with care-weighted meaning and the caller's gated appraisal.
    func emotionTag(
        for event: CognitiveEvent,
        affect: CognitiveAffectState,
        semantic: SemanticAppraisal,
        precomputedAppraisal appraisal: AffectAppraisal
    ) -> (valence: Double, arousal: Double, warmth: Double) {
        // A measured feeling bypasses residue arithmetic, regardless of its owner.
        if event.carriesMeasuredFeltValence {
            func metadataDouble(_ value: JSONValue?) -> Double? {
                switch value {
                case .double(let d): return d
                case .int(let i): return Double(i)
                default: return nil
                }
            }
            let felt = min(0.7, max(-0.7, metadataDouble(event.metadata["feltValence"]) ?? 0))
            let feltArousal = (metadataDouble(event.metadata["feltArousal"]) ?? 0.2).clamped01()
            return (valence: felt, arousal: feltArousal, warmth: (affect.socialWarmth).clamped01())
        }
        let affectTerm = affect.socialWarmth
            - 0.5 * affect.uncertainty
            - 0.3 * affect.taskPressure
        let meaning = meaningWeightedOutcomeBase(for: event, appraisal: semantic)
            + semanticValenceTerm(semantic)
            + appraisal.valence
        // Positive meaning damps negative residue by at most half.
        let dampedAffectTerm = (affectTerm < 0 && meaning > 0)
            ? affectTerm * (1 - min(0.5, meaning * 1.4))
            : affectTerm
        var pierced = dampedAffectTerm + meaning
        // Received affection may be muted but cannot become a wound;
        // the floor follows the speaker's relational weight.
        if appraisal.affection {
            pierced = max(pierced, -0.12 * appraisal.affectionWeight.clamped01())
        }
        return (
            valence: (pierced).clampedSigned(),
            arousal: (affect.arousal).clamped01(),
            warmth: (affect.socialWarmth).clamped01()
        )
    }

    func restoreAffect(from payloads: [JSONValue]) {
        guard case .object(let object)? = payloads.first,
              let updatedAt = dateValue(object["updatedAt"]) else { return }
        affect = CognitiveAffectState(
            arousal: object["arousal"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0,
            uncertainty: object["uncertainty"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0,
            taskPressure: object["taskPressure"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0,
            socialWarmth: object["socialWarmth"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0,
            updatedAt: updatedAt,
            lived: object["lived"]?.stringValue.flatMap(UInt64.init)
                ?? UInt64(max(0, object["lived"]?.integerValue.flatMap(Int.init(exactly:)) ?? 0))
        )
        lastUserPresenceAt = dateValue(object["lastUserPresenceAt"])
        lastWarmPresenceAt = dateValue(object["lastWarmPresenceAt"])
    }

    /// Per-axis decay half-lives. Arousal (alertness/energy) fades on a minutes scale;
    /// social warmth lingers for hours. This "honest decay" gives each axis real dynamic
    /// range across a day instead of one shared 1h half-life that blurred fast and slow
    /// feelings together and let active conversation peg every axis at the ceiling.

    /// Decay an affect state to `now` using per-axis half-lives. Centralizes the decay
    /// math used by the pure live projection and persisted checkpoints.
    private func decayedAffect(
        _ state: CognitiveAffectState,
        to now: Date,
        dynamics capturedDynamics: PersonalityDynamicsConfiguration?
    ) -> CognitiveAffectState {
        let elapsed = max(0, now.timeIntervalSince(state.updatedAt))
        guard elapsed > 0 else {
            var carried = state
            carried.updatedAt = now
            return carried
        }
        func decay(_ halfLife: TimeInterval) -> Double { pow(0.5, elapsed / halfLife) }
        let dyn = capturedDynamics ?? dynamics
        return CognitiveAffectState(
            arousal: state.arousal * decay(dyn.arousalHalfLife),
            uncertainty: state.uncertainty * decay(dyn.uncertaintyHalfLife),
            taskPressure: state.taskPressure * decay(dyn.taskPressureHalfLife),
            socialWarmth: state.socialWarmth * decay(dyn.socialWarmthHalfLife),
            updatedAt: now,
            lived: state.lived
        )
    }

    /// Saturating update toward the [0,1] bounds. A positive delta moves `value` a
    /// fraction of its remaining headroom toward 1; a negative delta moves it a fraction
    /// of the way toward 0. Unlike add-then-clamp, a high value resists further saturation,
    /// so an axis under sustained input settles below the ceiling with headroom to still
    /// register a stronger moment — and decay can always pull it back down.
    private func saturatingApproach(_ value: Double, _ delta: Double) -> Double {
        let v = (value).clamped01()
        if delta >= 0 {
            return (v + delta * (1 - v)).clamped01()
        } else {
            return (v + delta * v).clamped01()
        }
    }

    /// "Away" threshold: once User has been quiet this long, ambient presence applies.
    private static let ambientPresenceGap: TimeInterval = 30 * 60
    /// The quiet-but-present warmth floor held during his absence.
    private static let ambientPresenceWarmthBase: Double = 0.18
    /// The floor itself fades over a long absence so it never becomes permanent fake warmth.
    private static let ambientPresenceFloorHalfLife: TimeInterval = 12 * 60 * 60
    /// The former five-minute maintenance pass eased pressure and uncertainty by
    /// 5% per pass after the quiet boundary. Express the same response as elapsed
    /// time so reading at 31 minutes or four hours does not depend on how many
    /// scheduler ticks happened to run. `0.95` every five minutes is an
    /// approximately 67.56-minute half-life.
    private static let ambientQuietCalmingHalfLife: TimeInterval =
        (5 * 60) * log(0.5) / log(0.95)

    /// Pure read-time affect at an explicit instant. Canonical persistence keeps
    /// the last materialized anchor; callers observe analytic decay, ambient calm,
    /// and the warm-presence floor without advancing that anchor or writing.
    func projectedAffect(
        at now: Date,
        dynamics capturedDynamics: PersonalityDynamicsConfiguration? = nil
    ) -> CognitiveAffectState {
        guard configuration.enabled else { return affect }
        let source = affect
        var next = decayedAffect(source, to: now, dynamics: capturedDynamics)
        guard let lastPresence = lastUserPresenceAt else { return next }
        let quietBoundary = lastPresence.addingTimeInterval(Self.ambientPresenceGap)
        guard now >= quietBoundary else { return next }

        // Apply only the quiet interval not already materialized in `source`.
        // A later maintenance/shutdown checkpoint can therefore persist this
        // projection and a subsequent read will continue from that exact anchor.
        let quietAnchor = max(source.updatedAt, quietBoundary)
        let quietElapsed = max(0, now.timeIntervalSince(quietAnchor))
        if quietElapsed > 0 {
            let calmFactor = pow(0.5, quietElapsed / Self.ambientQuietCalmingHalfLife)
            next.taskPressure *= calmFactor
            next.uncertainty *= calmFactor
        }

        // Lingering warmth is anchored only by a genuinely warm user moment.
        if let lastWarm = lastWarmPresenceAt {
            let warmGap = now.timeIntervalSince(lastWarm)
            if warmGap >= Self.ambientPresenceGap {
                let warmthFloor = Self.ambientPresenceWarmthBase
                    * pow(0.5, warmGap / Self.ambientPresenceFloorHalfLife)
                if warmthFloor > 0.01 {
                    next.socialWarmth = max(next.socialWarmth, warmthFloor)
                }
            }
        }
        next.updatedAt = now
        return next
    }

}
