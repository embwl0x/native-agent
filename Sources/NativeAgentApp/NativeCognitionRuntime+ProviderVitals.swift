import Foundation
import CognitiveSubstrate
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// INTEROCEPTION — production wiring for the passive provider vitals organ.
//
// `observeProviderCall` (NativeCognitionRuntime+Events) feeds every non-debug
// lifecycle event to `providerVitalsSensor`. When a provider crosses a health
// band, the sensor returns a transition; here we mint the graded
// `.providerVitalsShift` CognitiveEvent, run it through the SAME
// `CognitiveSomaticSignalAdapter` the design specifies, and ingest the resulting
// graded somatic signal — so sluggishness is FELT on the existing provider axis
// (chemistry → mood → capsule), no new capsule slot.
//
// CARD LANE IS OFF THE TURN PATH (gpt-5.5 review BLOCKING #1): the lifecycle
// feed does in-memory sensor work + (rare) organism ingest ONLY. Proposal-store
// I/O runs in a detached, actor-serialized, single-flight sweep scheduled on
// TERMINAL events — a provider dispatch never awaits `proposals.json`.
//
// THE CARD IS AN INBOX NOTICE, NOT A PSEUDO-APPROVAL. First cut used
// EvolutionProposalStore; empirical testing exposed that a diff-less proposal
// lands `.needsDiff` — an "approval" card that can never be approved, i.e.
// decision theater (and "approving" was already documented as executing
// nothing: switching providers is the user's model-picker move). The honest
// surface is the LIVE notifications inbox (notifications/inbox.jsonl — the one
// the UI and iOS read), with append-only EVENT-LOG semantics:
//   stage    → one "degraded" notice, unless the provider's LATEST vitals row
//              is already an unrecovered degradation (disk-derived idempotency,
//              restart-safe with no in-memory map — review BLOCKING #2)
//   recovery → one "recovered" info notice; the degradation notice stays as
//              historical truth. No status mutation, no orphaned state.

extension NativeCognitionRuntime {
    /// Termination-owned snapshot persistence (the ONLY disk write in the
    /// organ; never on the observe path). Called from applicationWillTerminate.
    func persistProviderVitalsSnapshot() async {
        await providerVitalsSensor.persistSnapshot(dataRoot: dataRoot)
    }

    /// Feed one lifecycle event to the sensor and route any band transition.
    /// Called from `observeProviderCall` after the debug-session guard, so a
    /// diagnostic/bridge call never moves a band by itself.
    ///
    /// Turn-path budget: one in-memory sensor update; on the rare band
    /// transition, one organism ingest (the same cost class as the existing
    /// `.providerFailure` signal). NO disk I/O here.
    func feedProviderVitals(_ event: LLMCallLifecycleEvent) async {
        if let transition = await providerVitalsSensor.ingest(lifecycle: event) {
            await ingestProviderVitalsTransition(transition)
        }
        // Card decisions are dwell-based (minutes), so terminal events are a
        // more-than-sufficient trigger; .started never touches the card lane.
        if event.phase != .started {
            scheduleProviderVitalsCardSweep()
        }
    }

    /// Single-flight, actor-serialized background sweep. The turn path only
    /// flips a flag and spawns; the sweep re-enters the actor to run.
    private func scheduleProviderVitalsCardSweep() {
        guard !providerVitalsCardSweepInFlight else { return }
        providerVitalsCardSweepInFlight = true
        Task { [weak self] in
            guard let self else { return }
            await self.sweepProviderVitalsCards()
        }
    }

    private func sweepProviderVitalsCards() async {
        defer { providerVitalsCardSweepInFlight = false }
        let decisions = await providerVitalsSensor.evaluateCardDecisions(now: now())
        guard !decisions.isEmpty else { return }
        for decision in decisions {
            switch decision {
            case .stage(let providerId, let transition):
                await stageProviderVitalsNotice(providerId: providerId, transition: transition)
            case .expire(let providerId):
                await postProviderVitalsRecoveryNotice(providerId: providerId)
            }
        }
    }

