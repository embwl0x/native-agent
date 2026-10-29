import Foundation
import CognitiveSubstrate
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import ProviderRouting
import NativeAgentShared

// Blueprint: | `NativeCognitionRuntime+ProviderVitals.swift` | `NativeCognitionRuntime` provider interoception: passive vitals persistence, health-band transitions and graded somatic ingestion |

// INTEROCEPTION — production wiring for the passive provider vitals organ.
//
// `observeProviderCall` (NativeCognitionRuntime+Events) feeds every non-debug
// lifecycle event to `providerVitalsSensor`. When a provider crosses a health
// band, the sensor returns a transition; here we mint the graded
// `.providerVitalsShift` CognitiveEvent, run it through the SAME
// `CognitiveSomaticSignals` the design specifies, and ingest the resulting
// graded somatic signal — so sluggishness is FELT on the existing provider axis
// (chemistry → mood → capsule), no new capsule slot.
//
// Provider health bands affect the body without posting inbox cards.

extension NativeCognitionRuntime {
    /// Bootstrap-owned restore. Snapshot age and row validity are enforced by
    /// the sensor; a missing or stale file is a normal cold start. First
    /// outputs come from the retained traces, which grow with her history, so
    /// launch and her first turn never wait on that read.
    /// A stream that starts before the read lands runs unmeasured.
    func restoreProviderVitalsSnapshot() async {
        do {
            _ = try await providerVitalsSensor.restoreSnapshot(dataRoot: dataRoot, now: now())
        } catch {
            nativeLog("Provider vitals snapshot unavailable: %@", error.localizedDescription)
        }
        let sensor = providerVitalsSensor, root = dataRoot, cutoff = now()
        Task.detached(priority: .utility) {
            do {
                try await sensor.readFirstOutputs(dataRoot: root, before: cutoff)
            } catch {
                nativeLog("Provider first outputs unreadable from retained traces (first-output deadlines learn from this run's calls only): %@",
                          error.localizedDescription)
            }
        }
    }

    /// The stream guard's read port: the sensor is a `let`, so no hop onto
    /// this actor. Unmeasured until the launch read of first outputs lands.
    public nonisolated func firstOutputDeadline(provider: String, model: String,
                                                streamKind: String?, requestBytes: Int) async -> FirstOutputDeadline {
        await providerVitalsSensor.firstOutputDeadline(provider: provider, model: model, streamKind: streamKind, requestBytes: requestBytes)
    }

    /// Diagnostics: each provider's first outputs and cuts, as the guard sees them.
    public nonisolated func providerFirstOutputs() async -> String {
        await providerVitalsSensor.firstOutputReport()
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
    }

    /// Bootstrap archives any active provider-vitals inbox cards.
    func retireProviderVitalsNotices() async {
        let inbox = LiveNotificationInbox.live(dataRoot: dataRoot)
        do {
            let ids = try await inbox.rows().compactMap { row -> String? in
                guard case .object(let object) = row,
                      case .string("provider_vitals")? = object["source"],
                      case .string(let id)? = object["id"] else { return nil }
                return id
            }
            _ = try await inbox.archiveActive(
                ids: ids, readAt: ISO8601DateFormatter().string(from: now())
            )
        } catch {
            FileHandle.standardError.write(
                Data("ProviderVitals: retiring old inbox cards failed: \(error)\n".utf8)
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
            CognitiveSomaticSignals.vitalsDirectionMetadataKey: .string(transition.direction.rawValue),
            "emaErrorRate": .double(transition.emaErrorRate),
            "consecutiveFailures": .int(Int64(transition.consecutiveFailures)),
        ]
        if let ratio = transition.latencyRatio { metadata["latencyRatio"] = .double(ratio) }

        let event = CognitiveEvent(
            id: "provider-vitals-\(transition.providerId)-\(transition.to.label)-\(String(format: "%.0f", transition.occurredAt.timeIntervalSince1970.rounded(.towardZero) + 0))",
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

        guard let signal = CognitiveSomaticSignals.signal(from: event, id: UUID()) else { return }
        // Provider lifecycle is body evidence, not new semantic context — mirror
        // the raw provider path: coalesced persistence.
        await ingestPreparedOrganismSignal(
            signal, persistSynchronously: false
        )
    }
}
