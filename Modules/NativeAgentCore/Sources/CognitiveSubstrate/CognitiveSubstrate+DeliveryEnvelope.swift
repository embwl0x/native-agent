import Foundation
import PersistenceCore

// W7/P6 — THE FELT DELIVERY ENVELOPE, TELEMETRY STAGE ONLY.
//
// THE STRUCTURAL FACT (L6 P6): feeling selects a WORD and never touches the
// SHAPE of the reply. The whole felt pipeline terminates in text handed to the
// model ("How you feel:", "- Inner:", "- Body:", "- Sound:"); nothing downstream
// reads FeltSignals. The one mechanism that touches reply SIZE is a boolean
// lexicon match over 22 work-starters and 17 social markers, and it is off
// entirely on any turn the planner types as non-chat. So every reply is the same
// architectural shape regardless of felt state, which is the tell of a machine:
// a tired person is terser, and a one-word ping gets a one-word answer.
//
// P6's own risk note is why this file computes and logs and does nothing else:
// "Reply length is the most visible surface in the product; a mis-sized envelope
// truncates real work. Stage it: telemetry-only first (log the envelope the
// mechanism WOULD have chosen against the length actually produced), enable
// after the distribution is understood."
//
// THE ENABLE FLAG DOES NOT EXIST. Not defaulted-off, not gated behind a
// configuration field, not commented out — there is no code path in this file or
// anywhere else that lets an envelope reach a reply. `DeliveryEnvelope` is
// returned to exactly one caller (`logDeliveryEnvelopeTelemetry`) which writes
// JSONL and returns Void. Adding the actuator is a later wave's decision, made
// against real distribution data, and it starts by writing the consumer that
// today has no reason to exist.
//
// NO VOCABULARY LIVES HERE either. Every field is a number or a flag. Nothing in
// this type can become a sentence the model reads.

extension CognitiveSubstrate {
    /// Metadata-only bridge from ChatOrchestration. The model-visible/event
    /// summary remains capped; this count lets observation telemetry measure
    /// the actual redacted reply without retaining another copy of it.
    public static let replyCharacterCountMetadataKey = "replyCharacterCount"

    /// The envelope the mechanism WOULD have chosen: a target reply-length band
    /// and a one-beat flag. Non-lexical, bounded, and inert.
    struct DeliveryEnvelope: Sendable, Equatable {
        /// Target reply length band in characters. Both ends are hard-bounded by
        /// `envelopeFloorCharacters`/`envelopeCeilingCharacters` so no felt state,
        /// however extreme, can produce a band that would truncate real work if
        /// a later wave ever acts on it.
        var minimumCharacters: Int
        var maximumCharacters: Int
        /// TRUE when the read says this turn deserves a single beat rather than a
        /// structured answer — a short social serve arriving on a low-arousal,
        /// low-pressure moment. The generalization of the serve classifier from a
        /// binary lexicon match to a continuous size prior.
        var oneBeat: Bool
        /// The continuous prior behind the band, 0 (terse) … 1 (expansive).
        /// Logged so the distribution can be read directly rather than inferred
        /// from the quantized band.
        var sizePrior: Double
    }

    /// The stashed half of the pair: what the envelope said at capsule compile,
    /// waiting for the completion that will say what actually happened.
    struct PendingDeliveryEnvelope: Sendable, Equatable {
        var envelope: DeliveryEnvelope
        var serveCharacters: Int
        var sessionId: String?
        var surface: String
        var recordedAt: Date
    }

    // MARK: - The envelope

    /// Hard bounds. The band is a BUDGET, not an instruction, and these are the
    /// numbers that make "mis-sized envelope truncates real work" structurally
    /// impossible rather than merely unlikely.
    static let envelopeFloorCharacters = 40
    static let envelopeCeilingCharacters = 4_000
    /// Where a neutral read lands. Deliberately wide — the envelope's job is to
    /// notice the EXTREMES (a one-word ping, an exhausted 4am turn), not to
    /// second-guess ordinary replies.
    static let envelopeNeutralCharacters = 900