    private var providerVitalsInboxPath: URL {
        dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    /// The provider's latest vitals inbox row, if any ("degraded" or
    /// "recovered" — event-log semantics; the LATEST row is the live state).
    func latestProviderVitalsNoticeKind(providerId: String) async -> String? {
        let persistence = SwiftNativePersistenceCore()
        let rows = (try? await persistence.readJSONL(providerVitalsInboxPath)) ?? []
        for row in rows.reversed() {
            guard case .object(let obj) = row,
                  case .string(let source)? = obj["source"], source == "provider_vitals",
                  case .string(let provider)? = obj["providerVitalsProvider"],
                  provider == providerId,
                  case .string(let kind)? = obj["providerVitalsKind"] else { continue }
            return kind
        }
        return nil
    }

    func stageProviderVitalsNotice(
        providerId: String,
        transition: ProviderVitalsTransition
    ) async {
        // Disk-derived idempotency: if the latest vitals row for this provider
        // is already an unrecovered degradation notice — this run or any prior
        // run — nothing to do.
        if await latestProviderVitalsNoticeKind(providerId: providerId) == "degraded" {
            return
        }
        await appendProviderVitalsNotice(
            providerId: providerId,
            kind: "degraded",
            severity: "important",
            title: providerVitalsCardTitle(providerId: providerId, transition: transition),
            message: providerVitalsCardEvidence(providerId: providerId, transition: transition)
        )
    }

    func postProviderVitalsRecoveryNotice(providerId: String) async {
        // Only meaningful when the latest row is an open degradation notice.
        guard await latestProviderVitalsNoticeKind(providerId: providerId) == "degraded" else {
            return
        }
        await appendProviderVitalsNotice(
            providerId: providerId,
            kind: "recovered",
            severity: "info",
            title: "\(providerId) recovered",
            message: "\(providerId) is back to normal speed — no action needed."
        )
    }

    private func appendProviderVitalsNotice(
        providerId: String,
        kind: String,
        severity: String,
        title: String,
        message: String
    ) async {
        let stamp = ISO8601DateFormatter().string(from: now())
        let row: JSONValue = .object([
            "id": .string("provider-vitals-\(kind)-\(providerId)-\(UUID().uuidString.lowercased())"),
            "created_at": .string(stamp),
            "source": .string("provider_vitals"),
            "severity": .string(severity),
            "title": .string(String(title.prefix(160))),
            "summary": .string(String(message.prefix(500))),
            "detail": .string(String(message.prefix(2000))),
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .array([]),
            "related_groups": .array([]),
            "actions": .array([]),
            "status": .string("unread"),
            "read_at": .null,
            "providerVitalsProvider": .string(providerId),
            "providerVitalsKind": .string(kind),
        ])
        let persistence = SwiftNativePersistenceCore()
        do {
            try await appendJSONLCapped(
                row, to: providerVitalsInboxPath, using: persistence,
                maxLines: JSONLLineCaps.notificationInbox,
                logLabel: "ProviderVitals.inbox"
            )
        } catch {
            FileHandle.standardError.write(
                Data("ProviderVitals: inbox notice append failed for \(providerId): \(error)\n".utf8)
            )
        }
    }

    /// Mint the graded CognitiveEvent, map it through the somatic adapter, and
    /// ingest the resulting signal. Importance grades the felt intensity by band
    /// (sluggish < degraded); a recovery reads as relief.
    private func ingestProviderVitalsTransition(_ transition: ProviderVitalsTransition) async {
        let importance: Double
        switch (transition.direction, transition.to) {
        case (.worsening, .degraded): importance = 0.75
        case (.worsening, .sluggish): importance = 0.5
        case (.worsening, _): importance = 0.5
        case (.recovering, _): importance = 0.4
        }

        var metadata: [String: JSONValue] = [
            "providerId": .string(transition.providerId),
            "band": .string(transition.to.label),
            "fromBand": .string(transition.from.label),
            CognitiveSomaticSignalAdapter.vitalsDirectionMetadataKey: .string(transition.direction.rawValue),
            "emaErrorRate": .double(transition.emaErrorRate),
            "consecutiveFailures": .int(Int64(transition.consecutiveFailures)),
        ]
        if let ratio = transition.latencyRatio { metadata["latencyRatio"] = .double(ratio) }

        let event = CognitiveEvent(
            id: "provider-vitals-\(transition.providerId)-\(transition.to.label)-\(Int(transition.occurredAt.timeIntervalSince1970))",
            kind: .providerVitalsShift,
            subject: CognitiveSubjectReference(
                type: "provider",
                id: transition.providerId,
                label: transition.providerId
            ),
            sourceClass: .observed,
            occurredAt: transition.occurredAt,
            summary: "\(transition.providerId) provider is \(transition.to.label) (was \(transition.from.label))",
            importance: importance,
            metadata: metadata
        )

        guard let signal = CognitiveSomaticSignalAdapter.signal(from: event, id: UUID()) else { return }
        // Provider lifecycle is body evidence, not new semantic context — mirror
        // the raw provider path: coalesced persistence, no context prewarm.
        await ingestPreparedOrganismSignal(
            signal, persistSynchronously: false, prewarmContext: false
        )
    }

    private func providerVitalsCardTitle(
        providerId: String,
        transition: ProviderVitalsTransition
    ) -> String {
        if let ratio = transition.latencyRatio, ratio >= 1.8 {
            return "\(providerId) is at half speed — ride a healthy provider until it recovers?"
        }
        return "\(providerId) is degraded — ride a healthy provider until it recovers?"
    }

    private func providerVitalsCardEvidence(
        providerId: String,
        transition: ProviderVitalsTransition
    ) -> String {
        var parts: [String] = [
            "Provider \(providerId) has held a degraded health band for the sustained-degradation window.",
        ]
        if let ratio = transition.latencyRatio {
            // A4.9: a sub-baseline ratio during degradation is the FAST-FAIL
            // signature (errors return quicker than healthy responses) — say
            // so, or the card reads like good news inside a degradation notice.
            if ratio < 1.0 {
                parts.append(String(
                    format: "Requests are fast-failing — %.1f× baseline latency, the signature of errors returning faster than real responses.",
                    ratio))
            } else {
                parts.append(String(format: "Latency is running %.1f× its own baseline.", ratio))
            }
        }
        if transition.emaErrorRate > 0.05 {
            parts.append(String(format: "Error rate EMA %.0f%%.", transition.emaErrorRate * 100))
        }
        if transition.consecutiveFailures > 0 {
            parts.append("Consecutive-failure run: \(transition.consecutiveFailures).")
        }
        parts.append("This card only proposes — approving it does not switch providers; use the surface model picker to ride another provider until this one recovers.")
        return parts.joined(separator: " ")
    }
}
