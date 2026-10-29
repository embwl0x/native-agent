import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OrganismPrediction+Horizon.swift` | Horizon vocabulary, bounded register reads and refresh transitions; named plans keep name identity, unnamed atoms use whole-second due instants |

// Horizons use bounded real-store pointers and semantic-expectation rows; projected anticipation never changes stored chemistry.

/// Where a horizon expectation came from. Five real sources, closed set.
public enum OrganismHorizonSourceKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// A named Desk deferral or an unnamed dated memory atom — a stated plan.
    case statedPlan
    /// Persisted scheduled horizons settle; the composer creates no new ones.
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
/// An absent wire key decodes as nil, marking an ordinary semantic expectation.
public struct OrganismHorizonExpectation: Codable, Sendable, Equatable {
    public let sourceKind: OrganismHorizonSourceKind
    /// Bounded subject — WHO or WHAT she is waiting on. Canonicalised and
    /// prefix-capped at construction; empty only for unnamed memory plans.
    public let label: String
    /// Her guess at how it will feel: > 0 looking forward, < 0 dreading, 0 flat.
    /// A GUESS, not a measurement — it scales an undertone, never a mood.
    public let valence: Double

    public init(sourceKind: OrganismHorizonSourceKind, label: String, valence: Double) {
        self.sourceKind = sourceKind
        self.label = OrganismHorizonRegister.sourceLabel(sourceKind: sourceKind, label: label)
        self.valence = valence.isFinite ? valence.clampedSigned() : 0
    }
}

/// The nearest thing she is facing — the documented read the felt-fingerprint
/// builder consumes for the word-level `hopeful — Friday`.
public struct OrganismTowardRead: Sendable, Equatable {
    /// Bounded subject: only unnamed plan words are derived at this read's clock.
    public let label: String
    public let sourceKind: OrganismHorizonSourceKind
    /// −1 dreading · 0 flat · +1 looking forward. A SIGN, not a magnitude: the
    /// capsule picks a word, it does not render a number.
    public let valenceSign: Int
    public let dueAt: Date
    /// The horizon has passed and nothing has answered it — `waiting`.
    public let isOverdue: Bool

    /// The label as she reads it. `label` is a canonical display subject
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
    /// so its source stays explicit; admission still requires a touched care.
    public static let resolutionPathLabel = "horizonExpectation"
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
        OrganismToken.canonicalToken(raw)
    }

    /// An empty stated-plan label means its source has no name. Other source
    /// kinds still require an identifier and retain their existing validation.
    static func sourceLabel(sourceKind: OrganismHorizonSourceKind, label: String) -> String {
        sourceKind == .statedPlan && label.isEmpty ? "" : canonicalLabel(label)
    }

    /// An unnamed plan's words reach the capsule, so they are short by contract.
    public static let statedPlanLabelCharacterCap = 32

    /// One formatter for memory writes and unnamed-plan display reads.
    /// The due instant supplies an atom's words; stored time labels are stale.
    public static func statedPlanLabel(
        for dueAt: Date, at now: Date, timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.startOfDay(for: dueAt)
        let startOfToday = calendar.startOfDay(for: now)
        let dayCount = calendar.dateComponents([.day], from: startOfToday, to: day).day ?? 0
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let isoDay = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        var word: String
        switch dayCount {
        case 0: word = "today"
        case 1: word = "tomorrow"
        case 2...6:
            let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            let index = calendar.component(.weekday, from: day) - 1
            word = names.indices.contains(index) ? names[index] : isoDay
        default: word = isoDay
        }
        let time = calendar.dateComponents([.hour, .minute, .second], from: dueAt)
        // Preserve the day-only label for the existing end-of-day convention.
        if time.hour != 23 || time.minute != 59 || time.second != 59 {
            word += String(format: " %02d:%02d", time.hour ?? 0, time.minute ?? 0)
        }
        return String(word.prefix(statedPlanLabelCharacterCap))
    }

    /// Recognize only the canonical time-word shapes this formatter produces.
    /// Used to recover unnamed atoms from registers that stored display words.
    static func isStatedPlanTimeLabel(_ label: String) -> Bool {
        label.range(
            of: #"^(today|tomorrow|sunday|monday|tuesday|wednesday|thursday|friday|saturday|[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]))(-([01][0-9]|2[0-3])-[0-5][0-9])?$"#,
            options: .regularExpression
        ) != nil
    }

    /// Named plans keep their source's words; unnamed plans derive time words
    /// even when no source scan was due.
    public static func displayLabel(for row: OrganismPrediction, at now: Date) -> String? {
        guard let horizon = row.horizon else { return nil }
        return horizon.sourceKind == .statedPlan && horizon.label.isEmpty
            ? canonicalLabel(statedPlanLabel(for: row.dueAt, at: now))
            : horizon.label
    }

    /// A named plan is its canonical name. Only unnamed atoms use their due
    /// instant, rounded to whole seconds by the source encoder's rule.
    /// Named sources retain identity when their due time changes.
    public static func rowID(sourceKind: OrganismHorizonSourceKind, label: String, dueAt: Date) -> String {
        let identity = sourceKind == .statedPlan && label.isEmpty
            ? "due:\(dueAt.timeIntervalSince1970.rounded())"
            : canonicalLabel(label)
        return [idPrefix, sourceKind.rawValue, identity].joined(separator: ":")
    }

    /// One source, as the payload-free token the mint signal carries.
    /// `kind|dueEpochSeconds|valence|label` — four fields, with a bounded label,
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
            String(dueAt.timeIntervalSince1970),
            String(format: "%.2f", clean),
            sourceLabel(sourceKind: sourceKind, label: label),
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
        let label = sourceLabel(sourceKind: sourceKind, label: String(parts[3]))
        guard label != "unknown" else { return nil }
        return (sourceKind, label, valence.clampedSigned(), Date(timeIntervalSince1970: epoch))
    }

    // MARK: - Ledger reads

    /// Every OPEN horizon row, nearest horizon first.
    public static func open(
        in ledger: OrganismPredictionLedger
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
        // Bare time words do not name a horizon; the next named horizon leads.
        guard let row = open(in: ledger).first(where: { row in
            guard let label = displayLabel(for: row, at: now) else { return false }
            return !Self.bareTimeWords.contains(label.replacingOccurrences(of: "-", with: " "))
        }), let horizon = row.horizon,
            let label = displayLabel(for: row, at: now) else { return nil }
        let sign: Int = horizon.valence > 0 ? 1 : (horizon.valence < 0 ? -1 : 0)
        return OrganismTowardRead(
            label: label,
            sourceKind: horizon.sourceKind,
            valenceSign: sign,
            dueAt: row.dueAt,
            isOverdue: row.dueAt <= now
        )
    }
}

extension OrganismPredictiveBody {
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
            nextLedger.expiredCount = min(nextLedger.expiredCount, Int.max - 1) + 1
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
    ///      and takes the current label, valence and due time. Named plans keep
    ///      their identity when deferred to another day. A new source opens a row.
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
                sourceKind: source.sourceKind, label: source.label, dueAt: source.dueAt
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
        for row in OrganismHorizonRegister.open(in: ledger) where !present.contains(row.id) {
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
        let openRows = OrganismHorizonRegister.open(in: ledger)
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
        row.evidenceCount = min(row.evidenceCount, Int.max - 1) + 1
        row.lastUpdatedAt = date
        ledger.predictions[row.id] = row
        ledger.satisfiedCount = min(ledger.satisfiedCount, Int.max - 1) + 1
        applySatisfiedEffect(
            kind: .semanticExpectation,
            intensity: 0.4,
            bracing: bracing,
            ledger: &ledger,
            chemicalState: &chemicalState
        )
    }
}