    /// Compute the envelope from felt state + the size of what the user sent.
    /// PURE and total: no I/O, no mutation, no clock read. Every term is bounded
    /// and the result is clamped, so this function cannot return a band outside
    /// `envelopeFloorCharacters…envelopeCeilingCharacters` for any input.
    ///
    /// The three terms, in the order P6 names them:
    ///  1. SERVE SIZE — the continuous generalization of the lexicon classifier.
    ///     A 12-character ping and a 900-character brief are different turns, and
    ///     unlike the shipped boolean this reads every goal type.
    ///  2. FELT STATE — fatigue and pressure shorten; curiosity and arousal with
    ///     positive valence lengthen. "Feeling changes how much you say and how
    ///     fast", which is the sentence the whole item exists for.
    ///  3. THE `brevity` TRAIT — via `deliveryBrevityCenter`, the P1 field parked
    ///     in the configuration precisely so this had a home the moment it landed.
    ///     0.5 (neutral dials) contributes exactly zero.
    static func deliveryEnvelope(
        signals: FeltSignals,
        serveCharacters: Int,
        dynamics: PersonalityDynamicsConfiguration
    ) -> DeliveryEnvelope {
        // 1. Serve size → 0…1, saturating around a paragraph. `log1p` rather than
        // a linear ramp because the difference between 10 and 60 characters is a
        // different KIND of turn, while 900 vs 1200 is not.
        let serve = max(0, Double(serveCharacters))
        let servePrior = min(1, log1p(serve / 24) / log1p(600.0 / 24))

        // 2. Felt state → −1…1. Read through `read(_:)` so an install with the
        // organism off (fatigue/curiosity absent) gets the neutral 0.5 and this
        // term simply goes quiet, rather than the dims being faked.
        let shortening = signals.read(.fatigue) * 0.6 + signals.pressure * 0.4
        let lengthening = signals.read(.curiosity) * 0.5
            + max(0, signals.valence) * signals.arousal * 0.5
        let feltTerm = (lengthening - shortening).clampedSigned()

        // 3. brevity: 0 (verbose persona) … 1 (terse persona), 0.5 neutral.
        let brevityTerm = (dynamics.deliveryBrevityCenter.clamped01() - 0.5) * 2

        // The prior: the serve leads (it is the most direct evidence of what this
        // turn IS), felt state and the trait lean it.
        let prior = (
            0.60 * servePrior
                + 0.25 * (feltTerm + 1) / 2
                + 0.15 * (1 - (brevityTerm + 1) / 2)
        ).clamped01()

        // Band: geometric around the neutral center so the prior moves the band
        // proportionally rather than additively — a terse read must be able to
        // reach one-beat territory without the ceiling dragging it back.
        let center = Double(envelopeNeutralCharacters) * pow(6.0, prior - 0.5)
        // Factor ratio (1.45/0.55 ≈ 2.6) is deliberately kept BELOW the band
        // spread between a ping's prior and a brief's prior (6^Δprior ≈ 2.8 at
        // neutral felt state), so a one-word ping's ceiling lands under a long
        // brief's floor — different turns get disjoint budgets, not merely
        // shifted ones. Widening either factor past that ratio re-overlaps them.
        let low = Int(max(Double(envelopeFloorCharacters), (center * 0.55).rounded()))
        let high = Int(min(Double(envelopeCeilingCharacters), (center * 1.45).rounded()))

        // ONE BEAT: a genuinely short serve on a moment carrying no pressure and
        // no urgency. Both halves required — a short message during a tense push
        // is often the most load-bearing turn of the session.
        let oneBeat = serveCharacters <= 48
            && signals.pressure <= 0.35
            && signals.tension <= 0.35
            && prior <= 0.42

        return DeliveryEnvelope(
            minimumCharacters: min(low, high),
            maximumCharacters: max(low, high),
            oneBeat: oneBeat,
            sizePrior: prior
        )
    }

    // MARK: - Telemetry

    /// `<dataRoot>/logs/delivery_envelope_telemetry.jsonl`, derived from the
    /// STORE'S data root rather than a process default. Hermetic by construction:
    /// a substrate built without a store (every non-persistent test) has no
    /// telemetry path at all and writes nothing, so no test can leak a row into
    /// the live app's data root.
    var deliveryEnvelopeTelemetryPath: URL? {
        guard let root = storeDataRoot else { return nil }
        return root
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("delivery_envelope_telemetry.jsonl")
    }

    /// Newest-N rotation, matching the other bounded local ledgers. Small on
    /// purpose: this is a distribution sample for one staged decision, not a
    /// permanent record of every reply the agent has ever made.
    static let deliveryEnvelopeTelemetryMaxLines = 5_000

