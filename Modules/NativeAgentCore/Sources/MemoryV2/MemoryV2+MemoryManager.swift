// One model pass judges the exchange against kept memories and returns grounded add, update or skip actions.
// Native gates check shape and provenance, not a phrase catalogue.
//
// A lived moment is not a memory here: it is a care movement, judged in the
// same call (docs/MEMORY_SYSTEM_MAP.md).

import Foundation
import NativeAgentShared
import CoreFoundation
import NativeAgentCore
import PersistenceCore
import CognitiveSubstrate
import TurnTrace

// Blueprint: | `MemoryV2+MemoryManager.swift` | `MemoryManagerLane`: semantic after-turn memory decisions (one turn, or a bounded batch of owed turns via `MemoryBatchInput`) with writer-named plan dates, grounded correction validation and reconciliation against existing rows |

// MARK: - What the manager returns

public enum MemoryManagerAction: String, Codable, Sendable, Equatable {
    /// A new memory about the person.
    case add
    /// This changes a memory that already exists; `updatesId` names it.
    case update
    /// Nothing here worth keeping. The common answer.
    case skip
}

/// The exact target the judgment reviewed, retained in its durable meaning.
public struct MemoryManagerReviewedTarget: Codable, Sendable, Equatable {
    public let id: String
    public let fingerprint: String
    public let pending: Bool
}

/// Semantic eligibility belongs to the existing interpretation call. Native
/// validation checks attribution and exact evidence, never English word overlap.
public struct MemoryManagerGrounding: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case incoming, reply }
    public enum Attribution: String, Codable, Sendable { case speaker, agent, other }
    public let source: Source
    public let attribution: Attribution
    public let evidence: String
    public let eligible: Bool
    public let standing: Bool
}

public struct MemoryManagerDecision: Codable, Sendable, Equatable {
    /// A standalone third-person sentence about the person, in plain words.
    public let statement: String
    /// identity / location / employment / schedule / preference / relationship /
    /// goal / skill / fact — free text; stamped on the proposal as `kind`.
    public let kind: String
    /// Why it would still matter in a month. Shown on the review card.
    public let whyItMatters: String
    /// 0…1. Below `MemoryManagerLane.confidenceFloor` nothing stages.
    public let confidence: Double
    public let action: MemoryManagerAction
    /// For `.update`: the id of the existing memory this supersedes.
    public let updatesId: String?
    public let correctionSubject: String?
    public let standingEvidence: String?
    /// A plan or commitment's instant, named by the same call as the memory.
    public let due: Date?
    public let reviewedTarget: MemoryManagerReviewedTarget?
    public let grounding: MemoryManagerGrounding?

    public init(
        statement: String,
        kind: String,
        whyItMatters: String,
        confidence: Double,
        action: MemoryManagerAction,
        updatesId: String? = nil,
        correctionSubject: String? = nil,
        standingEvidence: String? = nil,
        due: Date? = nil,
        reviewedTarget: MemoryManagerReviewedTarget? = nil,
        grounding: MemoryManagerGrounding? = nil
    ) {
        self.statement = statement
        self.kind = kind
        self.whyItMatters = whyItMatters
        self.confidence = confidence
        self.action = action
        self.updatesId = updatesId
        self.correctionSubject = correctionSubject
        self.standingEvidence = standingEvidence
        self.due = due
        self.reviewedTarget = reviewedTarget
        self.grounding = grounding
    }
}

/// One existing memory, as the manager sees it.
public struct MemoryManagerExistingMemory: Sendable, Equatable {
    public let id: String
    public let content: String
    public let correctionSubject: String?
    public let kind: String?
    public init(id: String, content: String, correctionSubject: String? = nil, kind: String? = nil) {
        self.id = id
        self.content = content
        self.correctionSubject = correctionSubject
        self.kind = kind
    }
}

/// Everything the manager is given for one turn.
public struct MemoryManagerRequest: Sendable, Equatable {
    public let userMessage: String
    public let assistantMessage: String
    /// Top-K memories recalled by embedding for this exchange.
    public let existing: [MemoryManagerExistingMemory]
    /// Pending rows shown in the prompt and used to resolve update targets before meaning is written.
    /// Never reconstructed on replay.
    public let pendingTargets: [MemoryManagerExistingMemory]
    /// The nearest claims she was told to forget or the person rejected.
    public let forgotten: [String]
    /// The person's configured name, so a memory is about "User", never "the person".
    public let personName: String?
    public let standingAgent: Bool
    public let appAuthored: Bool
    /// What her turn took (`AfterTurnOrigin.took`), when it used tools.
    public let took: String?
    /// The exchange's clock, retained when an owed turn is judged later.
    public let occurredAt: Date?

