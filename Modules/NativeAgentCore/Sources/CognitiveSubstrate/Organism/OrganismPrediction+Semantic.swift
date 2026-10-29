import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OrganismPrediction+Semantic.swift` | Conversational expectation metadata and scope; `OrganismPredictiveBody` minting, reaction resolution and deterministic IDs |

/// Semantic predictions use only `CognitiveSubstrate` appraisal metadata:
/// what her completed turn expects and how the next user turn says it landed.
/// No metadata means no expectation; this lane makes no model call, reads no
/// cares and adds nothing to a prompt.
public enum OrganismSemanticExpectation {
    /// Metadata key on an `.assistantSpoke` signal: an OBJECT carrying the
    /// concern she has at stake in the turn she just finished plus that turn's
    /// scope. The label is a care id (`care:<UUID>`), never the content of the work.
    ///
    /// The same key carries `{session, turn}` alone as PROVENANCE on the felt
    /// cognitive event a semantic resolution produces.
    public static let mintMetadataKey = "semanticExpectation"
    /// Metadata key on a `.userSpoke` signal: an OBJECT carrying the appraisal
    /// owner's read of how the previous turn landed, plus the scope of the
    /// completion it is a verdict on.
    public static let reactionMetadataKey = "semanticReaction"

    /// Nested fields preserve the top-level somatic metadata key budget.
    /// Both objects carry opaque session and completion-turn ids, never content;
    /// minting and resolution require the complete scope.
    public static let concernField = "concern"
    public static let reactionField = "reaction"
    public static let sessionField = "session"
    public static let turnField = "turn"
    /// He pushed back — the expectation was wrong. The only violating value; an
    /// absent, empty, or unrecognised reaction reads as `neutral` (see below),
    /// so a producer bug can never manufacture violations.
    public static let pushbackReaction = "pushback"
    /// He agreed / built on it. Satisfied, and worth more than silence.
    public static let confirmedReaction = "confirmed"
    /// He moved on without pushing back. Still satisfied — the expectation was
    /// "this will hold", and it held — but with less evidence behind it.
    public static let neutralReaction = "neutral"

    /// Per-session pending cap; a fourth row evicts the oldest without an outcome.
    public static let maximumPendingPerSession = 3
    /// Backstop only. The next user turn normally resolves an expectation long
    /// before this; a day later, whatever she expected is no longer about the
    /// turn that produced it.
    public static let horizon: TimeInterval = 24 * 60 * 60
    /// Reserved id namespace, so a semantic row can never collide with the
    /// correlation-keyed `pending:` / `terminal:` ids.
    public static let idPrefix = "semantic"

    /// Evidence strength of a reaction. `confirmed` is a real signal; `neutral`
    /// is the absence of contradiction and moves her far less.
    static func satisfiedIntensity(for reaction: String, signalIntensity: Double) -> Double {
        let base = reaction == confirmedReaction ? 1.0 : 0.35
        return OrganismBodyConfidence.clamp(base * max(0.2, signalIntensity))
    }

    /// The scope inside the object at `key`. Both fields or neither: a
    /// half-scoped signal is a producer bug and must not mint or resolve.
    public static func scope(in metadata: [String: JSONValue], key: String) -> OrganismSemanticScope? {
        guard case .object(let object)? = metadata[key],
              case .string(let rawSession)? = object[sessionField],
              case .string(let rawTurn)? = object[turnField] else { return nil }
        let scope = OrganismSemanticScope(sessionID: rawSession, turnID: rawTurn)
        return scope.isUsable ? scope : nil
    }

    /// A named string field inside the object at `key`.
    static func field(_ field: String, in metadata: [String: JSONValue], key: String) -> String? {
        guard case .object(let object)? = metadata[key],
              case .string(let raw)? = object[field] else { return nil }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

/// Which conversation, and which of her turns, an expectation is about.
/// Opaque identifiers only; bounded at construction so a producer cannot grow a
/// prediction row. An absent `OrganismPrediction.semanticScope` decodes as nil;
/// a scoped reaction never resolves an unscoped row.
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

    /// Open an expectation about how the turn she just finished will land.
    /// Bounded four ways: the label AND the scope must be present and legible,
    /// at most `maximumPendingPerSession` may be open for that session, and a
    /// replayed signal cannot open the same row twice (the id folds in the turn
    /// and its own second).
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

        // Keep three pending rows per session, evicting oldest first.
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
        ), let scope = OrganismSemanticExpectation.scope(
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
        let clean = resolution.reaction.lowercased()
        // Fail toward "he did not push back". An unrecognised label is an absent
        // reading, and an absent reading must never mint the punishing outcome.
        let reaction = [
            OrganismSemanticExpectation.pushbackReaction,
            OrganismSemanticExpectation.confirmedReaction,
        ].contains(clean) ? clean : OrganismSemanticExpectation.neutralReaction
        let violated = reaction == OrganismSemanticExpectation.pushbackReaction
        let intensity = violated
            ? OrganismBodyConfidence.clamp(max(0.2, signal.intensity))
            : OrganismSemanticExpectation.satisfiedIntensity(
                for: reaction, signalIntensity: signal.intensity
            )
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
