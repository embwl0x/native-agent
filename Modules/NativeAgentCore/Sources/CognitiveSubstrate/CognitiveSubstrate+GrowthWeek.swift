// Frozen growth evidence stays native; grouping and words belong to growth-week.js.
import Foundation
import Experiences
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+GrowthWeek.swift` | Frozen timeline, standing-view revision/retirement proof and decoded disposition transitions; `growthWeek`/`growthWeekLines` share the owned `growth-week.js` face. Readout grouping, titles, reasons, alternatives, ordering, cap and undertone prose are removed from Swift; canonical timeline source titles stay in Replay for its other consumers. |

public enum CognitiveGrowthOutcome: String, Sendable, Equatable, CaseIterable {
    /// Formed and still waiting on an answer. Never counts as a change she made.
    case proposed
    /// She adopted it herself. A weaker lean than `approved`, and named apart
    /// from it everywhere, because nobody signed it.
    case held
    /// The person signed it.
    case approved
    /// A later reflection contradicted it and opened a revision — but that
    /// revision is itself still only a PROPOSAL. The old view is still held /
    /// active and has released nothing; saying "revised" here would show an
    /// unapproved lesson as adopted (Agent's rule).
    case revisionProposed
    /// A later reflection contradicted it and the revision was ADOPTED. Only
    /// now has the old view actually been released.
    case revised
    /// She let it go on purpose.
    case letGo
    /// The person declined it.
    case declined
    /// The set was full. NOT a change of mind — the distinction Agent asked for
    /// and the one a reader is most likely to get wrong months later.
    case outOfSet
    /// A proposal that aged out unanswered. Not released, not adopted, and not
    /// dressed up as either.
    case expiredUnresolved
    case unavailable
    /// A REPLAY PASS RAN. A dream night or a consolidation sweep is not a
    /// proposal and never was: it proposes nothing, carries nothing, and
    /// answers nothing. It used to land in `.proposed` because that is where a
    /// row with no resolution starts, so every dream night Agent had read back
    /// as a lesson she had put forward and nobody had answered (2026-09-14).
    case replayed

}

public struct CognitiveDispositionTransition: Sendable, Equatable {
    public var before: Double
    /// After time was accounted for and nothing else — the fade.
    public var afterDecay: Double
    /// After the experience was added — the move.
    public var afterContribution: Double
    public var at: Date
    /// What contributed: the reflection, the dream night, the settled view.
    public var source: String

    public init(before: Double, afterDecay: Double, afterContribution: Double, at: Date, source: String) {
        self.before = before
        self.afterDecay = afterDecay
        self.afterContribution = afterContribution
        self.at = at
        self.source = source
    }

    func toJSON() -> JSONValue {
        .object([
            "before": .double(before),
            "afterDecay": .double(afterDecay),
            "afterContribution": .double(afterContribution),
            "at": .double(at.timeIntervalSince1970),
            "source": .string(source),
        ])
    }
}


/// One shared authored face, including the stem's availability evidence.
public struct CognitiveGrowthWeek: Sendable, Equatable {
    public let projection: PartFaceSnapshot
    public var lines: [String] {
        if projection.status != .ready {
            return ["Growth week \(projection.status.rawValue): \(projection.error?.message ?? projection.status.rawValue)"]
        }
        return projection.face?.sections.flatMap { $0.rows.map(\.title) } ?? []
    }
}

extension CognitiveSubstrate {
    static func growthOutcomeTag(_ outcome: CognitiveGrowthOutcome) -> String {
        "outcome:\(outcome.rawValue)"
    }

    func growthOutcomeTagIds(for decision: Experience?) -> [String] {
        let outcome: CognitiveGrowthOutcome
        if let decision {
            outcome = switch decision.outcome?.status {
            case "approved": decision.claims.contains { $0.claim == "applied" } ? .approved : .unavailable
            case "denied": .declined
            case "canceled": .letGo
            default: decision.isOpen ? .proposed : .expiredUnresolved
            }
        } else { outcome = .unavailable }
        return [Self.growthOutcomeTag(outcome)]
    }

    /// Outcome of a single timeline event, from its tag — or, for rows written
    /// before the tag existed, from the summary prefixes those rows have always
    /// used. Nil when the event is not a transition at all (a revisit).
    static func growthOutcome(of event: CognitiveDevelopmentalTimelineEvent) -> CognitiveGrowthOutcome? {
        for id in event.externalEvidenceIds where id.hasPrefix("outcome:") {
            if let outcome = CognitiveGrowthOutcome(rawValue: String(id.dropFirst("outcome:".count))) {
                return outcome
            }
        }
        // LEGACY ROWS. Written before the tag; their wording is fixed history,
        // so reading it is safe here and nowhere else.
        let summary = event.summary.lowercased()
        if summary.hasPrefix("activated:") { return .approved }
        if summary.hasPrefix("held (self-adopted)") { return .held }
        if summary.hasPrefix("retired (chosen)") { return .letGo }
        if summary.hasPrefix("retired (stale)") { return .expiredUnresolved }
        if summary.hasPrefix("retired (displaced)")
            || summary.hasPrefix("released (capacity)")
            || summary.hasPrefix("retired (capacity)")
            || summary.hasPrefix("out of the current set") { return .outOfSet }
        if summary.hasPrefix("retired:") { return .declined }
        // The REM replay pass records a proposal's resolution with the status
        // in the TITLE and no tag at all, so every one of those rows read
        // "Schema proposal accepted — proposed" — the prose and the machine
        // channel contradicting each other on the same line (Agent, 2026-09-14;
        // five of her twelve rows). Nobody signs a REM resolution, so accepted
        // is `held` (her own) and rejected is `letGo`, never the person's
        // `approved`/`declined`. New rows carry the tag (CognitiveSubstrate+Replay);
        // this reads the ones already on disk.
        let title = event.title.lowercased()
        if title.hasPrefix("schema proposal accepted") { return .held }
        if title.hasPrefix("schema proposal rejected") { return .letGo }
        return nil
    }


    /// Captured before suspension: disposition numbers and revision evidence
    /// cannot come from a different read than this timeline/view packet.
    public func growthWeek(at now: Date? = nil) async -> CognitiveGrowthWeek {
        await growthWeek(from: await developmentalTimelineSnapshot(limit: 240), at: now)
    }

    public func growthWeek(from timeline: [CognitiveDevelopmentalTimelineEvent], at now: Date? = nil) async -> CognitiveGrowthWeek {
        let end = now ?? dependencies.now()
        let start = end.addingTimeInterval(-7 * 24 * 60 * 60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let events: [JSONValue] = timeline.filter { $0.occurredAt >= start && $0.occurredAt <= end }.map { event in
            .object([
                "id": .string(event.id.uuidString), "artifactId": event.artifactId.map { .string($0.uuidString) } ?? .null,
                "kind": .string(event.kind.rawValue), "title": .string(event.title), "summary": .string(event.summary),
                "at": .double(event.occurredAt.timeIntervalSince1970), "day": .string(formatter.string(from: event.occurredAt)),
                "lineageId": .string(event.lineageId), "evidence": .array(event.externalEvidenceIds.map(JSONValue.string)),
                "outcome": Self.growthOutcome(of: event).map { .string($0.rawValue) } ?? .null,
            ])
        }
        let views: [JSONValue] = standingViews.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { view in
            let predecessor = view.revisesViewId.flatMap { standingViews[$0] }
            // Adoption alone is NOT release: the predecessor must really be retired.
            let released = (view.status == .active || view.status == .held) && predecessor?.status == .retired
            let happenedAt = released ? predecessor!.updatedAt : view.createdAt
            return .object([
                "id": .string(view.id.uuidString), "title": .string(view.title), "body": .string(view.body),
                "status": .string(view.status.rawValue), "revises": view.revisesViewId.map { .string($0.uuidString) } ?? .null,
                "createdAt": .double(view.createdAt.timeIntervalSince1970),
                "released": .bool(released),
                "inWindow": .bool(happenedAt >= start && happenedAt <= end),
                "releasedAt": .double((predecessor?.updatedAt ?? view.updatedAt).timeIntervalSince1970),
                "revisitCount": .int(Int64(view.revisitCount)),
                "originExcerpt": .string(view.evidenceExcerpts.first ?? ""),
            ])
        }
        // Unicode character boundaries are a native text primitive, not a
        // clipping policy. JS chooses limits without splitting a Mac character.
        let texts = timeline.flatMap { [$0.title,$0.summary] } + standingViews.values.flatMap { [$0.title,$0.body] }
        var characterSet = Set<String>()
        for text in texts {
            let flat = text.replacingOccurrences(of:"\n",with:" ").trimmingCharacters(in:.whitespacesAndNewlines)
            for version in [text,flat] {
                for character in version {
                    let glyph = String(character)
                    if glyph.utf16.count > 1 { characterSet.insert(glyph) }
                }
            }
        }
        let clusters = characterSet.sorted { lhs,rhs in
            lhs.utf16.count != rhs.utf16.count ? lhs.utf16.count > rhs.utf16.count : lhs < rhs
        }
        let input: JSONValue = .object([
            "clusters": .array(clusters.map(JSONValue.string)),
            "events": .array(events), "views": .array(views),
            "transitions": .array(dispositionTransitions.filter { $0.at >= start && $0.at <= end }.map { move in
                .object([
                    "source": .string(move.source),
                    "before": .string(String(format: "%.2f", move.before)),
                    "after": .string(String(format: "%.2f", move.afterContribution)),
                    "faded": .string(String(format: "%+.2f", move.afterDecay - move.before)),
                    "moved": .string(String(format: "%+.2f", move.afterContribution - move.afterDecay)),
                ])
            }),
        ])
        return CognitiveGrowthWeek(projection: await dependencies.growthProjection(input))
    }

    public func growthWeekLines(at now: Date? = nil) async -> [String] {
        await growthWeek(at: now).lines
    }
}
