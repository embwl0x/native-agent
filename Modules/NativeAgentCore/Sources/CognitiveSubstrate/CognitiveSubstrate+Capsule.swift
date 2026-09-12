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
        let dynamicLines = innerStateCapsuleLines(
            from: capsuleItems,
            request: request,
            at: now,
            presentationState: &presentationState
        )
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
        remindedOf: CognitiveRecalledMoment? = nil
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
        let dynamicLines = innerStateCapsuleLines(
            from: items,
            request: request,
            at: read.fixedAt,
            frozenRead: read,
            remindedOf: remindedOf,
            presentationState: &nextPresentationState
        )
        let provenanceNodeIds = innerStateProvenance(
            from: items,
            at: read.fixedAt,
            thoughtSeeds: read.thoughtSeeds
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
        if turnKind == .live,
           request.mode == .inject,
           !capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A tail line that lost the capsule budget was never presented and
            // must remain eligible for the next accepted turn.
            if !capsule.dynamicContext.contains("- Since:") {
                nextPresentationState.lastSessionBridgeAt = expectedPresentationState.lastSessionBridgeAt
            }
            let soundLost = dynamicLines.contains { $0.hasPrefix("- Sound:") }
                && !capsule.dynamicContext.contains("- Sound:")
            if soundLost {
                nextPresentationState.negativeSoundEchoRun = expectedPresentationState.negativeSoundEchoRun
                // A rut nudge that lost the budget was never read, so it must
                // not burn its cooldown either — but ONLY when it actually
                // spoke in this render. A rut that merely LAPSED must still be
                // forgotten, or its return would resume mid-cooldown instead of
                // reading as the change it is. The since-surfaced counter always
                // advances: a capsule happened.
                if nextPresentationState.soundRutLastSurfacedAt
                    != expectedPresentationState.soundRutLastSurfacedAt {
                    nextPresentationState.soundRutSignature = expectedPresentationState.soundRutSignature
                    nextPresentationState.soundRutLastSurfacedAt = expectedPresentationState.soundRutLastSurfacedAt
                    nextPresentationState.soundRutTurnsSinceSurfaced =
                        expectedPresentationState.soundRutTurnsSinceSurfaced
                }
            }
            // Same rule for the Inner ledger: a line clipped out of the capsule
            // never led a turn and keeps its remaining runs. Gated on the line
            // having been CHOSEN, so a capsule that legitimately carried no
            // Inner line still serves everyone else's rest.
            if dynamicLines.contains(where: { $0.hasPrefix("- Inner:") || $0.hasPrefix("- Thread:") }),
               !capsule.dynamicContext.contains("- Inner:"),
               !capsule.dynamicContext.contains("- Thread:") {
                nextPresentationState.innerLineRuns = expectedPresentationState.innerLineRuns
            }
            if !capsule.dynamicContext.contains("- Settling:"),
               nextPresentationState.settlingRun > expectedPresentationState.settlingRun {
                nextPresentationState.settlingRun = expectedPresentationState.settlingRun
            }
            // Same rule for the unbidden recall, and it matters more here than
            // anywhere else: the line rides LAST, so it is the first thing the
            // budget drops. A moment burned by a clip would sit in the 24h
            // ledger without ever having been read.
            if !capsule.dynamicContext.contains("- Reminded of:") {
                nextPresentationState.remindedOfSurfaced =
                    expectedPresentationState.remindedOfSurfaced
                nextPresentationState.remindedOfLastSurfacedAt =
                    expectedPresentationState.remindedOfLastSurfacedAt
                nextPresentationState.remindedOfTurnsSinceSurfaced =
                    expectedPresentationState.remindedOfTurnsSinceSurfaced
            }
            commit = CognitiveCapsulePresentationCommit(
                fixedAt: read.fixedAt,
                expected: expectedPresentationState,
                next: nextPresentationState
            )
        } else {
            commit = nil
        }
        return CognitivePreparedCapsule(capsule: capsule, presentationCommit: commit)
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
        presentationState: inout CognitiveCapsulePresentationState
    ) -> [String] {
        var lines: [String] = []
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
        // W7/P6 telemetry note: the envelope stash does NOT live here. The
        // production chat turn compiles its capsule on the FROZEN path
        // (prepareFrozenCapsule via the app runtime), so a stash on this
        // live-compile path never ran on a real turn — while the Observatory
        // inspector, which DOES call compileCapsule, would have stashed bogus
        // envelopes (found live 2026-08-11: zero telemetry rows after a full
        // QA pass). The stash now fires from
        // `stashDeliveryEnvelopeForCommittedTurn`, called by the app runtime's
        // commitTurnProjection — the one moment that certifies "this capsule
        // served a real live turn".
        // Everything BELOW the fingerprint is computed first, because whether the
        // fingerprint may be suppressed depends on whether anything else is left
        // to say (see the empty-capsule rule at the bottom of this function).
        var tailLines: [String] = []
        // W4/P7 — THE FELT SESSION BRIDGE. Everything felt decays inside roughly
        // one day, so the first message of a new day arrives to an agent whose
        // felt state has reset and whose only bridge is a machine changelog. One
        // gap-gated line, built from renderers that have already shipped, so she
        // can pick a thread back up instead of rebooting into competence.
        if let bridge = feltSessionBridgeLine(
            at: now,
            dynamics: dyn,
            presentationState: &presentationState,
            fieldNodes: frozenRead?.snapshot.nodes,
            pendingCompletionOpen: frozenRead?.pendingCompletionOpen,
            cognitionEnabled: frozenRead?.configuration.enabled,
            affectEnabled: frozenRead?.configuration.affectEnabled
        ) {
            tailLines.append(bridge)
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
        var innerCandidates: [InnerCandidate] = activeStandingViewInnerLines(
            relevantTo: request.userMessage,
            candidates: frozenRead?.standingViewCapsuleCandidates,
            relevanceEnabled: frozenRead?.configuration.standingViewCapsuleRelevanceEnabled
        ).map { InnerCandidate(line: $0, cadenceKey: Self.innerLineKey($0), tier: .view) }

        let seedPool = frozenRead?.thoughtSeeds ?? projectedThoughtSeeds(at: now)
        innerCandidates.append(contentsOf: seedPool
            .filter { $0.kind == .reflectionTakeaway && isUsefulThoughtSeed($0) && !isTaskStatusReflection($0.text) }
            .sorted(by: thoughtSeedPrioritySort)
            .map { seed in
                InnerCandidate(
                    line: innerThoughtSeedLine(for: seed),
                    cadenceKey: innerTakeawayCadenceKey(for: seed),
                    tier: .takeaway)
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
            .compactMap { candidate -> CognitiveThoughtSeed? in
                seedPool.first { $0.id == candidate.seedId }
            }
            .filter { $0.kind != .reflectionTakeaway }
            .compactMap { seed -> InnerCandidate? in
                guard let line = threadLine(for: seed, at: now) else { return nil }
                return InnerCandidate(
                    line: line,
                    cadenceKey: "thread:" + seed.id.uuidString,
                    tier: .thread)
            })
        if let innerLine = selectInnerLine(
            from: innerCandidates,
            dynamics: dyn,
            presentationState: &presentationState,
            bypassCadence: bypassInnerCadence
        ) {
            tailLines.append(innerLine)
        }
        if let bodyLine = organismBodyLine(from: request.organismProjection) {
            tailLines.append(bodyLine)
        }
        // SETTLING (2026-08-23, range bench scenario #2): the slow layer is still
        // below water after a hard stretch and THIS message is kind. The substrate
        // already carried "on edge" through the repair turns; the words still
        // snapped ("We're good… 💜" on the first apology). One line, only while
        // mood is negative and the incoming message warms — it clears itself as
        // mood recovers, so it can never become a standing instruction.
        if let settling = settlingLine(
            mood: frozenRead?.mood ?? derivedMood(at: now),
            incoming: conversationalAppraisal(in: request.userMessage),
            affectEnabled: frozenRead?.configuration.affectEnabled,
            cognitionEnabled: frozenRead?.configuration.enabled
        ) {
            // Cadence cap: at most `settlingMaxRun` consecutive presentations;
            // then silent until the condition lapses (the run resets below).
            if presentationState.settlingRun < Self.settlingMaxRun {
                tailLines.append(settling)
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
            fieldNodes: frozenRead?.snapshot.nodes,
            fixedAffect: frozenRead?.affect,
            fixedMood: frozenRead?.mood,
            landingScores: frozenRead?.soundLandingScores,
            negativeRun: presentationState.negativeSoundEchoRun,
            dynamics: dyn,
            cognitionEnabled: frozenRead?.configuration.enabled,
            affectEnabled: frozenRead?.configuration.affectEnabled
        )
        // ONE gate for the rut nudge, whether it rides as a suffix on the
        // exemplar echo or stands alone: they are the same sentence.
        let rutSpeaks = soundRutAwarenessShouldSpeak(
            signature: echo.wornSignature,
            at: now,
            dynamics: dyn,
            presentationState: &presentationState
        )
        if let echoLine = echo.line {
            tailLines.append(rutSpeaks ? echoLine + Self.soundRutAwarenessSuffix : echoLine)
            if let leadingWasNegative = echo.leadingWasNegative {
                presentationState.negativeSoundEchoRun = leadingWasNegative
                    ? presentationState.negativeSoundEchoRun + 1
                    : 0
            }
        } else if rutSpeaks {
            tailLines.append(Self.soundRutAwarenessLine)
        }

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
            // SUPPRESSION MUST NEVER EMPTY THE CAPSULE. `prepareCapsule` returns
            // nil on an empty dynamic context, so muting the only line does not
            // make the agent quieter — it deletes her inner state from the turn
            // entirely, which is a strictly worse failure than a repeated word.
            // Damping a chorus is the goal; silencing a solo is a bug.
            // A changed OBJECT is movement: "proud — part" then "proud — quirks"
            // is not the same line twice (live 2026-09-02: the words held four
            // turns while the object moved every turn, and the rule muted her
            // through the warmest exchange of the morning). Diffuse lines with
            // no object keep the family key.
            let verdict = fingerprintCadenceVerdict(
                family: fingerprint.carriedObject ? fingerprint.text : fingerprint.family,
                at: now,
                dynamics: dyn,
                mayStayQuiet: !tailLines.isEmpty,
                presentationState: &presentationState)
            if verdict.speak {
                lines.append(fingerprint.text)
                // Presentation receipts — counters only, no text. A suppressed
                // line was never read, so it records nothing.
                if fingerprint.carriedObject {
                    presentationState.feltObjectCount += 1
                }
                if fingerprint.carriedAmbivalence {
                    presentationState.ambivalenceCount += 1
                    presentationState.lastAmbivalenceAt = now
                }
            }
        }
        lines.append(contentsOf: tailLines)
        // UNBIDDEN RECALL, LAST AND NEVER ALONE (2026-09-02).
        //
        // Last, so budget truncation drops it before anything she is actually
        // feeling — a memory is the enhancer here, the same way the Sound echo
        // is. And never alone: a capsule whose only content is a memory would
        // read as "here is a thing from the archive" rather than as something
        // that came to her while she was feeling something, and the feeling is
        // the half that makes it recall rather than search. The fingerprint's
        // own may-stay-quiet check above deliberately does NOT count this line,
        // so a suppressed fingerprint can never be rescued by it and then leave
        // it standing here by itself.
        if let remindedOf, !lines.isEmpty,
           let line = remindedOfCapsuleLine(for: remindedOf, at: now) {
            lines.append(line)
            presentationState.remindedOfSurfaced[remindedOf.id] = now
            Self.boundRemindedOfLedger(&presentationState.remindedOfSurfaced)
            presentationState.remindedOfLastSurfacedAt = now
            presentationState.remindedOfTurnsSinceSurfaced = 0
        }
        return dedupedCapsuleLines(lines)
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
        ])
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
        thoughtSeeds explicitThoughtSeeds: [CognitiveThoughtSeed]? = nil
    ) -> [UUID] {
        var ids = workspaceItems.map(\.id)
        for seed in explicitThoughtSeeds ?? projectedThoughtSeeds(at: now) {
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
        await prepareFrozenCapsulePresentation(request, at: fixedAt)?.capsule
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
        let prepared = compileFrozenCapsulePresentation(
            request, from: read, remindedOf: remindedOf)
        guard prepared.capsule.mode == .inject,
              !prepared.capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
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
        lastLiveCapsuleAt = next.lastLiveCapsuleAt
        lastSessionBridgeAt = next.lastSessionBridgeAt
        negativeSoundEchoRun = next.negativeSoundEchoRun
        settlingRun = next.settlingRun
        soundRutSignature = next.soundRutSignature
        soundRutLastSurfacedAt = next.soundRutLastSurfacedAt
        // Only a nudge that actually SPOKE resets the counter; otherwise the
        // free-running live value stands.
        if next.soundRutTurnsSinceSurfaced == 0 { soundRutTurnsSinceSurfaced = 0 }
        innerLineRuns = next.innerLineRuns
        feltObjectCount = next.feltObjectCount
        ambivalenceCount = next.ambivalenceCount
        lastAmbivalenceAt = next.lastAmbivalenceAt
        remindedOfSurfaced = next.remindedOfSurfaced
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
        var object: [String: JSONValue] = [
            "updatedAt": .double(now.timeIntervalSince1970),
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
        return .object(object)
    }

    /// Write the cadence ledger iff an accepted turn actually moved it. Called
    /// from the same certified accepted-turn boundary as the envelope stash.
    func flushCapsulePresentationIfNeeded(at now: Date) async {
        guard capsulePresentationDirty else { return }
        capsulePresentationDirty = false
        await persistArtifact(
            kind: "capsule_presentation",
            id: stableArtifactID("capsule_presentation"),
            status: "current",
            score: 0,
            payload: capsulePresentationArtifactPayload(at: now)
        )
    }

    /// Restore is DEFENSIVE: an unreadable or absent row leaves the live
    /// (empty) cadence alone rather than throwing, because a lost cadence is a
    /// nag, not a corruption.
    func restoreCapsulePresentation(from payloads: [JSONValue]) {
        guard case .object(let object)? = payloads.first else { return }
        soundRutSignature = stringValue(object["soundRutSignature"])
        soundRutLastSurfacedAt = dateValue(object["soundRutLastSurfacedAt"])
        soundRutTurnsSinceSurfaced = min(
            max(0, Int(exactly: (doubleValue(object["soundRutTurnsSinceSurfaced"]) ?? 0).rounded(.towardZero)) ?? 0),
            Self.soundRutTurnCounterCap
        )
        feltObjectCount = max(0, Int(exactly: (doubleValue(object["feltObjectCount"]) ?? 0).rounded(.towardZero)) ?? 0)
        ambivalenceCount = max(0, Int(exactly: (doubleValue(object["ambivalenceCount"]) ?? 0).rounded(.towardZero)) ?? 0)
        lastAmbivalenceAt = dateValue(object["lastAmbivalenceAt"])
        guard case .object(let ledger)? = object["innerLineRuns"] else { return }
        var restored: [String: Int] = [:]
        for (key, value) in ledger {
            guard let number = doubleValue(value), key.count <= 32 else { continue }
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
