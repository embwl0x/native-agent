// CognitiveSubstrate+Capsule.swift
// Move-only extraction (R8b) from CognitiveSubstrate.swift — see docs/build_plans/fable5-wave2-r8b-decomposition.md

import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `CognitiveSubstrate+Capsule.swift` | `CognitiveSubstrate`: `compileFrozenCapsulePresentation` owns chat and inspect-only reflection assembly |

extension CognitiveSubstrate {
    /// The moment this turn's unbidden recall already resolved, if any. It is a
    /// parameter rather than a lookup because the render is synchronous — see
    /// `remindedOfMoment(for:from:)`.

    /// Pure frozen render plus the presentation mutation that would become
    /// valid only if this exact capsule is accepted into provider context.
    public func compileFrozenCapsulePresentation(
        _ request: CognitiveCapsuleRequest,
        from read: CognitiveFrozenRead,
        remindedOf: CognitiveRecalledMoment? = nil,
        dreamTheme: CognitiveDreamTheme? = nil,
        gapItems: [String]? = nil
    ) -> CognitivePreparedCapsule {
        compileFrozenCapsulePresentation(
            request, from: read, remindedOf: remindedOf, dreamTheme: dreamTheme,
            gapItems: gapItems, careCue: nil, felt: nil, unreadable: [])
    }

