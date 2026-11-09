import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import Experiences
// Blueprint: | `StudioWanderLane.swift` | The hour's installation, material and Desk projection of its ordinary thought |

/// The person's switch admits opportunities; attention owns their worth and their thoughts.
public enum StudioWanderLane {

    // MARK: Installation

    public enum Installation: Sendable, Equatable {
        case installed
        /// Distinguish disabled preference from public-build restriction in diagnostics.
        case notInstalled(reason: String)

        public var isInstalled: Bool { self == .installed }
    }

    /// Public pre-onboarding builds cannot install this work.
    public static let enabledDefaultsKey = "studioWanderEnabled"

    /// A new agent has the hour from day one; the person can turn it off.
    public static let enabledByDefault = true

    /// Resolve from caller-supplied choices so this module owns no Bundle/environment dependency.
    /// Absent hour choice takes `enabledByDefault`; the Subconscious master also bounds installation.
    public static func resolveInstallation(
        enabled: Bool?,
        forcedNeutral: Bool,
        subconsciousEnabled: Bool
    ) -> Installation {
        if forcedNeutral {
            return .notInstalled(reason: "public_safe_before_onboarding")
        }
        guard subconsciousEnabled else {
            return .notInstalled(reason: "subconscious_off")
        }
        guard enabled ?? enabledByDefault else {
            return .notInstalled(reason: "switch_off")
        }
        return .installed
    }

    /// Desk reads the same settled thought that teaches attention; no hour outcome is stored separately.
    public enum Outcome: String, Sendable, Equatable { case hit, empty, withheld, failed }

    public struct ThoughtReading: Sendable, Equatable {
        public let at: String
        public let outcome: Outcome
    }

    public static func latestThought(dataRoot: URL) async throws -> ThoughtReading? {
        guard let entry = try await Attention.thoughts(dataRoot: dataRoot).last(where: {
            $0.thought?.through.contains("sense:hour") == true
        }) else { return nil }
        guard let status = entry.outcome?.status, let outcome = Outcome(rawValue: status) else {
            throw PersistenceCoreError.ioFailure("The hour's thought has no known terminal outcome: " + entry.id)
        }
        return ThoughtReading(at: entry.at, outcome: outcome)
    }

    // MARK: The agent's own material

    /// Offer only real material without assignment or ranking; empty material still permits exploration or decline.
    public struct Material: Sendable, Equatable {
        public var invitations: [String]
        /// Recent titles let the agent notice repetition without imposing an automatic avoidance rule.
        public var recentJournalTitles: [String]
        /// Offer pressing cares with explicit keys so the agent can choose which question continues, without assignment.
        public var cares: [String]

        public init(
            invitations: [String] = [],
            recentJournalTitles: [String] = [],
            cares: [String] = []
        ) {
            self.invitations = invitations
            self.recentJournalTitles = recentJournalTitles
            self.cares = cares
        }

        /// No material still leaves the hour's judgment to the agent.
        public var isEmpty: Bool {
            invitations.isEmpty && cares.isEmpty
        }

        public static let bulletLimit = 8
        public static let bulletCharacterLimit = 200

        static func bullets(_ values: [String]) -> String {
            values
                .prefix(bulletLimit)
                .map { "- " + String($0.prefix(bulletCharacterLimit)) }
                .joined(separator: "\n")
        }
    }

    /// Offer choice and decline equally without verdicts, quotas or absence pressure.
    /// Frame decline positively as complete; mentioning a nonexistent scoreboard would itself introduce one.
    public static func prompt(_ material: Material) throws -> String {
        var sections = [try completionPolicy("wander-hour", section: "prompt")
            + completionPolicy("wander-hour", section: "question")]
        if material.isEmpty {
            sections.append(try completionPolicy("wander-hour", section: "empty"))
        }
        if !material.cares.isEmpty {
            sections.append(try completionPolicy("wander-hour", section: "cares") + Material.bullets(material.cares))
        }
        if !material.invitations.isEmpty {
            sections.append(try completionPolicy("wander-hour", section: "invitations") + Material.bullets(material.invitations))
        }
        if !material.recentJournalTitles.isEmpty {
            sections.append(
                try completionPolicy("wander-hour", section: "journal") + Material.bullets(material.recentJournalTitles)
            )
        }
        return sections.joined(separator: "\n\n")
    }
}
