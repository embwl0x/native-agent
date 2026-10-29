import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import CryptoKit
// Blueprint: | `StudioRecall.swift` | Read-only recall and encounter-intake values |

// MARK: - Recall query

/// A read-only query over the journal. Every supplied field narrows the result (AND); an empty query matches everything. There is NO relevance score — the only ordering is newest-first, because the response text is the point and ranking it
/// would be the taste-score this store refuses to keep.
public struct StudioRecallQuery: Sendable, Equatable {
    public var text: String?
    public var title: String?
    public var creator: String?
    public var medium: String?
    public var tag: String?
    public var relationKind: StudioRelationKind?
    public var relatedTo: String?
    public var limit: Int

    public static let defaultLimit = 10
    public static let maximumLimit = 50

    public init(
        text: String? = nil,
        title: String? = nil,
        creator: String? = nil,
        medium: String? = nil,
        tag: String? = nil,
        relationKind: StudioRelationKind? = nil,
        relatedTo: String? = nil,
        limit: Int = StudioRecallQuery.defaultLimit
    ) {
        self.text = text
        self.title = title
        self.creator = creator
        self.medium = medium
        self.tag = tag
        self.relationKind = relationKind
        self.relatedTo = relatedTo
        self.limit = min(max(1, limit), StudioRecallQuery.maximumLimit)
    }
}

/// Matches, newest-first, plus an HONEST statement of what was left out.
public struct StudioRecallResult: Sendable, Equatable {
    public var entries: [StudioJournalEntry]
    public var matchedCount: Int
    public var hasMore: Bool
    /// The corrections file was damaged on this read, so an entry here may be showing a claim that has already been corrected. Never false by omission.
    public var correctionsUnreadable: Bool = false
    /// Journal history this read could not see (unreadable archives, damaged or undecodable lines). Matches and counts cover only what was read.
    public var historyUnreadable: [String] = []
}

// MARK: - Encounter intake

/// Studio's shared vocabulary for an unjournaled work already in reach; intake invents no work.
public struct StudioEncounterCandidate: Sendable, Equatable, Hashable {
    public enum Source: String, Sendable, CaseIterable, Equatable {
        /// A consult with real artifact refs is an invitation, not an assignment.
        case named
        /// A work the knowledge graph holds that the journal never answered.
        case unjournaledWork
        /// No producer; screen encounters require explicit capture consent.
        case crossedTheScreen
    }

    public var source: Source
    /// What it is called, when anything actually knows. A consult carries refs, not a title, and inventing one would be the dishonesty the whole design exists to prevent — so this stays optional.
    public var title: String?
    public var creator: String?
    /// The path or URL she would receive it through. TEXT: nothing in the intake path opens it. An honest encounter happens in front of the work, through the vision/browser organs, never by a queue quietly reading a file.
    public var reference: String?
    /// What names this candidate for dedup — a consult id, an entity id.
    public var originID: String
    public var noticedAt: String

    public init(
        source: Source,
        title: String? = nil,
        creator: String? = nil,
        reference: String? = nil,
        originID: String,
        noticedAt: String
    ) {
        self.source = source
        self.title = title
        self.creator = creator
        self.reference = reference
        self.originID = originID
        self.noticedAt = noticedAt
    }

}
