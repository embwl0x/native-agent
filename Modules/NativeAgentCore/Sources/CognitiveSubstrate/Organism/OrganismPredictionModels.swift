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
