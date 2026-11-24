// Felt-day origins expose only subject references and string metadata. Population eligibility is shared with mood and the summary; disclosure stays separate.

import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `CognitiveSubstrate+FeltOrigins.swift` | `CognitiveSubstrate.feltDayOrigins`: shared felt-day provenance |

/// Expose subject and metadata only; message payloads stay private.
public struct CognitiveFeltOrigin: Sendable, Equatable {
    public var subjectType: String
    public var subjectID: String
    /// The node's string-valued metadata. Non-string values are dropped: an id a consumer can cite is a string, and coercing numbers would invent ones.
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
    /// Match felt-day ranking so bounded consumers keep the strongest moments deterministically; disabled or unfelt state remains empty.
    func feltDayOrigins(at now: Date) async -> [CognitiveFeltOrigin] {
        guard configuration.enabled else { return [] }
        let ranked = feltDayNodes(at: now).sorted(by: Self.feltDayStronger)
        return ranked.map(CognitiveFeltOrigin.init(node:))
    }
}
