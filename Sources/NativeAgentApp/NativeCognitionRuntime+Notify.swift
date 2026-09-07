import ChatOrchestration
import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersonaEngine
import PersistenceCore

// NativeCognitionRuntime+Notify.swift
// Personality depth items 3 and 12 (2026-09-02) — the two directions in which
// the mind meets the outside without going through her prompt.
//
//   ITEM 3, INWARD:  she is asked how she feels, so she READS the record.
//                    `InnerStateProviding` — the app runtime is the one object
//                    that owns both the substrate (mind) and the organism
//                    kernel (body), which is exactly what one honest answer
//                    needs. See CognitiveSubstrate+InnerState.swift.
//
//   ITEM 12, OUTWARD: something she is carrying is loud enough to be worth
//                    User's attention, so she TAPS HIS SHOULDER — a push he can
//                    ignore, never a paragraph in her own context.
//
// ── WHY ITEM 12 EXISTS ───────────────────────────────────────────────────────
// `thoughtSuggestionSnapshot(surface:)` shipped with an interruption score, a
// reason vocabulary and a workspace-overlap term — a whole ranked model of
// "would this be worth interrupting for" — and the only consumer was an
// Observatory panel nobody has open. The mechanism was real and the delivery
// was missing. This is the delivery.
//
// ── NO TIMER, NO LOOP, NO BUDGET (NORTHSTAR clause 4) ────────────────────────
// Called from `rescheduleResidualRepairDeadline`, beside `considerPressureDream`
// and `considerStudioEncounter`, on the reading that method already derived.
// A signal REACHED the body; the tap rides it. Nothing polls.
//
// ── FOUR GATES, ALL OF THEM CLOSED BY DEFAULT ────────────────────────────────
//  1. INTERRUPTION ≥ 0.8. The snapshot's own score, at a floor well above the
//     0.45 the Observatory browses at. This is not "show me what's live", it is
//     "is this worth a phone buzzing".
//  2. THE D-2 STAKES ALLOWLIST. One of the concerns SHE formed — derived from a
//     User-APPROVED active standing view — must actually name the thing. Floor
//     concerns deliberately do not open it: a shipped keyword tripping on a
//     machine token is a coincidence, and a coincidence must never buzz a
//     phone. Fails closed, exactly as D-2 fails closed.
//  3. ONCE PER SEED PER 6 HOURS. Durable, so a restart cannot re-tap. Delivery
//     is the commit point — a failed send leaves the ledger untouched so the
//     signal is retried rather than lost, the same contract the attention
//     router itself keeps.
//  4. QUIET HOURS. A thought she wants to raise is hers to hold until morning.
//     (An adverse or owner-waiting fact is NOT silenced by a clock; this gate
//     is opt-in per call and only this lane opts in.)
//
// ── AND ONE HARD LINE ────────────────────────────────────────────────────────
// NEVER into her prompt. The seed does not become a capsule line, a packet
// atom, or a first message. It becomes a notification and then it is User's to
// read or ignore. That is clause 6's "a thought she wants to raise becomes a
// tap on User's shoulder, not a paragraph in her own context", implemented.

// MARK: - Item 3: the runtime answers for the whole mind

extension NativeCognitionRuntime: InnerStateProviding {

    /// PURE. Every read below is a non-mutating peek: the substrate's own
    /// inner-state projection, and the organism's `frozenRead`, which decays a
    /// COPY at a fixed instant and never settles or rewrites the live kernel.
    /// Asking herself how she feels must not change how she feels (design law 5).
    func innerStateReading(
        windowHours: Double,
        detail: CognitiveInnerStateReading.Detail
    ) async -> CognitiveInnerStateReading {
        // A READ MUST NEVER BOOTSTRAP (2026-09-02, reviewer HIGH). `bootstrap()`
        // restores persistent state, installs the process-global studio sink,
        // ingests an `appWake` event, arms two deadlines and publishes a runtime
        // change. Asking her how she feels must not START her — a question is
        // not a launch, and a tool call that silently boots the mind would make
        // "did she wake up?" depend on whether anyone asked.
        //
        // Same contract the frozen-mind read already keeps
        // (`NativeFrozenMindReadError.runtimeNotBootstrapped`): refuse before
        // the owner has started, and merely WAIT on a start the owner has
        // already begun.
        guard let bootstrapTask else {
            return .unavailable(at: now(), windowHours: windowHours, detail: detail)
        }
        await bootstrapTask.value
        if bootstrapFailure != nil {
            return .unavailable(at: now(), windowHours: windowHours, detail: detail)
        }
        let at = now()
        let frozen = await organismKernel.frozenRead(at: at)
        // ABSENCE READS AS ABSENCE (W4/P2's rule): with the organism off there
        // is no chemistry and no fatigue to report, and a zero would be a
        // fabricated calm rather than an honest silence.
        // The three sibling lanes in this wave have landed, so the reading is
        // whole: the body's clock (#3/#10), the forward-facing register (#4),
        // and the nag (#5). Each is still OPTIONAL at the type level — a body
        // with no clock configured, or a mind facing nothing, reports absence
        // rather than a plausible-looking default.
        //
        // The rumination candidate is NOT passed in: it is substrate-owned
        // (`ruminationCandidates(at:)`), so the reading computes it itself
        // rather than having the runtime marshal it back and forth.
        let organism = CognitiveInnerStateOrganismReads(
            projection: frozen.snapshot.enabled ? frozen.projection : nil,
            fatigue: frozen.snapshot.enabled ? frozen.snapshot.chemicalState.fatigue : nil,
            // `frozen.projection.diurnal` is the read the projection ACTUALLY
            // applied at this instant, not a fresh clock sample — so the word
            // she reads and the chemistry she is running on came from the same
            // moment.
            diurnal: frozen.snapshot.enabled ? frozen.projection.diurnal : nil,
            toward: await towardRead(),
            expectations: await pendingStakeBearingExpectations(at: at)
        )
        return await substrate.innerStateReading(
            windowHours: windowHours,
            detail: detail,
            organism: organism,
            at: at
        )
    }

