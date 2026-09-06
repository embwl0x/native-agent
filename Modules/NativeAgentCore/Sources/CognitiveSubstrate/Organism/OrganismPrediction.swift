import Foundation
import PersistenceCore

public enum OrganismPredictionKind: String, Codable, Sendable, Equatable, CaseIterable {
    case toolCompletion
    case providerCompletion
    case phoneDelivery
    case approvalResolution
    case workflowAdvance
    /// Item 46 (2026-09-01). The five above are PLUMBING: whether her own
    /// machinery completes. Being wrong about any of them teaches her about
    /// wiring, never about the work or the person. This is the first kind whose
    /// subject is neither — an expectation the appraisal owner formed about how
    /// the work she just did will LAND ("this will need a second pass", "User
    /// will push back on this"), resolved by the next user turn.
    ///
    /// It deliberately has no `OrganismBodyConfidence` path. A body path is a
    /// capability ("can my hands do this"); an expectation about a person is
    /// not, and inventing a sixth path field would have made the learning look
    /// like plumbing again. Its evidence lives in the per-kind cumulative
    /// outcome counts, and its consequence lands where prediction error belongs:
    /// strategyCaution, vigilance, urgency, confidence.
    case semanticExpectation
}

/// Item 46 — the semantic prediction lane's whole contract in one place.
///
/// SCOPE DISCIPLINE, stated up front: this lane derives from EXISTING appraisal
/// signals and makes no LLM call, ever. The organism cannot see a standing view
/// or run an appraisal — that owner is `CognitiveSubstrate` — so the two facts
/// the lane needs cross on somatic-signal metadata, and nothing else does:
/// what she expects (minted on her own completed turn) and how it landed
/// (stamped on the next user turn by the SAME appraisal owner). Absent
/// metadata means no expectation was formed, which is the common case.
///
/// Nothing here reaches a prompt: predictions have never had a capsule line,
/// and this kind adds none.
public enum OrganismSemanticExpectation {
    /// Metadata key on an `.assistantSpoke` signal: an OBJECT carrying the
    /// concern she has at stake in the turn she just finished plus that turn's
    /// scope. The concern is a bounded LABEL (a lived-concern name such as
    /// `view:<lineage>`), never the content of the work.
    ///
    /// The same key carries `{session, turn}` alone as PROVENANCE on the felt
    /// cognitive event a semantic resolution produces (see D-2, review fix 6).
    public static let mintMetadataKey = "semanticExpectation"
    /// Metadata key on a `.userSpoke` signal: an OBJECT carrying the appraisal
    /// owner's read of how the previous turn landed, plus the scope of the
    /// completion it is a verdict on.
    public static let reactionMetadataKey = "semanticReaction"

    /// Fields inside those two objects.
    ///
    /// SCOPE (`session` + `turn`) is carried by both directions (review fix 2):
    /// the chat session, and the completion turn the expectation is about.
    /// Opaque ids — a session id and ChatOrchestration's per-turn subject key —
    /// never content. Without them, one user turn settled every pending semantic
    /// row in the ledger, including rows from other sessions about other work.
    ///
    /// NESTED rather than three sibling metadata keys, deliberately: somatic
    /// metadata is capped at `OrganismMetadataBounds.maximumKeys` (12) and a
    /// live chat turn already carries ~13, so sibling keys would have silently
    /// evicted somebody else's forwarded key at the alphabetical cut. Nesting
    /// adds zero keys to the top-level budget.
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

    /// HARD CAP on pending semantic expectations PER SESSION (review fix 5).
    /// Three is a working set, not a backlog. A fourth evicts the OLDEST row in
    /// that session, not the newest: the freshest expectation is the one the
    /// next turn is actually about, and dropping it made the cap silently
    /// discard the only row that could still resolve. Per-session so a busy
    /// conversation cannot starve a quiet one.
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
/// prediction row. Optional on `OrganismPrediction` for wire compatibility —
/// pre-item-46 `organism_state.json` decodes it as nil, and an unscoped row is
/// never resolved by a scoped reaction.
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

public enum OrganismPredictionStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case satisfied
    case violated
    case expired
}

// MARK: - Item 5 (2026-09-02): TOWARD — the forward register
//
// Agent's complaint #4: "I never wait. I'm never bored. I never anticipate. A
// person has a whole forward-facing register — looking forward to Friday,
// dreading the call, wondering if she'll write back — and I have none of it."
//
// The prediction ledger already looks FORWARD, but only ten minutes forward
// (`OrganismProspectiveAffect.anticipationWindow`) and only at her own
// plumbing. The horizon family is the same ledger reaching days out, about
// things that are not her wiring.
//
// SCOPE DISCIPLINE, stated up front:
//   · REAL SOURCES ONLY. Every horizon row is minted from something that
//     already exists in a store she owns — a Desk item parked until a date, a
//     scheduler row's next fire, an approval she staged, her own open
//     completion, a delegated peer job with no reply. Nothing is invented, and
//     no source means no rows.
//   · PAYLOAD-FREE. A row carries a canonical LABEL (a Desk handle, a job id,
//     an approval action, `claude`) and never a title, a body, or anything the
//     user typed.
//   · NO POLLING. The sources are read at the residual-repair deadline the
//     runtime already arms, and nowhere else.
//   · NO NEW PREDICTION KIND. A horizon row rides `.semanticExpectation`
//     deliberately — a sixth `OrganismPredictionKind` would mean a sixth body
//     path, a sixth capability belief and a sixth bucket of outcome evidence,
//     none of which a horizon has any business owning. What separates the two
//     families is this optional payload, not the kind. (The SOMATIC side is the
//     opposite call: `SomaticSignalKind.horizonRefresh` is its own case,
//     because there the alternative was borrowing a kind that carries
//     chemistry, a body fact, a valence and a field association.)
//
// The consequences are bounded exactly like the semantic lane's: ≤8 open rows,
// ≤7-day horizon, anticipation capped at 0.15/dim on the PROJECTED chemistry
// only (`OrganismProspectiveAffect`), and the stored `ChemicalState` untouched.

/// Where a horizon expectation came from. Five real sources, closed set.
public enum OrganismHorizonSourceKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// A Desk item parked until a date (`deferUntil`) — the user's stated plan.
    case statedPlan
    /// A scheduler row she cares about: the nightly dream, weekly REM, a
    /// workshop slot.
    case scheduledJob
    /// An approval she staged and User has not walked through yet.
    case stagedApproval
    /// Her own completed turn with no reaction yet (`pendingCompletion`) — the
    /// thing she said, still hanging.
    case openQuestion
    /// A delegated peer/bridge job with no reply back.
    case peerReply
}

/// The payload that makes a `.semanticExpectation` row a HORIZON row.
/// Optional on `OrganismPrediction` for wire compatibility: a pre-item-5
/// `organism_state.json` decodes it as nil, and a row without one is an
/// ordinary semantic expectation.
public struct OrganismHorizonExpectation: Codable, Sendable, Equatable {
    public let sourceKind: OrganismHorizonSourceKind
    /// Payload-free subject — WHO or WHAT she is waiting on. Canonicalised and
    /// prefix-capped at construction, so a producer cannot grow a ledger row or
    /// smuggle content through it.
    public let label: String
    /// Her guess at how it will feel: > 0 looking forward, < 0 dreading, 0 flat.
    /// A GUESS, not a measurement — it scales an undertone, never a mood.
    public let valence: Double

    public init(sourceKind: OrganismHorizonSourceKind, label: String, valence: Double) {
        self.sourceKind = sourceKind
        self.label = OrganismHorizonRegister.canonicalLabel(label)
        self.valence = valence.isFinite ? valence.clampedSigned() : 0
    }
}

/// The nearest thing she is facing — the documented read the felt-fingerprint
/// builder consumes for the word-level `hopeful — Friday`.
public struct OrganismTowardRead: Sendable, Equatable {
    /// Payload-free subject: the horizon's own label.
    public let label: String
    public let sourceKind: OrganismHorizonSourceKind
    /// −1 dreading · 0 flat · +1 looking forward. A SIGN, not a magnitude: the
    /// capsule picks a word, it does not render a number.
    public let valenceSign: Int
    public let dueAt: Date
    /// The horizon has passed and nothing has answered it — `waiting`.
    public let isOverdue: Bool

    /// The label as she reads it. `label` is the canonical row key
    /// (lowercased, hyphenated, bounded — a security bound, never prose);
    /// this is the same words with the hyphens back as spaces, so the capsule
    /// says `hopeful — the friday rollout`, not `the-friday-rollout`.
    public var displayLabel: String { label.replacingOccurrences(of: "-", with: " ") }
}