    private func compileFrozenCapsulePresentation(
        _ request: CognitiveCapsuleRequest,
        from read: CognitiveFrozenRead,
        remindedOf: CognitiveRecalledMoment?,
        dreamTheme: CognitiveDreamTheme?,
        gapItems: [String]?,
        careCue: CognitiveCareCue?,
        felt: (signals: FeltSignals, fingerprint: FeltLineRender?)?,
        unreadable: [String]
    ) -> CognitivePreparedCapsule {
        guard read.configuration.enabled,
              read.configuration.capsuleInjectionEnabled,
              request.mode != .off else {
            return CognitivePreparedCapsule(
                capsule: CognitiveCapsule(
                    generatedAt: read.fixedAt,
                    mode: .off,
                    stableKernel: "",
                    dynamicContext: "",
                    provenanceNodeIds: [],
                    truncated: false
                )
            )
        }
        let maximumCharacters = min(
            read.configuration.maximumCapsuleCharacters,
            max(0, request.maximumCharacters ?? read.configuration.maximumCapsuleCharacters)
        )
        guard maximumCharacters > 0 else {
            return CognitivePreparedCapsule(
                capsule: CognitiveCapsule(
                    generatedAt: read.fixedAt,
                    mode: request.mode,
                    stableKernel: "",
                    dynamicContext: "",
                    provenanceNodeIds: [],
                    truncated: true
                )
            )
        }
        let items = read.workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) }
        let expectedPresentationState = read.capsulePresentationState
        var nextPresentationState = expectedPresentationState
        // Every cue that passed its own gate, best first; only one is shown.
        var cueWhy = CapsuleCueWhy()
        let candidateLines = innerStateCapsuleLines(
            from: items,
            request: request,
            at: read.fixedAt,
            frozenRead: read,
            remindedOf: remindedOf,
            dreamTheme: dreamTheme,
            gapItems: gapItems,
            careCue: careCue,
            felt: felt,
            presentationState: &nextPresentationState,
            why: &cueWhy
        )
        // Receipts are not cues: they never compete for the one felt slot.
        let dynamicLines = (request.surface == Self.cadenceExemptCapsuleSurface
            ? candidateLines : Self.oneFeltCue(candidateLines))
            + Array(Set(unreadable)).sorted().map(Self.unreadableCueLine)
        let capsule = assembledCapsule(
            request, at: read.fixedAt, dynamicLines: dynamicLines,
            workspaceItems: items,
            maximumCharacters: maximumCharacters)
        let turnKind = request.resolvedTurnKind
        let commit: CognitiveCapsulePresentationCommit?
        // Phase 5A: an EMPTY capsule is a normal accepted turn now, so it
        // commits too — otherwise "since the last capsule" (the Since gap) and
        // every rest counter would stall across a run of quiet turns.
        if turnKind == .live, request.mode == .inject {
            Self.keepUnshownCuesOwed(
                candidateLines: candidateLines,
                shown: capsule.dynamicContext,
                expected: expectedPresentationState,
                next: &nextPresentationState)
            commit = CognitiveCapsulePresentationCommit(
                fixedAt: read.fixedAt,
                expected: expectedPresentationState,
                next: nextPresentationState
            )
        } else {
            commit = nil
        }
        return CognitivePreparedCapsule(
            capsule: capsule,
            presentationCommit: commit,
            why: Self.cueWhyPayload(
                candidateLines: candidateLines, shown: capsule.dynamicContext, why: cueWhy,
                signature: Self.associationSignature(request.userMessage)))
    }

    private func assembledCapsule(
        _ request: CognitiveCapsuleRequest,
        at now: Date,
        dynamicLines: [String],
        workspaceItems: [CognitiveWorkspaceItem],
        maximumCharacters: Int
    ) -> CognitiveCapsule {
        let stableKernel = Self.capsuleStableKernel("How you feel:", dynamicLines: dynamicLines)
        let boundedStableKernel = bounded(stableKernel, maxCharacters: maximumCharacters)
        let separatorCost = dynamicLines.isEmpty || boundedStableKernel.isEmpty ? 0 : 2
        let remaining = max(0, maximumCharacters - boundedStableKernel.count - separatorCost)
        let fittedLines = fitCapsuleLines(dynamicLines, maxCharacters: remaining)
        return CognitiveCapsule(
            generatedAt: now,
            mode: request.mode,
            stableKernel: boundedStableKernel,
            dynamicContext: fittedLines.text,
            provenanceNodeIds: unique(workspaceItems.map(\.id)),
            truncated: fittedLines.truncated || boundedStableKernel.count < stableKernel.count,
            sourcePeerIds: CognitiveReflectionCause.unionPeerIds(workspaceItems.map {
                Self.peerIdentity(metadata: $0.node.metadata).map { [$0] } ?? []
            })
        )
    }

    /// A cue that passed its gate but was not shown — it lost the one slot or
    /// the budget — was never read, so its cadence stays owed (Phase 5A).
    static func keepUnshownCuesOwed(
        candidateLines: [String],
        shown: String,
        expected: CognitiveCapsulePresentationState,
        next: inout CognitiveCapsulePresentationState
    ) {
        // A tail line that lost the capsule budget was never presented and
        // must remain eligible for the next accepted turn.
        if !shown.contains("- Since:") {
            // An owed bridge keeps its gap: a Since line that was produced and
            // lost the slot (Settling outranks it) leaves `owedSinceGap` set by
            // its render, so the next turn still closes that gap.
            next.lastSessionBridgeAt = expected.lastSessionBridgeAt
        } else {
            next.owedSinceGap = nil
        }
        let soundLost = candidateLines.contains { $0.hasPrefix("- Sound:") }
            && !shown.contains("- Sound:")
        if soundLost {
            // A rut nudge that lost the budget was never read, so it must
            // not burn its cooldown either — but ONLY when it actually
            // spoke in this render. A rut that merely LAPSED must still be
            // forgotten, or its return would resume mid-cooldown instead of
            // reading as the change it is. The since-surfaced counter always
            // advances: a capsule happened.
            if next.soundRutLastSurfacedAt
                != expected.soundRutLastSurfacedAt {
                next.soundRutSignature = expected.soundRutSignature
                next.soundRutLastSurfacedAt = expected.soundRutLastSurfacedAt
                next.soundRutTurnsSinceSurfaced =
                    expected.soundRutTurnsSinceSurfaced
                next.soundRutEarlyRepeatSpent =
                    expected.soundRutEarlyRepeatSpent
            }
        }
        // Same rule for the felt words (Phase 5A): a family change that lost
        // the one cue slot was never read, so it stays a change.
        if let words = candidateLines.first(where: { !$0.hasPrefix("- ") }),
           !shown.contains(words) {
            next.fingerprintFamily = expected.fingerprintFamily
            next.fingerprintCount = expected.fingerprintCount
            next.fingerprintLastSurfacedAt =
                expected.fingerprintLastSurfacedAt
            next.ambivalenceCount = expected.ambivalenceCount
            next.lastAmbivalenceAt = expected.lastAmbivalenceAt
        }
        // A care she meant to bring up whose line was never read is still owed.
        if !shown.contains(careIntentionPrefix) {
            next.careReleased = expected.careReleased
        }
        // A plain care line that lost the budget never started its rest.
        if !shown.contains(careMindPrefix) {
            for (key, rest) in next.careLineRest where rest.turnsLeft == careLineRestTurns {
                next.careLineRest[key] = nil
            }
        }
        // Phase 5 B1: a dream phrase that lost the slot was never read.
        if !shown.contains("- Dream:") {
            next.dreamThemeSurfaced = expected.dreamThemeSurfaced
        }
        if !shown.contains("- Settling:"),
           next.settlingRun > expected.settlingRun {
            next.settlingRun = expected.settlingRun
        }
        // Same rule for the unbidden recall, and it matters more here than
        // anywhere else: the line rides LAST, so it is the first thing the
        // budget drops. A moment burned by a clip would sit in the 24h
        // ledger without ever having been read.
        if !shown.contains("- Reminded of:") {
            next.remindedOfSurfaced =
                expected.remindedOfSurfaced
            next.remindedOfLastSurfacedAt =
                expected.remindedOfLastSurfacedAt
            next.remindedOfTurnsSinceSurfaced =
                expected.remindedOfTurnsSinceSurfaced
        }
    }

    /// Rendering mutates only the caller's copied presentation value. The live
    /// actor is advanced later by `applyCapsulePresentationCommit`, and only for
    /// an accepted injection.
    private func innerStateCapsuleLines(
        from workspaceItems: [CognitiveWorkspaceItem],
        request: CognitiveCapsuleRequest,
        at now: Date,
        frozenRead: CognitiveFrozenRead,
        remindedOf: CognitiveRecalledMoment? = nil,
        dreamTheme: CognitiveDreamTheme? = nil,
        gapItems: [String]? = nil,
        careCue: CognitiveCareCue? = nil,
        felt: (signals: FeltSignals, fingerprint: FeltLineRender?)? = nil,
        presentationState: inout CognitiveCapsulePresentationState,
        why: inout CapsuleCueWhy
    ) -> [String] {
        var fingerprintSpoken: String?
        // Phase 5 B0: what she rejected for this kind of thing never leads.
        let dyn = frozenRead.personalityDynamics
        let signals = felt?.signals ?? feltSignalsForCapsule(
            from: workspaceItems,
            request: request,
            at: now,
            affect: frozenRead.affect,
            mood: frozenRead.mood,
            proxies: frozenRead.feltProxies,
            dynamics: dyn
        )
        // W4/P11 — the felt MODE, finally doing something. It stays what it always
        // was in the prompt: nothing. Not a word, not a line, not a byte. It only
        // steers WHICH already-attested exemplar the echo reaches for.
        let mode = frozenRead.configuration.enabled
            ? Self.feltMode(signals, intensityFloor: dyn.feltIntensityFloor)
            : nil
        // W4/P7 — THE SESSION BRIDGE. The first turn User takes after a real
        // gap (on his turns, across his doors — Phase 5 B2) can carry one line
        // of what actually happened while he was away; an empty gap, none.
        let gapOpened = request.fromUser
            ? Self.sinceGapOpened(presentationState, previousUserTurn: request.previousUserTurnAt, dynamics: dyn, at: now) : nil
        let since = feltSessionBridgeLine(
            at: now,
            dynamics: dyn,
            presentationState: &presentationState,
            fromUser: request.fromUser,
            previousUserTurn: request.previousUserTurnAt,
            gapItems: gapItems,
            cognitionEnabled: frozenRead.configuration.enabled,
            affectEnabled: frozenRead.configuration.enabled
        )
        if let since, let gapOpened {
            why.sources[since] = "gap:\(Int((now.timeIntervalSince(gapOpened) / 3_600).rounded()))h"
        }
        // ON HER MIND (cares lane 2): a charged care this message touches, or
        // her intention to bring up the one pressing hardest, first among the
        // felt cues. Neither, and the other cues compete as before.
        let resting = Self.advanceCareLineRest(&presentationState.careLineRest)
        let careLines = careCue.map {
            careCueLines($0, message: request.userMessage, gapOpened: gapOpened, resting: resting, at: now,
                         presentationState: &presentationState, why: &why)
        } ?? []
        let reflectionPreview = request.surface == Self.cadenceExemptCapsuleSurface
        let bodyLine = organismBodyLine(from: request.organismProjection)
        // SETTLING (2026-08-23, range bench scenario #2): the slow layer is still
        // below water after a hard stretch and THIS message is kind. The substrate
        // already carried "on edge" through the repair turns; the words still
        // snapped ("We're good… 💜" on the first apology). One line, only while
        // mood is negative and the incoming message warms — it clears itself as
        // mood recovers, so it can never become a standing instruction.
        var settlingSpoken: String?
        if let settling = settlingLine(
            mood: frozenRead.mood,
            incoming: conversationalAppraisal(in: request.userMessage),
            affectEnabled: frozenRead.configuration.enabled,
            cognitionEnabled: frozenRead.configuration.enabled
        ) {
            // Cadence cap: at most `settlingMaxRun` consecutive presentations;
            // then silent until the condition lapses (the run resets below).
            if presentationState.settlingRun < Self.settlingMaxRun {
                settlingSpoken = settling
                presentationState.settlingRun += 1
            }
        } else {
            presentationState.settlingRun = 0
        }
        // Wave G: the self-exemplar echo goes LAST so budget truncation drops it
        // before it can displace focus/feeling/inner — it's an enhancer, not core.
        let echo = soundEchoSelection(
            at: now,
            mode: mode,
            roomValence: signals.valence,
            currentSessionId: request.sessionId,
            surface: request.surface,
            trustedPeerIds: frozenRead.trustedPeerIds,
            fieldNodes: frozenRead.snapshot.nodes,
            fixedAffect: frozenRead.affect,
            fixedMood: frozenRead.mood,
            landingScores: frozenRead.soundLandingScores,
            dynamics: dyn,
            cognitionEnabled: frozenRead.configuration.enabled,
            affectEnabled: frozenRead.configuration.enabled,
            emitReceipts: request.mode == .inject
        )
        // ONE gate for the named rut line, whether or not the exemplar echo
        // speaks this turn.
        let rutSpeaks = soundRutAwarenessShouldSpeak(
            signature: echo.wornSignature,
            at: now,
            dynamics: dyn,
            presentationState: &presentationState,
            fedAgain: echo.rutFedAgain
        )
        let rutLine = rutSpeaks ? echo.rutLine : nil

        // The felt fingerprint REPLACES the Focus/Feeling/Voice sentences (User,
        // 2026-07-08): "How you feel" should hand her a word-level felt state she
        // FEELS, not sentences she reads. Attention (focused/foggy) is folded into
        // the fingerprint; her cares, continuity, Body and Sound anchors follow.
        let fingerprint: FeltLineRender?
        if let felt {
            fingerprint = felt.fingerprint
        } else {
            fingerprint = feltFingerprintLine(
                signals: signals,
                workspaceItems: workspaceItems,
                request: request,
                at: now,
                dynamics: dyn,
                affectEnabled: frozenRead.configuration.enabled
            )
        }
        if let fingerprint {
            // W4/P4 — SUPPRESS WHEN UNCHANGED. The rule the echo learned the hard
            // way generalizes to the line that matters most: a signal delivered on
            // every single turn stops being information and becomes a standing
            // instruction. An identical "How you feel: warm" for forty consecutive
            // turns is a stuck gauge and the model will express it — that is the
            // exact mechanism that made `tender` a tic. Her felt state does not go
            // away here; it stops being re-narrated.
            //
            // Phase 5A (2026-10-03) retires the never-empty rule: ONE felt cue
            // or none, and none is normal. The words speak when the felt FAMILY
            // moved (run 1), not for every capsule it holds still; the object
            // word is no longer spoken, so it no longer counts as movement.
            let verdict = fingerprintCadenceVerdict(
                family: fingerprint.family,
                at: now,
                dynamics: dyn,
                presentationState: &presentationState)
            if verdict.speak, verdict.run == 1 || reflectionPreview {
                fingerprintSpoken = fingerprint.bareText
                // Presentation receipts — counters only, no text. A suppressed
                // line was never read, so it records nothing.
                if fingerprint.carriedAmbivalence {
                    presentationState.ambivalenceCount += 1
                    presentationState.lastAmbivalenceAt = now
                }
            } else if request.mode == .inject {
                TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("C09"), "site": .string("CognitiveSubstrate+Capsule.swift:innerStateCapsuleLines")]))
            }
        }
        // UNBIDDEN RECALL (2026-09-02). The never-alone rule retired with
        // Phase 5A: in a one-cue capsule every cue stands alone.
        var remindedSpoken: String?
        if let remindedOf,
           let line = remindedOfCapsuleLine(for: remindedOf, at: now) {
            remindedSpoken = line
            why.sources[line] = "memory:" + remindedOf.id
            why.scores[line] = remindedOf.score
            presentationState.remindedOfSurfaced[remindedOf.id] = now
            Self.boundRemindedOfLedger(&presentationState.remindedOfSurfaced)
            presentationState.remindedOfLastSurfacedAt = now
            presentationState.remindedOfTurnsSinceSurfaced = 0
        }
        // DREAM RESIDUE (Phase 5 B1): last night's dream, only when this
        // message connects to it, marked as a dream association.
        var dreamSpoken: String?
        if let dreamTheme, let line = dreamCapsuleLine(for: dreamTheme) {
            dreamSpoken = line
            why.sources[line] = "dream:" + dreamTheme.id
            why.scores[line] = dreamTheme.score
            presentationState.dreamThemeSurfaced[dreamTheme.id] = now
            Self.boundDreamThemeLedger(&presentationState.dreamThemeSurfaced)
        }
        // ONE FELT CUE OR NONE (Phase 5A, 2026-10-03). Every producer above
        // already ran its own gate; this orders the survivors by how much they
        // belong to THIS turn — the message itself made Settling, the gap made
        // Since, the feeling dragged up Reminded-of, then state that merely moved.
        // `oneFeltCue` keeps
        // the first and the rut line. A cue that loses is restored by the
        // clip rule in `compileFrozenCapsulePresentation`, so it stays owed.
        // Her private reflection prompt is not a turn: it keeps every line, in
        // the historical order (see `cadenceExemptCapsuleSurface`).
        if reflectionPreview {
            return dedupedCapsuleLines([fingerprintSpoken, since, bodyLine, settlingSpoken,
                                        echo.line, rutLine, remindedSpoken].compactMap { $0 })
        }
        let ordered: [String?] = careLines + [
            settlingSpoken, since, remindedSpoken,
            dreamSpoken,
            fingerprintSpoken,
            bodyLine, echo.line, rutLine,
        ]
        return dedupedCapsuleLines(ordered.compactMap { $0 })
    }

    static let soundEchoPrefix = "- Sound: lately you've sounded like"

    /// Phase 5 B0 — why this turn's cue was chosen, collected while the lines
    /// are produced. Trace only: none of it reaches the prompt.
    struct CapsuleCueWhy: Sendable {
        var sources: [String: String] = [:]
        var scores: [String: Double] = [:]
        /// The care line that is her intention to bring it up, when one is.
        var careIntention: String?
    }

    /// The `mind.why` record for the felt cue: every cue that passed its gate,
    /// in the order the one-cue rule ranks them (rank 1 leads), its score and
    /// source where it has one, the winner, and the turn's signature.
    static func cueWhyPayload(
        candidateLines: [String],
        shown: String,
        why: CapsuleCueWhy,
        signature: [String]
    ) -> JSONValue {
        func kind(_ line: String) -> String {
            for (prefix, name) in [("- Since:", "since"),
                                   ("- Reminded of:", "reminded_of"), ("- Settling:", "settling"),
                                   ("- Body:", "body"), ("- Sound:", "sound"),
                                   ("- Dream:", "dream"), (careMindPrefix, "care"),
                                   (careIntentionPrefix, "care")] where line.hasPrefix(prefix) {
                return name
            }
            return "felt"
        }
        func row(_ line: String, rank: Int) -> JSONValue {
            var fields: [String: JSONValue] = [
                "rank": .int(Int64(rank)), "kind": .string(kind(line)),
                "text": .string(String(line.prefix(120))), "shown": .bool(shown.contains(line)),
            ]
            if let source = why.sources[line] { fields["source"] = .string(source) }
            if let score = why.scores[line] { fields["score"] = .double((score * 1000).rounded() / 1000) }
            if isCareCueLine(line) {
                if let source = why.sources[line] { fields["careId"] = .string(String(source.dropFirst("care:".count))) }
                fields["intention"] = .bool(line == why.careIntention)
            }
            return .object(fields)
        }
        let winner = candidateLines.first { shown.contains($0) }
        return .object([
            "lane": .string("cue"),
            "signature": .array(signature.map { .string($0) }),
            "candidates": .array(candidateLines.prefix(10).enumerated().map { row($1, rank: $0 + 1) }),
            "winner": winner.map { row($0, rank: (candidateLines.firstIndex(of: $0) ?? 0) + 1) } ?? .null,
        ])
    }

    /// The one cue, plus the rut line when it spoke: the rut nudge changes her
    /// next sentence directly, so it never competes with how she feels. A care
    /// cue that leads keeps its second care line: it is one thought.
    static func oneFeltCue(_ ordered: [String]) -> [String] {
        let isRut: (String) -> Bool = { $0.hasPrefix("- Sound:") && !$0.hasPrefix(soundEchoPrefix) }
        let cues = ordered.filter { !isRut($0) }
        let lead = cues.first.map(isCareCueLine) == true ? Array(cues.prefix(while: isCareCueLine)) : Array(cues.prefix(1))
        return lead + [ordered.first(where: isRut)].compactMap { $0 }
    }

    /// "How you feel:" is a PROMISE that the next thing is her feeling words.
    ///
    /// The fingerprint may legitimately stay quiet (the suppress-when-unchanged
    /// rule fires only when other lines exist), and when it did, the capsule
    /// still shipped the header with an `- Inner:` reflection immediately under
    /// it — measured on 184 of 1,482 live capsules. Read positionally, by a
    /// model or by an analyst, a care then IS her stated feeling. The
    /// labelled lines say what they are on their own, so when there are no
    /// feeling words the header simply does not appear.
    static func capsuleStableKernel(_ kernel: String, dynamicLines: [String]) -> String {
        guard let first = dynamicLines.first else { return kernel }
        return first.hasPrefix("- ") ? "" : kernel
    }

    private func organismBodyLine(from projection: OrganismProjection?) -> String? {
        guard let projection,
              !projection.isNeutral,
              let rawLine = projection.bodyLine?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawLine.isEmpty else {
            return nil
        }
        let line = rawLine.hasPrefix("- Body:")
            ? rawLine
            : "- Body: \(rawLine.replacingOccurrences(of: #"^-?\s*Body:\s*"#, with: "", options: .regularExpression))"
        let lower = line.lowercased()
        guard !lower.contains("chemicalstate"),
              !lower.contains("bodyschema"),
              !lower.contains("organismkernel"),
              !lower.contains("organismprojection"),
              line.rangeOfCharacter(from: .decimalDigits) == nil else {
            return nil
        }
        let boundedLine = capsuleLineText(line, maxCharacters: 180)
        guard boundedLine.hasPrefix("- Body:") else { return nil }
        return boundedLine
    }

    /// Drop verbatim-duplicate capsule lines (the lossy inner-state translator can map
    /// several workspace nodes onto the same cue), preserving order and
    /// the first occurrence. Keeps the bounded capsule from spending its budget on repeats.
    private func dedupedCapsuleLines(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in lines {
            let key = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if seen.insert(key).inserted { out.append(line) }
        }
        return out
    }

    /// Production preparation seam: one immutable cognition epoch plus a pure
    /// presentation commit for the accepted-turn boundary.
    public func prepareFrozenCapsulePresentation(
        _ request: CognitiveCapsuleRequest,
        at fixedAt: Date
    ) async -> CognitivePreparedCapsule? {
        let requestTurnKind = request.resolvedTurnKind
        guard requestTurnKind == .live || request.allowNonLiveProjection else { return nil }
        let read = await frozenRead(at: fixedAt, currentSessionId: request.sessionId)
        // One local store lookup at most, against the read we already froze —
        // no second snapshot, no provider call, and nothing at all when the
        // cadence is closed or the store is cold.
        // …and re-checked against LIVE cadence/ledger state on the way out: the
        // lookup suspended, and an accepted turn may have surfaced this very
        // moment while it did (`revalidatedRemindedOf`).
        var felt: (signals: FeltSignals, fingerprint: FeltLineRender?)?
        var unreadable: [String] = []
        let remindedOf = await remindedOfMoment(for: request, from: read, felt: &felt, unreadable: &unreadable)
            .flatMap { revalidatedRemindedOf($0, against: read) }
        // Phase 5 B: the two continuity lookups, local and gated the same way
        // (a dream only when the cooldown is open and the message has words;
        // the gap only on User's first turn back).
        let dreamTheme = await dreamThemeCue(for: request, from: read, unreadable: &unreadable)
        let gapItems = await sinceGapItems(for: request, from: read, unreadable: &unreadable)
        let careCue = await careCue(for: request, from: read)
        let prepared = compileFrozenCapsulePresentation(
            request, from: read, remindedOf: remindedOf,
            dreamTheme: dreamTheme, gapItems: gapItems, careCue: careCue, felt: felt, unreadable: unreadable)
        // An empty capsule still returns, carrying its commit (Phase 5A);
        // callers inject only `nonEmptyCapsule`.
        guard prepared.capsule.mode == .inject else { return nil }
        return prepared
    }

    /// Apply presentation-only state after the exact frozen capsule was
    /// accepted into provider context. A stale/out-of-order commit is ignored
    /// rather than rolling cadence backward over a newer accepted turn.
    @discardableResult
    public func applyCapsulePresentationCommit(
        _ commit: CognitiveCapsulePresentationCommit
    ) -> Bool {
        // The rut turn counter free-runs on accepted turns, so an ingest
        // between prepare and commit legitimately moves it. Comparing it here
        // would reject the whole commit for a field the render only reads.
        guard Self.presentationCommitIdentity(capsulePresentationStateSnapshot())
                == Self.presentationCommitIdentity(commit.expected) else { return false }
        let next = commit.next
        if let family = next.fingerprintFamily,
           let surfacedAt = next.fingerprintLastSurfacedAt {
            fingerprintFamilyRun = FingerprintFamilyRun(
                family: family,
                count: next.fingerprintCount,
                lastSurfacedAt: surfacedAt
            )
        } else {
            fingerprintFamilyRun = nil
        }
        owedSinceGap = next.owedSinceGap
        lastSessionBridgeAt = next.lastSessionBridgeAt
        settlingRun = next.settlingRun
        soundRutSignature = next.soundRutSignature
        soundRutLastSurfacedAt = next.soundRutLastSurfacedAt
        soundRutEarlyRepeatSpent = next.soundRutEarlyRepeatSpent
        // Only a nudge that actually SPOKE resets the counter; otherwise the
        // free-running live value stands.
        if next.soundRutTurnsSinceSurfaced == 0 { soundRutTurnsSinceSurfaced = 0 }
        feltObjectCount = next.feltObjectCount
        ambivalenceCount = next.ambivalenceCount
        lastAmbivalenceAt = next.lastAmbivalenceAt
        remindedOfSurfaced = next.remindedOfSurfaced
        dreamThemeSurfaced = next.dreamThemeSurfaced
        careReleased = next.careReleased
        careLineRest = next.careLineRest
        // Only a line that actually SPOKE resets the free-running counter, and
        // "spoke" is the surfaced STAMP moving — not the counter reading zero,
        // which is also what a never-surfaced line looks like.
        if next.remindedOfLastSurfacedAt != commit.expected.remindedOfLastSurfacedAt {
            remindedOfTurnsSinceSurfaced = 0
        }
        remindedOfLastSurfacedAt = next.remindedOfLastSurfacedAt
        // Persist the accepted cue cadence at the same turn boundary.
        capsulePresentationDirty = true
        return true
    }

    // MARK: - Durable capsule cadence

    /// Bounded, content-free presentation payload. Everything here is a counter,
    /// a digest, or a timestamp — no line text reaches disk.
    func capsulePresentationArtifactPayload(at now: Date) -> JSONValue {
        var object: [String: JSONValue] = [
            "updatedAt": .double(now.timeIntervalSince1970),
            "soundRutTurnsSinceSurfaced": .int(Int64(soundRutTurnsSinceSurfaced)),
            // Presentation receipts. Counters, so the question "did the
            // ambivalence exception ever fire on a real turn, and how often"
            // survives a relaunch as a measurement.
            "feltObjectCount": .int(Int64(feltObjectCount)),
            "ambivalenceCount": .int(Int64(ambivalenceCount)),
        ]
        if let lastAmbivalenceAt {
            object["lastAmbivalenceAt"] = .double(lastAmbivalenceAt.timeIntervalSince1970)
        }
        if let signature = soundRutSignature {
            object["soundRutSignature"] = .string(bounded(signature, maxCharacters: 240))
        }
        if let surfacedAt = soundRutLastSurfacedAt {
            object["soundRutLastSurfacedAt"] = .double(surfacedAt.timeIntervalSince1970)
        }
        if soundRutEarlyRepeatSpent {
            object["soundRutEarlyRepeatSpent"] = .bool(true)
        }
        // Phase 5 B: an owed gap, the gap last bridged, and the dream ledger
        // are timestamps and ids, so they survive a relaunch.
        if let owedSinceGap {
            object["owedSinceGap"] = .double(owedSinceGap.timeIntervalSince1970)
        }
        if let lastSessionBridgeAt {
            object["lastSessionBridgeAt"] = .double(lastSessionBridgeAt.timeIntervalSince1970)
        }
        if !dreamThemeSurfaced.isEmpty {
            object["dreamThemeSurfaced"] = .object(dreamThemeSurfaced.mapValues { .double($0.timeIntervalSince1970) })
        }
        if !careReleased.isEmpty {
            object["careReleased"] = .object(careReleased.mapValues { .double($0.timeIntervalSince1970) })
        }
        if !careLineRest.isEmpty {
            object["careLineRest"] = .object(careLineRest.mapValues {
                .array([.double($0.shownAt.timeIntervalSince1970), .int(Int64($0.turnsLeft))])
            })
        }
        return .object(object)
    }

    /// The runtime's accepted-turn boundary, after committing an injected live capsule.
    public func flushCommittedCapsulePresentation(at now: Date) async {
        guard configuration.enabled, configuration.capsuleInjectionEnabled else { return }
        await flushCapsulePresentationIfNeeded(at: now)
    }

    /// Write the cadence ledger iff an accepted turn actually moved it.
    func flushCapsulePresentationIfNeeded(at now: Date) async {
        guard capsulePresentationDirty else { return }
        // Clear before suspension so a concurrent update keeps its own dirty flag.
        capsulePresentationDirty = false
        do {
            try await persistArtifactChecked(
                kind: "capsule_presentation",
                id: stableArtifactID("capsule_presentation"),
                status: "current",
                score: 0,
                payload: capsulePresentationArtifactPayload(at: now)
            )
        } catch {
            capsulePresentationDirty = true
        }
    }

    /// Restore is DEFENSIVE: an unreadable or absent row leaves the live
    /// (empty) cadence alone rather than throwing, because a lost cadence is a
    /// nag, not a corruption.
    func restoreCapsulePresentation(from payloads: [JSONValue]) {
        guard case .object(let object)? = payloads.first else { return }
        // A named rut's signature is "kind:phrase". Anything else was left by
        // the retired unnamed nudge; carried forward it read as a CHANGE and
        // held the first named line behind the 2-turn gap (live 2026-09-25:
        // the rut slid below threshold before the gap cleared).
        soundRutSignature = stringValue(object["soundRutSignature"])
            .flatMap { $0.contains(":") ? $0 : nil }
        soundRutLastSurfacedAt = dateValue(object["soundRutLastSurfacedAt"])
        soundRutEarlyRepeatSpent = object["soundRutEarlyRepeatSpent"] == .bool(true)
            && soundRutSignature != nil
        soundRutTurnsSinceSurfaced = min(
            max(0, Int(exactly: (doubleValue(object["soundRutTurnsSinceSurfaced"]) ?? 0).rounded(.towardZero)) ?? 0),
            Self.soundRutTurnCounterCap
        )
        feltObjectCount = max(0, Int(exactly: (doubleValue(object["feltObjectCount"]) ?? 0).rounded(.towardZero)) ?? 0)
        ambivalenceCount = max(0, Int(exactly: (doubleValue(object["ambivalenceCount"]) ?? 0).rounded(.towardZero)) ?? 0)
        lastAmbivalenceAt = dateValue(object["lastAmbivalenceAt"])
        owedSinceGap = dateValue(object["owedSinceGap"])
        lastSessionBridgeAt = dateValue(object["lastSessionBridgeAt"])
        if case .object(let dreams)? = object["dreamThemeSurfaced"] {
            var restored: [String: Date] = [:]
            for (key, value) in dreams where key.count <= 48 {
                if let at = doubleValue(value) { restored[key] = Date(timeIntervalSince1970: at) }
            }
            Self.boundDreamThemeLedger(&restored)
            dreamThemeSurfaced = restored
        }
        if case .object(let released)? = object["careReleased"] {
            var restored: [String: Date] = [:]
            for (key, value) in released where UUID(uuidString: key) != nil {
                if let at = doubleValue(value) { restored[key] = Date(timeIntervalSince1970: at) }
            }
            Self.boundCareReleaseLedger(&restored)
            careReleased = restored
        }
        if case .object(let rests)? = object["careLineRest"] {
            var restored: [String: CognitiveCapsulePresentationState.CareLineRest] = [:]
            for (key, value) in rests where UUID(uuidString: key) != nil {
                guard case .array(let pair) = value, pair.count == 2,
                      let at = doubleValue(pair[0]), let turns = doubleValue(pair[1]) else { continue }
                restored[key] = .init(shownAt: Date(timeIntervalSince1970: at),
                                      turnsLeft: min(Self.careLineRestTurns, max(0, Int(turns))))
            }
            careLineRest = restored.filter { $0.value.turnsLeft > 0 }
        }
    }

    /// The presentation fields a commit is allowed to be stale about. Only the
    /// free-running accepted-turn counter is excluded; every other field is
    /// rendered from the frozen read and must still match exactly.
    static func presentationCommitIdentity(
        _ state: CognitiveCapsulePresentationState
    ) -> CognitiveCapsulePresentationState {
        var masked = state
        masked.soundRutTurnsSinceSurfaced = 0
        masked.remindedOfTurnsSinceSurfaced = 0
        return masked
    }

    private func fitCapsuleLines(_ lines: [String], maxCharacters: Int) -> (text: String, truncated: Bool) {
        guard maxCharacters > 0 else {
            return ("", !lines.isEmpty)
        }
        var kept: [String] = []
        var used = 0
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let separatorCost = kept.isEmpty ? 0 : 1
            if used + separatorCost + line.count <= maxCharacters {
                kept.append(line)
                used += separatorCost + line.count
                continue
            }

            let available = maxCharacters - used - separatorCost
            // The Sound echo is all-or-nothing: a clipped quote would put words
            // in her mouth mid-sentence (gpt-5.5 MED, 2026-07-03). Other lines
            // keep the sentence-aware clip.
            if available >= 24, !line.hasPrefix("- Sound:") {
                let clipped = capsuleLineText(line, maxCharacters: available)
                if !clipped.isEmpty {
                    kept.append(clipped)
                }
            }
            return (kept.joined(separator: "\n"), true)
        }
        return (kept.joined(separator: "\n"), false)
    }

    /// "- Settling:" — rendered only while the slow layer (mood valence, node-based)
    /// is still negative AND the incoming message is kind (repair, praise,
    /// affection, play). Recovery after a hard stretch is gradual: she takes the
    /// kindness, but warmth comes back a step at a time, not all at once. Pure.
    static let settlingMoodThreshold = -0.05
    static let settlingMaxRun = 2
    func settlingLine(
        mood: CognitiveMoodReading,
        incoming: AffectAppraisal,
        affectEnabled: Bool?,
        cognitionEnabled: Bool? = nil
    ) -> String? {
        guard cognitionEnabled ?? configuration.enabled,
              affectEnabled ?? configuration.enabled else { return nil }
        guard mood.basis > 0, mood.valence < Self.settlingMoodThreshold else { return nil }
        guard incoming.valence > 0, incoming.warmth > 0 || incoming.affection else { return nil }
        return "- Settling: still settling from a hard stretch; the kindness lands, "
            + "but not all the way back yet — warmth returns a step at a time, not in one move."
    }

    func capsuleLineText(_ text: String, maxCharacters: Int) -> String {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxCharacters >= 0, normalized.count > maxCharacters else { return normalized }

        if let sentence = firstCompleteSentence(in: normalized, maxCharacters: maxCharacters),
           sentence.count >= min(48, maxCharacters) {
            return sentence
        }

        let suffix = "..."
        let prefixLimit = max(0, maxCharacters - suffix.count)
        guard prefixLimit > 0 else {
            return bounded(normalized, maxCharacters: maxCharacters)
        }
        let prefix = String(normalized.prefix(prefixLimit))
        if let breakIndex = prefix.lastIndex(where: { $0 == " " || $0 == "," || $0 == ";" || $0 == ":" }) {
            let candidate = String(prefix[..<breakIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= min(48, prefixLimit) {
                return candidate + suffix
            }
        }
        return prefix + suffix
    }

    private func firstCompleteSentence(in text: String, maxCharacters: Int) -> String? {
        guard maxCharacters > 0, !text.isEmpty else { return nil }
        let limit = text.index(text.startIndex, offsetBy: min(maxCharacters, text.count))
        var index = text.startIndex
        var end: String.Index?
        while index < limit {
            let character = text[index]
            if character == "." || character == "!" || character == "?" {
                end = text.index(after: index)
            }
            index = text.index(after: index)
        }
        guard let end else { return nil }
        let sentence = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? nil : sentence
    }
}