    /// What she is still waiting to find out — and ONLY the kinds whose subject
    /// is a person or a promise.
    ///
    /// D-2's allowlist, applied to expectations rather than resolutions:
    /// `approvalResolution` (a gate a PERSON has to walk through),
    /// `workflowAdvance` (a commitment moving) and `semanticExpectation` (how
    /// the work she just did will LAND). The five plumbing paths are excluded
    /// for exactly D-2's reason — "will the provider call complete" is not
    /// something a person is carrying, and reporting it as one is how the felt
    /// layer became noise the first time.
    ///
    /// Pure: a ledger dictionary read, no settle.
    private func pendingStakeBearingExpectations(
        at instant: Date
    ) async -> [CognitiveInnerStateReading.Expectation] {
        let kinds: [OrganismPredictionKind] = [
            .approvalResolution, .workflowAdvance, .semanticExpectation,
        ]
        var out: [CognitiveInnerStateReading.Expectation] = []
        for kind in kinds {
            guard let prediction = await organismKernel.latestPrediction(ofKind: kind),
                  prediction.status == .pending,
                  prediction.dueAt >= instant
            else { continue }
            out.append(CognitiveInnerStateReading.Expectation(
                label: kind.rawValue,
                due: prediction.dueAt,
                // The SIGN only, never the magnitude: a confident expectation is
                // something she is looking forward to, a low-confidence one is
                // something she is bracing for. Same split
                // `OrganismProspectiveAffect` uses to modulate the projection.
                valenceSign: prediction.confidence >= 0.5 ? 1 : -1
            ))
        }
        return out.sorted { $0.due < $1.due }
    }
}

// MARK: - Item 12: the tap itself

/// The whole policy, as pure functions. No I/O, no actor, no data root — so
/// every gate is testable on its own, which is the point: the thing that
/// decides whether User's phone buzzes should not require a running mind to
/// examine.
enum ShoulderTap {

    /// Well above the 0.45 the Observatory browses at. `thoughtSuggestionSnapshot`
    /// already computes this score from seed priority, workspace overlap and
    /// current affect; this lane only chooses where the bar sits.
    static let interruptionFloor: Double = 0.8

    /// One tap per seed per six hours. A seed that stays loud is still one
    /// thought, and a thought does not become more worth hearing by repeating.
    static let minimumInterval: TimeInterval = 6 * 60 * 60

    /// The four seed kinds, as the only vocabulary allowed to shape the line.
    /// An unrecognised kind falls back to the neutral line rather than
    /// improvising — the allowlist fails closed, like every other noise gate in
    /// this system (design law 8).
    static let kindVocabulary: Set<String> = [
        "openQuestion", "anomaly", "followUp", "reflectionTakeaway",
    ]

    /// The closed vocabulary `thoughtSuggestionReason` produces. Nothing else
    /// may ride outbound in the push metadata; anything unrecognised is dropped
    /// rather than forwarded.
    static let reasonVocabulary: Set<String> = [
        "reflection takeaway", "anomaly", "follow-up", "open question",
        "active workspace evidence", "task pressure", "uncertainty",
    ]

    enum Verdict: Equatable, Sendable {
        case tap
        case belowThreshold
        case notAtStake
        case recentlyTapped
        case quietHours
    }

