import Foundation

// MARK: - Studio store (desk 903 phases 1–2)
//
// The durable side of the agent's aesthetic life: a JOURNAL of encounters she
// wrote herself, and the CONSULTS filed against her taste. Both live under
// <dataRoot>/studio/ and are deliberately separate from MemoryV2 — taste is not
// facts and must not compete with recall budgets.
//
// STORE:
//   • <dataRoot>/studio/journal/journal.jsonl — append-only encounter entries.
//     ADDITIVE ONLY: there is no update and no delete. A judgment that changes
//     is a NEW entry linked to the old one (`relations`), so the contradiction
//     is preserved rather than flattened.
//   • <dataRoot>/studio/consults/<id>.json — one envelope per consult, keyed by
//     a stable id the caller can hand back later.
//
// THE VETOES THIS FILE ENFORCES (design spec, binding):
//   1. HONEST ENCOUNTERS ONLY. A consult with no artifact refs is
//      description-only, and a description-only consult can NEVER become a
//      journal encounter. Enforced at BOTH ends: the consult must declare
//      itself description-only when it carries no refs, and a journal entry
//      whose origin is such a consult is refused.
//   2. AN ENCOUNTER DOESN'T OWE A VERDICT. `stance: abstained` is fully valid,
//      and it is the one case where `response` may be absent.
//   3. NO SCORES. There is no rating, score, confidence, or sentiment field
//      anywhere in the entry shape — not optional, not ignored: absent. The
//      tool layer refuses unknown fields rather than dropping them, so a
//      caller cannot smuggle one in and believe it was recorded.
//   4. NOTHING AUTO-APPENDS. Filing a consult writes NOTHING to the journal;
//      turning one into an entry is a separate, deliberate act.
//
// This store is generic engine: no persona-specific content lives here.

// MARK: - Clock

/// Studio timestamps use the same ISO-8601 UTC microsecond shape as every other
/// Swift-native feed, so entries sort lexicographically beside them.
public enum StudioClock {
    public static func nowISO(_ date: Date = Date()) -> String { TaskLedgerClock.nowISO(date) }
    public static func parseISO(_ s: String) -> Date? { TaskLedgerClock.parseISO(s) }
}

// MARK: - Errors

public enum StudioError: Error, LocalizedError, Sendable, Equatable {
    /// A consult with no artifact refs that did not declare itself
    /// description-only. Veto 1: the agent never claims an encounter she did
    /// not actually have.
    case consultMissingDescriptionOnlyFlag
    /// A consult with neither refs nor a description — nothing to judge.
    case consultHasNothingToJudge
    case consultQuestionMissing
    case unknownConsult(String)
    case malformedConsult(String)
    case invalidIdentifier(String)
    /// Veto 1, the journal end: a description-only consult can never become an
    /// encounter.
    case descriptionOnlyConsultCannotBecomeEncounter(String)
    case journalOriginConsultRequiresRef
    case journalWorkTitleMissing
    case journalResponseMissing
    case unknownOriginKind(String)
    case unknownStanceKind(String)
    case unknownRelationKind(String)
    case relationMissingEntryId

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
        }
    }
}

// MARK: - Consult envelope

/// One filed consult. The envelope is written ONCE and read back verbatim; the
/// store never edits it, never scores it, and never suggests a verdict.
public struct StudioConsult: Sendable, Equatable {
    public var id: String
    public var filedAt: String
    /// What the agent can actually look at — file paths or URLs. Empty means
    /// description-only.
    public var artifactRefs: [String]
    public var description: String?
    /// What portion of the work is available (a spread, a rough cut, one screen).
    public var portionAvailable: String?
    public var question: String
    public var projectContext: String?
    public var stage: String?
    public var constraints: String?
    public var priorDiscussion: String?
    /// Declared, never inferred after the fact: this consult carries no work,
    /// only a description of one.
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
        // A missing description_only flag decodes as FALSE only when refs are
        // present. An envelope with no refs is description-only by definition,
        // whatever the bytes say — the honest reading is the restrictive one.
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

// MARK: - Journal entry

public enum StudioOriginKind: String, Sendable, CaseIterable, Equatable {
    case wandering, consult, project
}

public enum StudioStance: String, Sendable, CaseIterable, Equatable {
    case open, formed, abstained
}

public enum StudioRelationKind: String, Sendable, CaseIterable, Equatable {
    case deepens, contradicts, revises, echoes
}

/// What was encountered. `title` is the only required part — the rest is
/// whatever is actually known, never invented to fill a field.
public struct StudioWork: Sendable, Equatable {
    public var title: String
    public var creator: String?
    public var medium: String?
    public var date: String?
    public var version: String?
    public var edition: String?