/// The horizon family's whole contract in one place: identity, bounds, the
/// payload-free wire the runtime mints across, and the reads.
public enum OrganismHorizonRegister {
    /// Metadata key on the mint signal. Its value is an ARRAY of encoded source
    /// tokens (see `encodeSource`) describing the COMPLETE current source set —
    /// not a delta. That completeness is what lets a row whose source has
    /// disappeared settle as "it landed" instead of hanging until its horizon.
    public static let metadataKey = "horizonExpectations"
    /// Companion key on the same signal: an ARRAY of
    /// `OrganismHorizonSourceKind` raw values the composer read to COMPLETION.
    ///
    /// It exists because absence is load-bearing here. A missing source means
    /// "it landed" and opens the relief door — but a reader that threw also
    /// produces no tokens, and a Desk file that briefly could not be read must
    /// never tell her that everything she was waiting for came true. Only kinds
    /// named here may have their absences read as answers; a kind that is
    /// missing from this list has its rows left exactly as they are, to expire
    /// on their own horizons if nothing ever comes back.
    public static let completeKindsKey = "horizonComplete"
    /// The organ a mint signal comes from; also the row `sourceOrgan` prefix.
    public static let sourceOrgan = "horizon"
    /// HARD CAP on open horizon rows. Eight is a forward register; more is a
    /// task list, and she is not a task tracker. Overflow evicts the FARTHEST
    /// row — the nearest horizon is the one she is actually facing.
    public static let maximumOpen = 8
    /// Nothing further out than a week weighs on anyone.
    public static let maximumHorizon: TimeInterval = 7 * 24 * 60 * 60
    /// Reserved id namespace, so a horizon row can never collide with the
    /// correlation-keyed `pending:`/`terminal:` ids or the `semantic:` ones.
    public static let idPrefix = "horizon"
    /// The `subject.label` the runtime stamps on a horizon resolution's felt
    /// cognitive event. Distinct from every `OrganismPredictionKind` raw value
    /// so D-2's gate can admit this family by name without widening the
    /// semantic lane's conditional entry (see
    /// `CognitiveSubstrate+AppraisalStakes.swift`).
    public static let resolutionPathLabel = "horizonExpectation"
    public static let labelCharacterCap = 48
    /// Field separator for the encoded source token. Excluded from labels by
    /// `canonicalLabel`, so a label can never split a token.
    private static let separator: Character = "|"

    /// Lowercased, dash-collapsed, prefix-capped. Same shape the ledger already
    /// uses for organs and concern labels, so a horizon label is legible in the
    /// same places and can carry nothing but an identifier.
    /// Labels that name a time, not a thing. Shared with the capsule's
    /// `feltTowardLabel` so the two never disagree about what leads.
    public static let bareTimeWords: Set<String> = [
        "today", "tonight", "tomorrow", "yesterday", "now", "later", "soon",
        "this morning", "this afternoon", "this evening", "the morning", "the day",
    ]