    public init(
        userMessage: String,
        assistantMessage: String,
        existing: [MemoryManagerExistingMemory] = [],
        pendingTargets: [MemoryManagerExistingMemory] = [],
        forgotten: [String] = [],
        personName: String? = nil,
        standingAgent: Bool = false,
        appAuthored: Bool = false,
        took: String? = nil,
        occurredAt: Date? = nil
    ) {
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
        self.existing = existing
        self.pendingTargets = pendingTargets
        self.forgotten = forgotten
        self.personName = personName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? personName : nil
        self.standingAgent = standingAgent
        self.appAuthored = appAuthored
        self.took = took
        self.occurredAt = occurredAt
    }
}

public struct AfterTurnInterpretation: Codable, Sendable {
    public let memories: [MemoryManagerDecision]
    public let affect: CognitiveSubstrate.AffectAppraisal
    public let caring: CaringAppraisalVerdict
    /// What moved her against the cares she was shown.
    public let cares: [CognitiveCareJudgment]
    /// The incoming words were the app's, so only her side of the exchange counts.
    public let appAuthored: Bool
    public let model: String?
    public let surface: String

    /// The record's key for the model that judged: the judgment's own surface
    /// and model, as the call reported them. A label's scope is this key.
    public var judgingKey: String { Self.judgingKey(surface: surface, model: model) }
    public static func judgingKey(surface: String, model: String?) -> String {
        AfterTurnMemorySurprise.fingerprint(["memory-judgment-v2", surface, model ?? ""])
    }

    public init(memories: [MemoryManagerDecision],
                affect: CognitiveSubstrate.AffectAppraisal, caring: CaringAppraisalVerdict,
                cares: [CognitiveCareJudgment] = [], appAuthored: Bool = false,
                model: String?, surface: String) {
        self.memories = memories
        self.affect = affect
        self.caring = caring
        self.cares = cares
        self.appAuthored = appAuthored
        self.model = model
        self.surface = surface
    }
}

/// The seam. The production conformer (`MindMemoryJudgment`) asks the model on
/// the Providers "Memory" row. There is
/// deliberately NO rule-based conformer: a memory invented by a pattern is what
/// this file exists to delete.
///
public struct AfterTurnMemoryFailure: Error, Codable, Sendable, Hashable {
    public enum Reason: String, Codable, Sendable, Hashable {
        case deadline, cancelled, provider, invalidJSON, missingSections
        case invalidCaring, invalidAffect, invalidMemories, invalidCares
        case authExpired, codexCLISessionExpired, rateLimited, overloaded, contextTooLong
        case network, outputLimit, refused, requestRejected, invalidProviderResponse, routingUnavailable, modelUnavailable

        /// A held queue written before moments became care story may still say
        /// `invalidMoment`; it reads as the memories failure it now is.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let reason = Reason(rawValue: raw == "invalidMoment" ? "invalidMemories" : raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "unknown after-turn failure \(raw)"))
            }
            self = reason
        }
    }
    public let reason: Reason
    public let recovery: String
    public let model: String?
    public let surface: String
    public let at: Date

    public init(reason: Reason, recovery: String, model: String?, surface: String, at: Date = Date()) {
        self.reason = reason
        self.recovery = recovery
        self.model = model
        self.surface = surface
        self.at = at
    }

    public var detail: String {
        "After-turn memory failed: \(reason.rawValue). \(recovery) No new memory was saved from this pass."
    }

    public var interpretationFailure: AfterTurnInterpretationFailure {
        switch reason {
        case .deadline: return .deadline
        case .cancelled: return .cancellation
        case .authExpired, .codexCLISessionExpired: return .authentication
        case .invalidJSON, .missingSections: return .envelope
        case .invalidCaring: return .caring
        case .invalidAffect: return .affect
        case .invalidMemories: return .memories
        case .invalidCares: return .cares
        default: return .provider
        }
    }
}

public enum AfterTurnInterpretationFailure: String, Error, Sendable {
    case provider, authentication, deadline, cancellation
    case envelope, caring, affect, memories, cares
}