    public init(
        title: String,
        creator: String? = nil,
        medium: String? = nil,
        date: String? = nil,
        version: String? = nil,
        edition: String? = nil
    ) {
        self.title = title
        self.creator = creator
        self.medium = medium
        self.date = date
        self.version = version
        self.edition = edition
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["title": .string(title)]
        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { obj[key] = .string(value) }
        }
        put("creator", creator)
        put("medium", medium)
        put("date", date)
        put("version", version)
        put("edition", edition)
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> StudioWork? {
        guard case .object(let obj) = value, case .string(let title)? = obj["title"] else { return nil }
        func str(_ key: String) -> String? {
            if case .string(let s)? = obj[key], !s.isEmpty { return s }
            return nil
        }
        return StudioWork(
            title: title, creator: str("creator"), medium: str("medium"),
            date: str("date"), version: str("version"), edition: str("edition")
        )
    }
}

/// HOW the work was received. Both fields are free text on purpose: the design
/// names examples ("original, reproduction, screening, playthrough, excerpt"),
/// not a closed set, and a closed enum would force a caller to misdescribe a
/// reception the vocabulary does not cover — the exact dishonesty the
/// honest-encounter rule exists to prevent.
public struct StudioReception: Sendable, Equatable {
    public var how: String?
    public var wholeOrPart: String?

    public init(how: String? = nil, wholeOrPart: String? = nil) {
        self.how = how
        self.wholeOrPart = wholeOrPart
    }

    public var isEmpty: Bool { (how ?? "").isEmpty && (wholeOrPart ?? "").isEmpty }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [:]
        if let how, !how.isEmpty { obj["how"] = .string(how) }
        if let wholeOrPart, !wholeOrPart.isEmpty { obj["whole_or_part"] = .string(wholeOrPart) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> StudioReception {
        guard case .object(let obj) = value else { return StudioReception() }
        func str(_ key: String) -> String? {
            if case .string(let s)? = obj[key], !s.isEmpty { return s }
            return nil
        }
        return StudioReception(how: str("how"), wholeOrPart: str("whole_or_part"))
    }
}

public struct StudioOrigin: Sendable, Equatable {
    public var kind: StudioOriginKind
    public var ref: String?

