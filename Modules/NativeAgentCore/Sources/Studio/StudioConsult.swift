import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import CryptoKit
// Blueprint: | `StudioConsult.swift` | Studio errors and immutable consult envelopes |

// MARK: - Errors

public enum StudioError: Error, LocalizedError, Sendable, Equatable {
    /// A consult without artifact refs must declare itself description-only.
    case consultMissingDescriptionOnlyFlag
    /// A consult with neither refs nor a description — nothing to judge.
    case consultHasNothingToJudge
    case consultQuestionMissing
    case unknownConsult(String)
    case malformedConsult(String)
    case invalidIdentifier(String)
    /// A description-only consult cannot become an encounter.
    case descriptionOnlyConsultCannotBecomeEncounter(String)
    case journalOriginConsultRequiresRef
    case journalWorkTitleMissing
    case journalResponseMissing
    case unknownOriginKind(String)
    case unknownStanceKind(String)
    case unknownRelationKind(String)
    case relationMissingEntryId
    case unknownJournalEntry(String)
    case amendmentReasonMissing
    case amendmentCorrectionMissing
    /// The passage to supersede is not in the entry's original response — a correction must name text that is actually there, or it is rewriting something the entry never said.
    case amendmentPassageNotFound(String)
    /// The passage appears more than once, so which one is being corrected is not knowable. Quote more of the sentence.
    case amendmentPassageNotUnique(String)
    /// An abstained entry with no response has no passage to supersede.
    case amendmentEntryHasNoResponse(String)
    /// The passage this correction names overlaps one an earlier amendment already superseded. Two corrections over the same words would nest one strike-through inside another and neither would read as written.
    case amendmentPassageOverlaps(passage: String, existingAmendmentID: String, existingPassage: String)

    public var errorDescription: String? {
        switch self {
        case .consultMissingDescriptionOnlyFlag:
            return "studio_consult: no artifact_refs were given, so this consult is description-only — set description_only=true. A description-only consult can be critiqued, but it can never become a journal encounter."
        case .consultHasNothingToJudge:
            return "studio_consult: give artifact_refs, a description, or both — there is nothing to look at otherwise."
        case .consultQuestionMissing:
            return "studio_consult: question is required — say what is actually being asked."
        case .unknownConsult(let id):
            return "studio: no consult with id '\(id)'."
        case .malformedConsult(let id):
            return "studio: the consult envelope for '\(id)' exists but does not decode."
        case .invalidIdentifier(let raw):
            return "studio: '\(raw)' is not a valid studio id (letters, digits and underscores only)."
        case .descriptionOnlyConsultCannotBecomeEncounter(let id):
            return "studio_journal: consult '\(id)' was description-only — a concept or brief with no work in front of you. It can be critiqued, but it is not an encounter and can never enter the journal as one. Journal the work itself when you actually receive it."
        case .journalOriginConsultRequiresRef:
            return "studio_journal: origin.kind=consult needs origin.ref — the consult id this entry came from."
        case .journalWorkTitleMissing:
            return "studio_journal: work.title is required — name what you encountered."
        case .journalResponseMissing:
            return "studio_journal: response is required unless stance.kind=abstained (an encounter doesn't owe a verdict, but a formed or open stance owes its judgment)."
        case .unknownOriginKind(let raw):
            return "studio_journal: unknown origin.kind '\(raw)' (expected wandering | consult | project)."
        case .unknownStanceKind(let raw):
            return "studio_journal: unknown stance.kind '\(raw)' (expected open | formed | abstained)."
        case .unknownRelationKind(let raw):
            return "studio_journal: unknown relation kind '\(raw)' (expected deepens | contradicts | revises | echoes)."
        case .relationMissingEntryId:
            return "studio_journal: every relation needs an entry_id — the entry it deepens/contradicts/revises/echoes."
        case .unknownJournalEntry(let id):
            return "studio_journal_amend: no journal entry with id '\(id)'."
        case .amendmentReasonMissing:
            return "studio_journal_amend: reason is required — say why the entry is wrong. A correction with no reason is a rewrite wearing a date."
        case .amendmentCorrectionMissing:
            return "studio_journal_amend: correction is required — the text that now stands."
        case .amendmentPassageNotFound(let passage):
            return "studio_journal_amend: supersedes text is not in that entry's response, verbatim: \"\(passage)\". Quote the passage exactly as written, or omit supersedes to append a dated correction instead."
        case .amendmentPassageNotUnique(let passage):
            return "studio_journal_amend: \"\(passage)\" appears more than once in that entry's response, so which one is being corrected is not knowable. Quote more of the sentence."
        case .amendmentEntryHasNoResponse(let id):
            return "studio_journal_amend: entry '\(id)' has no response text, so there is no passage to supersede. Omit supersedes to append a dated correction."
        case .amendmentPassageOverlaps(let passage, let existing, let existingPassage):
            return "studio_journal_amend: \"\(passage)\" overlaps a passage amendment '\(existing)' already corrected (\"\(existingPassage)\"). Correcting the same words twice would nest one correction inside another. Quote a passage that does not overlap it, or omit supersedes to append a dated correction that stands on its own."
        }
    }
}

