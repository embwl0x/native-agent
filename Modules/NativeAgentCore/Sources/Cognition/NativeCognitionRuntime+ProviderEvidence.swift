// Move-only extraction (tightness Wave C) from NativeCognitionRuntime.swift

import Foundation
import ChatOrchestration
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting

extension NativeCognitionRuntime {
    public nonisolated static func providerPathEvidence(
        providerID: String, dataRoot: URL, since: Date, now: Date = Date()
    ) async throws -> (model: String, observedAt: Date)? {
        let receipt = try await SwiftNativePersistenceCore().readJSONLReporting(
            dataRoot.appendingPathComponent("traces/events.jsonl"))
        guard receipt.report.malformedLineCount == 0 else {
            throw PersistenceCoreError.ioFailure("Provider evidence is incomplete; repair traces/events.jsonl before checking the provider.")
        }
        var newest: (model: String, observedAt: Date)?
        for row in receipt.rows {
            guard let decoded = Self.decodeProviderLifecycleEvidence(row),
                  decoded.provider == providerID, decoded.evidence.outcome == .succeeded,
                  decoded.evidence.observedAt >= since, decoded.evidence.observedAt <= now,
                  decoded.evidence.observedAt > (newest?.observedAt ?? .distantPast) else { continue }
            newest = (decoded.model, decoded.evidence.observedAt)
        }
        return newest
    }

    func recordProviderLifecycleEvidence(_ event: LLMCallLifecycleEvent) {
        let outcome: ProviderPathEvidenceOutcome
        switch event.phase {
        case .started: outcome = .started
        case .succeeded: outcome = .succeeded
        case .failed: outcome = .failed
        case .cancelled: outcome = .cancelled
        }
        providerLifecycleEvidenceByCallID[event.id] = ProviderPathEvidence(
            evidenceID: "provider-call:\(event.id)",
            observedAt: event.occurredAt,
            outcome: outcome
        )
        enforceProviderLifecycleEvidenceCapacity()
        cachedBodyRead = nil
        publishRuntimeChange(reason: "provider_lifecycle:\(event.phase.rawValue)")
    }

    func providerPathEvidence(at date: Date) -> [ProviderPathEvidence] {
        providerLifecycleEvidenceByCallID.values.map { evidence in
            guard evidence.outcome == .started,
                  date.timeIntervalSince(evidence.observedAt) >= Self.providerLifecycleExpiry
            else { return evidence }
            return ProviderPathEvidence(
                evidenceID: evidence.evidenceID,
                observedAt: evidence.observedAt.addingTimeInterval(Self.providerLifecycleExpiry),
                outcome: .expired
            )
        }
    }

    func restoreProviderLifecycleEvidence() async {  // internal for actor extensions (move-only Wave C)
        let path = dataRoot.appendingPathComponent("traces/events.jsonl")
        // This feed interleaves provider calls with tool, preload, plan and
        // memory rows. Read a bounded mixed-event window, then keep the newest
        // provider outcomes; tailing only 32 mixed rows restored just 15 live
        // outcomes and made healthy providers look uncertain after restart.
        let rows = (try? await SwiftNativePersistenceCore().tailJSONL(
            path,
            limit: Self.maximumProviderLifecycleEvidence * 64,
            maxBytes: 1_048_576
        )) ?? []
        var restored: [String: ProviderPathEvidence] = [:]
        for row in rows.reversed() {
            guard restored.count < Self.maximumProviderLifecycleEvidence else { break }
            guard let decoded = Self.decodeProviderLifecycleEvidence(row) else { continue }
            let evidence = decoded.evidence
            restored[evidence.evidenceID] = evidence
        }
        for (key, value) in restored where providerLifecycleEvidenceByCallID[key] == nil {
            providerLifecycleEvidenceByCallID[key] = value
        }
        enforceProviderLifecycleEvidenceCapacity()
        if !restored.isEmpty { cachedBodyRead = nil }
    }

    private nonisolated static func decodeProviderLifecycleEvidence(
        _ row: JSONValue
    ) -> (provider: String, model: String, evidence: ProviderPathEvidence)? {
        guard case .object(let object) = row,
              case .string("llm.call")? = object["kind"],
              case .string(let rawDate)? = object["createdAt"],
              let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(rawDate))
                ?? (try? Date.ISO8601FormatStyle().parse(rawDate)),
              case .object(let payload)? = object["payload"],
              case .string(let provider)? = payload["provider"],
              case .string(let model)? = payload["model"] else { return nil }
        let outcome: ProviderPathEvidenceOutcome = {
            guard case .string(let status)? = object["status"] else {
                return .succeeded // completed rows from before status existed
            }
            switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "ok", "succeeded", "completed": return .succeeded
            case "cancelled", "canceled": return .cancelled
            default: return .failed
            }
        }()
        let rowID: String = {
            if case .string(let id)? = object["id"], !id.isEmpty { return id }
            return "\(provider):\(model):\(rawDate)"
        }()
        return (provider, model, ProviderPathEvidence(
            evidenceID: "trace-call:\(rowID)", observedAt: date, outcome: outcome))
    }

    /// The trace tail is a transient sensor and may be unavailable during the
    /// launch race. The organism's cumulative capability belief is already a
    /// durable projection over exact lifecycle outcomes, so it can bridge that
    /// gap without manufacturing duplicate observations or extending the
    /// provider body's six-hour freshness window.
    nonisolated static func providerCapabilityFallbackProjection(
        _ capability: OrganismCapabilityBelief?,
        now: Date,
        halfLife: TimeInterval = 2 * 60 * 60,
        staleAfter: TimeInterval = 6 * 60 * 60
    ) -> ProviderPathBeliefProjection? {
        guard let capability,
              capability.kind == .providerCompletion,
              capability.evidenceBasis == .cumulativeOutcomes,
              capability.evidenceCount > 0,
              let lastEvidenceAt = capability.lastEvidenceAt else { return nil }
        let boundedHalfLife = halfLife.isFinite ? max(1, halfLife) : 2 * 60 * 60
        let boundedStaleAfter = staleAfter.isFinite
            ? max(boundedHalfLife, staleAfter)
            : 6 * 60 * 60
        let age = max(0, now.timeIntervalSince(lastEvidenceAt))
        let freshness = age <= boundedStaleAfter
            ? exp(-log(2) * age / boundedHalfLife)
            : 0
        return ProviderPathBeliefProjection(
            generatedAt: now,
            estimate: capability.successLikelihood,
            freshness: freshness,
            uncertainty: capability.uncertainty,
            evidenceCount: capability.evidenceCount,
            newestEvidenceAt: lastEvidenceAt,
            state: .unobserved,
            bodySchemaProvidersHealthy: nil
        )
    }

    private func enforceProviderLifecycleEvidenceCapacity() {
        guard providerLifecycleEvidenceByCallID.count > Self.maximumProviderLifecycleEvidence else {
            return
        }
        let keep = providerLifecycleEvidenceByCallID
            .sorted {
                if $0.value.observedAt != $1.value.observedAt {
                    return $0.value.observedAt > $1.value.observedAt
                }
                return $0.key < $1.key
            }
            .prefix(Self.maximumProviderLifecycleEvidence)
        providerLifecycleEvidenceByCallID = Dictionary(
            uniqueKeysWithValues: keep.map { ($0.key, $0.value) }
        )
    }
}