    public init(kind: StudioOriginKind, ref: String? = nil) {
        self.kind = kind
        self.ref = ref
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["kind": .string(kind.rawValue)]
        if let ref, !ref.isEmpty { obj["ref"] = .string(ref) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> StudioOrigin? {
        guard case .object(let obj) = value,
              case .string(let kindRaw)? = obj["kind"],
              let kind = StudioOriginKind(rawValue: kindRaw) else { return nil }
        var ref: String?
        if case .string(let r)? = obj["ref"], !r.isEmpty { ref = r }
        return StudioOrigin(kind: kind, ref: ref)
    }
}

/// Where the judgment stands. `abstained` is a first-class outcome, not a
/// failure — and it carries an optional reason, never a penalty.
public struct StudioStanceValue: Sendable, Equatable {
    public var kind: StudioStance
    public var reason: String?

    public init(kind: StudioStance, reason: String? = nil) {
        self.kind = kind
        self.reason = reason
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["kind": .string(kind.rawValue)]
        if let reason, !reason.isEmpty { obj["reason"] = .string(reason) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> StudioStanceValue? {
        guard case .object(let obj) = value,
              case .string(let kindRaw)? = obj["kind"],
              let kind = StudioStance(rawValue: kindRaw) else { return nil }
        var reason: String?
        if case .string(let r)? = obj["reason"], !r.isEmpty { reason = r }
        return StudioStanceValue(kind: kind, reason: reason)
    }
}

/// A typed link to an earlier entry. This is the ONLY revision mechanism: an
/// entry is never rewritten, so changing her mind shows up as a later entry
/// that `revises` or `contradicts` the first, and both survive.
public struct StudioRelation: Sendable, Equatable {
    public var kind: StudioRelationKind
    public var entryId: String

    public init(kind: StudioRelationKind, entryId: String) {
        self.kind = kind
        self.entryId = entryId
    }

    public func toJSON() -> JSONValue {
        .object(["kind": .string(kind.rawValue), "entry_id": .string(entryId)])
    }

    public static func fromJSON(_ value: JSONValue) -> StudioRelation? {
        guard case .object(let obj) = value,
              case .string(let kindRaw)? = obj["kind"],
              let kind = StudioRelationKind(rawValue: kindRaw),
              case .string(let entryId)? = obj["entry_id"],
              !entryId.isEmpty else { return nil }
        return StudioRelation(kind: kind, entryId: entryId)
    }
}

/// One encounter, one written judgment. The freeform `response` is the heart of
/// it; every other field exists to say what was encountered and how.
///
/// There is no rating, score, confidence, sentiment, or canon-status field, and
/// there never will be one here — canon membership is a separate deliberate act.
public struct StudioJournalEntry: Sendable, Equatable {
    public var id: String
    public var encounteredAt: String
    public var recordedAt: String
    public var work: StudioWork
    public var reception: StudioReception
    public var artifactRefs: [String]
    public var origin: StudioOrigin
    public var response: String?
    public var stance: StudioStanceValue
    public var relations: [StudioRelation]
    public var tags: [String]

    public init(
        id: String,
        encounteredAt: String,
        recordedAt: String,
        work: StudioWork,
        reception: StudioReception = StudioReception(),
        artifactRefs: [String] = [],
        origin: StudioOrigin,
        response: String? = nil,
        stance: StudioStanceValue,
        relations: [StudioRelation] = [],
        tags: [String] = []
    ) {
        self.id = id
        self.encounteredAt = encounteredAt
        self.recordedAt = recordedAt
        self.work = work
        self.reception = reception
        self.artifactRefs = artifactRefs
        self.origin = origin
        self.response = response
        self.stance = stance
        self.relations = relations
        self.tags = tags
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "encountered_at": .string(encounteredAt),
            "recorded_at": .string(recordedAt),
            "work": work.toJSON(),
            "origin": origin.toJSON(),
            "stance": stance.toJSON(),
        ]
        if !reception.isEmpty { obj["reception"] = reception.toJSON() }
        if !artifactRefs.isEmpty { obj["artifact_refs"] = .array(artifactRefs.map { .string($0) }) }
        if let response, !response.isEmpty { obj["response"] = .string(response) }
        if !relations.isEmpty { obj["relations"] = .array(relations.map { $0.toJSON() }) }
        if !tags.isEmpty { obj["tags"] = .array(tags.map { .string($0) }) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> StudioJournalEntry? {
        guard case .object(let obj) = value,
              case .string(let id)? = obj["id"],
              case .string(let recordedAt)? = obj["recorded_at"],
              let work = obj["work"].flatMap(StudioWork.fromJSON),
              let origin = obj["origin"].flatMap(StudioOrigin.fromJSON),
              let stance = obj["stance"].flatMap(StudioStanceValue.fromJSON) else { return nil }
        var encounteredAt = recordedAt
        if case .string(let e)? = obj["encountered_at"], !e.isEmpty { encounteredAt = e }
        let reception = obj["reception"].map(StudioReception.fromJSON) ?? StudioReception()
        var refs: [String] = []
        if case .array(let arr)? = obj["artifact_refs"] {
            refs = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        var response: String?
        if case .string(let r)? = obj["response"], !r.isEmpty { response = r }
        var relations: [StudioRelation] = []
        if case .array(let arr)? = obj["relations"] {
            relations = arr.compactMap { StudioRelation.fromJSON($0) }
        }
        var tags: [String] = []
        if case .array(let arr)? = obj["tags"] {
            tags = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        return StudioJournalEntry(
            id: id, encounteredAt: encounteredAt, recordedAt: recordedAt,
            work: work, reception: reception, artifactRefs: refs, origin: origin,
            response: response, stance: stance, relations: relations, tags: tags
        )
    }
}

// MARK: - Recall query

/// A read-only query over the journal. Every supplied field narrows the result
/// (AND); an empty query matches everything. There is NO relevance score — the
/// only ordering is newest-first, because the response text is the point and
/// ranking it would be the taste-score this store refuses to keep.
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
}

// MARK: - Store

/// Append-under-flock studio store. Stateless — all state lives on disk.
public struct SwiftNativeStudioStore: Sendable {
    public static let logLabel = "StudioStore"

    public let dataRoot: URL
    public let persistence: SwiftNativePersistenceCore

    public init(dataRoot: URL, persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()) {
        self.dataRoot = dataRoot
        self.persistence = persistence
    }

    /// `<dataRoot>/studio/`.
    public var studioRoot: URL {
        dataRoot.appendingPathComponent("studio", isDirectory: true)
    }

    /// `<dataRoot>/studio/journal/journal.jsonl`.
    public var journalPath: URL {
        studioRoot
            .appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent("journal.jsonl")
    }

    /// `<dataRoot>/studio/consults/`.
    public var consultsDirectory: URL {
        studioRoot.appendingPathComponent("consults", isDirectory: true)
    }

    /// `<dataRoot>/studio/journal/journal_archive_<stamp>.jsonl` — where the
    /// lines a cap trim would otherwise DESTROY are moved to first.
    ///
    /// The line cap on `journal.jsonl` trims by keeping the newest N lines and
    /// discarding the rest. For telemetry that is retention; for a life record
    /// it is deletion, and it would break the one promise the journal makes —
    /// no entry ever ceases to exist (gpt-5.5 review). So before any trim can
    /// run, the doomed lines are moved HERE, byte for byte. This file is never
    /// capped, never registered in the path-owned registry, and never read by
    /// `recall` — it is the overflow shelf, not a second journal.
    ///
    /// One file per trim event, stamped, so each event is self-describing.
    public func journalArchivePath(now: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return studioRoot
            .appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent("journal_archive_\(f.string(from: now)).jsonl")
    }

    /// `<dataRoot>/studio/journal/trim_receipts.jsonl` — one row per trim event:
    /// what was moved, where, and how big the journal was at the time.
    public var journalTrimReceiptsPath: URL {
        studioRoot
            .appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent("trim_receipts.jsonl")
    }

    /// Every overflow archive on the shelf, oldest stamp first. Nothing in the
    /// product calls this — `recall` deliberately reads the live journal only —
    /// but the shelf has to be enumerable, or "archived" would just be a nicer
    /// word for lost.
    public func journalArchivePaths() throws -> [URL] {
        let directory = studioRoot.appendingPathComponent("journal", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("journal_archive_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Test seam: fires on EVERY pre-trim overflow check the production append
    /// path performs, with the number of lines that check is about to move.
    /// It observes; it never decides anything.
    @TaskLocal public static var journalOverflowCheckObserver: (@Sendable (Int) -> Void)?

    /// `<dataRoot>/studio/consults/<id>.json`, for an id that has already been
    /// validated by `validatedIdentifier`.
    public func consultPath(id: String) throws -> URL {
        consultsDirectory.appendingPathComponent("\(try Self.validatedIdentifier(id)).json")
    }

    // MARK: Identifiers

    /// Studio ids are `<prefix>_<stamp>_<random>` and contain nothing that could
    /// escape the consults directory. Validated on the way in AND on the way
    /// out, because the read side takes an id straight from a model.
    static func validatedIdentifier(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard !trimmed.isEmpty,
              trimmed.count <= 128,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw StudioError.invalidIdentifier(raw)
        }
        return trimmed
    }

    /// A stable, sortable, filename-safe id: `<prefix>_<yyyyMMddTHHmmss>_<hex>`.
    static func newIdentifier(prefix: String, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        let random = UUID().uuidString.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
        return "\(prefix)_\(f.string(from: now))_\(random)"
    }

    // MARK: Consults

    /// File a consult. Writes the envelope and NOTHING else: no journal entry,
    /// no retrieval, no suggested verdict. Returns the stored envelope so the
    /// caller sees exactly what was persisted, including its id.
    @discardableResult
    public func fileConsult(
        artifactRefs: [String],
        description: String?,
        portionAvailable: String?,
        question: String,
        projectContext: String?,
        stage: String?,
        constraints: String?,
        priorDiscussion: String?,
        descriptionOnly: Bool,
        now: Date = Date()
    ) async throws -> StudioConsult {
        let refs = artifactRefs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { throw StudioError.consultQuestionMissing }
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        // VETO 1, the consult end. No refs means there is no work in front of
        // her, and the caller has to SAY so — a consult that quietly omits its
        // refs must never look like an encounter later.
        if refs.isEmpty {
            guard descriptionOnly else { throw StudioError.consultMissingDescriptionOnlyFlag }
            guard let trimmedDescription, !trimmedDescription.isEmpty else {
                throw StudioError.consultHasNothingToJudge
            }
        }
        let consult = StudioConsult(
            id: Self.newIdentifier(prefix: "consult", now: now),
            filedAt: StudioClock.nowISO(now),
            artifactRefs: refs,
            description: (trimmedDescription?.isEmpty == false) ? trimmedDescription : nil,
            portionAvailable: portionAvailable?.trimmingCharacters(in: .whitespacesAndNewlines),
            question: trimmedQuestion,
            projectContext: projectContext?.trimmingCharacters(in: .whitespacesAndNewlines),
            stage: stage?.trimmingCharacters(in: .whitespacesAndNewlines),
            constraints: constraints?.trimmingCharacters(in: .whitespacesAndNewlines),
            priorDiscussion: priorDiscussion?.trimmingCharacters(in: .whitespacesAndNewlines),
            // Refs present but declared description-only is honest and allowed:
            // it can only make the consult LESS eligible, never more.
            descriptionOnly: descriptionOnly || refs.isEmpty
        )
        try await persistence.writeJSON(consult.toJSON(), to: try consultPath(id: consult.id))
        return consult
    }

    /// Read one consult envelope back, verbatim.
    public func readConsult(id: String) async throws -> StudioConsult {
        _ = try Self.validatedIdentifier(id)
        guard let consult = try await consultIfExists(id: id) else {
            throw StudioError.unknownConsult(id)
        }
        return consult
    }

    /// The consult an arbitrary reference NAMES, or nil when it names no consult
    /// at all — an origin ref is "whatever identifies the source", so a desk
    /// handle, a URL, or a project name is a legitimate ref that simply is not a
    /// consult id. A ref that DOES resolve is returned whatever the entry claims
    /// its origin kind to be; a stored envelope that no longer decodes throws
    /// rather than passing as "not a consult".
    public func consultIfExists(id: String) async throws -> StudioConsult? {
        guard let path = try? consultPath(id: id),
              FileManager.default.fileExists(atPath: path.path) else { return nil }
        let raw = await persistence.readJSON(path, defaultValue: .null)
        guard let consult = StudioConsult.fromJSON(raw) else {
            throw StudioError.malformedConsult(id)
        }
        return consult
    }

    // MARK: Journal

    /// Append ONE entry. There is deliberately no counterpart: no update, no
    /// delete, no rewrite. Revision happens through a later linked entry.
    ///
    /// The append is DURABLE (F_FULLFSYNC before the descriptor closes) and runs
    /// through the path-owned cap registry, so the journal cannot be grown by a
    /// writer that skipped retention — see `jsonlPathOwnedCapPolicy`.
    @discardableResult
    public func appendJournalEntry(
        encounteredAt: String?,
        work: StudioWork,
        reception: StudioReception,
        artifactRefs: [String],
        origin: StudioOrigin,
        response: String?,
        stance: StudioStanceValue,
        relations: [StudioRelation],
        tags: [String],
        now: Date = Date()
    ) async throws -> StudioJournalEntry {
        guard !work.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudioError.journalWorkTitleMissing
        }
        let trimmedResponse = response?.trimmingCharacters(in: .whitespacesAndNewlines)
        // VETO 2: an encounter doesn't owe a verdict. `abstained` is the one
        // stance that may stand without a response; open/formed owe theirs.
        if stance.kind != .abstained, (trimmedResponse ?? "").isEmpty {
            throw StudioError.journalResponseMissing
        }
        // VETO 1, the journal end. A consult-origin entry must name its consult.
        if origin.kind == .consult, (origin.ref ?? "").isEmpty {
            throw StudioError.journalOriginConsultRequiresRef
        }
        // The description-only check keys on WHAT THE REF RESOLVES TO, never on
        // the kind the caller declared. Gating it on `kind == .consult` left the
        // veto one relabel away from useless: {kind: wandering, ref: <a
        // description-only consult>} walked straight past it (gpt-5.5 review).
        // A ref that resolves to no consult stays fine — an origin ref is
        // "whatever identifies the source".
        if let ref = origin.ref, !ref.isEmpty,
           let consult = try await consultIfExists(id: ref) {
            if consult.descriptionOnly {
                throw StudioError.descriptionOnlyConsultCannotBecomeEncounter(consult.id)
            }
        } else if origin.kind == .consult, let ref = origin.ref {
            // kind=consult promises a consult; an unresolvable one is a claim we
            // cannot check, so it fails rather than passing unverified.
            throw StudioError.unknownConsult(ref)
        }
        let recordedAt = StudioClock.nowISO(now)
        let entry = StudioJournalEntry(
            id: Self.newIdentifier(prefix: "entry", now: now),
            encounteredAt: (encounteredAt?.isEmpty == false) ? encounteredAt! : recordedAt,
            recordedAt: recordedAt,
            work: work,
            reception: reception,
            artifactRefs: artifactRefs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            origin: origin,
            response: (trimmedResponse?.isEmpty == false) ? trimmedResponse : nil,
            stance: stance,
            relations: relations,
            tags: tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        try await appendPathOwnedJSONL(
            entry.toJSON(),
            to: journalPath,
            using: persistence,
            logLabel: Self.logLabel,
            durable: true,
            // ARCHIVE BEFORE TRIM. This hook runs inside the feed's flock and
            // BEFORE the append, so a throw here means no append and no trim —
            // a shelf that cannot be written is a reason to stop, never a reason
            // to drop the oldest entries quietly.
            beforePotentialLineCap: { try await archiveJournalOverflowIfNeeded() }
        )
        return entry
    }

    /// Move the lines a cap trim is about to discard onto the overflow shelf,
    /// durably, and record the event — before the append that would trigger the
    /// trim, and before the trim itself.
    ///
    /// `incoming` is how many lines the pending append adds (1 on the live
    /// path), so the count matches exactly what `enforceJSONLLineCap` will drop
    /// afterwards. `maxLines` is the journal's registered budget; it is a
    /// parameter only so a test can exercise the overflow without writing a
    /// hundred thousand entries.
    ///
    /// Throws rather than skipping on anything it cannot handle — an unreadable
    /// journal is the one case where trimming must NOT proceed.
    func archiveJournalOverflowIfNeeded(
        maxLines: Int = JSONLLineCaps.studioJournal,
        incoming: Int = 1,
        now: Date = Date()
    ) async throws {
        let doomed = try journalOverflowLines(maxLines: maxLines, incoming: incoming)
        Self.journalOverflowCheckObserver?(doomed.count)
        guard !doomed.isEmpty else { return }

        let directory = journalPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = journalArchivePath(now: now)
        // Raw BYTES, not re-serialized rows: the shelf has to hold exactly what
        // the journal held, including a line this build could not decode.
        var payload = Data()
        for line in doomed {
            payload.append(contentsOf: line.utf8)
            payload.append(0x0A)
        }
        try SwiftNativePersistenceCore.appendBytes(payload, to: archive, durable: true)
        // The receipt is written only after the bytes are on the platter, and a
        // receipt failure also blocks the trim. Worst case is an archived line
        // that was not trimmed after all — duplicated, never lost.
        try await persistence.appendJSONLDurable(
            .object([
                "ts": .string(StudioClock.nowISO(now)),
                "archive": .string(archive.lastPathComponent),
                "archived_lines": .int(Int64(doomed.count)),
                "cap": .int(Int64(maxLines)),
            ]),
            to: journalTrimReceiptsPath
        )
        NSLog("%@: journal cap reached — moved %d oldest line(s) to %@ before any trim",
              Self.logLabel, doomed.count, archive.lastPathComponent)
    }

    /// The exact lines `enforceJSONLLineCap` would drop after `incoming` more
    /// are appended: the OLDEST `count + incoming - maxLines` of them.
    private func journalOverflowLines(maxLines: Int, incoming: Int) throws -> [String] {
        guard maxLines > 0, FileManager.default.fileExists(atPath: journalPath.path) else { return [] }
        // A file of n bytes holds at most n lines, so below the budget in BYTES
        // it cannot be over it in lines. This is what keeps the check free on
        // the ordinary append — the same sound bound `enforceJSONLLineCap` uses.
        if let size = ((try? FileManager.default.attributesOfItem(
            atPath: journalPath.path
        ))?[.size] as? NSNumber)?.intValue, size + incoming <= maxLines {
            return []
        }
        let data = try Data(contentsOf: journalPath)
        guard let text = String(data: data, encoding: .utf8) else {
            // Never trim what we cannot read: skipping here is how entries would
            // vanish without ever reaching the shelf.
            throw PersistenceCoreError.ioFailure(
                "studio journal at \(journalPath.path) is not valid UTF-8 — refusing to trim it"
            )
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        let overflow = lines.count + incoming - maxLines
        guard overflow > 0 else { return [] }
        return lines.prefix(overflow).map(String.init)
    }

    /// Every entry in file (append) order. The journal is a curated life record
    /// — a few entries a week, not telemetry — so reading it whole is honest and
    /// cheap; `recall` is what bounds what a caller sees.
    public func readJournal() async throws -> [StudioJournalEntry] {
        guard FileManager.default.fileExists(atPath: journalPath.path) else { return [] }
        let rows = try await persistence.readJSONL(journalPath)
        return rows.compactMap { StudioJournalEntry.fromJSON($0) }
    }

    /// Read-only search. Returns matching entries VERBATIM, newest first, capped
    /// by `query.limit`, with an explicit `hasMore`. No scoring, no ranking, and
    /// nothing calls this on the agent's behalf.
    public func recall(_ query: StudioRecallQuery) async throws -> StudioRecallResult {
        let entries = try await readJournal()
        let matches = entries.reversed().filter { Self.matches($0, query) }
        let bounded = Array(matches.prefix(query.limit))
        return StudioRecallResult(
            entries: bounded,
            matchedCount: matches.count,
            hasMore: matches.count > bounded.count
        )
    }

    static func matches(_ entry: StudioJournalEntry, _ query: StudioRecallQuery) -> Bool {
        func fold(_ s: String) -> String {
            s.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
        func contains(_ haystack: String?, _ needle: String?) -> Bool {
            guard let needle, !needle.isEmpty else { return true }
            guard let haystack else { return false }
            return fold(haystack).contains(fold(needle))
        }
        guard contains(entry.work.title, query.title) else { return false }
        guard contains(entry.work.creator, query.creator) else { return false }
        guard contains(entry.work.medium, query.medium) else { return false }
        if let tag = query.tag, !tag.isEmpty {
            guard entry.tags.contains(where: { fold($0) == fold(tag) }) else { return false }
        }
        if let kind = query.relationKind {
            guard entry.relations.contains(where: { $0.kind == kind }) else { return false }
        }
        if let relatedTo = query.relatedTo, !relatedTo.isEmpty {
            guard entry.relations.contains(where: { $0.entryId == relatedTo }) else { return false }
        }
        if let text = query.text, !text.isEmpty {
            // Free text reads the whole entry, response included — the response
            // is the point, so it must be searchable in its own words.
            let haystack = [
                entry.id, entry.work.title, entry.work.creator ?? "", entry.work.medium ?? "",
                entry.response ?? "", entry.stance.reason ?? "",
                entry.reception.how ?? "", entry.reception.wholeOrPart ?? "",
                entry.tags.joined(separator: " "),
                entry.artifactRefs.joined(separator: " "),
            ].joined(separator: " ")
            guard fold(haystack).contains(fold(text)) else { return false }
        }
        return true
    }
}