// MARK: - Consult envelope

/// One filed consult. The envelope is written ONCE and read back verbatim; the store never edits it, never scores it, and never suggests a verdict.
public struct StudioConsult: Sendable, Equatable {
    public var id: String
    public var filedAt: String
    /// What the agent can actually look at — file paths or URLs. Empty means description-only.
    public var artifactRefs: [String]
    public var description: String?
    /// What portion of the work is available (a spread, a rough cut, one screen).
    public var portionAvailable: String?
    public var question: String
    public var projectContext: String?
    public var stage: String?
    public var constraints: String?
    public var priorDiscussion: String?
    /// Declared, never inferred after the fact: this consult carries no work, only a description of one.
    public var descriptionOnly: Bool

    public init(
        id: String,
        filedAt: String,
        artifactRefs: [String],
        description: String? = nil,
        portionAvailable: String? = nil,
        question: String,
        projectContext: String? = nil,
        stage: String? = nil,
        constraints: String? = nil,
        priorDiscussion: String? = nil,
        descriptionOnly: Bool
    ) {
        self.id = id
        self.filedAt = filedAt
        self.artifactRefs = artifactRefs
        self.description = description
        self.portionAvailable = portionAvailable
        self.question = question
        self.projectContext = projectContext
        self.stage = stage
        self.constraints = constraints
        self.priorDiscussion = priorDiscussion
        self.descriptionOnly = descriptionOnly
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "filed_at": .string(filedAt),
            "question": .string(question),
            "description_only": .bool(descriptionOnly),
            "artifact_refs": .array(artifactRefs.map { .string($0) }),
        ]
        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { obj[key] = .string(value) }
        }
        put("description", description)
        put("portion_available", portionAvailable)
        put("project_context", projectContext)
        put("stage", stage)
        put("constraints", constraints)
        put("prior_discussion", priorDiscussion)
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> StudioConsult? {
        guard case .object(let obj) = value,
              case .string(let id)? = obj["id"],
              case .string(let filedAt)? = obj["filed_at"],
              case .string(let question)? = obj["question"] else { return nil }
        // A missing description_only flag decodes as FALSE only when refs are present. An envelope with no refs is description-only by definition, whatever the bytes say — the honest reading is the restrictive one.
        var refs: [String] = []
        if case .array(let arr)? = obj["artifact_refs"] {
            refs = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        var descriptionOnly = refs.isEmpty
        if case .bool(let flag)? = obj["description_only"], flag { descriptionOnly = true }
        func str(_ key: String) -> String? {
            if case .string(let s)? = obj[key], !s.isEmpty { return s }
            return nil
        }
        return StudioConsult(
            id: id,
            filedAt: filedAt,
            artifactRefs: refs,
            description: str("description"),
            portionAvailable: str("portion_available"),
            question: question,
            projectContext: str("project_context"),
            stage: str("stage"),
            constraints: str("constraints"),
            priorDiscussion: str("prior_discussion"),
            descriptionOnly: descriptionOnly
        )
    }
}
