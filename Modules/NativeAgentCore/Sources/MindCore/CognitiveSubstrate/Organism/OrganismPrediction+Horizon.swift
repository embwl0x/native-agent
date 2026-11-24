import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OrganismPrediction+Horizon.swift` | Bounded horizon registers; named identity and whole-second unnamed plans |

// Horizons use bounded real-store pointers and semantic-expectation rows; projected anticipation never changes stored chemistry.

/// Only real source kinds may mint a horizon.
public enum OrganismHorizonSourceKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// Stated plans include named Desk deferrals and unnamed dated memory atoms.
    case statedPlan
    /// Staged approvals stay open until the person decides.
    case stagedApproval
    /// Only an unanswered completion may supply this expectation.
    case openQuestion
    /// Delegated work stays open until a reply arrives.
    case peerReply
}

/// Only an explicit horizon wire key distinguishes horizon rows from ordinary semantic expectations.
public struct OrganismHorizonExpectation: Codable, Sendable, Equatable {
    public let sourceKind: OrganismHorizonSourceKind
    /// Bounded subject — WHO or WHAT the agent is waiting on. Canonicalised and prefix-capped at construction; empty only for unnamed memory plans.
    public let label: String
    /// The agent's guess at how it will feel: > 0 looking forward, < 0 dreading, 0 flat. A GUESS, not a measurement — it scales an undertone, never a mood.
    public let valence: Double

    public init(sourceKind: OrganismHorizonSourceKind, label: String, valence: Double) {
        self.sourceKind = sourceKind
        self.label = OrganismHorizonRegister.sourceLabel(sourceKind: sourceKind, label: label)
        self.valence = valence.isFinite ? valence.clampedSigned() : 0
    }
}

/// Expose only the nearest payload-free horizon for felt-word attribution.
public struct OrganismTowardRead: Sendable, Equatable {
    /// Bounded subject: only unnamed plan words are derived at this read's clock.
    public let label: String
    public let sourceKind: OrganismHorizonSourceKind
    /// −1 dreading · 0 flat · +1 looking forward. A SIGN, not a magnitude: the capsule picks a word, it does not render a number.
    public let valenceSign: Int
    public let dueAt: Date
    /// An unanswered passed horizon is waiting, never a presumed result.
    public let isOverdue: Bool

    /// Canonical labels are security-bounded identifiers; display restores spaces so the capsule reads as language.
    public var displayLabel: String { label.replacingOccurrences(of: "-", with: " ") }
}

/// Keep horizon identity, wire bounds and projection rules together.
public enum OrganismHorizonRegister {
    /// Metadata key on the mint signal. Its value is an ARRAY of encoded source tokens (see `encodeSource`) describing the current source inventory. Inventory
    /// absence never proves an outcome.
    public static let metadataKey = "horizonExpectations"
    /// Mint and row identity share this organ prefix.
    public static let sourceOrgan = "horizon"
    /// Cap open horizons at eight so the register stays attention, not task tracking; evict farthest to retain what is nearest.
    public static let maximumOpen = 8
    /// Nothing further out than a week weighs on anyone.
    public static let maximumHorizon: TimeInterval = 7 * 24 * 60 * 60
    /// Reserved id namespace, so a horizon row can never collide with the correlation-keyed `pending:`/`terminal:` ids or the `semantic:` ones.
    public static let idPrefix = "horizon"
    /// Use a resolution label distinct from prediction-kind strings so felt provenance remains explicit; care admission still applies.
    public static let resolutionPathLabel = "horizonExpectation"
    /// Field separator for the encoded source token. Excluded from labels by `canonicalLabel`, so a label can never split a token.
    private static let separator: Character = "|"

    /// Share canonical time-word recognition with the capsule so a bare time cannot lead as a named subject.
    public static let bareTimeWords: Set<String> = [
        "today", "tonight", "tomorrow", "yesterday", "now", "later", "soon",
        "this morning", "this afternoon", "this evening", "the morning", "the day",
    ]

    public static func canonicalLabel(_ raw: String) -> String {
        OrganismToken.canonicalToken(raw)
    }

    /// Only unnamed plans may omit a label; other sources need a real identifier.
    static func sourceLabel(sourceKind: OrganismHorizonSourceKind, label: String) -> String {
        sourceKind == .statedPlan && label.isEmpty ? "" : canonicalLabel(label)
    }

    /// An unnamed plan's words reach the capsule, so they are short by contract.
    public static let statedPlanLabelCharacterCap = 32

    /// Share unnamed-plan formatting with memory writes; derive words from due time so stored time labels cannot go stale.
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
        // Keep day-only wording for end-of-day plans.
        if time.hour != 23 || time.minute != 59 || time.second != 59 {
            word += String(format: " %02d:%02d", time.hour ?? 0, time.minute ?? 0)
        }
        return String(word.prefix(statedPlanLabelCharacterCap))
    }

    /// Named plans keep their source's words; unnamed plans derive time words even when no source scan was due.
    public static func displayLabel(for row: OrganismPrediction, at now: Date) -> String? {
        guard let horizon = row.horizon else { return nil }
        return horizon.sourceKind == .statedPlan && horizon.label.isEmpty
            ? canonicalLabel(statedPlanLabel(for: row.dueAt, at: now))
            : horizon.label
    }

    /// Named source identity survives due-time edits; unnamed atom identity uses whole-second due time.
    public static func rowID(sourceKind: OrganismHorizonSourceKind, label: String, dueAt: Date) -> String {
        let identity = sourceKind == .statedPlan && label.isEmpty
            ? "due:\(dueAt.timeIntervalSince1970.rounded())"
            : canonicalLabel(label)
        return [idPrefix, sourceKind.rawValue, identity].joined(separator: ":")
    }

    /// Encode kind, due second, valence and bounded label within the metadata string cap.
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

    /// Malformed source tokens mint nothing; an unknown subject cannot be invented.
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

    /// Only open rows compete for the nearest horizon.
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

    /// Read terminal horizons before the next mint prunes them so every pending announcement can drain.
    public static func settled(in ledger: OrganismPredictionLedger) -> [OrganismPrediction] {
        ledger.predictions.values
            .filter { $0.horizon != nil && $0.status != .pending }
            .sorted { lhs, rhs in
                if lhs.lastUpdatedAt != rhs.lastUpdatedAt { return lhs.lastUpdatedAt < rhs.lastUpdatedAt }
                return lhs.id < rhs.id
            }
    }

    /// Read nearest due time with stable id ties; expose only label and valence sign. No open horizon renders silence.
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
    /// Horizon refresh changes and sweeps only horizon rows; the somatic path would falsely count calendar reads as physiology or operational misses.
    public static func applyingHorizonRefresh(
        signal: SomaticSignal,
        to ledger: OrganismPredictionLedger,
        chemicalState: ChemicalState,
        at now: Date
    ) -> (ledger: OrganismPredictionLedger, chemicalState: ChemicalState) {
        var nextLedger = ledger
        applyHorizonSources(signal: signal, ledger: &nextLedger)
        for id in nextLedger.predictions.keys.sorted() {
            guard var row = nextLedger.predictions[id],
                  row.horizon != nil,
                  row.status == .pending,
                  row.dueAt < now else { continue }
            // The shared transition never counts waiting as a miss.
            _ = applyExpiryTransition(to: &row, at: now)
            nextLedger.predictions[id] = row
            nextLedger.expiredCount = min(nextLedger.expiredCount, Int.max - 1) + 1
        }
        nextLedger.lastUpdatedAt = max(nextLedger.lastUpdatedAt ?? .distantPast, now)
        return (nextLedger, chemicalState)
    }

    /// Prune announced terminals, then refresh or mint present sources. Missing sources retain uncertainty until their real due instant. Neither a complete
    /// inventory nor an empty one establishes an outcome. At most eight open rows remain; overflow evicts the farthest without a verdict.
    private static func applyHorizonSources(
        signal: SomaticSignal,
        ledger: inout OrganismPredictionLedger
    ) {
        guard case .array(let rawSources)? = signal.metadata[OrganismHorizonRegister.metadataKey] else {
            return
        }
        let now = signal.occurredAt

        // Prune only terminal horizons whose announcement boundary has passed.
        for row in OrganismHorizonRegister.settled(in: ledger) {
            ledger.predictions.removeValue(forKey: row.id)
        }

        // Overdue sources may refresh an existing horizon but cannot mint anticipation the body never held; future sources may mint within the week.
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
        // The cap belongs to the things the agent can still look toward. An overdue entry costs no slot — it is presence, not expectation.
        mintable = Array(mintable.prefix(OrganismHorizonRegister.maximumOpen))
        // An overdue source only ever updates a row the agent already holds.
        for source in overdue {
            guard var existing = ledger.predictions[source.id],
                  existing.status == .pending,
                  now >= existing.lastUpdatedAt else { continue }
            existing.dueAt = source.dueAt
            existing.horizon = source.horizon
            existing.lastUpdatedAt = now
            ledger.predictions[source.id] = existing
        }

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

        // Enforce the cap on the complete ledger, not only new tokens; farthest eviction is neither expiry nor outcome.
        let openRows = OrganismHorizonRegister.open(in: ledger)
        if openRows.count > OrganismHorizonRegister.maximumOpen {
            for stale in openRows.suffix(openRows.count - OrganismHorizonRegister.maximumOpen) {
                ledger.predictions.removeValue(forKey: stale.id)
            }
        }
    }

    /// Lean even odds by guessed valence so a hoped-for failure can disappoint without treating an expected bad result as disappointment.
    private static func horizonConfidence(for horizon: OrganismHorizonExpectation) -> Double {
        OrganismBodyConfidence.clamp(0.5 + 0.45 * horizon.valence)
    }

    private static func horizonUncertainty(for horizon: OrganismHorizonExpectation) -> Double {
        OrganismBodyConfidence.clamp(0.5 - 0.25 * abs(horizon.valence))
    }
}
