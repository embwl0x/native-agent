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
        if providerLifecycleEvidenceByCallID.count > Self.maximumProviderLifecycleEvidence {
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
        let rows = (try? await SwiftNativePersistenceCore().tailJSONL(
            path,
            limit: Self.maximumProviderLifecycleEvidence,
            maxBytes: 1_048_576
        )) ?? []
        var restored: [String: ProviderPathEvidence] = [:]
        for row in rows {
            guard case .object(let object) = row,
                  case .string("llm.call")? = object["kind"],
                  case .string(let rawDate)? = object["createdAt"],
                  let date = ISO8601DateFormatter().date(from: rawDate),
                  case .object(let payload)? = object["payload"],
                  case .string(let provider)? = payload["provider"],
                  case .string(let model)? = payload["model"]
            else { continue }
            let identity = "trace-success:\(provider):\(model):\(rawDate)"
            let evidence = ProviderPathEvidence(
                evidenceID: identity,
                observedAt: date,
                outcome: .succeeded
            )
            restored[evidence.evidenceID] = evidence
        }
        for (key, value) in restored where providerLifecycleEvidenceByCallID[key] == nil {
            providerLifecycleEvidenceByCallID[key] = value
        }
    }
}