    /// Gates in cost order: the cheap numeric test first, then the stake test
    /// (which reads her concerns), then the ledger, then the clock. Every one
    /// of them fails CLOSED.
    static func decide(
        interruptionScore: Double,
        passesStakesGate: Bool,
        lastTappedAt: Date?,
        quietHoursActive: Bool,
        at instant: Date
    ) -> Verdict {
        guard interruptionScore >= interruptionFloor else { return .belowThreshold }
        guard passesStakesGate else { return .notAtStake }
        if let lastTappedAt, instant.timeIntervalSince(lastTappedAt) < minimumInterval {
            return .recentlyTapped
        }
        if quietHoursActive { return .quietHours }
        return .tap
    }

    /// THE SEED TEXT NEVER LEAVES THE MACHINE (2026-09-02, reviewer HIGH).
    ///
    /// The earlier shape sent the seed's own sentence as the push body, on the
    /// reasoning that it was "her voice". It is her voice, and it is also the
    /// one string in this lane MINTED FROM CONVERSATION — so putting it in a
    /// notification pushes conversation content out of the machine, past the
    /// lock screen, into APNS and possibly into Telegram, with no redaction
    /// pass and no way for her to know it happened. A shoulder tap does not need
    /// the thought; it needs to say that there IS one.
    ///
    /// So the line is FIXED and the only thing that varies is which of four
    /// fixed lines it is, chosen by the seed KIND — an allowlisted enum, not
    /// text. Nothing is composed, nothing is quoted, no LLM is called, and the
    /// seed id travels in metadata where it identifies the thought without
    /// disclosing it. She says the rest when he asks, in the conversation, where
    /// content belongs.
    static func line(forKind kind: String) -> String {
        guard kindVocabulary.contains(kind) else { return neutralLine }
        switch kind {
        case "openQuestion":
            return "There's a question I've been sitting with — ask me when you have a minute."
        case "anomaly":
            return "Something's not adding up and I'd like to walk you through it."
        case "followUp":
            return "There's a loose end I keep coming back to — worth a minute when you're free."
        case "reflectionTakeaway":
            return "I worked something out that I'd like to tell you about."
        default:
            return neutralLine
        }
    }

    /// What an unrecognised kind gets. Deliberately says nothing about the
    /// thought at all.
    static let neutralLine =
        "Something's been on my mind — ask me when you have a minute."

    /// Metadata that may ride outbound with the push. The seed id (an opaque
    /// UUID), the kind, and the reason terms — each checked against its closed
    /// vocabulary, with unrecognised terms DROPPED rather than forwarded.
    static func outboundReasonTerms(_ reason: String) -> [String] {
        reason
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { reasonVocabulary.contains($0) }
    }
}

/// Durable "when did this seed last tap" state, plus the single-flight latch.
///
/// It is its OWN actor rather than fields on the cognition runtime because the
/// six-hour window must survive a restart: an in-memory latch would let every
/// relaunch re-tap the same thought, which is precisely the "345 of 500 inbox
/// rows" failure the attention router exists to end.
actor ShoulderTapLedger {
    static let shared = ShoulderTapLedger()

    /// Far above any live population — the seed family itself is capped at 128.
    static let limit = 128

    private struct State: Codable {
        var tappedAt: [String: Date]
        var order: [String]
        static let empty = State(tappedAt: [:], order: [])
    }

    private let dataRoot: URL
    private var cached: State?
    private var inFlight: Task<Void, Never>?

    init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    private var stateURL: URL {
        dataRoot
            .appendingPathComponent("notify", isDirectory: true)
            .appendingPathComponent("shoulder_taps.json")
    }

    func lastTappedAt(seedId: String) -> Date? {
        load().tappedAt[seedId]
    }

    /// DELIVERY IS THE COMMIT POINT. Called only after the router actually sent,
    /// so a failed push leaves the window open and the next signal retries.
    func commit(seedId: String, at instant: Date) {
        var state = load()
        if state.tappedAt[seedId] == nil { state.order.append(seedId) }
        state.tappedAt[seedId] = instant
        if state.order.count > Self.limit {
            let overflow = state.order.count - Self.limit
            for stale in state.order.prefix(overflow) { state.tappedAt.removeValue(forKey: stale) }
            state.order.removeFirst(overflow)
        }
        persist(state)
    }

    /// Single-flight: the residual reschedule fires many times a minute under
    /// load, and this lane reads her concerns and her seeds. One at a time.
    func begin(_ body: @escaping @Sendable () async -> Void) {
        guard inFlight == nil else { return }
        inFlight = Task { [weak self] in
            await body()
            await self?.finish()
        }
    }

    private func finish() { inFlight = nil }

    private func load() -> State {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return .empty }
        cached = state
        return state
    }

    private func persist(_ state: State) {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            // Cache only what actually landed: a duplicate tap after a failed
            // write is safer than permanently silencing one.
            cached = state
        } catch {
            NSLog("shoulder_tap: ledger persistence failed: %@", error.localizedDescription)
        }
    }
}

