import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import CryptoKit
// Blueprint: | `StudioRecall.swift` | Read-only recall and encounter-intake values |

// MARK: - Recall query

/// AND filters and newest-first order preserve the response as evidence without assigning taste scores.
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

/// Report omitted coverage alongside verbatim matches.
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
        case unjournaledWork
    }

    public var source: Source
    /// Titles stay optional: consult refs cannot prove a work's name.
    public var title: String?
    public var creator: String?
    /// Intake exposes paths as text only; an encounter requires actually viewing the work through the vision or browser owner.
    public var reference: String?
    /// Use consult or entity identity to deduplicate candidates.
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
