import Foundation
import CognitiveSubstrate
import NativeAgentCore
import NotificationInbox
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
// the UI and iOS read), with one active state per provider and archived event
// history. A recovery cannot coexist with an unread degradation warning, while
// disk-derived idempotency stays restart-safe with no in-memory association.

extension NativeCognitionRuntime {
    /// Bootstrap-owned restore. Snapshot age and row validity are enforced by
    /// the sensor; a missing or stale file is a normal cold start.
    func restoreProviderVitalsSnapshot() async {
        _ = await providerVitalsSensor.restoreSnapshot(dataRoot: dataRoot, now: now())
    }

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
        await reconcileProviderVitalsNotices()
        let decisions = await providerVitalsSensor.evaluateCardDecisions(now: now())
        guard !decisions.isEmpty else { return }
        for decision in decisions {
            switch decision {
            case .stage(let providerId, let transition):
                // User, 2026-09-06: the sensor flips its card latch BEFORE this
                // write, and the write can fail (a lock or disk error is logged
                // and swallowed). That permanently consumed the transition: the
                // latch said a card was up, none existed, and it was never
                // re-staged. Put the latch back so the next sweep retries.
                if await !stageProviderVitalsNotice(
                    providerId: providerId, transition: transition
                ) {
                    await providerVitalsSensor.revertCardLatch(
                        providerId: providerId, to: false
                    )
                }
            case .expire(let providerId):
                if await !postProviderVitalsRecoveryNotice(providerId: providerId) {
                    await providerVitalsSensor.revertCardLatch(
                        providerId: providerId, to: true
                    )
                }
            }
        }
    }

    private var providerVitalsInboxPath: URL {
        dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    /// Repairs rows from builds that kept every provider state active. The
    /// newest state remains untouched; older active states become archived
    /// history. Bootstrap runs this even when no new transition is due.
    func reconcileProviderVitalsNotices() async {
        do {
            _ = try await LiveNotificationInbox(path: providerVitalsInboxPath)
                .archiveSupersededActiveRows(
                    source: "provider_vitals",
                    groupField: "providerVitalsProvider",
                    readAt: ISO8601DateFormatter().string(from: now())
                )
        } catch {
            FileHandle.standardError.write(
                Data("ProviderVitals: inbox reconciliation failed: \(error)\n".utf8)
            )
        }
    }

    /// Returns false ONLY when the inbox write itself failed — a gate that
    /// declines the append (the state is already on disk) is a success.
    @discardableResult
    func stageProviderVitalsNotice(
        providerId: String,
        transition: ProviderVitalsTransition
    ) async -> Bool {
        // Disk-derived idempotency: if the latest vitals row for this provider
        // is already an unrecovered degradation notice — this run or any prior
        // run — nothing to do. The check runs INSIDE the inbox lock together
        // with the append (see `appendProviderVitalsNotice`).
        await appendProviderVitalsNotice(
            providerId: providerId,
            kind: "degraded",
            severity: "important",
            title: providerVitalsCardTitle(providerId: providerId, transition: transition),
            message: providerVitalsCardEvidence(providerId: providerId, transition: transition),
            gateOnLatestKind: { $0 != "degraded" }
        )
    }

    @discardableResult
    func postProviderVitalsRecoveryNotice(providerId: String) async -> Bool {
        // User, 2026-09-06: the card expires as soon as the band drops BELOW
        // degraded, and that includes `sluggish` — so a provider that was still
        // measurably slow got a card announcing it was "back to normal speed".
        // The wording follows the band the sensor actually reads now.
        let band = await providerVitalsSensor.vitals(for: providerId)?.band
        let message: String = band == .sluggish
            ? "\(providerId) is no longer degraded, but is still slower than usual — no action needed."
            : "\(providerId) is back to normal speed — no action needed."
        let title = band == .sluggish
            ? "\(providerId) no longer degraded"
            : "\(providerId) recovered"
        // Only meaningful when the latest row is an open degradation notice —
        // checked under the same lock as the append.
        return await appendProviderVitalsNotice(
            providerId: providerId,
            kind: "recovered",
            severity: "info",
            title: title,
            message: message,
            gateOnLatestKind: { $0 == "degraded" }
        )
    }

    /// Append one vitals notice iff `gateOnLatestKind` accepts the provider's
    /// latest on-disk state. Gate, retirement of the prior active state, and
    /// append run as one canonical inbox transaction.
    /// Returns false only when the transaction THREW; a gate refusal is a
    /// success (the disk already carries the state the caller wanted).
    private func appendProviderVitalsNotice(
        providerId: String,
        kind: String,
        severity: String,
        title: String,
        message: String,
        gateOnLatestKind: @escaping @Sendable (String?) -> Bool
    ) async -> Bool {
        let stamp = ISO8601DateFormatter().string(from: now())
        let cardID = "provider-vitals-\(kind)-\(providerId)-\(UUID().uuidString.lowercased())"
        let row: JSONValue = .object([
            "id": .string(cardID),
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
        do {
            _ = try await LiveNotificationInbox(path: providerVitalsInboxPath)
                .appendReplacingActiveGroup(
                    row,
                    id: cardID,
                    source: "provider_vitals",
                    groupField: "providerVitalsProvider",
                    groupValue: providerId,
                    stateField: "providerVitalsKind",
                    transitionAt: stamp,
                    ifLatestStateAllows: gateOnLatestKind
                )
            return true
        } catch {
            // A read/lock/write failure ABORTS the notice — no card is better
            // than a duplicate `degraded` card the recovery gate can't clear.
            FileHandle.standardError.write(
                Data("ProviderVitals: inbox notice (\(kind)) failed for \(providerId): \(error)\n".utf8)
            )
            return false
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
