import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import CryptoKit
// Blueprint: | `StudioConsult.swift` | Immutable consults and checked errors |

// MARK: - Errors

public enum StudioError: Error, LocalizedError, Sendable, Equatable {
    /// Missing artifact refs require an explicit description-only declaration.
    case consultMissingDescriptionOnlyFlag
    /// Neither refs nor description leaves nothing to judge.
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
    /// Corrections must quote original response text; otherwise they rewrite words the entry never said.
    case amendmentPassageNotFound(String)
    /// Repeated passages are ambiguous; a longer quotation must identify the correction.
    case amendmentPassageNotUnique(String)
    /// An abstained entry without a response has no passage to correct.
    case amendmentEntryHasNoResponse(String)
    /// Overlapping corrections would nest strike-throughs and misrepresent both amendments.
    case amendmentPassageOverlaps(passage: String, existingAmendmentID: String, existingPassage: String)

    public var errorDescription: String? {
        switch self {
        case .consultMissingDescriptionOnlyFlag:
            return """
                studio_consult: no artifact_refs were given, so this consult is description-only — set description_only=true. A description-only consult can \
                be critiqued, but it can never become a journal encounter.
                """
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
            return """
                studio_journal: consult '\(id)' was description-only — a concept or brief with no work in front of you. It can be critiqued, but it is \
                not an encounter and can never enter the journal as one. Journal the work itself when you actually receive it.
                """
        case .journalOriginConsultRequiresRef:
            return "studio_journal: origin.kind=consult needs origin.ref — the consult id this entry came from."
        case .journalWorkTitleMissing:
            return "studio_journal: work.title is required — name what you encountered."
        case .journalResponseMissing:
            return """
                studio_journal: response is required unless stance.kind=abstained (an encounter doesn't owe a verdict, but a formed or open stance owes its \
                judgment).
                """
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
            return """
                studio_journal_amend: supersedes text is not in that entry's response, verbatim: \"\(passage)\". Quote the passage exactly as written, or \
                omit supersedes to append a dated correction instead.
                """
        case .amendmentPassageNotUnique(let passage):
            return """
                studio_journal_amend: \"\(passage)\" appears more than once in that entry's response, so which one is being corrected is not knowable. Quote \
                more of the sentence.
                """
        case .amendmentEntryHasNoResponse(let id):
            return """
                studio_journal_amend: entry '\(id)' has no response text, so there is no passage to supersede. Omit supersedes to \
                append a dated correction.
                """
        case .amendmentPassageOverlaps(let passage, let existing, let existingPassage):
            return """
                studio_journal_amend: \"\(passage)\" overlaps a passage amendment '\(existing)' already corrected (\"\(existingPassage)\"). Correcting the \
                same words twice would nest one correction inside another. Quote a passage that does not overlap it, or omit supersedes to append a dated \
                correction that stands on its own.
                """
        }
    }
}

// MARK: - Consult envelope

/// Keep the filed envelope immutable so reads cannot alter the evidence or imply a verdict.
public struct StudioConsult: Sendable, Equatable {
    public var id: String
    public var filedAt: String
    /// Empty artifact refs mean description-only.
    public var artifactRefs: [String]
    public var description: String?
    public var portionAvailable: String?
    public var question: String
    public var projectContext: String?
    public var stage: String?
    public var constraints: String?
    public var priorDiscussion: String?
    /// Declare description-only intake explicitly; later readers cannot infer an encounter.
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
              case .bool(let descriptionOnly)? = obj["description_only"] else { return nil }
        do {
            let row = try StudioSavedRow(value)
            let refs = try row.strings("artifact_refs", required: true)
            let description = try row.optionalString("description")
            guard (!refs.isEmpty || descriptionOnly), (!refs.isEmpty || description != nil) else { return nil }
            return try StudioConsult(id: row.string("id"), filedAt: row.string("filed_at"), artifactRefs: refs,
                description: description, portionAvailable: row.optionalString("portion_available"),
                question: row.string("question"), projectContext: row.optionalString("project_context"),
                stage: row.optionalString("stage"), constraints: row.optionalString("constraints"),
                priorDiscussion: row.optionalString("prior_discussion"), descriptionOnly: descriptionOnly)
        } catch { return nil }
    }
}