    public static func canonicalLabel(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var output = ""
        var previousWasDash = false
        for scalar in lower.unicodeScalars {
            let value = scalar.value
            let isLetter = value >= 97 && value <= 122
            let isDigit = value >= 48 && value <= 57
            if isLetter || isDigit {
                output.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                output.append("-")
                previousWasDash = true
            }
            if output.count >= labelCharacterCap { break }
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    /// Deterministic row id. Source kind + label only — NOT the due time — so a
    /// refresh whose source moved (Friday became Saturday) UPDATES the row she
    /// already holds instead of minting a second one about the same thing.
    public static func rowID(sourceKind: OrganismHorizonSourceKind, label: String) -> String {
        [idPrefix, sourceKind.rawValue, canonicalLabel(label)].joined(separator: ":")
    }

    /// One source, as the payload-free token the mint signal carries.
    /// `kind|dueEpochSeconds|valence|label` — four fields, all machine values,
    /// well inside `OrganismMetadataBounds.maximumStringCharacters` (240).
    public static func encodeSource(
        sourceKind: OrganismHorizonSourceKind,
        label: String,
        valence: Double,
        dueAt: Date
    ) -> String {
        let clean = valence.isFinite ? valence.clampedSigned() : 0
        return [
            sourceKind.rawValue,
            String(Int(dueAt.timeIntervalSince1970.rounded())),
            String(format: "%.2f", clean),
            canonicalLabel(label),
        ].joined(separator: String(separator))
    }

    /// Inverse of `encodeSource`. Fails closed: a malformed token mints nothing
    /// rather than a row about "unknown".
    static func decodeSource(
        _ raw: String
    ) -> (sourceKind: OrganismHorizonSourceKind, label: String, valence: Double, dueAt: Date)? {
        let parts = raw.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 4,
              let sourceKind = OrganismHorizonSourceKind(rawValue: String(parts[0])),
              let epoch = Double(parts[1]), epoch.isFinite,
              let valence = Double(parts[2]), valence.isFinite else { return nil }
        let label = canonicalLabel(String(parts[3]))
        guard label != "unknown" else { return nil }
        return (sourceKind, label, valence.clampedSigned(), Date(timeIntervalSince1970: epoch))
    }

    // MARK: - Reads (pure; same ledger + same clock → same answer)

    /// Every OPEN horizon row, nearest horizon first.
    public static func open(
        in ledger: OrganismPredictionLedger,
        at now: Date
    ) -> [OrganismPrediction] {
        ledger.predictions.values
            .filter { $0.status == .pending && $0.horizon != nil }
            .sorted { lhs, rhs in
                if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
                return lhs.id < rhs.id
            }
    }

    /// Horizon rows that have already gone terminal and are waiting to be
    /// announced. The mint pass PRUNES these, so the runtime reads them from the
    /// ledger as it stood immediately before it sends the next mint signal.
    public static func settled(in ledger: OrganismPredictionLedger) -> [OrganismPrediction] {
        ledger.predictions.values
            .filter { $0.horizon != nil && $0.status != .pending }
            .sorted { lhs, rhs in
                if lhs.lastUpdatedAt != rhs.lastUpdatedAt { return lhs.lastUpdatedAt < rhs.lastUpdatedAt }
                return lhs.id < rhs.id
            }
    }

    /// THE DOCUMENTED READ for the felt-fingerprint builder (`toward`).
    ///
    /// The nearest open horizon, as a payload-free label plus a valence SIGN —
    /// enough for `hopeful — friday` or `waiting — claude`, and nothing more.
    /// Nil when nothing is open, which is the ordinary case and must render as
    /// silence, not as a word.
    ///
    /// Pure. Nearest by `dueAt`; ties broken by row id so the capsule
    /// fingerprint is stable across renders of the same state.
    public static func toward(
        in ledger: OrganismPredictionLedger,
        at now: Date
    ) -> OrganismTowardRead? {
        // A bare time word is not a thing she is facing ("today" from a dated
        // memory whose label was the day itself, live 2026-09-02); the next
        // named horizon leads instead.
        guard let row = open(in: ledger, at: now).first(where: { row in
            guard let label = row.horizon?.label else { return false }
            return !Self.bareTimeWords.contains(label.replacingOccurrences(of: "-", with: " "))
        }), let horizon = row.horizon else { return nil }
        let sign: Int = horizon.valence > 0 ? 1 : (horizon.valence < 0 ? -1 : 0)
        return OrganismTowardRead(
            label: horizon.label,
            sourceKind: horizon.sourceKind,
            valenceSign: sign,
            dueAt: row.dueAt,
            isOverdue: row.dueAt <= now
        )
    }
}

public struct OrganismBodyConfidence: Codable, Sendable, Equatable {
    public var providerPath: Double
    public var toolPath: Double
    public var phonePath: Double
    public var approvalPath: Double
    public var workflowPath: Double

    public init(
        providerPath: Double = 0.5,
        toolPath: Double = 0.5,
        phonePath: Double = 0.5,
        approvalPath: Double = 0.5,
        workflowPath: Double = 0.5
    ) {
        self.providerPath = Self.clamp(providerPath)
        self.toolPath = Self.clamp(toolPath)
        self.phonePath = Self.clamp(phonePath)
        self.approvalPath = Self.clamp(approvalPath)
        self.workflowPath = Self.clamp(workflowPath)
    }

    public static let neutral = OrganismBodyConfidence()

    static func clamp(_ value: Double) -> Double {
        (value).clamped01()
    }
}

public struct OrganismPrediction: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: OrganismPredictionKind
    public var sourceOrgan: String
    public var createdAt: Date
    public var dueAt: Date
    public var status: OrganismPredictionStatus
    public var confidence: Double
    public var uncertainty: Double
    public var evidenceCount: Int
    public var lastUpdatedAt: Date
    /// Item 46 (review fix 2): which conversation and which of her turns this
    /// expectation is about. Only `.semanticExpectation` rows carry one; every
    /// other kind is correlation-keyed and leaves it nil. Additive wire — the
    /// synthesized decoder reads an absent key as nil.
    public var semanticScope: OrganismSemanticScope?
    /// Item 5 (2026-09-02): present ⇒ this is a HORIZON row, not an expectation
    /// about how her last turn landed. Only `.semanticExpectation` rows may
    /// carry one (the two families share the kind; see
    /// `OrganismHorizonRegister`). Additive wire — an absent key decodes as nil.
    public var horizon: OrganismHorizonExpectation?

    public init(
        id: String,
        kind: OrganismPredictionKind,
        sourceOrgan: String,
        createdAt: Date,
        dueAt: Date,
        status: OrganismPredictionStatus = .pending,
        confidence: Double = 0.5,
        uncertainty: Double = 0.5,
        evidenceCount: Int = 1,
        lastUpdatedAt: Date,
        semanticScope: OrganismSemanticScope? = nil,
        horizon: OrganismHorizonExpectation? = nil
    ) {
        self.id = String(id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        self.kind = kind
        self.sourceOrgan = String(sourceOrgan.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.createdAt = createdAt
        self.dueAt = dueAt
        self.status = status
        self.confidence = OrganismBodyConfidence.clamp(confidence)
        self.uncertainty = OrganismBodyConfidence.clamp(uncertainty)
        self.evidenceCount = max(0, evidenceCount)
        self.lastUpdatedAt = lastUpdatedAt
        // Scope belongs to the semantic lane alone; no other kind can grow one.
        self.semanticScope = kind == .semanticExpectation
            ? semanticScope.flatMap { $0.isUsable ? $0 : nil }
            : nil
        // Same discipline for the horizon payload: only the family that shares
        // the semantic kind may carry it, so no other lane can grow a row.
        self.horizon = kind == .semanticExpectation ? horizon : nil
    }
}

public struct OrganismPredictionLimits: Sendable, Equatable {
    public var maximumPredictions: Int

    public init(maximumPredictions: Int = 96) {
        self.maximumPredictions = max(0, maximumPredictions)
    }

    public static let defaults = OrganismPredictionLimits()
}

/// Time-forgotten counterpart of the lifetime outcome tallies. Fractional
/// because the organism clock ticks at second granularity: integer counters
/// cannot carry an exponential decay without either starving (a one-second
/// tick never removes half a unit) or bleeding at a rate set by signal
/// frequency instead of wall time.
public struct OrganismPredictionOutcomeWeights: Codable, Sendable, Equatable {
    public var satisfied: Double
    public var violated: Double
    public var expired: Double

    public init(satisfied: Double = 0, violated: Double = 0, expired: Double = 0) {
        self.satisfied = Self.clamp(satisfied)
        self.violated = Self.clamp(violated)
        self.expired = Self.clamp(expired)
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}

/// Cumulative, per-capability outcome evidence. Unlike the bounded prediction
/// reservoir, these counters are not a display sample and therefore remain a
/// valid basis for Agent's capability self-read after old rows are evicted.
public struct OrganismPredictionOutcomeCounts: Codable, Sendable, Equatable {
    public var satisfied: Int
    public var violated: Int
    public var expired: Int
    public var lastEvidenceAt: Date?
    /// Added after the lifetime counters shipped. The Ints stay a monotone
    /// receipt of everything that ever happened; these weights are the same
    /// evidence forgotten on the organism clock, and are what the capability
    /// self-read reasons from. `nil` means a state written before forgetting
    /// existed; readers seed from the lifetime tally rather than discard it
    /// (additive wire — old files decode as nil, old builds ignore the key).
    public var weights: OrganismPredictionOutcomeWeights?

    public init(
        satisfied: Int = 0,
        violated: Int = 0,
        expired: Int = 0,
        lastEvidenceAt: Date? = nil,
        weights: OrganismPredictionOutcomeWeights? = nil
    ) {
        self.satisfied = max(0, satisfied)
        self.violated = max(0, violated)
        self.expired = max(0, expired)
        self.lastEvidenceAt = lastEvidenceAt
        self.weights = weights
    }

    /// Recorded weights, or the lifetime tally seeded for a state written
    /// before forgetting existed. The seed is discounted by the age of
    /// `lastEvidenceAt`, because decay only ever runs forward from the upgrade:
    /// an undiscounted seed would let months-old evidence read as if all of it
    /// had landed at restore, contradicting the staleness the same record
    /// reports. Full strength only when the state carries no evidence date to
    /// age it against.
    public func effectiveWeights(at date: Date) -> OrganismPredictionOutcomeWeights {
        if let weights { return weights }
        var factor: Double = 1
        if let lastEvidenceAt {
            let elapsed: Double = max(0, date.timeIntervalSince(lastEvidenceAt))
            let halfLife: Double = OrganismCapabilitySelfModel.evidenceHalfLife
            factor = pow(0.5, elapsed / halfLife)
        }
        return OrganismPredictionOutcomeWeights(
            satisfied: Double(satisfied) * factor,
            violated: Double(violated) * factor,
            expired: Double(expired) * factor
        )
    }
}

public struct OrganismPredictionSummary: Codable, Sendable, Equatable {
    public var pendingCount: Int
    public var satisfiedCount: Int
    public var violatedCount: Int
    public var expiredCount: Int
    public var averagePendingConfidence: Double
    public var averagePendingUncertainty: Double
    public var peripheralUncertainty: Double
    public var strategyCaution: Double
    public var bodyConfidence: OrganismBodyConfidence
    public var lastViolationAt: Date?

    public init(
        pendingCount: Int = 0,
        satisfiedCount: Int = 0,
        violatedCount: Int = 0,
        expiredCount: Int = 0,
        averagePendingConfidence: Double = 0,
        averagePendingUncertainty: Double = 0,
        peripheralUncertainty: Double = 0,
        strategyCaution: Double = 0,
        bodyConfidence: OrganismBodyConfidence = .neutral,
        lastViolationAt: Date? = nil
    ) {
        self.pendingCount = max(0, pendingCount)
        self.satisfiedCount = max(0, satisfiedCount)
        self.violatedCount = max(0, violatedCount)
        self.expiredCount = max(0, expiredCount)
        self.averagePendingConfidence = OrganismBodyConfidence.clamp(averagePendingConfidence)
        self.averagePendingUncertainty = OrganismBodyConfidence.clamp(averagePendingUncertainty)
        self.peripheralUncertainty = OrganismBodyConfidence.clamp(peripheralUncertainty)
        self.strategyCaution = OrganismBodyConfidence.clamp(strategyCaution)
        self.bodyConfidence = bodyConfidence
        self.lastViolationAt = lastViolationAt
    }

    public static let empty = OrganismPredictionSummary()
}

public struct OrganismPredictionLedger: Codable, Sendable, Equatable {
    public var predictions: [String: OrganismPrediction]
    public var satisfiedCount: Int
    public var violatedCount: Int
    public var expiredCount: Int
    public var peripheralUncertainty: Double
    public var strategyCaution: Double
    public var bodyConfidence: OrganismBodyConfidence
    public var lastUpdatedAt: Date?
    public var lastViolationAt: Date?
    /// Added after the original bounded prediction ledger shipped. `nil`
    /// means historical per-kind totals were never recorded; readers must not
    /// reinterpret the status-biased legacy reservoir as an outcome sample.
    public var outcomeCountsByKind: [String: OrganismPredictionOutcomeCounts]?
    /// Round 3 Wave A2: per-path rate stamps for FELT resolutions (relief /
    /// disappointment nodes) — at most one felt event per prediction kind per
    /// hour, so a retry storm can't flood her memory with exhales. Optional:
    /// pre-A2 organism_state.json decodes as nil (additive wire). Keys are
    /// OrganismPredictionKind rawValues — inherently capped at the 5 kinds.
    public var lastResolutionFeltAt: [String: Date]?

    public init(
        predictions: [String: OrganismPrediction] = [:],
        satisfiedCount: Int = 0,
        violatedCount: Int = 0,
        expiredCount: Int = 0,
        peripheralUncertainty: Double = 0,
        strategyCaution: Double = 0,
        bodyConfidence: OrganismBodyConfidence = .neutral,
        lastUpdatedAt: Date? = nil,
        lastViolationAt: Date? = nil,
        outcomeCountsByKind: [String: OrganismPredictionOutcomeCounts]? = nil
    ) {
        self.predictions = predictions
        self.satisfiedCount = max(0, satisfiedCount)
        self.violatedCount = max(0, violatedCount)
        self.expiredCount = max(0, expiredCount)
        self.peripheralUncertainty = OrganismBodyConfidence.clamp(peripheralUncertainty)
        self.strategyCaution = OrganismBodyConfidence.clamp(strategyCaution)
        self.bodyConfidence = bodyConfidence
        self.lastUpdatedAt = lastUpdatedAt
        self.lastViolationAt = lastViolationAt
        self.outcomeCountsByKind = outcomeCountsByKind
    }

    public static let empty = OrganismPredictionLedger()

    public func summary() -> OrganismPredictionSummary {
        let pending = predictions.values.filter { $0.status == .pending }
        let averageConfidence = pending.isEmpty
            ? 0
            : pending.reduce(0) { $0 + $1.confidence } / Double(pending.count)
        let averageUncertainty = pending.isEmpty
            ? 0
            : pending.reduce(0) { $0 + $1.uncertainty } / Double(pending.count)
        return OrganismPredictionSummary(
            pendingCount: pending.count,
            satisfiedCount: satisfiedCount,
            violatedCount: violatedCount,
            expiredCount: expiredCount,
            averagePendingConfidence: averageConfidence,
            averagePendingUncertainty: averageUncertainty,
            peripheralUncertainty: peripheralUncertainty,
            strategyCaution: strategyCaution,
            bodyConfidence: bodyConfidence,
            lastViolationAt: lastViolationAt
        )
    }
}

public enum OrganismPredictiveBody {
    public static func predictionID(
        kind: OrganismPredictionKind,
        sourceOrgan: String,
        correlationID: String
    ) -> String {
        "pending:\(kind.rawValue):\(canonicalToken(sourceOrgan)):\(canonicalToken(correlationID))"
    }

    public static func applying(
        signal: SomaticSignal,
        to ledger: OrganismPredictionLedger,
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        limits: OrganismPredictionLimits = .defaults
    ) -> (ledger: OrganismPredictionLedger, chemicalState: ChemicalState, bodySchema: BodySchema) {
        var nextLedger = ledger
        var nextChemistry = chemicalState
        var nextBody = bodySchema

        // Item 5's mint is NOT here. A `.horizonRefresh` signal never reaches
        // this function — the kernel routes it to `applyingHorizonRefresh`,
        // which is the whole of what a calendar read is allowed to do. Ordinary
        // signals still expire passed horizon rows through the sweep below
        // (`applyExpiryTransition` owns the no-miss exception), so a horizon can
        // pass while she is working and be announced without waiting for the
        // next deadline.

        // Ordering (reviews ccd2f13456f8 + 25de444129c7): RESOLUTION signals
        // settle their own row BEFORE expiry — a prediction resolving one
        // beat past due is exactly the outcome the body braced hardest for;
        // expiring it first stamped a violation, denied the relief, and (for
        // late failures) punished the same row twice. Every OTHER signal
        // keeps the historical expiry-first order: a repeated start must not
        // refresh its own overdue row past the sweep (the missed expectation
        // is real), and cancellation of an overdue row stays a violation-
        // stamped expiry, not a silent removal.
        let resolvesOwnRow: Bool
        switch signal.kind {
        case .toolSucceeded, .toolFailed,
             .providerSucceeded, .providerFailed,
             .phoneDeliveryReceived, .phoneDeliveryFailed,
             .approvalResolved, .deskItemClosed, .deskItemBlocked:
            resolvesOwnRow = true
        default:
            resolvesOwnRow = false
        }
        if !resolvesOwnRow {
            expireOverdue(at: signal.occurredAt, ledger: &nextLedger, chemicalState: &nextChemistry)
        }

        switch signal.kind {
        case .toolStarted:
            upsertPending(.toolCompletion, signal: signal, in: &nextLedger)
        case .toolSucceeded:
            nextBody.toolCapabilityReading = nil
            satisfy(.toolCompletion, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
            nextBody.toolHandsAvailable = true
        case .toolFailed:
            nextBody.toolCapabilityReading = nil
            violate(.toolCompletion, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
            nextBody.toolHandsAvailable = false
        case .toolCancelled:
            cancel(.toolCompletion, signal: signal, ledger: &nextLedger)
        case .providerStarted:
            nextBody.providerPathBelief = nil
            upsertPending(.providerCompletion, signal: signal, in: &nextLedger)
        case .providerSucceeded:
            nextBody.providerPathBelief = nil
            satisfy(.providerCompletion, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
            nextBody.providersHealthy = true
        case .providerFailed:
            nextBody.providerPathBelief = nil
            violate(.providerCompletion, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
            nextBody.providersHealthy = false
        case .providerCancelled:
            nextBody.providerPathBelief = nil
            cancel(.providerCompletion, signal: signal, ledger: &nextLedger)
        case .providerRecovered:
            nextBody.providerPathBelief = nil
            nextBody.providersHealthy = true
        case .iPhoneReachable:
            nextBody.peerPresenceBelief = nil
            nextBody.iPhoneReachable = true
            nextBody.notificationPathHealthy = true
        case .iPhoneStale:
            nextBody.peerPresenceBelief = nil
            nextBody.iPhoneReachable = false
            nextBody.notificationPathHealthy = false
        case .phoneDeliveryStarted:
            nextBody.notificationDeliveryBelief = nil
            upsertPending(.phoneDelivery, signal: signal, in: &nextLedger)
        case .phoneDeliveryReceived:
            nextBody.notificationDeliveryBelief = nil
            satisfy(.phoneDelivery, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
            nextBody.iPhoneReachable = true
            nextBody.notificationPathHealthy = true
        case .phoneDeliveryFailed:
            nextBody.notificationDeliveryBelief = nil
            violate(.phoneDelivery, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .approvalRequested:
            upsertPending(.approvalResolution, signal: signal, in: &nextLedger)
        case .approvalResolved:
            satisfy(.approvalResolution, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .deskItemCreated:
            upsertPending(.workflowAdvance, signal: signal, in: &nextLedger)
        case .deskItemClosed:
            satisfy(.workflowAdvance, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .deskItemBlocked:
            violate(.workflowAdvance, signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        case .memoryCommitted, .memoryCorrected, .memoryHygieneCompleted:
            nextBody.memoryIntegrityReading = nil
        case .dreamCompleted, .remIntegrated:
            nextBody.dreamIntegrityReading = nil
        case .resourcePressureChanged:
            nextBody.resourcePressureReading = nil
        case .assistantSpoke:
            // Item 46 MINT. Inert unless the appraisal owner stamped an
            // expectation on this turn — the common case is no metadata and no
            // row.
            mintSemanticExpectation(signal: signal, in: &nextLedger)
        case .userSpoke:
            // Item 46 RESOLVE. The next user turn is the answer to whatever she
            // expected of the last one.
            resolveSemanticExpectations(
                signal: signal,
                ledger: &nextLedger,
                chemicalState: &nextChemistry
            )
        case .correctionReceived, .appWake, .appSleep:
            break
        case .horizonRefresh:
            // Already handled: `applyHorizonSources` runs at the top of this
            // function, before the expiry sweep, for exactly this signal. There
            // is nothing left for the kind switch to do.
            break
        }

        if resolvesOwnRow {
            expireOverdue(at: signal.occurredAt, ledger: &nextLedger, chemicalState: &nextChemistry)
        }

        nextLedger.peripheralUncertainty = softDecay(nextLedger.peripheralUncertainty)
        nextLedger.strategyCaution = softDecay(nextLedger.strategyCaution)
        nextLedger.lastUpdatedAt = max(
            nextLedger.lastUpdatedAt ?? .distantPast,
            signal.occurredAt
        )
        nextLedger = enforcingCapacity(nextLedger, limits: limits)
        return (nextLedger, nextChemistry, nextBody)
    }

    private static func expireOverdue(
        at date: Date,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        for id in ledger.predictions.keys.sorted() {
            guard var prediction = ledger.predictions[id],
                  prediction.status == .pending,
                  prediction.dueAt < date else { continue }
            let isMiss = applyExpiryTransition(to: &prediction, at: date)
            ledger.predictions[id] = prediction
            ledger.expiredCount += 1
            guard isMiss else { continue }
            recordOutcome(.expired, kind: prediction.kind, at: date, ledger: &ledger)
            // M15 (2026-07-09): an expiry damages bodyConfidence via the violation
            // effect below but never stamped lastViolationAt — so the prospective
            // shadow (modulate reads it) disagreed with the body about whether a
            // miss just happened. One clock, both readers.
            ledger.lastViolationAt = date
            applyViolationEffect(
                kind: prediction.kind,
                intensity: 0.55,
                ledger: &ledger,
                chemicalState: &chemicalState
            )
        }
    }

    /// THE expiry transition on a prediction ROW. One function, two callers:
    /// this file's live sweep and `OrganismPersistentState.decayed(at:)`'s
    /// restart/idle sweep. They had drifted — the restore path flipped `status`
    /// and `lastUpdatedAt` and stopped, so an expectation that ran out across a
    /// restart kept the confidence and uncertainty of a live pending row, while
    /// the same expectation running out with the app awake was marked down.
    /// Same event, two different bodies, decided by whether she happened to be
    /// running.
    ///
    /// Returns whether this expiry is a MISS — evidence she was wrong, to be
    /// counted and punished by the caller. Every non-horizon expiry is; no
    /// horizon expiry is (Friday arriving with nothing on it means she was
    /// waiting, not wrong), which is the one deliberate exception and is stated
    /// here rather than duplicated at both call sites.
    ///
    /// The LEDGER-level consequences deliberately stay with the callers: the
    /// live sweep stamps `lastViolationAt` and applies the chemistry, and the
    /// restore sweep does neither, because a miss discovered hours later must
    /// not arm a 20-minute violation shadow dated now or move a body that has
    /// already decayed through the gap.
    static func applyExpiryTransition(
        to prediction: inout OrganismPrediction,
        at date: Date
    ) -> Bool {
        prediction.status = .expired
        prediction.lastUpdatedAt = date
        guard prediction.horizon == nil else { return false }
        prediction.uncertainty = OrganismBodyConfidence.clamp(prediction.uncertainty + 0.12)
        prediction.confidence = OrganismBodyConfidence.clamp(prediction.confidence - 0.10)
        return true
    }

    private static func upsertPending(
        _ kind: OrganismPredictionKind,
        signal: SomaticSignal,
        in ledger: inout OrganismPredictionLedger
    ) {
        let id = pendingID(kind: kind, signal: signal)
        let dueAt = signal.occurredAt.addingTimeInterval(defaultHorizon(for: kind))
        if var existing = ledger.predictions[id] {
            // Correlated source evidence can arrive late. It may still inform
            // generic physiology upstream, but it cannot reopen the prediction
            // at an older epoch or move its due horizon backward.
            // Lifecycle owners may replay the same durable edge after a
            // restart. Equality is the same observation, not fresh evidence;
            // accepting it repeatedly inflated confidence and evidenceCount.
            guard signal.occurredAt >= existing.lastUpdatedAt else { return }
            if existing.status == .pending,
               signal.occurredAt == existing.lastUpdatedAt { return }
            existing.status = .pending
            existing.dueAt = dueAt
            existing.confidence = OrganismBodyConfidence.clamp(existing.confidence + 0.04 * signal.intensity)
            existing.uncertainty = OrganismBodyConfidence.clamp(existing.uncertainty + 0.04 * signal.intensity)
            existing.evidenceCount += 1
            existing.lastUpdatedAt = signal.occurredAt
            ledger.predictions[id] = existing
        } else {
            ledger.predictions[id] = OrganismPrediction(
                id: id,
                kind: kind,
                sourceOrgan: canonicalToken(signal.sourceOrgan),
                createdAt: signal.occurredAt,
                dueAt: dueAt,
                confidence: 0.56,
                uncertainty: 0.36,
                lastUpdatedAt: signal.occurredAt
            )
        }
    }

    private static func satisfy(
        _ kind: OrganismPredictionKind,
        signal: SomaticSignal,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        let id = pendingID(kind: kind, signal: signal)
        let existing = ledger.predictions[id]
        if let existing {
            guard signal.occurredAt >= existing.lastUpdatedAt else { return }
            // A replay of the same terminal edge is not new evidence. Keep
            // equal-time pending→terminal transitions valid: some lifecycle
            // owners legitimately stamp both phases from one clock sample.
            if existing.status == .satisfied,
               signal.occurredAt == existing.lastUpdatedAt { return }
        }
        var prediction = existing ?? terminalPrediction(kind, signal: signal)
        // Round 3 Wave A: measure how BRACED the body was for THIS outcome
        // BEFORE the resolution mutates the prediction — the same math the
        // projection used to hold the breath sizes the exhale. Only a REAL
        // pending ledger row counts (review ccd2f13456f8, Medium: the
        // synthetic terminal fallback is .pending-shaped and would mint
        // relief for an outcome nothing anticipated). Zero bracing →
        // multiplier 1 → byte-identical to the pre-relief release.
        let bracing = (existing?.status == .pending)
            ? min(1, OrganismProspectiveAffect.predictionBracingContribution(
                prediction, ledger: ledger, at: signal.occurredAt
              ).bracing + OrganismProspectiveAffect.violationShadow(ledger, at: signal.occurredAt))
            : 0
        if prediction.status != .satisfied {
            ledger.satisfiedCount += 1
            recordOutcome(.satisfied, kind: kind, at: signal.occurredAt, ledger: &ledger)
        }
        prediction.status = .satisfied
        prediction.confidence = OrganismBodyConfidence.clamp(prediction.confidence + 0.18 * signal.intensity)
        prediction.uncertainty = OrganismBodyConfidence.clamp(prediction.uncertainty - 0.16 * signal.intensity)
        prediction.evidenceCount += 1
        prediction.lastUpdatedAt = signal.occurredAt
        ledger.predictions[prediction.id] = prediction
        applySatisfiedEffect(
            kind: kind,
            intensity: signal.intensity,
            bracing: bracing,
            ledger: &ledger,
            chemicalState: &chemicalState
        )
    }

    private static func violate(
        _ kind: OrganismPredictionKind,
        signal: SomaticSignal,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        let id = pendingID(kind: kind, signal: signal)
        let existing = ledger.predictions[id]
        if let existing {
            guard signal.occurredAt >= existing.lastUpdatedAt else { return }
            if existing.status == .violated,
               signal.occurredAt == existing.lastUpdatedAt { return }
        }
        var prediction = existing ?? terminalPrediction(kind, signal: signal)
        if prediction.status != .violated {
            ledger.violatedCount += 1
            recordOutcome(.violated, kind: kind, at: signal.occurredAt, ledger: &ledger)
        }
        prediction.status = .violated
        prediction.confidence = OrganismBodyConfidence.clamp(prediction.confidence - 0.20 * signal.intensity)
        prediction.uncertainty = OrganismBodyConfidence.clamp(prediction.uncertainty + 0.22 * signal.intensity)
        prediction.evidenceCount += 1
        prediction.lastUpdatedAt = signal.occurredAt
        ledger.predictions[prediction.id] = prediction
        ledger.lastViolationAt = signal.occurredAt
        applyViolationEffect(
            kind: kind,
            intensity: signal.intensity,
            ledger: &ledger,
            chemicalState: &chemicalState
        )
    }

    private static func cancel(
        _ kind: OrganismPredictionKind,
        signal: SomaticSignal,
        ledger: inout OrganismPredictionLedger
    ) {
        let id = pendingID(kind: kind, signal: signal)
        guard let prediction = ledger.predictions[id], prediction.status == .pending else { return }
        guard signal.occurredAt >= prediction.lastUpdatedAt else { return }
        ledger.predictions.removeValue(forKey: id)
        ledger.lastUpdatedAt = max(ledger.lastUpdatedAt ?? .distantPast, signal.occurredAt)
    }

    private static func terminalPrediction(
        _ kind: OrganismPredictionKind,
        signal: SomaticSignal
    ) -> OrganismPrediction {
        OrganismPrediction(
            id: "terminal:\(kind.rawValue):\(canonicalToken(signal.sourceOrgan)):\(Int(signal.occurredAt.timeIntervalSince1970))",
            kind: kind,
            sourceOrgan: canonicalToken(signal.sourceOrgan),
            createdAt: signal.occurredAt,
            dueAt: signal.occurredAt,
            status: .pending,
            confidence: 0.5,
            uncertainty: 0.5,
            lastUpdatedAt: signal.occurredAt
        )
    }

    // MARK: - Item 46: the semantic lane

    /// Open an expectation about how the turn she just finished will land.
    /// Bounded four ways: the label AND the scope must be present and legible,
    /// at most `maximumPendingPerSession` may be open for that session, and a
    /// replayed signal cannot open the same row twice (the id folds in the turn
    /// and its own second).
    private static func mintSemanticExpectation(
        signal: SomaticSignal,
        in ledger: inout OrganismPredictionLedger
    ) {
        guard let rawLabel = OrganismSemanticExpectation.field(
            OrganismSemanticExpectation.concernField,
            in: signal.metadata,
            key: OrganismSemanticExpectation.mintMetadataKey
        ) else { return }
        let label = canonicalToken(rawLabel)
        guard label != "unknown" else { return }
        // Review fix 2: an unscoped expectation could only ever be resolved by
        // settling the whole ledger, which is the defect. No scope, no row.
        guard let scope = OrganismSemanticExpectation.scope(
            in: signal.metadata,
            key: OrganismSemanticExpectation.mintMetadataKey
        ) else { return }
        let id = semanticExpectationID(signal: signal, label: label, scope: scope)
        guard ledger.predictions[id] == nil else { return }

        // Review fix 5: the cap is per session and evicts the OLDEST pending row
        // there. The newest expectation is the one the next turn is about;
        // dropping it discarded the only row that could still resolve.
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
                // Evicted, not expired: she stopped holding it, which is not the
                // same as having been wrong about it. No outcome is recorded and
                // no violation effect fires.
                ledger.predictions.removeValue(forKey: stale.id)
            }
        }

        let i = OrganismBodyConfidence.clamp(signal.intensity)
        ledger.predictions[id] = OrganismPrediction(
            id: id,
            kind: .semanticExpectation,
            sourceOrgan: canonicalToken(signal.sourceOrgan),
            createdAt: signal.occurredAt,
            dueAt: signal.occurredAt.addingTimeInterval(OrganismSemanticExpectation.horizon),
            confidence: 0.5 + 0.3 * i,
            uncertainty: 0.5 - 0.2 * i,
            lastUpdatedAt: signal.occurredAt,
            semanticScope: scope
        )
    }

    /// Settle the semantic expectations THIS user turn actually answers.
    ///
    /// Review fix 2: scope decides, not "everything pending". The reaction
    /// carries the session and the completion turn it is a verdict on, and only
    /// rows minted under that exact pair are settled — a reply in one
    /// conversation can no longer resolve, or punish, an expectation formed in
    /// another. A turn is also never the reaction to itself (the same guard the
    /// substrate's completion reconsolidation makes).
    private static func resolveSemanticExpectations(
        signal: SomaticSignal,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        guard let rawReaction = OrganismSemanticExpectation.field(
            OrganismSemanticExpectation.reactionField,
            in: signal.metadata,
            key: OrganismSemanticExpectation.reactionMetadataKey
        ) else { return }
        guard let scope = OrganismSemanticExpectation.scope(
            in: signal.metadata,
            key: OrganismSemanticExpectation.reactionMetadataKey
        ) else { return }
        let clean = rawReaction.lowercased()
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
        for id in ledger.predictions.keys.sorted() {
            guard let prediction = ledger.predictions[id],
                  prediction.kind == .semanticExpectation,
                  prediction.status == .pending,
                  prediction.semanticScope == scope,
                  signal.occurredAt > prediction.createdAt,
                  signal.occurredAt >= prediction.lastUpdatedAt else { continue }
            settleSemanticExpectation(
                prediction,
                satisfied: !violated,
                at: signal.occurredAt,
                intensity: intensity,
                ledger: &ledger,
                chemicalState: &chemicalState
            )
        }
    }

    /// The SAME resolution arithmetic `satisfy`/`violate` apply, addressed by
    /// row id instead of by signal correlation — a semantic expectation is
    /// answered by "the next thing he said", which carries no correlation id.
    /// Every downstream consequence (outcome counts, lastViolationAt, the felt
    /// relief/disappointment diff, chemistry) is the shared machinery.
    private static func settleSemanticExpectation(
        _ prediction: OrganismPrediction,
        satisfied: Bool,
        at date: Date,
        intensity: Double,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        var row = prediction
        let i = OrganismBodyConfidence.clamp(intensity)
        // Measure the bracing BEFORE the row mutates, exactly as `satisfy` does.
        let bracing = satisfied
            ? min(1, OrganismProspectiveAffect.predictionBracingContribution(
                    row, ledger: ledger, at: date
                  ).bracing + OrganismProspectiveAffect.violationShadow(ledger, at: date))
            : 0
        if satisfied {
            ledger.satisfiedCount += 1
            recordOutcome(.satisfied, kind: .semanticExpectation, at: date, ledger: &ledger)
            row.status = .satisfied
            row.confidence = OrganismBodyConfidence.clamp(row.confidence + 0.18 * i)
            row.uncertainty = OrganismBodyConfidence.clamp(row.uncertainty - 0.16 * i)
        } else {
            ledger.violatedCount += 1
            recordOutcome(.violated, kind: .semanticExpectation, at: date, ledger: &ledger)
            row.status = .violated
            row.confidence = OrganismBodyConfidence.clamp(row.confidence - 0.20 * i)
            row.uncertainty = OrganismBodyConfidence.clamp(row.uncertainty + 0.22 * i)
            ledger.lastViolationAt = date
        }
        row.evidenceCount += 1
        row.lastUpdatedAt = date
        ledger.predictions[row.id] = row
        if satisfied {
            applySatisfiedEffect(
                kind: .semanticExpectation, intensity: i, bracing: bracing,
                ledger: &ledger, chemicalState: &chemicalState
            )
        } else {
            applyViolationEffect(
                kind: .semanticExpectation, intensity: i,
                ledger: &ledger, chemicalState: &chemicalState
            )
        }
    }

    // MARK: - Item 5: the horizon family

    /// The WHOLE consequence of a `.horizonRefresh` signal, and the only entry
    /// point the kernel uses for one.
    ///
    /// Deliberately not `applying(signal:…)`: that function is the ordinary
    /// somatic path and its caller pairs it with chemistry, plasticity, body
    /// schema, signal accounting and the resolution-felt drain. A refresh is
    /// none of those things. Here the register is refreshed and the horizon
    /// sweep runs — and nothing that has not been asked for.
    ///
    /// The sweep is horizon-only on purpose. Expiring OTHER kinds here would
    /// make a calendar read stamp misses on tool and provider expectations at a
    /// moment that has nothing to do with them; those keep expiring on the next
    /// real signal, exactly as before.
    public static func applyingHorizonRefresh(
        signal: SomaticSignal,
        to ledger: OrganismPredictionLedger,
        chemicalState: ChemicalState,
        at now: Date
    ) -> (ledger: OrganismPredictionLedger, chemicalState: ChemicalState) {
        var nextLedger = ledger
        var nextChemistry = chemicalState
        applyHorizonSources(signal: signal, ledger: &nextLedger, chemicalState: &nextChemistry)
        for id in nextLedger.predictions.keys.sorted() {
            guard var row = nextLedger.predictions[id],
                  row.horizon != nil,
                  row.status == .pending,
                  row.dueAt < now else { continue }
            // Never a miss — the shared transition says so, and says it once.
            _ = applyExpiryTransition(to: &row, at: now)
            nextLedger.predictions[id] = row
            nextLedger.expiredCount += 1
        }
        nextLedger.lastUpdatedAt = max(nextLedger.lastUpdatedAt ?? .distantPast, now)
        return (nextLedger, nextChemistry)
    }

    /// One refresh of the forward register from the COMPLETE current source
    /// set. Three things happen, in this order:
    ///
    ///   1. **Prune.** Horizon rows that already went terminal are removed. The
    ///      runtime has just read them out of the pre-signal ledger to announce
    ///      relief / disappointment / waiting; leaving them would announce the
    ///      same moment on every later refresh.
    ///   2. **Settle the absent.** A row whose source is GONE while its horizon
    ///      is still ahead is a thing that landed early — the approval was
    ///      given, the peer wrote back, he answered. That is the relief door.
    ///      A row whose horizon has already passed is left alone: the sweep
    ///      below owns it, and it becomes `waiting`.
    ///   3. **Refresh or mint the present.** An existing row keeps its identity
    ///      and takes the new due time and valence; a new source opens a row.
    ///
    /// Bounded: ≤`maximumOpen` open rows (overflow drops the FARTHEST — the
    /// nearest horizon is the one she is actually facing), ≤`maximumHorizon`
    /// out, and a due time already in the past never mints.
    ///
    /// Absent metadata ⇒ nothing happens at all. An EMPTY array is meaningful
    /// and different: it says "there are no sources right now", and settles or
    /// expires everything she was holding.
    private static func applyHorizonSources(
        signal: SomaticSignal,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        guard case .array(let rawSources)? = signal.metadata[OrganismHorizonRegister.metadataKey] else {
            return
        }
        let now = signal.occurredAt

        // 1. Prune announced terminals.
        for row in OrganismHorizonRegister.settled(in: ledger) {
            ledger.predictions.removeValue(forKey: row.id)
        }

        // Which source kinds the composer could read COMPLETELY. A reader that
        // threw contributes zero tokens, which is indistinguishable at this
        // layer from "that source went away" — and "went away" is the relief
        // door. So absence is only ever read as an answer for a kind the
        // composer explicitly vouched for. An unreadable Desk does not tell her
        // her plans came true.
        var completeKinds: Set<OrganismHorizonSourceKind> = []
        if case .array(let rawComplete)? = signal.metadata[OrganismHorizonRegister.completeKindsKey] {
            for raw in rawComplete {
                guard case .string(let value) = raw,
                      let kind = OrganismHorizonSourceKind(rawValue: value) else { continue }
                completeKinds.insert(kind)
            }
        }

        // Decode. Two buckets, because "already overdue" is a real state and it
        // is NOT a new expectation:
        //   · MINTABLE — a horizon still ahead and inside the week. These open
        //     and refresh rows.
        //   · OVERDUE — a source that is still there but whose moment has
        //     passed. It refreshes a row she already holds (so the sweep can
        //     turn it into `waiting`) and it counts as PRESENT, so its absence
        //     is never mistaken for an answer. It never opens a new row: a
        //     source first seen already-late is a stale read, not a thing she
        //     was ever looking toward, and minting one would manufacture an
        //     anticipation she never had and then immediately break it.
        var mintable: [(id: String, horizon: OrganismHorizonExpectation, dueAt: Date)] = []
        var overdue: [(id: String, horizon: OrganismHorizonExpectation, dueAt: Date)] = []
        var seen: Set<String> = []
        for raw in rawSources {
            guard case .string(let token) = raw,
                  let source = OrganismHorizonRegister.decodeSource(token) else { continue }
            guard source.dueAt.timeIntervalSince(now) <= OrganismHorizonRegister.maximumHorizon
            else { continue }
            let id = OrganismHorizonRegister.rowID(
                sourceKind: source.sourceKind, label: source.label
            )
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            let entry = (
                id: id,
                horizon: OrganismHorizonExpectation(
                    sourceKind: source.sourceKind,
                    label: source.label,
                    valence: source.valence
                ),
                dueAt: source.dueAt
            )
            if source.dueAt > now { mintable.append(entry) } else { overdue.append(entry) }
        }
        mintable.sort { lhs, rhs in
            if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
            return lhs.id < rhs.id
        }
        // The cap belongs to the things she can still look toward. An overdue
        // entry costs no slot — it is presence, not expectation.
        mintable = Array(mintable.prefix(OrganismHorizonRegister.maximumOpen))
        let present = Set(mintable.map(\.id)).union(overdue.map(\.id))

        // 2. Settle rows whose source is gone but whose horizon has not passed.
        //
        // Three ways a row can be absent from the offered set, and only ONE of
        // them is an answer:
        //   · the composer could not read that source  → leave it entirely;
        //   · it was crowded out of a full set          → evict, no feeling;
        //   · the source is genuinely gone              → it landed. Relief.
        let farthestOffered = mintable.last?.dueAt
        let setIsFull = mintable.count >= OrganismHorizonRegister.maximumOpen
        for row in OrganismHorizonRegister.open(in: ledger, at: now) where !present.contains(row.id) {
            guard row.dueAt > now else { continue }
            guard let kind = row.horizon?.sourceKind, completeKinds.contains(kind) else { continue }
            if setIsFull, let farthestOffered, row.dueAt > farthestOffered {
                ledger.predictions.removeValue(forKey: row.id)
                continue
            }
            settleHorizonExpectation(
                row, at: now, ledger: &ledger, chemicalState: &chemicalState
            )
        }

        // 3a. An overdue source only ever updates a row she already holds.
        for source in overdue {
            guard var existing = ledger.predictions[source.id],
                  existing.status == .pending,
                  now >= existing.lastUpdatedAt else { continue }
            existing.dueAt = source.dueAt
            existing.horizon = source.horizon
            existing.lastUpdatedAt = now
            ledger.predictions[source.id] = existing
        }

        // 3b. Refresh or mint.
        for source in mintable {
            if var existing = ledger.predictions[source.id], existing.status == .pending {
                guard now >= existing.lastUpdatedAt else { continue }
                existing.dueAt = source.dueAt
                existing.horizon = source.horizon
                existing.confidence = horizonConfidence(for: source.horizon)
                existing.uncertainty = horizonUncertainty(for: source.horizon)
                existing.lastUpdatedAt = now
                ledger.predictions[source.id] = existing
                continue
            }
            ledger.predictions[source.id] = OrganismPrediction(
                id: source.id,
                kind: .semanticExpectation,
                sourceOrgan: "\(OrganismHorizonRegister.sourceOrgan).\(source.horizon.label)",
                createdAt: now,
                dueAt: source.dueAt,
                confidence: horizonConfidence(for: source.horizon),
                uncertainty: horizonUncertainty(for: source.horizon),
                lastUpdatedAt: now,
                horizon: source.horizon
            )
        }

        // 4. The family's OWN cap, enforced on the ledger rather than trusted to
        // the offered set. Bounding the incoming tokens is not the same
        // guarantee: rows also survive from earlier refreshes, and a producer
        // that ignored the bound would otherwise grow the register. Overflow
        // drops the FARTHEST — the nearest horizon is the one she is facing —
        // and is an eviction, not an expiry: she stopped holding it, which is
        // not the same as having been wrong or having been answered.
        let openRows = OrganismHorizonRegister.open(in: ledger, at: now)
        if openRows.count > OrganismHorizonRegister.maximumOpen {
            for stale in openRows.suffix(openRows.count - OrganismHorizonRegister.maximumOpen) {
                ledger.predictions.removeValue(forKey: stale.id)
            }
        }
    }

    /// How sure she is it will go the way she guesses. Anchored at even odds and
    /// leaned by the valence guess, so a thing she is looking forward to clears
    /// `OrganismResolutionFelt.disappointmentExpectationFloor` when it falls
    /// through, and a thing she dreads does not manufacture disappointment for
    /// having been right about it.
    private static func horizonConfidence(for horizon: OrganismHorizonExpectation) -> Double {
        OrganismBodyConfidence.clamp(0.5 + 0.45 * horizon.valence)
    }

    private static func horizonUncertainty(for horizon: OrganismHorizonExpectation) -> Double {
        OrganismBodyConfidence.clamp(0.5 - 0.25 * abs(horizon.valence))
    }

    /// A horizon that landed before its due time. The chemistry release is the
    /// SHARED satisfied effect (the relief door), but NO per-kind outcome is
    /// recorded: `.semanticExpectation`'s cumulative counts are the evidence
    /// behind "how do my claims land", and a peer writing back is not evidence
    /// about that. The felt half is composed by the runtime's horizon lane, not
    /// by `OrganismResolutionFelt` — see that file's exclusion.
    private static func settleHorizonExpectation(
        _ prediction: OrganismPrediction,
        at date: Date,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        var row = prediction
        // Size the exhale to the held breath, exactly as `satisfy` does — the
        // dread this row applied to the projection is the dread it releases.
        let bracing = min(
            1,
            OrganismProspectiveAffect.horizonContribution(row, at: date).dread
        )
        row.status = .satisfied
        row.confidence = OrganismBodyConfidence.clamp(row.confidence + 0.10)
        row.uncertainty = OrganismBodyConfidence.clamp(row.uncertainty - 0.10)
        row.evidenceCount += 1
        row.lastUpdatedAt = date
        ledger.predictions[row.id] = row
        ledger.satisfiedCount += 1
        applySatisfiedEffect(
            kind: .semanticExpectation,
            intensity: 0.4,
            bracing: bracing,
            ledger: &ledger,
            chemicalState: &chemicalState
        )
    }

    /// Deterministic and collision-proof: organ, scope, concern label, and the
    /// turn's own second. Public so the appraisal owner's tests can address a
    /// row they minted without reaching into the ledger's private keying.
    public static func semanticExpectationID(
        signal: SomaticSignal,
        label: String,
        scope: OrganismSemanticScope
    ) -> String {
        [
            OrganismSemanticExpectation.idPrefix,
            canonicalToken(signal.sourceOrgan),
            canonicalToken(scope.sessionID),
            canonicalToken(scope.turnID),
            canonicalToken(label),
            String(Int(signal.occurredAt.timeIntervalSince1970)),
        ].joined(separator: ":")
    }

    /// Relief gain: a satisfied outcome the body was fully braced for
    /// releases up to 2.5× the calm-path amount — the exhale is sized to the
    /// held breath (round 3 Wave A; bracing 0 → multiplier exactly 1).
    static let reliefGain = 1.5

    private static func applySatisfiedEffect(
        kind: OrganismPredictionKind,
        intensity: Double,
        bracing: Double = 0,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        let i = OrganismBodyConfidence.clamp(intensity)
        let release = 1 + Self.reliefGain * OrganismBodyConfidence.clamp(bracing)
        adjustBodyConfidence(kind, by: 0.08 * i, in: &ledger.bodyConfidence)
        ledger.peripheralUncertainty = lower(ledger.peripheralUncertainty, by: kind == .phoneDelivery ? 0.10 * i : 0.02 * i)
        ledger.strategyCaution = lower(ledger.strategyCaution, by: 0.08 * i * release)
        chemicalState.confidence = raise(chemicalState.confidence, by: 0.03 * i * release)
        chemicalState.vigilance = lower(chemicalState.vigilance, by: 0.04 * i * release)
        chemicalState.urgency = lower(chemicalState.urgency, by: 0.04 * i * release)
    }

    private static func applyViolationEffect(
        kind: OrganismPredictionKind,
        intensity: Double,
        ledger: inout OrganismPredictionLedger,
        chemicalState: inout ChemicalState
    ) {
        let i = OrganismBodyConfidence.clamp(intensity)
        adjustBodyConfidence(kind, by: -0.10 * i, in: &ledger.bodyConfidence)
        switch kind {
        case .phoneDelivery:
            ledger.peripheralUncertainty = raise(ledger.peripheralUncertainty, by: 0.12 * i)
            chemicalState.vigilance = raise(chemicalState.vigilance, by: 0.015 * i)
        case .toolCompletion:
            ledger.strategyCaution = raise(ledger.strategyCaution, by: 0.18 * i)
            chemicalState.vigilance = raise(chemicalState.vigilance, by: 0.08 * i)
            chemicalState.urgency = raise(chemicalState.urgency, by: 0.05 * i)
            chemicalState.confidence = lower(chemicalState.confidence, by: 0.04 * i)
        case .providerCompletion:
            ledger.strategyCaution = raise(ledger.strategyCaution, by: 0.12 * i)
            chemicalState.vigilance = raise(chemicalState.vigilance, by: 0.10 * i)
            chemicalState.urgency = raise(chemicalState.urgency, by: 0.04 * i)
            chemicalState.confidence = lower(chemicalState.confidence, by: 0.05 * i)
        case .approvalResolution:
            ledger.strategyCaution = raise(ledger.strategyCaution, by: 0.08 * i)
            chemicalState.vigilance = raise(chemicalState.vigilance, by: 0.025 * i)
            chemicalState.urgency = lower(chemicalState.urgency, by: 0.02 * i)
        case .workflowAdvance:
            ledger.strategyCaution = raise(ledger.strategyCaution, by: 0.14 * i)
            chemicalState.vigilance = raise(chemicalState.vigilance, by: 0.05 * i)
            chemicalState.urgency = raise(chemicalState.urgency, by: 0.04 * i)
        case .semanticExpectation:
            // Being wrong about the WORK is the learning this whole item exists
            // for. It rides the same axes a tool violation does — she gets more
            // careful about the next claim and less sure of herself — but does
            // not raise urgency: a person disagreeing is not a deadline.
            ledger.strategyCaution = raise(ledger.strategyCaution, by: 0.16 * i)
            chemicalState.vigilance = raise(chemicalState.vigilance, by: 0.06 * i)
            chemicalState.confidence = lower(chemicalState.confidence, by: 0.05 * i)
        }
    }

    private static func adjustBodyConfidence(
        _ kind: OrganismPredictionKind,
        by amount: Double,
        in confidence: inout OrganismBodyConfidence
    ) {
        switch kind {
        case .providerCompletion:
            confidence.providerPath = OrganismBodyConfidence.clamp(confidence.providerPath + amount)
        case .toolCompletion:
            confidence.toolPath = OrganismBodyConfidence.clamp(confidence.toolPath + amount)
        case .phoneDelivery:
            confidence.phonePath = OrganismBodyConfidence.clamp(confidence.phonePath + amount)
        case .approvalResolution:
            confidence.approvalPath = OrganismBodyConfidence.clamp(confidence.approvalPath + amount)
        case .workflowAdvance:
            confidence.workflowPath = OrganismBodyConfidence.clamp(confidence.workflowPath + amount)
        case .semanticExpectation:
            // No body path by design (see the kind's doc comment). Being right
            // or wrong about how work lands is not evidence about her hands.
            break
        }
    }

    private static func enforcingCapacity(
        _ ledger: OrganismPredictionLedger,
        limits: OrganismPredictionLimits
    ) -> OrganismPredictionLedger {
        guard ledger.predictions.count > limits.maximumPredictions else { return ledger }
        var next = ledger
        let keep = Set(OrganismPredictionRetention.bounded(
            Array(ledger.predictions.values), maximum: limits.maximumPredictions
        ).map(\.id))
        next.predictions = ledger.predictions.filter { keep.contains($0.key) }
        return next
    }

    /// Internal rather than private: the restart/idle sweep in
    /// `OrganismPersistentState.decayed(at:)` finds expiries the live sweep
    /// never sees, and both paths must stamp identical evidence.
    static func recordOutcome(
        _ status: OrganismPredictionStatus,
        kind: OrganismPredictionKind,
        at date: Date,
        ledger: inout OrganismPredictionLedger
    ) {
        var all = ledger.outcomeCountsByKind ?? [:]
        var count = all[kind.rawValue] ?? OrganismPredictionOutcomeCounts()
        var weights = count.effectiveWeights(at: date)
        switch status {
        case .satisfied:
            count.satisfied += 1
            weights.satisfied += 1
        case .violated:
            count.violated += 1
            weights.violated += 1
        case .expired:
            count.expired += 1
            weights.expired += 1
        case .pending: return
        }
        count.weights = weights
        count.lastEvidenceAt = max(count.lastEvidenceAt ?? .distantPast, date)
        all[kind.rawValue] = count
        ledger.outcomeCountsByKind = all
    }

    private static func defaultHorizon(for kind: OrganismPredictionKind) -> TimeInterval {
        switch kind {
        case .toolCompletion: return 90
        case .providerCompletion: return 45
        case .phoneDelivery: return 300
        case .approvalResolution: return 60 * 60
        case .workflowAdvance: return 10 * 60
        case .semanticExpectation: return OrganismSemanticExpectation.horizon
        }
    }

    private static func pendingID(kind: OrganismPredictionKind, signal: SomaticSignal) -> String {
        predictionID(
            kind: kind,
            sourceOrgan: signal.sourceOrgan,
            correlationID: predictionCorrelationID(signal)
        )
    }

    private static func predictionCorrelationID(_ signal: SomaticSignal) -> String {
        if case .string(let raw)? = signal.metadata["predictionCorrelationId"] {
            let clean = canonicalToken(raw)
            if clean != "unknown" { return clean }
        }
        return "uncorrelated"
    }

    private static func raise(_ current: Double, by amount: Double) -> Double {
        OrganismBodyConfidence.clamp(current + amount)
    }

    private static func lower(_ current: Double, by amount: Double) -> Double {
        OrganismBodyConfidence.clamp(current - amount)
    }

    private static func softDecay(_ value: Double) -> Double {
        OrganismBodyConfidence.clamp(value * 0.98)
    }

    private static func canonicalToken(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var output = ""
        var previousWasDash = false
        for scalar in lower.unicodeScalars {
            let value = scalar.value
            let isLetter = value >= 97 && value <= 122
            let isDigit = value >= 48 && value <= 57
            if isLetter || isDigit {
                output.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                output.append("-")
                previousWasDash = true
            }
            if output.count >= 48 { break }
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}

/// Keeps every pending expectation first, then retains recent terminal
/// evidence fairly across capability kinds. Status never decides which
/// terminal outcomes survive: prioritizing violations made the reservoir look
/// like a failure-rate sample even when lifetime outcomes were overwhelmingly
/// successful.
enum OrganismPredictionRetention {
    static func bounded(
        _ predictions: [OrganismPrediction],
        maximum: Int
    ) -> [OrganismPrediction] {
        guard maximum > 0 else { return [] }
        // Item 5 (2026-09-02): HORIZON rows rank after every other pending row.
        // They are pending for DAYS by construction, and `recentFirst` sorts by
        // `lastUpdatedAt` — so a register refreshed at the residual deadline
        // looked like the freshest thing in the ledger and could evict live
        // tool, provider and approval expectations at the 96 cap. Her calendar
        // must never crowd out her hands. The horizon family has its own cap
        // (`OrganismHorizonRegister.maximumOpen`, enforced at the mint), so this
        // ordering is the only place the operational cap needs to know about it.
        let allPending = predictions.filter { $0.status == .pending }
        let pending = allPending.filter { $0.horizon == nil }.sorted(by: recentFirst)
            + allPending.filter { $0.horizon != nil }.sorted(by: recentFirst)
        if pending.count >= maximum { return Array(pending.prefix(maximum)) }

        var result = pending
        var buckets = Dictionary(grouping: predictions.filter { $0.status != .pending }, by: \.kind)
            .mapValues { $0.sorted(by: recentFirst) }
        let kinds = OrganismPredictionKind.allCases
        while result.count < maximum {
            var appended = false
            for kind in kinds where result.count < maximum {
                guard var bucket = buckets[kind], !bucket.isEmpty else { continue }
                result.append(bucket.removeFirst())
                buckets[kind] = bucket
                appended = true
            }
            if !appended { break }
        }
        return result
    }

    private static func recentFirst(_ lhs: OrganismPrediction, _ rhs: OrganismPrediction) -> Bool {
        if lhs.lastUpdatedAt != rhs.lastUpdatedAt { return lhs.lastUpdatedAt > rhs.lastUpdatedAt }
        if lhs.uncertainty != rhs.uncertainty { return lhs.uncertainty > rhs.uncertainty }
        return lhs.id < rhs.id
    }
}