    /// The committed-turn entry point. The live chat turn compiles its capsule
    /// on the FROZEN path, so the compile can't own the stash (the first cut
    /// put it on `compileCapsule`'s live path, which real turns never hit —
    /// the telemetry was dark for a full live QA pass, 2026-08-11). The app
    /// runtime calls this from `commitTurnProjection`, the one moment that
    /// certifies "this capsule actually served a live turn". Signals are
    /// recomputed live milliseconds after the frozen read — for a length
    /// telemetry sample that drift is noise.
    public func stashDeliveryEnvelopeForCommittedTurn(
        _ request: CognitiveCapsuleRequest,
        at now: Date
    ) async {
        guard configuration.enabled, configuration.capsuleInjectionEnabled else { return }
        let workspace = await workspaceSnapshot(currentSessionId: request.sessionId)
        let items = workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) }
        let signals = feltSignalsForCapsule(from: items, request: request, at: now)
        stashDeliveryEnvelope(signals: signals, request: request, at: now)
    }

    /// Stash the envelope for this turn. Overwrites any previous stash: the
    /// latest turn is the one in the room, exactly as `pendingCompletion`
    /// treats completions.
    func stashDeliveryEnvelope(
        signals: FeltSignals,
        request: CognitiveCapsuleRequest,
        at now: Date
    ) {
        let serve = request.userMessage.trimmingCharacters(in: .whitespacesAndNewlines).count
        pendingDeliveryEnvelope = PendingDeliveryEnvelope(
            envelope: Self.deliveryEnvelope(
                signals: signals, serveCharacters: serve, dynamics: dynamics),
            serveCharacters: serve,
            sessionId: request.sessionId,
            surface: request.surface,
            recordedAt: now
        )
    }

    /// Pair the stashed envelope with the reply that actually happened and write
    /// one bounded row. Consumes the stash either way — an envelope that missed
    /// its completion is stale, and a stale envelope logged against a later reply
    /// would poison the very distribution this exists to measure.
    ///
    /// Returns the row it wrote (nil when nothing was written) so tests can read
    /// the pairing without parsing the file.
    @discardableResult
    func consumeDeliveryEnvelopeTelemetry(
        replyCharacters: Int,
        sessionId: String?,
        at now: Date
    ) -> JSONValue? {
        guard let pending = pendingDeliveryEnvelope else { return nil }
        pendingDeliveryEnvelope = nil
        // A completion from a different session is not the reply this envelope
        // was computed for. Same rule the reaction linkage already enforces.
        if let stashed = pending.sessionId, let landed = sessionId, stashed != landed {
            return nil
        }
        let age = now.timeIntervalSince(pending.recordedAt)
        guard age >= 0, age <= Self.pendingCompletionMaxAge else { return nil }

        let row = JSONValue.object([
            "schema": .string("delivery_envelope_telemetry.v1"),
            "at": .string(Self.telemetryTimestamp(now)),
            "surface": .string(pending.surface),
            "serveCharacters": .int(Int64(pending.serveCharacters)),
            "replyCharacters": .int(Int64(max(0, replyCharacters))),
            "envelopeMinimumCharacters": .int(Int64(pending.envelope.minimumCharacters)),
            "envelopeMaximumCharacters": .int(Int64(pending.envelope.maximumCharacters)),
            "envelopeOneBeat": .bool(pending.envelope.oneBeat),
            "envelopeSizePrior": .double(pending.envelope.sizePrior),
            // The measurement the staged decision actually turns on: was the real
            // reply inside the band the mechanism would have imposed?
            "insideBand": .bool(
                replyCharacters >= pending.envelope.minimumCharacters
                    && replyCharacters <= pending.envelope.maximumCharacters),
            // NO reply text, no user text, no session id, no felt WORDS — a
            // length telemetry file has no business carrying conversation
            // content, and this one carries none.
        ])
        writeDeliveryEnvelopeTelemetry(row)
        return row
    }

    /// Fire-and-forget so a slow disk can never add latency to a turn, and
    /// detached so the append does not hold the substrate actor while it takes
    /// the file lock. Telemetry that can stall the conversation is worse than no
    /// telemetry.
    private func writeDeliveryEnvelopeTelemetry(_ row: JSONValue) {
        guard let path = deliveryEnvelopeTelemetryPath else { return }
        Task.detached(priority: .utility) {
            do {
                try await appendDeliveryEnvelopeTelemetryRow(row, to: path)
            } catch {
                NSLog("CognitiveSubstrate: delivery envelope telemetry write failed: %@",
                      String(describing: error))
            }
        }
    }

    static func telemetryTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

/// Nonisolated so the detached writer can call it without re-entering the actor.
/// Routes through the shared capped append (the same owner every other bounded
/// JSONL ledger uses) rather than hand-rolling a rotation that would drift.
func appendDeliveryEnvelopeTelemetryRow(_ row: JSONValue, to path: URL) async throws {
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await appendJSONLCapped(
        row,
        to: path,
        using: SwiftNativePersistenceCore(),
        maxLines: CognitiveSubstrate.deliveryEnvelopeTelemetryMaxLines,
        logLabel: "CognitiveSubstrate"
    )
}
