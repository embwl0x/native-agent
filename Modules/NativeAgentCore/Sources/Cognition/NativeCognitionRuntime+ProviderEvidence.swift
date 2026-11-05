import Foundation
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import Experiences
import PersistenceCore
import ProviderRouting
import TurnTrace

// Blueprint: | `NativeCognitionRuntime+ProviderEvidence.swift` | `NativeCognitionRuntime`. |

extension NativeCognitionRuntime {
    public nonisolated static func providerPathEvidence(
        providerID: String, dataRoot: URL, since: Date, now: Date = Date()
    ) async throws -> (model: String, observedAt: Date)? {
        let receipt = try await TurnTraceRecentReader(dataRootOverride: dataRoot)
            .traceEvidence(now: now, since: since, kinds: ["llm.call"])
        guard receipt.turns.unreadable == 0 else {
            throw PersistenceCoreError.ioFailure("Provider evidence is incomplete; inspect the retained trace sources before checking the provider.")
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

    func restoreProviderLifecycleEvidence() async {
        // Bound restored provider evidence from the record.
        let rows: [JSONValue]
        do {
            let read = try await TurnTraceRecentReader(
                dataRootOverride: dataRoot, rowLimit: Self.maximumProviderLifecycleEvidence * 64
            ).traceEvidence(kinds: ["llm.call"])
            guard read.turns.unreadable == 0 else {
                throw PersistenceCoreError.ioFailure("Provider lifecycle history contains unreadable trace rows.")
            }
            rows = read.rows
        } catch {
            RepairOwed.owe(dataRoot, id: "provider-evidence:" + UUID().uuidString, kind: .run,
                operation: "cognition.provider.evidence", owner: "experiences/experiences.sqlite",
                words: "Provider lifecycle history is unavailable: \(error.localizedDescription)",
                tap: "Repair the life record while preserving its rows. No cumulative belief will replace it.")
            return
        }
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
        let outcome: ProviderPathEvidenceOutcome? = {
            guard case .string(let status)? = object["status"] else {
                return nil // No recorded outcome can attest a successful provider call.
            }
            switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "ok", "succeeded", "completed": return .succeeded
            case "cancelled", "canceled": return .cancelled
            case "unknown": return nil
            case "failed", "error": return .failed
            default: return nil
            }
        }()
        guard let outcome else { return nil }
        let rowID: String = {
            if case .string(let id)? = object["id"], !id.isEmpty { return id }
            return "\(provider):\(model):\(rawDate)"
        }()
        return (provider, model, ProviderPathEvidence(
            evidenceID: "trace-call:\(rowID)", observedAt: date, outcome: outcome))
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
