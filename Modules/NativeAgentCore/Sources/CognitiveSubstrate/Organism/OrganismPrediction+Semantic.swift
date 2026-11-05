import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OrganismPrediction+Semantic.swift` | `OrganismPredictiveBody`: scoped expectations, reactions and stable IDs |

/// Only scoped substrate appraisal metadata mints and resolves semantic expectations; absent metadata supplies no expectation or model work.
public enum OrganismSemanticExpectation {
    /// Carry a care-id concern and opaque turn scope, never work content; felt resolutions reuse the key for provenance only.
    public static let mintMetadataKey = "semanticExpectation"
    /// Metadata key on a `.userSpoke` signal: an OBJECT carrying the appraisal owner's read of how the previous turn landed, plus the scope of the completion
    /// it is a verdict on.
    public static let reactionMetadataKey = "semanticReaction"

    /// Nested fields preserve the top-level somatic metadata key budget. Both objects carry opaque session and completion-turn ids, never content; minting and
    /// resolution require the complete scope.
    public static let concernField = "concern"
    public static let reactionField = "reaction"
    public static let sessionField = "session"
    public static let turnField = "turn"
    /// A grounded disagreement with the prior statement. Absent, empty or unrecognised readings never settle an expectation.
    public static let pushbackReaction = "pushback"
    /// Explicit confirmation of the prior claim, never inferred from good mood.
    public static let confirmedReaction = "confirmed"
    /// Per-session pending cap; a fourth row evicts the oldest without an outcome.
    public static let maximumPendingPerSession = 3
    /// Backstop only. The next user turn normally resolves an expectation long before this; a day later, whatever the agent expected is no longer about the
    /// turn that produced it.
    public static let horizon: TimeInterval = 24 * 60 * 60
    /// Reserved id namespace, so a semantic row can never collide with the correlation-keyed `pending:` / `terminal:` ids.
    public static let idPrefix = "semantic"

    /// The scope inside the object at `key`. Both fields or neither: a half-scoped signal is a producer bug and must not mint or resolve.
    public static func scope(in metadata: [String: JSONValue], key: String) -> OrganismSemanticScope? {
        guard case .object(let object)? = metadata[key],
              case .string(let rawSession)? = object[sessionField],
              case .string(let rawTurn)? = object[turnField] else { return nil }
        let scope = OrganismSemanticScope(sessionID: rawSession, turnID: rawTurn)
        return scope.isUsable ? scope : nil
    }

    static func field(_ field: String, in metadata: [String: JSONValue], key: String) -> String? {
        guard case .object(let object)? = metadata[key],
              case .string(let raw)? = object[field] else { return nil }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

/// Require bounded complete session/turn scope so a reaction cannot settle an unscoped expectation.
public struct OrganismSemanticScope: Codable, Sendable, Equatable {
    public let sessionID: String
    public let turnID: String

    public init(sessionID: String, turnID: String) {
        self.sessionID = String(
            sessionID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
        )
        self.turnID = String(
            turnID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
        )
    }

    public var isUsable: Bool { !sessionID.isEmpty && !turnID.isEmpty }
}

extension OrganismPredictiveBody {
    // MARK: - Semantic expectations

    /// Require label and full scope, enforce the per-session cap and fold turn/time into identity so replay cannot mint twice.
    static func mintSemanticExpectation(
        signal: SomaticSignal,
        in ledger: inout OrganismPredictionLedger
    ) {
        guard let rawLabel = OrganismSemanticExpectation.field(
            OrganismSemanticExpectation.concernField,
            in: signal.metadata,
            key: OrganismSemanticExpectation.mintMetadataKey
        ) else { return }
        let label = OrganismToken.canonicalToken(rawLabel)
        guard label != "unknown" else { return }
        // Both session and completion turn are required to mint a row.
        guard let scope = OrganismSemanticExpectation.scope(
            in: signal.metadata,
            key: OrganismSemanticExpectation.mintMetadataKey
        ) else { return }
        let id = semanticExpectationID(signal: signal, label: label, scope: scope)
        guard ledger.predictions[id] == nil else { return }

        // The per-session cap evicts oldest rows without declaring outcomes.
        let sessionPending = ledger.predictions.values
            .filter {
                $0.kind == .semanticExpectation && $0.status == .pending
                    && $0.semanticScope?.sessionID == scope.sessionID
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }
        if sessionPending.count >= OrganismSemanticExpectation.maximumPendingPerSession {
            let overflow = sessionPending.count
                - OrganismSemanticExpectation.maximumPendingPerSession + 1
            for stale in sessionPending.prefix(overflow) {
                // Eviction records no outcome or violation effect.
                ledger.predictions.removeValue(forKey: stale.id)
            }
        }

        let i = OrganismBodyConfidence.clamp(signal.intensity)
        ledger.predictions[id] = OrganismPrediction(
            id: id,
            kind: .semanticExpectation,
            sourceOrgan: OrganismToken.canonicalToken(signal.sourceOrgan),
            createdAt: signal.occurredAt,
            dueAt: signal.occurredAt.addingTimeInterval(OrganismSemanticExpectation.horizon),
            confidence: 0.5 + 0.3 * i,
            uncertainty: 0.5 - 0.2 * i,
            lastUpdatedAt: signal.occurredAt,
            semanticScope: scope
        )
    }

    /// One admission for expiry protection and settlement, in deterministic ID order.
    static func semanticPredictionsResolved(
        by signal: SomaticSignal, in ledger: OrganismPredictionLedger
    ) -> (reaction: String, ids: [String])? {
        guard let reaction = OrganismSemanticExpectation.field(
            OrganismSemanticExpectation.reactionField,
            in: signal.metadata,
            key: OrganismSemanticExpectation.reactionMetadataKey
        ), [OrganismSemanticExpectation.pushbackReaction,
            OrganismSemanticExpectation.confirmedReaction].contains(reaction),
        let scope = OrganismSemanticExpectation.scope(
            in: signal.metadata,
            key: OrganismSemanticExpectation.reactionMetadataKey
        ) else { return nil }
        let ids = ledger.predictions.values.filter {
            $0.kind == .semanticExpectation && $0.status == .pending
                && $0.semanticScope == scope && signal.occurredAt > $0.createdAt
                && signal.occurredAt >= $0.lastUpdatedAt
        }.map(\.id).sorted()
        return (reaction, ids)
    }

    /// Settle only the exact session/completion-turn scope a later reaction answers.
    static func resolveSemanticExpectations(
        signal: SomaticSignal,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        guard let resolution = semanticPredictionsResolved(by: signal, in: ledger) else { return }
        let reaction = resolution.reaction
        let violated = reaction == OrganismSemanticExpectation.pushbackReaction
        let intensity = OrganismBodyConfidence.clamp(max(0.2, signal.intensity))
        for id in resolution.ids {
            guard let prediction = ledger.predictions[id] else { continue }
            settlePrediction(
                prediction,
                satisfied: !violated,
                anticipated: true,
                at: signal.occurredAt,
                intensity: intensity,
                ledger: &ledger,
                chemicalState: &chemicalState
            )
        }
    }

    /// Bounded deterministic identity from the organ, scope, concern and second.
    public static func semanticExpectationID(
        signal: SomaticSignal,
        label: String,
        scope: OrganismSemanticScope
    ) -> String {
        let components = [
            signal.sourceOrgan,
            scope.sessionID,
            scope.turnID,
            label,
            String(format: "%.0f", signal.occurredAt.timeIntervalSince1970.rounded(.towardZero) + 0),
        ]
        let identity = components.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(OrganismSemanticExpectation.idPrefix):\(digest)"
    }
}
