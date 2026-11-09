import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `CognitiveSubstrate+Capsule.swift` | `CognitiveSubstrate`: frozen cues, shared presence and presentation commits |

extension CognitiveSubstrate {
    /// Pure frozen render plus the presentation mutation that would become valid only if this exact capsule is accepted into provider context.
    public func compileFrozenCapsulePresentation(
        _ request: CognitiveCapsuleRequest,
        from read: CognitiveFrozenRead,
        remindedOf: CognitiveRecalledMoment? = nil,
        dreamTheme: CognitiveDreamTheme? = nil,
        gapItems: [String]? = nil,
        turn: Turn?
    ) -> CognitivePreparedCapsule {
        compileFrozenCapsulePresentation(
            request, from: read, remindedOf: remindedOf, dreamTheme: dreamTheme,
            gapItems: gapItems, careCue: nil, felt: nil,
            dreamFeeling: dreamFeelingFrame(at: read.fixedAt, sleep: request.sleepDream), unreadable: [], turn: turn)
    }

    private func compileFrozenCapsulePresentation(
        _ request: CognitiveCapsuleRequest,
        from read: CognitiveFrozenRead,
        remindedOf: CognitiveRecalledMoment?,
        dreamTheme: CognitiveDreamTheme?,
        gapItems: [String]?,
        careCue: CognitiveCareCue?,
        felt: (signals: FeltSignals, fingerprint: FeltLineRender?)?,
        dreamFeeling: String,
        unreadable: [String],
        turn: Turn?
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
        // Feeling leads; intentions and voice have their own place beside one continuity cue.
        var cueWhy = CapsuleCueWhy()
        let expression = innerStateCapsuleLines(
            from: items,
            request: request,
            at: read.fixedAt,
            frozenRead: read,
            remindedOf: remindedOf,
            dreamTheme: dreamTheme,
            gapItems: gapItems,
            careCue: careCue,
            felt: felt,
            dreamFeeling: dreamFeeling,
            presentationState: &nextPresentationState,
            why: &cueWhy,
            turn: turn
        )
        let candidateLines = expression.lines
        // Who she is, every live turn: one trait she has shown and who she is with this person, outside the felt-cue competition.
        let selfReading: CognitiveTurnSelf? = request.mode == .inject && request.resolvedTurnKind == .live
            ? turnSelf(for: request.speaker, from: read, among: Self.capsuleReachableCares(for: request, from: read)) : nil
        let selfLines = [selfReading?.trait.map { "- Who you are: " + $0 }, selfReading?.withPerson.map { "- With them: " + $0 }]
            .compactMap { $0 }
        // A held self-choice is the frame of expression, so cue cadence cannot make it vanish mid-stretch.
        let registerLine = read.affect.chosenRegister.flatMap { chosen -> String? in
            guard chosen.isActive(in: request.sessionId, at: read.fixedAt) else { return nil }
            return "Your chosen register: " + capsuleLineText(chosen.choice.name, maxCharacters: 80) + "."
        }
        let dynamicLines = [registerLine].compactMap { $0 } + Self.capsulePresentationLines(candidateLines, surface: request.surface)
            + selfLines
            + Array(Set(unreadable + [selfReading?.unavailable].compactMap { $0 })).sorted().map(Self.unreadableCueLine)
        let capsule = assembledCapsule(
            request, at: read.fixedAt, dynamicLines: dynamicLines,
            feelingFrame: expression.frame,
            workspaceItems: items,
            maximumCharacters: maximumCharacters)
        let turnKind = request.resolvedTurnKind
        let commit: CognitiveCapsulePresentationCommit?
        // Empty accepted capsules still commit so gap and rest counters advance through quiet turns.
        if turnKind == .live, request.mode == .inject {
            Self.keepUnshownCuesOwed(
                candidateLines: candidateLines,
                shown: capsule.dynamicContext,
                expected: expectedPresentationState,
                next: &nextPresentationState)
            commit = CognitiveCapsulePresentationCommit(
                mindEpoch: read.mindEpoch,
                fixedAt: read.fixedAt,
                expected: expectedPresentationState,
                next: nextPresentationState,
                feelingFrameShown: capsule.feelingFrame != nil
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
        feelingFrame: CognitiveFeelingFrame,
        workspaceItems: [CognitiveWorkspaceItem],
        maximumCharacters: Int
    ) -> CognitiveCapsule {
        let fittedLines = fitCapsuleLines(dynamicLines, maxCharacters: maximumCharacters)
        return CognitiveCapsule(
            generatedAt: now,
            mode: request.mode,
            stableKernel: "",
            dynamicContext: fittedLines.text,
            provenanceNodeIds: unique(workspaceItems.map(\.id)),
            truncated: fittedLines.truncated,
            sourcePeerIds: CognitiveReflectionCause.unionPeerIds(workspaceItems.map {
                Self.peerIdentity(metadata: $0.node.metadata, dataRoot: conversationDataRoot).map { [$0] } ?? []
            }),
            feelingFrame: fittedLines.text.contains(feelingFrame.promptText) ? feelingFrame : nil
        )
    }

    /// An eligible cue that lost its slot or budget was never read, so its cadence remains owed.
    static func keepUnshownCuesOwed(
        candidateLines: [String],
        shown: String,
        expected: CognitiveCapsulePresentationState,
        next: inout CognitiveCapsulePresentationState
    ) {
        // A tail line that lost the capsule budget was never presented and must remain eligible for the next accepted turn.
        if !shown.contains("- Since:") {
            // An owed bridge keeps its gap: a Since line that was produced and lost the slot to a care leaves `owedSinceGap` set by its render, so the next
            // turn still closes that gap.
            next.lastSessionBridgeAt = expected.lastSessionBridgeAt
        } else {
            next.owedSinceGap = nil
        }
        let soundLost = candidateLines.contains { $0.hasPrefix("- Sound:") }
            && !shown.contains("- Sound:")
        if soundLost {
            // Only shown nudges spend cooldown; lapsed ruts still clear their identity so a return reads as change. Accepted-turn counters always advance.
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
        // Only a whole delivered frame becomes the reference for the next reply's shift.
        if let frame = candidateLines.first(where: { $0.hasPrefix(CognitiveFeelingFrame.header) }),
           !shown.contains(frame) {
            next.fingerprintFamily = expected.fingerprintFamily
            next.ambivalenceCount = expected.ambivalenceCount
            next.lastAmbivalenceAt = expected.lastAmbivalenceAt
        }
        // A care the agent meant to bring up whose line was never read is still owed.
        if !shown.contains(careIntentionPrefix) {
            next.careReleased = expected.careReleased
        }
        // A plain care line that lost the budget never started its rest.
        if !shown.contains(careMindPrefix) {
            for (key, rest) in Array(next.careLineRest) where rest.turnsLeft == careLineRestTurns {
                next.careLineRest[key] = nil
            }
        }
        // A dream phrase that lost its slot remains unread.
        if !shown.contains("- Dream:") {
            next.dreamThemeSurfaced = expected.dreamThemeSurfaced
        }
        // Unbidden recall rides last and is clipped first; only a shown moment may spend its 24h ledger entry.
        if !shown.contains("- Reminded of:") {
            next.remindedOfSurfaced =
                expected.remindedOfSurfaced
            next.remindedOfLastSurfacedAt =
                expected.remindedOfLastSurfacedAt
            next.remindedOfTurnsSinceSurfaced =
                expected.remindedOfTurnsSinceSurfaced
        }
    }

    /// Rendering mutates only the caller's copied presentation value. The live actor is advanced later by `applyCapsulePresentationCommit`, and only for an
    /// accepted injection.
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
        dreamFeeling: String,
        presentationState: inout CognitiveCapsulePresentationState,
        why: inout CapsuleCueWhy,
        turn: Turn?
    ) -> (lines: [String], frame: CognitiveFeelingFrame) {
        let dyn = frozenRead.personalityDynamics
        let signals = felt?.signals ?? feltSignalsForCapsule(
            from: workspaceItems,
            request: request,
            frozenRead: frozenRead
        )
        // Felt mode selects an attested exemplar without adding prompt text.
        let mode = frozenRead.configuration.enabled
            ? signals.flatMap { Self.feltMode($0, intensityFloor: dyn.feltIntensityFloor) }
            : nil
        // Only the user's first turn after a qualifying gap may carry a cue of actual events.
        let gapOpened = request.fromUser
            ? Self.sinceGapOpened(presentationState, previousUserTurn: request.previousUserTurnAt, dynamics: dyn, at: now) : nil
        let since = feltSessionBridgeLine(
            from: frozenRead,
            presentationState: &presentationState,
            fromUser: request.fromUser,
            previousUserTurn: request.previousUserTurnAt,
            gapItems: gapItems
        )
        if let since, let gapOpened {
            why.sources[since] = "gap:\(String(format: "%.0f", (now.timeIntervalSince(gapOpened) / 3_600).rounded()))h"
        }
        // The care cue owns intentions; the frame reads charge independently of message matching and cue rest.
        let resting = Self.advanceCareLineRest(&presentationState.careLineRest)
        // The feeling frame already says what is on her mind; the care cue adds only its intentions.
        let careLines = (careCue.map {
            careCueLines($0, message: request.userMessage, gapOpened: gapOpened, resting: resting, at: now,
                         presentationState: &presentationState, why: &why)
        } ?? []).filter { !$0.hasPrefix(Self.careMindPrefix) }
        // Voice selection reads this turn's felt register without deciding whether feeling is present.
        let echo = signals.map { signals in soundEchoSelection(
            from: frozenRead,
            mode: mode,
            roomValence: signals.valence,
            currentSessionId: request.sessionId,
            surface: request.surface,
            emitReceipts: request.mode == .inject,
            turn: turn
        ) } ?? .silent
        // ONE gate for the named rut line, whether or not the exemplar echo speaks this turn.
        let rutSpeaks = soundRutAwarenessShouldSpeak(
            signature: echo.wornSignature,
            at: now,
            dynamics: dyn,
            presentationState: &presentationState,
            fedAgain: echo.rutFedAgain
        )
        let rutLine = rutSpeaks ? echo.rutLine : nil

        // Association keeps the same felt object and counter-reading as the frame.
        let fingerprint: FeltLineRender?
        if let felt {
            fingerprint = felt.fingerprint
        } else if let signals {
            fingerprint = feltFingerprintLine(
                signals: signals,
                workspaceItems: workspaceItems,
                request: request,
                at: now,
                dynamics: dyn,
                affectEnabled: frozenRead.configuration.enabled
            )
        } else { fingerprint = nil }
        let frame = feelingFrame(
            request: request, read: frozenRead, dreamFeeling: dreamFeeling,
            leadWord: fingerprint?.leadWord, counterWord: fingerprint?.counterWord,
            presentationState: &presentationState)
        if Self.frameCognitionAvailable(frozenRead), fingerprint?.counterWord != nil {
            presentationState.ambivalenceCount = min(presentationState.ambivalenceCount, Int.max - 1) + 1
            presentationState.lastAmbivalenceAt = now
        }
        var remindedSpoken: String?
        if let remindedOf,
           let line = remindedOfCapsuleLine(for: remindedOf, at: now) {
            remindedSpoken = line
            why.sources[line] = "care:" + remindedOf.careID.uuidString
            why.scores[line] = remindedOf.score
            presentationState.remindedOfSurfaced[remindedOf.id] = now
            Self.boundRemindedOfLedger(&presentationState.remindedOfSurfaced)
            presentationState.remindedOfLastSurfacedAt = now
            presentationState.remindedOfTurnsSinceSurfaced = 0
        }
        // Dream cues require a connection to this message and explicitly identify themselves as associations.
        var dreamSpoken: String?
        if let dreamTheme, let line = dreamCapsuleLine(for: dreamTheme) {
            dreamSpoken = line
            why.sources[line] = "dream:" + dreamTheme.id
            why.scores[line] = dreamTheme.score
            presentationState.dreamThemeSurfaced[dreamTheme.id] = now
            Self.boundDateLedger(&presentationState.dreamThemeSurfaced)
        }
        let ordered: [String?] = [frame.promptText] + careLines + [
            since, remindedSpoken,
            dreamSpoken,
            echo.line, rutLine,
        ]
        return (dedupedCapsuleLines(ordered.compactMap { $0 }), frame)
    }

    /// Trace cue selection at production without adding its explanation to the prompt.
    struct CapsuleCueWhy: Sendable {
        var sources: [String: String] = [:]
        var scores: [String: Double] = [:]
        var careIntention: String?
    }

    /// Traces retain every candidate and whether its own lane reached the delivered capsule.
    static func cueWhyPayload(
        candidateLines: [String],
        shown: String,
        why: CapsuleCueWhy,
        signature: [String]
    ) -> JSONValue {
        func kind(_ line: String) -> String {
            for (prefix, name) in [("- Since:", "since"),
                                   ("- Reminded of:", "reminded_of"),
                                   ("- Sound:", "sound"),
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
            "shown": .array(candidateLines.enumerated().filter { shown.contains($0.element) }.map { row($0.element, rank: $0.offset + 1) }),
            "winner": winner.map { row($0, rank: (candidateLines.firstIndex(of: $0) ?? 0) + 1) } ?? .null,
        ])
    }

    /// Each lane is selected before fitting; the frame always spends the budget first.
    static func capsulePresentationLines(_ ordered: [String], surface: String) -> [String] {
        guard surface != cadenceExemptCapsuleSurface else { return ordered }
        let frame = ordered.filter { $0.hasPrefix(CognitiveFeelingFrame.header) }
        let intentions = ordered.filter { $0.hasPrefix(careIntentionPrefix) }
        let sound = ordered.filter { $0.hasPrefix("- Sound:") }
        let continuity = ordered.first {
            !$0.hasPrefix(CognitiveFeelingFrame.header) && !$0.hasPrefix(careIntentionPrefix) && !$0.hasPrefix("- Sound:")
        }
        return frame + intentions + sound + [continuity].compactMap { $0 }
    }

    /// Preserve the first duplicate only so lossy translation cannot spend the capsule budget on repeated cues.
    private func dedupedCapsuleLines(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in lines {
            let key = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if seen.insert(key).inserted { out.append(line) }
        }
        return out
    }

    /// Production preparation seam: one immutable cognition epoch plus a pure presentation commit for the accepted-turn boundary.
    public func prepareFrozenCapsulePresentation(
        _ request: CognitiveCapsuleRequest,
        at fixedAt: Date,
        turn: Turn
    ) async -> CognitivePreparedCapsule? {
        let requestTurnKind = request.resolvedTurnKind
        guard requestTurnKind == .live || request.allowNonLiveProjection else { return nil }
        let read = frozenRead(at: fixedAt)
        let dreamFeeling = dreamFeelingFrame(at: fixedAt, sleep: request.sleepDream)
        let reachableCares = Self.capsuleReachableCares(for: request, from: read)
        // Embed the felt line once against the frozen read; after suspension, recheck live cadence and ledger to avoid repeating an intervening turn's cue.
        async let recallRead = {
            var felt: (signals: FeltSignals, fingerprint: FeltLineRender?)?
            var unreadable: [String] = []
            let moment = await self.remindedOfMoment(for: request, from: read, among: reachableCares, felt: &felt, unreadable: &unreadable, turn: turn)
            return (moment, felt, unreadable)
        }()
        // Local continuity lookups keep their dream cooldown and first-turn gap gates.
        async let dreamRead = {
            var unreadable: [String] = []
            let cue = await self.dreamThemeCue(for: request, from: read, unreadable: &unreadable)
            return (cue, unreadable)
        }()
        async let gapRead = {
            var unreadable: [String] = []
            let items = await self.sinceGapItems(for: request, from: read, unreadable: &unreadable)
            return (items, unreadable)
        }()
        async let careRead = {
            var unreadable: [String] = []
            let cue = await self.careCue(for: request, from: read, among: reachableCares, unreadable: &unreadable, turn: turn)
            return (cue, unreadable)
        }()
        let (recall, dream, gap, careCue) = await (recallRead, dreamRead, gapRead, careRead)
        guard !forgettingInFlight, mindEpoch == read.mindEpoch else { return nil }
        let remindedOf = recall.0.flatMap { revalidatedRemindedOf($0, against: read) }
        let prepared = compileFrozenCapsulePresentation(
            request, from: read, remindedOf: remindedOf,
            dreamTheme: dream.0, gapItems: gap.0, careCue: careCue.0,
            felt: recall.1, dreamFeeling: dreamFeeling,
            unreadable: dream.1 + gap.1 + recall.2 + careCue.1, turn: turn)
        // An empty capsule still returns, carrying its commit; callers inject only `nonEmptyCapsule`.
        guard prepared.capsule.mode == .inject else { return nil }
        return prepared
    }

    /// Apply presentation-only state after the exact frozen capsule was accepted into provider context. A stale/out-of-order commit is ignored rather than
    /// rolling cadence backward over a newer accepted turn.
    @discardableResult
    public func applyCapsulePresentationCommit(
        _ commit: CognitiveCapsulePresentationCommit,
        turn: Turn
    ) -> Bool {
        guard !forgettingInFlight, commit.mindEpoch == mindEpoch else {
            TurnTraceBus.fireFromContext(kind: "cognition.capsule_commit_refused", payload: .object([
                "preparedMindEpoch": .string(String(commit.mindEpoch)),
                "currentMindEpoch": .string(String(mindEpoch)), "clearInFlight": .bool(forgettingInFlight),
            ]), turn: turn)
            return false
        }
        // The rut turn counter free-runs on accepted turns, so an ingest between prepare and commit legitimately moves it. Comparing it here would reject the
        // whole commit for a field the render only reads.
        guard Self.presentationCommitIdentity(capsulePresentationState)
                == Self.presentationCommitIdentity(commit.expected) else { return false }
        var next = commit.next
        // Reply settlement owns this reference independently of provider-context acceptance.
        next.fingerprintFamily = capsulePresentationState.fingerprintFamily
        // Ingest advances these counters independently while a render is frozen.
        if next.soundRutTurnsSinceSurfaced != 0 {
            next.soundRutTurnsSinceSurfaced = capsulePresentationState.soundRutTurnsSinceSurfaced
        }
        if next.remindedOfLastSurfacedAt == commit.expected.remindedOfLastSurfacedAt {
            next.remindedOfTurnsSinceSurfaced = capsulePresentationState.remindedOfTurnsSinceSurfaced
        } else {
            next.remindedOfTurnsSinceSurfaced = 0
        }
        guard next != capsulePresentationState else { return true }
        let before = capsulePresentationArtifactPayload(at: commit.fixedAt)
        capsulePresentationState = next
        // A resident-only feeling reference does not rewrite an unchanged durable ledger.
        if before != capsulePresentationArtifactPayload(at: commit.fixedAt) { capsulePresentationDirty = true }
        return true
    }

    /// The last completed, saved reply supplies the comparison, even when other turns accepted context while it was running.
    public func applyReplyFeelingCommit(_ commit: CognitiveCapsulePresentationCommit) {
        guard !forgettingInFlight, commit.mindEpoch == mindEpoch, commit.feelingFrameShown else { return }
        capsulePresentationState.fingerprintFamily = commit.next.fingerprintFamily
    }

    // MARK: - Durable capsule cadence

    /// Bounded, content-free presentation payload. Everything here is a counter, a digest, or a timestamp — no line text reaches disk.
    func capsulePresentationArtifactPayload(at now: Date) -> JSONValue {
        var object: [String: JSONValue] = [
            "updatedAt": .double(now.timeIntervalSince1970),
            "soundRutTurnsSinceSurfaced": .int(Int64(capsulePresentationState.soundRutTurnsSinceSurfaced)),
            "remindedOfTurnsSinceSurfaced": .int(Int64(capsulePresentationState.remindedOfTurnsSinceSurfaced)),
            // Content-free presentation counters survive relaunch so ambivalence frequency remains measurable.
            "ambivalenceCount": .int(Int64(capsulePresentationState.ambivalenceCount)),
        ]
        if let lastAmbivalenceAt = capsulePresentationState.lastAmbivalenceAt {
            object["lastAmbivalenceAt"] = .double(lastAmbivalenceAt.timeIntervalSince1970)
        }
        if let remindedOfLastSurfacedAt = capsulePresentationState.remindedOfLastSurfacedAt {
            object["remindedOfLastSurfacedAt"] = .double(remindedOfLastSurfacedAt.timeIntervalSince1970)
        }
        if !capsulePresentationState.remindedOfSurfaced.isEmpty {
            object["remindedOfSurfaced"] = .object(capsulePresentationState.remindedOfSurfaced.mapValues { .double($0.timeIntervalSince1970) })
        }
        if let signature = capsulePresentationState.soundRutSignature {
            object["soundRutSignature"] = .string(bounded(signature, maxCharacters: 240))
        }
        if let surfacedAt = capsulePresentationState.soundRutLastSurfacedAt {
            object["soundRutLastSurfacedAt"] = .double(surfacedAt.timeIntervalSince1970)
        }
        if capsulePresentationState.soundRutEarlyRepeatSpent {
            object["soundRutEarlyRepeatSpent"] = .bool(true)
        }
        // Gap and dream cadence survive relaunch as timestamps and ids.
        if let owedSinceGap = capsulePresentationState.owedSinceGap {
            object["owedSinceGap"] = .double(owedSinceGap.timeIntervalSince1970)
        }
        if let lastSessionBridgeAt = capsulePresentationState.lastSessionBridgeAt {
            object["lastSessionBridgeAt"] = .double(lastSessionBridgeAt.timeIntervalSince1970)
        }
        if !capsulePresentationState.dreamThemeSurfaced.isEmpty {
            object["dreamThemeSurfaced"] = .object(capsulePresentationState.dreamThemeSurfaced.mapValues { .double($0.timeIntervalSince1970) })
        }
        if !capsulePresentationState.careReleased.isEmpty {
            object["careReleased"] = .object(capsulePresentationState.careReleased.mapValues { .double($0.timeIntervalSince1970) })
        }
        if !capsulePresentationState.careLineRest.isEmpty {
            object["careLineRest"] = .object(capsulePresentationState.careLineRest.mapValues {
                .array([.double($0.shownAt.timeIntervalSince1970), .int(Int64($0.turnsLeft))])
            })
        }
        return .object(object)
    }

    public func flushCommittedCapsulePresentation(at now: Date) async {
        guard configuration.enabled, configuration.capsuleInjectionEnabled else { return }
        await flushCapsulePresentationIfNeeded(at: now)
    }

    /// Persist only changed accepted-turn cadence; previews cannot spend it.
    func flushCapsulePresentationIfNeeded(at now: Date) async {
        guard capsulePresentationDirty else { return }
        do { try await persistCapsulePresentationChecked(at: now) }
        catch { /* The checked owner records the stage and cause below. */ }
    }

    /// A journal fold awaits its own durable write even if another cadence flush has already cleared the dirty flag while saving.
    func persistCapsulePresentationChecked(at now: Date) async throws {
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
            await notingPersistence("capsule_presentation") { }
        } catch {
            capsulePresentationDirty = true
            await notingPersistence("capsule_presentation") { throw error }
            throw error
        }
    }

    /// Only a fully validated present payload reaches this projection. An absent artifact leaves the empty cadence; damaged bytes fail restore.
    func restoreCapsulePresentation(from payloads: [JSONValue]) {
        guard case .object(let object)? = payloads.first else { return }
        // Only named "kind:phrase" rut signatures carry cadence.
        capsulePresentationState.soundRutSignature = object["soundRutSignature"]?.stringValue
            .flatMap { $0.contains(":") ? $0 : nil }
        capsulePresentationState.soundRutLastSurfacedAt = dateValue(object["soundRutLastSurfacedAt"])
        capsulePresentationState.soundRutEarlyRepeatSpent = object["soundRutEarlyRepeatSpent"] == .bool(true)
            && capsulePresentationState.soundRutSignature != nil
        capsulePresentationState.soundRutTurnsSinceSurfaced = min(
            max(0, Int(exactly: (object["soundRutTurnsSinceSurfaced"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0).rounded(.towardZero)) ?? 0),
            Self.soundRutTurnCounterCap
        )
        capsulePresentationState.ambivalenceCount = max(0, Int(exactly: (object["ambivalenceCount"]?.numberValue(coercingStrings: false, finiteOnly: false)
            ?? 0).rounded(.towardZero)) ?? 0)
        capsulePresentationState.lastAmbivalenceAt = dateValue(object["lastAmbivalenceAt"])
        capsulePresentationState.remindedOfLastSurfacedAt = dateValue(object["remindedOfLastSurfacedAt"])
        capsulePresentationState.remindedOfTurnsSinceSurfaced = min(Self.soundRutTurnCounterCap,
            max(0, Int(exactly: (object["remindedOfTurnsSinceSurfaced"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0).rounded(.towardZero))
                ?? 0))
        var recalled: [String: Date] = [:]
        if case .object(let moments)? = object["remindedOfSurfaced"] {
            for (key, value) in moments where key.utf8.count <= 120 {
                guard let at = value.numberValue(coercingStrings: false, finiteOnly: false), at.isFinite else { continue }
                recalled[key] = Date(timeIntervalSince1970: at)
            }
        }
        Self.boundRemindedOfLedger(&recalled)
        capsulePresentationState.remindedOfSurfaced = recalled
        capsulePresentationState.owedSinceGap = dateValue(object["owedSinceGap"])
        capsulePresentationState.lastSessionBridgeAt = dateValue(object["lastSessionBridgeAt"])
        if case .object(let dreams)? = object["dreamThemeSurfaced"] {
            var restored: [String: Date] = [:]
            for (key, value) in dreams where key.count <= 48 {
                if let at = value.numberValue(coercingStrings: false, finiteOnly: false) { restored[key] = Date(timeIntervalSince1970: at) }
            }
            Self.boundDateLedger(&restored)
            capsulePresentationState.dreamThemeSurfaced = restored
        }
        if case .object(let released)? = object["careReleased"] {
            var restored: [String: Date] = [:]
            for (key, value) in released where UUID(uuidString: key) != nil {
                if let at = value.numberValue(coercingStrings: false, finiteOnly: false) { restored[key] = Date(timeIntervalSince1970: at) }
            }
            Self.boundDateLedger(&restored)
            capsulePresentationState.careReleased = restored
        }
        if case .object(let rests)? = object["careLineRest"] {
            var restored: [String: CognitiveCapsulePresentationState.CareLineRest] = [:]
            for (key, value) in rests where UUID(uuidString: key) != nil {
                guard case .array(let pair) = value, pair.count == 2,
                      let at = pair[0].numberValue(coercingStrings: false, finiteOnly: false), let turns = pair[1].numberValue(coercingStrings: false,
                          finiteOnly: false),
                      turns.isFinite else { continue }
                restored[key] = .init(shownAt: Date(timeIntervalSince1970: at),
                                      turnsLeft: Int(min(Double(Self.careLineRestTurns), max(0, turns))))
            }
            capsulePresentationState.careLineRest = restored.filter { $0.value.turnsLeft > 0 }
        }
    }

    /// Accepted-turn counters and the completed-reply reference have independent write boundaries.
    static func presentationCommitIdentity(
        _ state: CognitiveCapsulePresentationState
    ) -> CognitiveCapsulePresentationState {
        var masked = state
        masked.soundRutTurnsSinceSurfaced = 0
        masked.remindedOfTurnsSinceSurfaced = 0
        masked.fingerprintFamily = nil
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
            // Sound echoes stay whole; other lines may use sentence-aware clipping.
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