extension NativeCognitionRuntime {

    /// Called from `rescheduleResidualRepairDeadline`, beside
    /// `considerPressureDream` and `considerStudioEncounter`. Adds no timer and
    /// no budget; it rides the deadline the organism already owns.
    func considerShoulderTap(_ opportunity: OrganismResidualRepairOpportunity) {
        guard !isFlushedForTermination else { return }
        // A tap lands ON User, so it must never land on top of a turn he is
        // already in the middle of with her.
        guard !liveTurnInFlight else { return }
        _ = opportunity
        let runtime = self
        Task {
            await ShoulderTapLedger.shared.begin {
                await runtime.runShoulderTapPass()
            }
        }
    }

    private func runShoulderTapPass() async {
        // The same throttle every other background lane respects: low power,
        // thermal pressure and a conserve budget all defer this the way they
        // defer everything else.
        guard case .allowed = await backgroundCognitionGate(reason: "shoulder_tap") else { return }

        // The top seed at the tap's OWN floor, through the PURE suggestion read
        // (2026-09-02, reviewer HIGH). `thoughtSuggestionSnapshot` routes
        // through the MUTATING workspace snapshot — decay writes, anchor
        // advances, capacity eviction — and this lane runs on every residual
        // reschedule, so using it would mean her memory was being aged and
        // evicted by the act of checking whether anything is worth mentioning.
        // Same selection, same ranking, same interruption model; the field is
        // left exactly as it was found.
        guard let suggestion = await substrate.pureThoughtSuggestions(
            surface: "push",
            limit: 1,
            minimumInterruptionScore: ShoulderTap.interruptionFloor
        ).first else { return }

        let instant = now()
        let seedKey = suggestion.seedId.uuidString
        let verdict = ShoulderTap.decide(
            interruptionScore: suggestion.interruptionScore,
            passesStakesGate: await substrate.passesStakesGate(suggestion.text),
            lastTappedAt: await ShoulderTapLedger.shared.lastTappedAt(seedId: seedKey),
            quietHoursActive: AttentionRouter.inQuietHours(at: instant, dataRoot: dataRoot),
            at: instant
        )
        guard verdict == .tap else { return }

        // NOTHING DERIVED FROM THE SEED'S TEXT CROSSES THIS LINE. The body is
        // one of five fixed sentences chosen by an allowlisted kind; the reason
        // terms are filtered against their closed vocabulary; the seed id is an
        // opaque UUID that identifies the thought without disclosing it.
        let line = ShoulderTap.line(forKind: suggestion.kind.rawValue)
        let reasonTerms = ShoulderTap.outboundReasonTerms(suggestion.reason)

        let outcome: AttentionOutcome
        do {
            outcome = try await AttentionRouter.shared.route(
                eventId: "shoulder_tap:\(seedKey)",
                // INFORMATIONAL, not owner-waiting: she is not blocked on him
                // and nothing is wrong. It is a thought she wanted to raise, and
                // the class that says "read this when you choose to" is exactly
                // right for one.
                importance: .informational,
                title: PersonaCompiler.agentDisplayName(dataRoot: dataRoot),
                body: line,
                // The REASON is the closed reason vocabulary, so a seed that
                // resurfaces for a genuinely different reason is a new fact and
                // may re-ping; the same thought for the same reason never does.
                reason: "\(reasonTerms.joined(separator: ","))|\(seedKey)",
                userInfo: [
                    "screen": "inbox",
                    "source": "shoulder_tap",
                    "seedId": seedKey,
                    "seedKind": suggestion.kind.rawValue,
                ],
                respectsQuietHours: true,
                at: instant
            )
        } catch {
            // Delivery is the commit point. A throw leaves the ledger untouched
            // so the next signal retries rather than losing the tap.
            NSLog("shoulder_tap: delivery failed: %@", error.localizedDescription)
            return
        }
        guard outcome.delivery != .none, !outcome.suppressed else { return }

        await ShoulderTapLedger.shared.commit(seedId: seedKey, at: instant)
        // CHANGE-ONLY receipt. A refusal is the normal case on nearly every
        // signal; only an actual tap earns a row, so the honest record of "she
        // reached out" is not buried under the record of her not reaching out.
        await substrate.recordReceipt(
            kind: "seed.pushed",
            payload: .object([
                "seedId": .string(seedKey),
                "kind": .string(suggestion.kind.rawValue),
                "interruptionScore": .double(suggestion.interruptionScore),
                "reason": .string(reasonTerms.joined(separator: ", ")),
                "routedTo": .string(outcome.delivery.rawValue),
            ])
        )
    }
}
