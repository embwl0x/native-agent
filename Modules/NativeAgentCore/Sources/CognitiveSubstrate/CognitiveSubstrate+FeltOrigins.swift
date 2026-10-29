// Felt-day origins expose only subject references and string metadata.
// Population eligibility is shared with mood and the summary; disclosure stays separate.

import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `CognitiveSubstrate+FeltOrigins.swift` | `CognitiveSubstrate.feltDayOrigins`: last-day felt-node provenance for dreams, using the same population as the felt-day summary |

/// Where one felt node came from. Subject + metadata only, deliberately.
public struct CognitiveFeltOrigin: Sendable, Equatable {
    public var subjectType: String
    public var subjectID: String
    /// The node's string-valued metadata. Non-string values are dropped: an id
    /// a consumer can cite is a string, and coercing numbers would invent ones.
    public var metadata: [String: String]

    init(node: CognitiveNode) {
        subjectType = node.subjectReference.type
        subjectID = node.subjectReference.id
        metadata = node.metadata.compactMapValues { value in
            if case .string(let text) = value { return text }
            return nil
        }
    }

    /// Metadata wins over the subject reference; blank ids cite nothing.
    public var studioEntryID: String? {
        if let value = metadata[CognitiveEvent.studioEntryIDMetadataKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        guard subjectType == CognitiveSubstrate.studioEntrySubjectType else { return nil }
        let value = subjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public extension CognitiveSubstrate {
    /// Provenance of the last-24h felt nodes — the same population
    /// `feltDaySummary(at:)` integrates over, strongest-felt first.
    ///
    /// Ordering matches the summary's ranking (|valence| desc, arousal desc,
    /// stable id) so a consumer that keeps only the first N keeps the ones that
    /// mattered most, deterministically across dictionary orderings.
    ///
    /// Empty when cognition or affect is off, or nothing was felt — the same
    /// silence the summary returns nil for.
    func feltDayOrigins(at now: Date) async -> [CognitiveFeltOrigin] {
        guard configuration.enabled else { return [] }
        let ranked = feltDayNodes(at: now).sorted(by: Self.feltDayStronger)
        return ranked.map(CognitiveFeltOrigin.init(node:))
    }
}
