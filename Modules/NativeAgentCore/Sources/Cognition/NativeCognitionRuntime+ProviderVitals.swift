import Foundation
import CognitiveSubstrate
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import ProviderRouting
import NativeAgentShared

// Blueprint: | `NativeCognitionRuntime+ProviderVitals.swift` | `NativeCognitionRuntime`. |

// Route passive provider health transitions through the existing graded somatic path so felt sluggishness needs no new capsule slot.
// Reuse actual lifecycle evidence without provider calls or inbox cards.

extension NativeCognitionRuntime {
    /// The sensor validates snapshot age and rows; absent or stale snapshots start cold.
    /// Load retained first-output traces without blocking launch or turns; streams remain unmeasured until publication.
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

    /// The immutable sensor permits actor-free guard reads; evidence stays unmeasured until bootstrap publication.
    public nonisolated func firstOutputDeadline(provider: String, model: String,
                                                streamKind: String?, requestBytes: Int) async -> FirstOutputDeadline {
        await providerVitalsSensor.firstOutputDeadline(provider: provider, model: model, streamKind: streamKind, requestBytes: requestBytes)
    }

    public nonisolated func providerFirstOutputs() async -> String {
        await providerVitalsSensor.firstOutputReport()
    }

    /// Persist only at termination, never on the observation path.
    func persistProviderVitalsSnapshot() async {
        await providerVitalsSensor.persistSnapshot(dataRoot: dataRoot)
    }

    /// Observe actual lifecycle calls in memory only; ingest a body signal solely on health-band transitions.
    func feedProviderVitals(_ event: LLMCallLifecycleEvent) async {
        if let transition = await providerVitalsSensor.ingest(lifecycle: event) {
            await ingestProviderVitalsTransition(transition)
        }
    }

    /// Map health bands through graded somatic evidence so degradation intensity and recovery relief share the existing body path.
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
        // Lifecycle evidence is not semantic context; coalesce its persistence.
        await ingestPreparedOrganismSignal(
            signal, persistSynchronously: false
        )
    }
}
