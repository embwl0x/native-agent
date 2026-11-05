// Frozen growth evidence stays native; grouping and words belong to growth-week.js.
import Foundation
import Experiences
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+GrowthWeek.swift` | `growthWeek`/`growthWeekLines`: frozen evidence for `growth-week.js` |

public enum CognitiveGrowthOutcome: String, Sendable, Equatable, CaseIterable {
    /// An unanswered proposal is not a change.
    case proposed
    /// Adoption is self-directed, never reported as person-approved.
    case held
    /// Approval requires the person's decision.
    case approved
    /// Release requires an explicit decision.
    case letGo
    /// Decline requires the person's decision.
    case declined
    /// Expiry is unanswered, never release or adoption.
    case expiredUnresolved
    case unavailable
    /// Replay alone attests no proposal or resolution.
    case replayed

}

public struct CognitiveDispositionTransition: Sendable, Equatable {
    public var before: Double
    /// Decay records elapsed time alone.
    public var afterDecay: Double
    /// Movement records the added experience.
    public var afterContribution: Double
    public var at: Date
    /// Source identity distinguishes reflection from dream contribution.
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


/// One authored face includes the stem's availability evidence.
public struct CognitiveGrowthWeek: Sendable, Equatable {
    public let projection: PartFaceSnapshot
    public var lines: [String] {
        if projection.status != .ready {
            return ["Growth week \(projection.status.rawValue): \(projection.error?.message ?? projection.status.rawValue)"]
        }
        return projection.face?.sections.flatMap { section in
            section.rows.map { row in
                [row.title, row.detail].compactMap { $0 }.joined(separator: "\n")
            }
        } ?? []
    }
}

extension CognitiveSubstrate {
    struct GrowthWeekInput: Sendable {
        let proposals: [CognitiveSchemaProposal]
        let events: [CognitiveDevelopmentalTimelineEvent]
        let transitions: [CognitiveDispositionTransition]
        let end: Date
    }

    func growthWeekInput(at end: Date) -> GrowthWeekInput {
        GrowthWeekInput(proposals: Array(schemaProposals.values), events: Array(developmentalTimeline.values),
                        transitions: dispositionTransitions, end: end)
    }

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

    /// Only an explicit outcome tag attests a timeline transition.
    static func growthOutcome(of event: CognitiveDevelopmentalTimelineEvent) -> CognitiveGrowthOutcome? {
        for id in event.externalEvidenceIds where id.hasPrefix("outcome:") {
            if let outcome = CognitiveGrowthOutcome(rawValue: String(id.dropFirst("outcome:".count))) {
                return outcome
            }
        }
        return nil
    }


    /// Captured before suspension: disposition numbers and revision evidence cannot come from a different read than this timeline packet.
    public func growthWeek(at now: Date? = nil) async -> CognitiveGrowthWeek {
        await growthWeek(input: growthWeekInput(at: now ?? dependencies.now()))
    }

    func growthWeek(input: GrowthWeekInput) async -> CognitiveGrowthWeek {
        let resolved = await schemaProposalSnapshot(from: input.proposals)
        let timeline = developmentalTimelineSnapshot(proposals: resolved, events: input.events, limit: 240)
        return await growthWeek(from: timeline, transitions: input.transitions, at: input.end)
    }

    public func growthWeek(from timeline: [CognitiveDevelopmentalTimelineEvent], at now: Date? = nil) async -> CognitiveGrowthWeek {
        await growthWeek(from: timeline, transitions: dispositionTransitions, at: now ?? dependencies.now())
    }

    private func growthWeek(from timeline: [CognitiveDevelopmentalTimelineEvent], transitions: [CognitiveDispositionTransition],
        at end: Date) async -> CognitiveGrowthWeek {
        let start = end.addingTimeInterval(-7 * 24 * 60 * 60)
        let events: [JSONValue] = timeline.filter { $0.occurredAt >= start && $0.occurredAt <= end }.map { event in
            .object([
                "id": .string(event.id.uuidString), "artifactId": event.artifactId.map { .string($0.uuidString) } ?? .null,
                "kind": .string(event.kind.rawValue), "title": .string(event.title), "summary": .string(event.summary),
                "at": .double(event.occurredAt.timeIntervalSince1970), "day": .string(NativeTimestampFormat.calendarDay(event.occurredAt)),
                "lineageId": .string(event.lineageId), "evidence": .array(event.externalEvidenceIds.map(JSONValue.string)),
                "outcome": Self.growthOutcome(of: event).map { .string($0.rawValue) } ?? .null,
            ])
        }
        // Unicode character boundaries are a native text primitive, not a clipping policy. JS chooses limits without splitting a Mac character.
        let texts = timeline.flatMap { [$0.title,$0.summary] }
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
            "events": .array(events),
            "transitions": .array(transitions.filter { $0.at >= start && $0.at <= end }.map { move in
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
