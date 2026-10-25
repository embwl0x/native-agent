import Foundation
import PersistenceCore
import Desk
import CognitiveSubstrate

// Blueprint: | `AutonomousPursuitProposer.swift` | `AutonomousPursuitProposer`: at most one reflection pursuit from a live non-seed life-depth care with a stance; life approval, Desk cap and citation dedup guard admission |

public struct PursuitProposal: Sendable, Equatable {
    public let project: String
    public let title: String
    public let summary: String
    public let pursuit: Pursuit
    public let citedCareId: String
    public let rationale: String
}

public enum AutonomousPursuitProposer {
    /// A reflection can form a stance, but cannot take a care to life depth.
    /// That approval is the pre-existing evidence this route requires.
    public static func propose(
        cares: [CognitiveCare], openAgentPursuitCount: Int, citedCareIds: Set<String>
    ) -> PursuitProposal? {
        guard openAgentPursuitCount < SwiftNativeDeskStore.maxOpenAgentPursuits else { return nil }
        for care in cares where care.fadedAt == nil && care.origin != .seed && care.depth == .life {
            let id = care.id.uuidString
            guard !citedCareIds.contains(id), let stance = care.stance,
                  !stance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let title = bounded("Pursue: \(care.about)", max: 120)
            let pursuit = Pursuit(
                why: bounded("This care is part of my life; I want to test where my stance leads: \(stance.text)", max: 240),
                evidence: PromotionDossier(citations: [.care(id: id)]),
                doneLooksLike: bounded("A concrete finding or artifact that examines my stance on \(care.about)", max: 240),
                abandonCondition: "If a few work sessions pass with no new insight, I close it with a note on what I learned by letting it go.",
                privateName: nil)
            guard pursuit.validationError() == nil else { continue }
            return PursuitProposal(project: "workshop", title: title,
                summary: "Self-pursuit proposed from a life-depth care.", pursuit: pursuit, citedCareId: id,
                rationale: bounded("Proposed self-pursuit from life-depth care \(id): \(stance.text)", max: 240))
        }
        return nil
    }

    public static func bounded(_ text: String, max: Int) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