/// One owed exchange in a batch: its own request and context, exactly
/// as the turn would have been judged alone.
public struct MemoryBatchInput: Sendable {
    public let request: MemoryManagerRequest
    public let context: AfterTurnContext?
    public let factsEnabled: Bool
    public init(request: MemoryManagerRequest, context: AfterTurnContext?, factsEnabled: Bool) {
        self.request = request
        self.context = context
        self.factsEnabled = factsEnabled
    }
}

/// No incoming message returns nil; failures throw bounded recovery evidence.
/// An empty memory array is a valid abstention.
public protocol MemoryManaging: Sendable {
    /// The record's key (`AfterTurnInterpretation.judgingKey`) for the model
    /// this turn's judgment would run on, read without changing the request.
    /// nil: unkeyed, so no prediction stands.
    func predictionModelKey() async -> String?
    func interpret(_ request: MemoryManagerRequest, context: AfterTurnContext?,
                   factsEnabled: Bool) async throws -> AfterTurnInterpretation?
    /// Several owed exchanges in one call, one section each, in input order.
    /// A nil entry is a section the reply lacked or got wrong: that exchange
    /// stays owed. Throws when the call itself fails.
    func interpretBatch(_ inputs: [MemoryBatchInput]) async throws -> [AfterTurnInterpretation?]
    func relevantRecallIDs(query: String, candidates: [MemoryManagerExistingMemory], generation: String?, topK: Int?) async
        -> Result<Set<String>, AfterTurnMemoryFailure>
}

// MARK: - Lane constants, prompt, parse, gate

public enum MemoryManagerLane {
    /// Distinct from `adaptive-promoter:` (the deleted regex lane) and the
    /// retired `moment-promoter:` so a row's provenance names the pass that made it.
    public static let sourcePrefix = "memory-manager"
    /// Nothing below this stages, whatever the action says.
    public static let confidenceFloor = 0.8
    /// How many owed exchanges one batch judgment takes. Four keeps one
    /// call's prompt near a single turn's scale while the rules are sent once.
    public static let batchLimit = 4
    /// How many existing memories the manager is shown.
    public static let recallTopK = 8
    /// How many pending proposals the manager is shown.
    public static let pendingCap = 24
    /// A memory is a sentence, not a paragraph.
    public static let statementCap = 200
    public static let statementFloor = 12
    /// How many forgotten claims the manager is shown: the nearest, by the
    /// same embedding as the memories it sees.
    public static let forgottenTopK = 8
    /// Metadata key carrying the memory an update supersedes, so Keep archives
    /// the old row (`SwiftNativeMemoryV2.acceptProposal`).
    public static let supersedesKey = "supersedes_memory_id"
    /// Metadata key carrying the fingerprint the superseded memory had WHEN THE
    /// PROPOSAL WAS STAGED. Acceptance refuses to demote a row that has changed
    /// since — the person reviewed a replacement for the old wording, not for
    /// whatever that row says now.
    public static let supersedesHashKey = "supersedes_content_hash"
    /// Metadata key carrying the manager's reason, for the review card.
    public static let whyKey = "why_it_matters"
    /// Metadata `lane` value. NOT "moment" — `MemoryMoments.isMoment` keys on
    /// that word for the retired lane's rows.
    public static let lane = "fact"

    // MARK: parse

    /// Parse the decoded candidates; an empty array is valid abstention.
    public static func parse(_ array: [Any]) throws -> [MemoryManagerDecision] {
        // An empty list is abstention; a candidate that is not the declared
        // shape is a failed reply, held for retry, never a silent drop.
        let decisions = array.map { ($0 as? [String: Any]).flatMap(decision(from:)) }
        guard !decisions.contains(where: { $0 == nil }) else {
            throw FoundationModelsError.decodeFailed("a memory candidate did not match the declared shape")
        }
        return decisions.compactMap { $0 }
    }

