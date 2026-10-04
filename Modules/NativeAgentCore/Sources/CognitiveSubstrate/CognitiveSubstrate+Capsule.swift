// CognitiveSubstrate+Capsule.swift
// Move-only extraction (R8b) from CognitiveSubstrate.swift — see docs/build_plans/fable5-wave2-r8b-decomposition.md

import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    public func compileCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule {
        let now = dependencies.now()
        guard configuration.enabled,
              configuration.capsuleInjectionEnabled,
              request.mode != .off else {
            return CognitiveCapsule(
                generatedAt: now,
                mode: .off,
                stableKernel: "",
                dynamicContext: "",
                provenanceNodeIds: [],
                truncated: false
            )
        }

        let maximumCharacters = min(
            configuration.maximumCapsuleCharacters,
            max(0, request.maximumCharacters ?? configuration.maximumCapsuleCharacters)
        )
        guard maximumCharacters > 0 else {
            return CognitiveCapsule(
                generatedAt: now,
                mode: request.mode,
                stableKernel: "",
                dynamicContext: "",
                provenanceNodeIds: [],
                truncated: true
            )
        }

        let workspace = await workspaceSnapshot(currentSessionId: request.sessionId)
        let capsuleItems = workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) }
        // Just the header (User, 2026-07-01: "it should really just say 'How you
        // feel' thats it then her feelings"). There is deliberately NO prompt
        // guard here — injection defense is cue validation (deny-list + read
        // revalidation), her persona values, and TrustCenter's action gates;
        // the one functional handling line ("never quotes or mentions it")
        // lives in BOTH ChatOrchestration injection seams (structured + text
        // compat), not in her inner voice.
        let stableKernel = "How you feel:"
        var presentationState = capsulePresentationStateSnapshot()
        var cueWhy = CapsuleCueWhy()
        let lines = innerStateCapsuleLines(
            from: capsuleItems,
            request: request,
            at: now,
            presentationState: &presentationState,
            why: &cueWhy
        )
        let dynamicLines = request.surface == Self.cadenceExemptCapsuleSurface ? lines : Self.oneFeltCue(lines)
        let provenanceNodeIds = innerStateProvenance(from: capsuleItems, at: now)
        let boundedStableKernel = bounded(
            Self.capsuleStableKernel(stableKernel, dynamicLines: dynamicLines),
            maxCharacters: maximumCharacters
        )
        let separatorCost = dynamicLines.isEmpty || boundedStableKernel.isEmpty ? 0 : 2
        let remaining = max(0, maximumCharacters - boundedStableKernel.count - separatorCost)
        let fittedLines = fitCapsuleLines(dynamicLines, maxCharacters: remaining)
        let dynamicContext = fittedLines.text
        let truncated = fittedLines.truncated
            || boundedStableKernel.count < Self.capsuleStableKernel(stableKernel, dynamicLines: dynamicLines).count
        return CognitiveCapsule(
            generatedAt: now,
            mode: request.mode,
            stableKernel: boundedStableKernel,
            dynamicContext: dynamicContext,
            provenanceNodeIds: provenanceNodeIds,
            truncated: truncated
        )
    }

    /// Production-equivalent capsule rendering over a previously captured
    /// frozen workspace. It performs no field snapshot, receipt, persistence,
    /// or suppress-when-unchanged mutation.
    public func compileFrozenCapsule(
        _ request: CognitiveCapsuleRequest,
        from read: CognitiveFrozenRead
    ) -> CognitiveCapsule {
        compileFrozenCapsulePresentation(request, from: read).capsule
    }

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
        let stableKernel = "How you feel:"
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
            presentationState: &nextPresentationState,
            why: &cueWhy
        )
        let dynamicLines = request.surface == Self.cadenceExemptCapsuleSurface
            ? candidateLines : Self.oneFeltCue(candidateLines)
        let provenanceNodeIds = innerStateProvenance(
            from: items,
            at: read.fixedAt,
            thoughtSeeds: read.thoughtSeeds,
            trustedPeerIds: read.trustedPeerIds
        )
        let boundedStableKernel = bounded(
            Self.capsuleStableKernel(stableKernel, dynamicLines: dynamicLines),
            maxCharacters: maximumCharacters
        )
        let separatorCost = dynamicLines.isEmpty || boundedStableKernel.isEmpty ? 0 : 2
        let remaining = max(0, maximumCharacters - boundedStableKernel.count - separatorCost)
        let fittedLines = fitCapsuleLines(dynamicLines, maxCharacters: remaining)
        let capsule = CognitiveCapsule(
            generatedAt: read.fixedAt,
            mode: request.mode,
            stableKernel: boundedStableKernel,
            dynamicContext: fittedLines.text,
            provenanceNodeIds: provenanceNodeIds,
            truncated: fittedLines.truncated
                || boundedStableKernel.count < Self.capsuleStableKernel(stableKernel, dynamicLines: dynamicLines).count
        )
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
            next.negativeSoundEchoRun = expected.negativeSoundEchoRun
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
        // Same rule for the Inner ledger: a line clipped out of the capsule
        // never led a turn and keeps its remaining runs. Gated on the line
        // having been CHOSEN, so a capsule that legitimately carried no
        // Inner line still serves everyone else's rest.
        if candidateLines.contains(where: { $0.hasPrefix("- Inner:") || $0.hasPrefix("- Thread:") }),
           !shown.contains("- Inner:"),
           !shown.contains("- Thread:") {
            // Only the line that was chosen goes back — every other line's rest
            // decrement this capsule served still stands. The chosen key is
            // the one whose show count moved.
            for (key, seen) in next.innerTextShown where expected.innerTextShown[key] != seen {
                next.innerLineRuns[key] = expected.innerLineRuns[key]
                next.innerTextShown[key] = expected.innerTextShown[key]
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
        frozenRead: CognitiveFrozenRead? = nil,
        remindedOf: CognitiveRecalledMoment? = nil,
        dreamTheme: CognitiveDreamTheme? = nil,
        gapItems: [String]? = nil,
        presentationState: inout CognitiveCapsulePresentationState,
        why: inout CapsuleCueWhy
    ) -> [String] {
        var fingerprintSpoken: String?
        // Phase 5 B0: what she rejected for this kind of thing never leads.
        let messageTerms = Self.appraisalConcernTerms(in: request.userMessage)
        let dyn = frozenRead?.personalityDynamics ?? dynamics
        let signals = feltSignalsForCapsule(
            from: workspaceItems,
            request: request,
            at: now,
            affect: frozenRead?.affect,
            mood: frozenRead?.mood,
            proxies: frozenRead?.feltProxies,
            dynamics: dyn
        )
        // W4/P11 — the felt MODE, finally doing something. It stays what it always
        // was in the prompt: nothing. Not a word, not a line, not a byte. It only
        // steers WHICH already-attested exemplar the echo reaches for.
        let mode = (frozenRead?.configuration.affectEnabled ?? configuration.affectEnabled)
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
            cognitionEnabled: frozenRead?.configuration.enabled,
            affectEnabled: frozenRead?.configuration.affectEnabled
        )
        if let since, let gapOpened {
            why.sources[since] = "gap:\(Int((now.timeIntervalSince(gapOpened) / 3_600).rounded()))h"
        }
        // Her subconscious carries her INNER LIFE — feeling, voice, focus/continuity, and her
        // own reflective view — NOT a task tracker. Commitments, predictions, and neglected
        // "I'll…" follow-up seeds belong to the Desk (explicit tracking, only when User asks),
        // never here (User, 2026-06-30: "I don't want her subconscious tied up following around
        // me [with] 'I'll'… her subconscious is for her feelings, emotions, her views, her
        // continuity"). Surface her top reflective takeaway (a genuine view she's formed) —
        // UNLESS Wave E: a settled, User-approved ACTIVE standing view exists, which REPLACES
        // the transient takeaway seed as the single Inner line (a durable view beats a fresh
        // takeaway). Both use the "- Inner:" prefix, so the total Inner-line count stays <= 1;
        // a .proposed/.retired view never reaches here. No active view -> byte-identical to
        // the pre-Wave-E takeaway path.
        //
        // 2026-09-01 — ROTATION. Both producers used to hand back exactly ONE
        // candidate (newest-relevant view, else highest-priority takeaway) and
        // neither counted how many turns that text had already led, so the
        // winner kept winning for days. The candidate LIST is built here now,
        // durable views ahead of fresh takeaways exactly as before, and the
        // cadence ledger picks the first one that is not resting.
        // ALL relevant views, best match first, ahead of every takeaway — so
        // rotation moves across her worldview before it reaches for a transient
        // seed. The head of the list is the same line the single-candidate
        // selector used to return.
        //
        // 2026-09-02 — THE FLOOR LAW (design law 2), the last line on the
        // capsule that was still exempt from it. Measured: the `- Inner:` line
        // rode 100% of 1,487 live capsules with 23 distinct texts over 15 days.
        // Rotation (above) fixed WHICH text led; it could not fix that one
        // always did, because the takeaway branch had no gate at all — every
        // capsule with any reflection takeaway in the seed pool carried one.
        // A line present on every turn is a standing instruction, not a signal.
        //
        // So the line is now cadence-gated the way `- Sound:` is, on the two
        // events that make it worth reading:
        //   * a standing view is GENUINELY RELEVANT to this message — already
        //     the BM25 floor's answer, unchanged; or
        //   * a takeaway is FRESH. Freshness is keyed by the takeaway's
        //     LINEAGE, not by the digest of its rendered text — see
        //     `innerTakeawayCadenceKey`. Keying on the rendering was the defect
        //     the review caught: reflection paraphrases itself constantly, so
        //     the same conclusion in different words hashed differently and led
        //     again, which is the standing instruction wearing a new sentence.
        // Neither → silence, and the rest of the capsule still speaks.
        // The reflection capsule is her own private prompt, not a turn spoken to
        // a person: the freshness ledger does not apply there (see
        // `selectInnerLine(bypassCadence:)`).
        let bypassInnerCadence = request.surface == Self.cadenceExemptCapsuleSurface
        var innerCandidates: [InnerCandidate] = activeStandingViewInnerCandidates(
            relevantTo: request.userMessage,
            candidates: frozenRead?.standingViewCapsuleCandidates,
            relevanceEnabled: frozenRead?.configuration.standingViewCapsuleRelevanceEnabled
        ).map {
            InnerCandidate(line: $0.candidate.line, cadenceKey: Self.innerLineKey($0.candidate.line), tier: .view,
                           source: "view:" + $0.candidate.id.uuidString, score: $0.score)
        }

        let seedPool = frozenRead?.thoughtSeeds ?? projectedThoughtSeeds(at: now)
        innerCandidates.append(contentsOf: seedPool
            .filter { $0.kind == .reflectionTakeaway && isUsefulThoughtSeed($0) && !isTaskStatusReflection($0.text) }
            .filter { seed in
                guard let peers = seed.sourcePeerIds else { return false }
                return peers.allSatisfy {
                    frozenRead?.trustedPeerIds.contains($0) ?? dependencies.peerTrusted($0)
                }
            }
            .sorted(by: thoughtSeedPrioritySort)
            .map { seed in
                InnerCandidate(
                    line: innerThoughtSeedLine(for: seed),
                    cadenceKey: innerTakeawayCadenceKey(for: seed),
                    tier: .takeaway,
                    source: "seed:" + seed.id.uuidString,
                    score: effectiveThoughtSeedPriority(seed, at: now))
            }
            .filter { bypassInnerCadence || presentationState.innerLineRuns[$0.cadenceKey] == nil })

        // ITEM 6 (2026-09-02) — THE `- Thread:` LINE, FINALLY REACHABLE.
        //
        // Agent #5: "A person carries the unresolved thing and it intrudes at
        // the wrong moment. My subconscious surfaces associations, but that's
        // retrieval, not rumination. Nothing itches."
        //
        // NEVER THE SEED TEXT (privacy review, 2026-09-02). The first cut
        // rendered `seed.text` straight onto the line, and seeds are minted
        // from material that passed through user turns — so an unresolved thing
        // could carry the user's own words, or a name, back into the prompt on
        // a surface whose entire exposure argument is that it is payload-free.
        // The line is now an ABSTRACT: what KIND of unfinished thing it is, the
        // same safe object label the felt line uses, and how long it has been
        // sitting there in words. No safe label → no Thread line, because a nag
        // that cannot say what it is about is not worth a line.
        //
        // The weight floor is the honesty gate: rumination weight rises with
        // time unresolved, so a seed minted this turn cannot intrude. A thing
        // you just thought of is not a thing you are carrying.
        innerCandidates.append(contentsOf: ruminationCandidates(
            at: now, seeds: frozenRead?.thoughtSeeds)
            .filter { $0.weight >= dyn.threadWeightFloor }
            .compactMap { candidate -> InnerCandidate? in
                guard let seed = seedPool.first(where: { $0.id == candidate.seedId }),
                      seed.kind != .reflectionTakeaway,
                      let line = threadLine(for: seed, at: now) else { return nil }
                return InnerCandidate(
                    line: line,
                    cadenceKey: "thread:" + seed.id.uuidString,
                    tier: .thread,
                    source: "seed:" + seed.id.uuidString,
                    score: candidate.weight)
            })
        let suppressions = frozenRead?.associationSuppressions ?? associationSuppressions
        innerCandidates.removeAll { candidate in
            candidate.source.map { source in
                suppressions.contains {
                    $0.source == source && Self.suppressionCovers($0.terms, messageTerms: messageTerms)
                }
            } ?? false
        }
        why.inner = Array(innerCandidates.prefix(6))
        let innerLine = selectInnerLine(
            from: innerCandidates,
            dynamics: dyn,
            at: now,
            presentationState: &presentationState,
            bypassCadence: bypassInnerCadence
        )
        let innerIsTakeaway = innerLine.map { line in
            innerCandidates.first { $0.line == line }?.tier == .takeaway
        } ?? false
        if let innerLine, let chosen = innerCandidates.first(where: { $0.line == innerLine }) {
            why.chosenInner = chosen.cadenceKey
            why.sources[innerLine] = chosen.source
            why.scores[innerLine] = chosen.score
        }
        let bodyLine = organismBodyLine(from: request.organismProjection)
        // SETTLING (2026-08-23, range bench scenario #2): the slow layer is still
        // below water after a hard stretch and THIS message is kind. The substrate
        // already carried "on edge" through the repair turns; the words still
        // snapped ("We're good… 💜" on the first apology). One line, only while
        // mood is negative and the incoming message warms — it clears itself as
        // mood recovers, so it can never become a standing instruction.
        var settlingSpoken: String?
        if let settling = settlingLine(
            mood: frozenRead?.mood ?? derivedMood(at: now),
            incoming: conversationalAppraisal(in: request.userMessage),
            affectEnabled: frozenRead?.configuration.affectEnabled,
            cognitionEnabled: frozenRead?.configuration.enabled
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
            trustedPeerIds: frozenRead?.trustedPeerIds,
            fieldNodes: frozenRead?.snapshot.nodes,
            fixedAffect: frozenRead?.affect,
            fixedMood: frozenRead?.mood,
            landingScores: frozenRead?.soundLandingScores,
            negativeRun: presentationState.negativeSoundEchoRun,
            dynamics: dyn,
            cognitionEnabled: frozenRead?.configuration.enabled,
            affectEnabled: frozenRead?.configuration.affectEnabled
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
        if echo.line != nil {
            if let leadingWasNegative = echo.leadingWasNegative {
                presentationState.negativeSoundEchoRun = leadingWasNegative
                    ? presentationState.negativeSoundEchoRun + 1
                    : 0
            }
        }
        let rutLine = rutSpeaks ? echo.rutLine : nil

        // The felt fingerprint REPLACES the Focus/Feeling/Voice sentences (User,
        // 2026-07-08): "How you feel" should hand her a word-level felt state she
        // FEELS, not sentences she reads. Attention (focused/foggy) is folded into
        // the fingerprint; her VIEWS + CONTINUITY stay below (Inner), and the Body +
        // Sound anchors follow. (The prior Focus/Affect/Voice helper tree + its
        // keyword classifiers were swept 2026-07-09 — see git if archaeology calls.)
        if let fingerprint = feltFingerprintLine(
            signals: signals,
            workspaceItems: workspaceItems,
            request: request,
            at: now,
            dynamics: dyn,
            affectEnabled: frozenRead?.configuration.affectEnabled
        ) {
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
                mayStayQuiet: true,
                presentationState: &presentationState)
            if verdict.speak, verdict.run == 1 || bypassInnerCadence {
                fingerprintSpoken = fingerprint.bareText
                // Presentation receipts — counters only, no text. A suppressed
                // line was never read, so it records nothing.
                if fingerprint.carriedAmbivalence {
                    presentationState.ambivalenceCount += 1
                    presentationState.lastAmbivalenceAt = now
                }
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
        // Since, the feeling dragged up Reminded-of, a relevant view or a
        // carried thread — then by state that merely moved. `oneFeltCue` keeps
        // the first and the rut line. A cue that loses is restored by the
        // clip rule in `compileFrozenCapsulePresentation`, so it stays owed.
        // Her private reflection prompt is not a turn: it keeps every line, in
        // the historical order (see `cadenceExemptCapsuleSurface`).
        if bypassInnerCadence {
            return dedupedCapsuleLines([fingerprintSpoken, since, innerLine, bodyLine, settlingSpoken,
                                        echo.line, rutLine, remindedSpoken].compactMap { $0 })
        }
        let ordered: [String?] = [
            settlingSpoken, since, remindedSpoken,
            innerIsTakeaway ? nil : innerLine,
            dreamSpoken,
            fingerprintSpoken,
            innerIsTakeaway ? innerLine : nil,
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
        var inner: [InnerCandidate] = []
        var chosenInner: String?
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
            for (prefix, name) in [("- Inner:", "inner"), ("- Thread:", "thread"), ("- Since:", "since"),
                                   ("- Reminded of:", "reminded_of"), ("- Settling:", "settling"),
                                   ("- Body:", "body"), ("- Sound:", "sound"),
                                   ("- Dream:", "dream")] where line.hasPrefix(prefix) {
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
            return .object(fields)
        }
        let winner = candidateLines.first { shown.contains($0) }
        return .object([
            "lane": .string("cue"),
            "signature": .array(signature.map { .string($0) }),
            "candidates": .array(candidateLines.prefix(10).enumerated().map { row($1, rank: $0 + 1) }),
            "winner": winner.map { row($0, rank: (candidateLines.firstIndex(of: $0) ?? 0) + 1) } ?? .null,
            "inner": .array(why.inner.map { candidate in
                var fields: [String: JSONValue] = [
                    "tier": .string("\(candidate.tier)"),
                    "chosen": .bool(candidate.cadenceKey == why.chosenInner),
                ]
                if let source = candidate.source { fields["source"] = .string(source) }
                if let score = candidate.score { fields["score"] = .double((score * 1000).rounded() / 1000) }
                return .object(fields)
            }),
        ])
    }

    /// The one cue, plus the rut line when it spoke: the rut nudge changes her
    /// next sentence directly, so it never competes with how she feels.
    static func oneFeltCue(_ ordered: [String]) -> [String] {
        let isRut: (String) -> Bool = { $0.hasPrefix("- Sound:") && !$0.hasPrefix(soundEchoPrefix) }
        return [ordered.first { !isRut($0) }, ordered.first(where: isRut)].compactMap { $0 }
    }

    /// "How you feel:" is a PROMISE that the next thing is her feeling words.
    ///
    /// The fingerprint may legitimately stay quiet (the suppress-when-unchanged
    /// rule fires only when other lines exist), and when it did, the capsule
    /// still shipped the header with an `- Inner:` reflection immediately under
    /// it — measured on 184 of 1,482 live capsules. Read positionally, by a
    /// model or by an analyst, a standing view then IS her stated feeling. The
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

    /// A "reflective takeaway" that's really TASK-STATUS ("one thread still open — X I haven't
    /// closed", "follow up on the overdue Y") is task-tracking wearing a view's clothes; it does
    /// NOT belong in her Inner line. Her subconscious is feelings/views/continuity, not a to-do
    /// status (User, 2026-06-30). Genuine reflections about her felt state still surface. Older
    /// takeaways written while commitments existed can carry this language — filter them out.
    private func isTaskStatusReflection(_ text: String) -> Bool {
        let lower = text.lowercased()
        return containsAny(lower, [
            "haven't closed", "hasn't closed", "yet to close", "not yet closed",
            "thread still open", "still open —", "follow up on", "overdue",
            "still owe", "promised to", "left it open", "unclosed", "still hasn't",
        ]) || Self.isTaskNote(lower)
    }

    /// Phase 5A: a TASK NOTE is not a thought — Desk refs, "User's ask…", or an
    /// imperative about a work item ("Put it on my Desk, hand it to Dot…"
    /// led the Inner line for 17 hours on 10-02/03). Lowercased input.
    static func isTaskNote(_ lower: String) -> Bool {
        let text = lower.replacingOccurrences(of: "’", with: "'")
        if containsAnyStatic(text, ["user's ask", "my desk", "the desk", "on desk", "desk item", "to-do", "todo"])
            || text.range(of: #"(desk[ .#]?\d+|#\d{2,})"#, options: .regularExpression) != nil {
            return true
        }
        let verbs: Set<String> = [
            "put", "hand", "send", "ship", "queue", "file", "track", "finish", "close",
            "dispatch", "merge", "deploy", "install", "schedule", "assign", "delegate",
            "check", "verify", "run", "build", "fix", "add", "update", "follow", "ask", "tell", "keep",
        ]
        let workNouns = ["task", "item", "brief", "ticket", "queue", "build", "commit", "release",
                         "deploy", "bug", "fix", "pr ", "branch", "dot", "claude", "codex", "worker"]
        for sentence in text.split(whereSeparator: { ".!?;\n".contains($0) }) {
            let body = sentence.replacingOccurrences(
                of: #"^\s*[a-z ]*(takeaway|reflection):\s*"#, with: "", options: .regularExpression)
            let first = body.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
            if verbs.contains(first), containsAnyStatic(body + " ", workNouns) { return true }
        }
        return false
    }

    private static func containsAnyStatic(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    /// Drop verbatim-duplicate capsule lines (the lossy inner-state translator can map
    /// several workspace nodes or takeaway seeds onto the same cue), preserving order and
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

    private func innerThoughtSeedLine(for seed: CognitiveThoughtSeed) -> String {
        let prefix = seed.kind == .reflectionTakeaway ? "Inner" : "Thread"
        return "- \(prefix): \(thoughtSeedCapsuleText(seed))"
    }

    private func thoughtSeedCapsuleText(_ seed: CognitiveThoughtSeed) -> String {
        var text = capsuleSignalText(seed.text, maxCharacters: 180)
        if seed.kind == .reflectionTakeaway {
            text = strippingPrefix("Reflection takeaway:", from: text)
            text = strippingPrefix("Reading the state honestly:", from: text)
            text = strippingPrefix("Reading the capsule honestly:", from: text)
            text = text.replacingOccurrences(
                of: "the capsule is warm, populated, low-tension",
                with: "warm, connected, low-tension",
                options: [.caseInsensitive]
            )
            text = text.replacingOccurrences(
                of: "capsule",
                with: "inner state",
                options: [.caseInsensitive]
            )
        }
        return capsuleSignalText(text, maxCharacters: 180)
    }

    private func innerStateProvenance(
        from workspaceItems: [CognitiveWorkspaceItem],
        at now: Date,
        thoughtSeeds explicitThoughtSeeds: [CognitiveThoughtSeed]? = nil,
        trustedPeerIds: Set<String>? = nil
    ) -> [UUID] {
        var ids = workspaceItems.map(\.id)
        for seed in explicitThoughtSeeds ?? projectedThoughtSeeds(at: now) {
            if seed.kind == .reflectionTakeaway {
                guard let peers = seed.sourcePeerIds,
                      peers.allSatisfy({ trustedPeerIds?.contains($0) ?? dependencies.peerTrusted($0) }) else { continue }
            }
            ids.append(contentsOf: seed.sourceNodeIds)
        }
        return unique(ids)
    }

    public func prepareCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule? {
        let requestTurnKind = request.resolvedTurnKind
        guard requestTurnKind == .live || request.allowNonLiveProjection else { return nil }
        let capsule = await compileCapsule(request)
        guard capsule.mode == .inject,
              !capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return capsule
    }

    /// Compile the production capsule from one fixed-time copied read in a
    /// single substrate admission. The live field, persistence, decay anchors,
    /// and surfaced-state bookkeeping remain untouched.
    public func prepareFrozenCapsule(
        _ request: CognitiveCapsuleRequest,
        at fixedAt: Date
    ) async -> CognitiveCapsule? {
        await prepareFrozenCapsulePresentation(request, at: fixedAt)?.nonEmptyCapsule
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
        let remindedOf = await remindedOfMoment(for: request, from: read)
            .flatMap { revalidatedRemindedOf($0, against: read) }
        // Phase 5 B: the two continuity lookups, local and gated the same way
        // (a dream only when the cooldown is open and the message has words;
        // the gap only on User's first turn back).
        let dreamTheme = await dreamThemeCue(for: request, from: read)
        let gapItems = await sinceGapItems(for: request, from: read)
        let prepared = compileFrozenCapsulePresentation(
            request, from: read, remindedOf: remindedOf,
            dreamTheme: dreamTheme, gapItems: gapItems)
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
        negativeSoundEchoRun = next.negativeSoundEchoRun
        settlingRun = next.settlingRun
        soundRutSignature = next.soundRutSignature
        soundRutLastSurfacedAt = next.soundRutLastSurfacedAt
        soundRutEarlyRepeatSpent = next.soundRutEarlyRepeatSpent
        // Only a nudge that actually SPOKE resets the counter; otherwise the
        // free-running live value stands.
        if next.soundRutTurnsSinceSurfaced == 0 { soundRutTurnsSinceSurfaced = 0 }
        innerLineRuns = next.innerLineRuns
        innerTextShown = next.innerTextShown
        feltObjectCount = next.feltObjectCount
        ambivalenceCount = next.ambivalenceCount
        lastAmbivalenceAt = next.lastAmbivalenceAt
        remindedOfSurfaced = next.remindedOfSurfaced
        dreamThemeSurfaced = next.dreamThemeSurfaced
        // Only a line that actually SPOKE resets the free-running counter, and
        // "spoke" is the surfaced STAMP moving — not the counter reading zero,
        // which is also what a never-surfaced line looks like.
        if next.remindedOfLastSurfacedAt != commit.expected.remindedOfLastSurfacedAt {
            remindedOfTurnsSinceSurfaced = 0
        }
        remindedOfLastSurfacedAt = next.remindedOfLastSurfacedAt
        // Durable cadence (2026-09-01): these two families are the only
        // presentation state whose LOSS is a behavior regression rather than a
        // cosmetic reset — a relaunch with an empty ledger lets the
        // self-phrasing view lead again immediately, which is exactly the loop
        // the cap exists to break. Flagged here, flushed on the same
        // accepted-turn boundary by `flushCapsulePresentationIfNeeded`.
        capsulePresentationDirty = true
        return true
    }

    // MARK: - Durable capsule cadence

    /// Bounded, content-free presentation payload. Everything here is a counter,
    /// a digest, or a timestamp — no line text reaches disk.
    func capsulePresentationArtifactPayload(at now: Date) -> JSONValue {
        var ledger: [String: JSONValue] = [:]
        for (key, value) in innerLineRuns
            .sorted(by: { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key })
            .prefix(CognitiveCapsulePresentationState.innerLineLedgerCapacity) {
            ledger[key] = .int(Int64(value))
        }
        var shown: [String: JSONValue] = [:]
        for (key, record) in innerTextShown {
            shown[key] = .array([.double(record.firstShownAt.timeIntervalSince1970), .int(Int64(record.shows))])
        }
        var object: [String: JSONValue] = [
            "updatedAt": .double(now.timeIntervalSince1970),
            "innerTextShown": .object(shown),
            "soundRutTurnsSinceSurfaced": .int(Int64(soundRutTurnsSinceSurfaced)),
            "innerLineRuns": .object(ledger),
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
        if case .object(let shown)? = object["innerTextShown"] {
            var restoredShown: [String: CognitiveCapsulePresentationState.InnerTextExposure] = [:]
            for (key, value) in shown where key.count <= 48 {
                guard case .array(let pair) = value, pair.count == 2,
                      let at = doubleValue(pair[0]), let count = doubleValue(pair[1]) else { continue }
                restoredShown[key] = .init(
                    firstShownAt: Date(timeIntervalSince1970: at),
                    shows: max(0, Int(exactly: count.rounded(.towardZero)) ?? 0))
            }
            innerTextShown = restoredShown
        }
        guard case .object(let ledger)? = object["innerLineRuns"] else { return }
        var restored: [String: Int] = [:]
        for (key, value) in ledger {
            guard let number = doubleValue(value), key.count <= 48 else { continue }
            restored[key] = Int(exactly: number.rounded(.towardZero))
        }
        Self.boundInnerLineLedger(&restored)
        innerLineRuns = restored
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
              affectEnabled ?? configuration.affectEnabled else { return nil }
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