    private static func decision(from object: [String: Any]) -> MemoryManagerDecision? {
        guard let rawStatement = object["statement"] as? String else {
            return nil
        }
        let normalizedStatement = rawStatement
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let statement = MemoryTextClip.sentenceClip(normalizedStatement, cap: statementCap)
        if normalizedStatement.count > statementCap {
            TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("M13"), "site": .string("MemoryV2+MemoryManager.swift:decision")]))
        }
        guard !statement.isEmpty else { return nil }
        guard let actionRaw = object["action"] as? String,
              let action = MemoryManagerAction(rawValue: actionRaw),
              let kindRaw = object["kind"] as? String, allowedKinds.contains(kindRaw) else { return nil }
        let updatesId = (object["updates_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = object["standing_evidence"] as? String
        guard let number = object["confidence"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let confidence = number.doubleValue
        guard confidence.isFinite, (0...1).contains(confidence) else { return nil }
        let grounding: MemoryManagerGrounding?
        if let value = object["grounding"] as? [String: Any],
           let sourceRaw = value["source"] as? String, let source = MemoryManagerGrounding.Source(rawValue: sourceRaw),
           let attributionRaw = value["attribution"] as? String,
           let attribution = MemoryManagerGrounding.Attribution(rawValue: attributionRaw),
           let evidence = value["evidence"] as? String,
           let eligible = value["eligible"] as? NSNumber, CFGetTypeID(eligible) == CFBooleanGetTypeID(),
           let standing = value["standing"] as? NSNumber, CFGetTypeID(standing) == CFBooleanGetTypeID() {
            grounding = .init(source: source, attribution: attribution, evidence: evidence,
                              eligible: eligible.boolValue, standing: standing.boolValue)
        } else {
            guard action == .skip else { return nil }
            grounding = nil
        }
        return MemoryManagerDecision(
            statement: statement,
            kind: kindRaw,
            whyItMatters: ((object["why_it_matters"] as? String) ?? "")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: confidence,
            action: action,
            updatesId: (updatesId?.isEmpty == false) ? updatesId : nil,
            correctionSubject: object["subject"] as? String,
            standingEvidence: evidence,
            due: due(from: object["due"]),
            grounding: grounding
        )
    }

    /// Decode only the writer's ISO-8601 field, never the statement's prose.
    /// A date-time without an offset is in the Mac's local time zone.
    private static func due(from value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let zoned: ISO8601DateFormatter.Options = .withInternetDateTime
        let local = zoned.subtracting(.withTimeZone)
        for options in [zoned, zoned.union(.withFractionalSeconds), local, local.union(.withFractionalSeconds)] {
            formatter.formatOptions = options
            if let date = formatter.date(from: raw) {
                return date > Date() ? date : nil
            }
        }
        return nil
    }

    /// The one kind vocabulary (`MemoryKindStamp.writerKinds`).
    static let allowedKinds = Set(MemoryKindStamp.writerKinds)

    public static func correctionRejectionReason(
        _ decision: MemoryManagerDecision, userMessage: String, isPeer: Bool, personName: String? = nil
    ) -> String? {
        guard !isPeer else { return "a peer cannot author a standing human correction" }
        guard let grounding = decision.grounding, grounding.standing,
              grounding.source == .incoming, grounding.attribution == .speaker,
              let evidence = decision.standingEvidence, evidence == grounding.evidence else {
            return "standing rule lacks the interpretation's direct human attribution and evidence"
        }
        if let refusal = statementRejectionReason(decision, userMessage: userMessage, assistantMessage: "") { return refusal }
        let unquoted = unquotedHumanMessage(userMessage)
        guard unquoted.contains(evidence) else { return "quoted instruction is not a standing rule" }
        func components(_ value: String) -> Set<String> {
            Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        guard let subject = decision.correctionSubject,
              subject.range(of: #"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$"#, options: .regularExpression) != nil,
              subject.count <= 80,
              personName.map({ components(subject).isDisjoint(with: components($0)) }) ?? true,
              !AdaptiveCandidateHygiene.assistantNames.contains(where: { !components(subject).isDisjoint(with: components($0)) }) else {
            return "correction subject must be neutral"
        }
        return nil
    }

    private static func unquotedHumanMessage(_ message: String) -> String {
        var text = message
        for pattern in [#"(?s)```.*?```"#, #"(?s)\".*?\""#, #"(?s)“.*?”"#,
                        #"(?s)`[^`]*`"#, #"(?s)‘.*?’"#,
                        #"(?s)(?<![\p{L}\p{N}])'[^']*'(?![\p{L}\p{N}])"#,
                        #"(?m)^\s*>.*$"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return text
    }

    // MARK: the gate

    /// Why this statement must NOT be staged — nil when it may.
    ///
    /// The interpretation owns semantic eligibility in every language. This
    /// gate checks bounded shape and exact attributed evidence in its source.
    public static func statementRejectionReason(
        _ decision: MemoryManagerDecision,
        userMessage: String,
        assistantMessage: String
    ) -> String? {
        let text = decision.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (statementFloor...statementCap).contains(text.count), !text.contains("\n") else {
            return "memory sentence is outside its shape bound"
        }
        guard let grounding = decision.grounding, grounding.eligible,
              !grounding.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "no eligible attributed grounding from the interpretation"
        }
        switch grounding.source {
        case .incoming:
            guard grounding.attribution == .speaker, userMessage.contains(grounding.evidence) else {
                return "evidence is not attributed to the incoming speaker's exact words"
            }
        case .reply:
            guard grounding.attribution == .agent, assistantMessage.contains(grounding.evidence) else {
                return "evidence is not attributed to the agent's exact reply"
            }
        }
        return nil
    }

    // MARK: the update contract

    /// Updates replace one row shown to the model; an unseen target stays unresolved for repair without retargeting or becoming an add.
    static func resolvingTargets(_ interpretation: AfterTurnInterpretation,
                                 request: MemoryManagerRequest) -> AfterTurnInterpretation {
        let decisions = interpretation.memories.map { decision in
            guard decision.action == .update else { return decision }
            let kept = request.existing.first { $0.id == decision.updatesId }
            let pending = request.pendingTargets.first { $0.id == decision.updatesId }
            let target = kept ?? pending
            return MemoryManagerDecision(
                statement: decision.statement, kind: decision.kind,
                whyItMatters: decision.whyItMatters, confidence: decision.confidence,
                action: .update, updatesId: decision.updatesId,
                correctionSubject: decision.correctionSubject, standingEvidence: decision.standingEvidence,
                due: decision.due,
                reviewedTarget: target.map { .init(id: $0.id, fingerprint: contentFingerprint($0.content),
                                                   pending: kept == nil) }, grounding: decision.grounding)
        }
        return AfterTurnInterpretation(memories: decisions, affect: interpretation.affect,
            caring: interpretation.caring, cares: interpretation.cares, appAuthored: interpretation.appAuthored,
            model: interpretation.model, surface: interpretation.surface)
    }

    /// The fingerprint an update carries for its target. Same normalization and
    /// digest the store uses for proposal content, so one definition answers
    /// "is this still the row that was reviewed?".
    public static func contentFingerprint(_ text: String) -> String {
        MemoryStorage.contentHash(text)
    }

    /// Metadata stamped on one staged statement.
    public static func metadata(
        for decision: MemoryManagerDecision,
        sessionId: String,
        surface: String,
        observedAt: Date? = nil
    ) -> [String: JSONValue] {
        var meta: [String: JSONValue] = [
            "kind": .string(decision.kind),
            "lane": .string(lane),
            "session_id": .string(sessionId),
            "surface": .string(surface),
            "action": .string(decision.action.rawValue),
            "requires_approval": .bool(true),
        ]
        if !decision.whyItMatters.isEmpty {
            meta[whyKey] = .string(decision.whyItMatters)
        }
        let now = Date()
        if let due = decision.due, due > now {
            meta[MemoryDueDateStamp.dueAtKey] = .string(MemoryDueDateStamp.iso8601(due))
            meta[MemoryDueDateStamp.dueLabelKey] = .string(MemoryDueDateStamp.label(for: due, at: now))
            meta[MemoryDueDateStamp.dueSourceKey] = .string("memory_manager")
        }
        if decision.kind == "correction", let subject = decision.correctionSubject {
            meta["correction_subject"] = .string(subject)
            meta["lesson"] = .string(MemoryRecoveryReadout.lesson(metadata: .object(meta), text: decision.statement))
            meta["correction"] = .bool(true)
            meta["standing_evidence"] = decision.standingEvidence.map(JSONValue.string) ?? .null
            if let observedAt {
                meta["observed_at"] = .string(NativeTimestampFormat.fractionalZulu(observedAt))
            }
        }
        // The durable judgment's fingerprint wins, never today's recalled words.
        if decision.action == .update, let target = decision.reviewedTarget, !target.pending,
           target.id == decision.updatesId, !target.id.isEmpty {
            meta[supersedesKey] = .string(target.id)
            meta[supersedesHashKey] = .string(target.fingerprint)
        }
        return meta
    }
}
