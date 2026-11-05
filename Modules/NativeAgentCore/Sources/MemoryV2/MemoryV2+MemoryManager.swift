// The model judges grounded add, update and skip decisions; native gates check shape and provenance rather than language patterns. Lived moments become care
// movements in the same call.

import Foundation
import NativeAgentShared
import CoreFoundation
import NativeAgentCore
import PersistenceCore
import CognitiveSubstrate
import TurnTrace
import Desk

// Blueprint: | `MemoryV2+MemoryManager.swift` | `MemoryManagerLane`, `MemoryManagerPromise`: grounded decisions, reviewed targets and promises |

// MARK: - What the manager returns

public enum MemoryManagerAction: String, Codable, Sendable, Equatable {
    case add
    case update
    case skip
}

/// The exact target the judgment reviewed, retained in its durable meaning.
public struct MemoryManagerReviewedTarget: Codable, Sendable, Equatable {
    public let id: String
    public let fingerprint: String
    public let pending: Bool
}

/// Semantic eligibility belongs to the existing interpretation call. Native validation checks attribution and exact evidence, never English word overlap.
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
    public let statement: String
    /// Carry the model's free-text classification into proposal kind.
    public let kind: String
    /// Retain the long-term reason for review.
    public let whyItMatters: String
    /// 0…1. Below `MemoryManagerLane.confidenceFloor` nothing stages.
    public let confidence: Double
    public let action: MemoryManagerAction
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

public struct MemoryManagerRequest: Sendable, Equatable {
    public let userMessage: String
    public let assistantMessage: String
    public let existing: [MemoryManagerExistingMemory]
    /// Pending rows shown in the prompt and used to resolve update targets before meaning is written. Never reconstructed on replay.
    public let pendingTargets: [MemoryManagerExistingMemory]
    /// The nearest claims the agent was told to forget or the person rejected.
    public let forgotten: [String]
    /// Use the person's configured name so retained facts identify their subject.
    public let personName: String?
    public let standingAgent: Bool
    public let appAuthored: Bool
    /// Preserve tool-use origin from AfterTurnOrigin.took.
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

/// What the agent said it would do later in this reply, not a request made to the agent.
public struct MemoryManagerPromise: Codable, Sendable, Equatable {
    public let words: String
    public let when: String
    public let source: String

    /// Absence and [] are valid. A malformed present section is never abstention.
    public static func parse(_ value: Any?, reply: String) throws -> [Self] {
        guard let value else { return [] }
        guard let rows = value as? [[String: Any]] else {
            throw FoundationModelsError.decodeFailed("promises must be an array of objects")
        }
        var promises: [Self] = []
        for row in rows {
            guard let words = row["words"] as? String,
                  !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let when = row["when"] as? String,
                  let source = row["source"] as? String,
                  !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  reply.contains(source) else {
                throw FoundationModelsError.decodeFailed("promise \(promises.count) requires nonempty words, when and exact reply source")
            }
            switch when {
            case "next_turn", "own_turn", "when_user_messages": break
            default:
                if when.hasPrefix("after_card "), case .afterCard(let id)? = MyQueue.When(when),
                   !id.contains(where: \.isWhitespace), reply.contains(id) { break }
                if when.hasPrefix("at "), case .at? = MyQueue.When(when) { break }
                throw FoundationModelsError.decodeFailed("promise \(promises.count) has invalid when: \(when)")
            }
            promises.append(Self(words: words.trimmingCharacters(in: .whitespacesAndNewlines),
                                 when: when, source: source))
        }
        return promises
    }
}

public struct AfterTurnInterpretation: Codable, Sendable {
    public let memories: [MemoryManagerDecision]
    public let affect: CognitiveSubstrate.AffectAppraisal
    public let caring: CaringAppraisalVerdict
    public let cares: [CognitiveCareJudgment]
    public let promises: [MemoryManagerPromise]
    /// The incoming words were the app's, so only the agent's side of the exchange counts.
    public let appAuthored: Bool
    public let model: String?
    public let surface: String

    /// The record's key for the model that judged: the judgment's own surface and model, as the call reported them. A label's scope is this key.
    public var judgingKey: String { Self.judgingKey(surface: surface, model: model) }
    public static func judgingKey(surface: String, model: String?) -> String {
        AfterTurnMemorySurprise.fingerprint(["memory-judgment-v2", surface, model ?? ""])
    }

    public init(memories: [MemoryManagerDecision],
                affect: CognitiveSubstrate.AffectAppraisal, caring: CaringAppraisalVerdict,
                cares: [CognitiveCareJudgment] = [], promises: [MemoryManagerPromise] = [], appAuthored: Bool = false,
                model: String?, surface: String) {
        self.memories = memories
        self.affect = affect
        self.caring = caring
        self.cares = cares
        self.promises = promises
        self.appAuthored = appAuthored
        self.model = model
        self.surface = surface
    }

    private enum CodingKeys: String, CodingKey {
        case memories, affect, caring, cares, promises, appAuthored, model, surface
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        memories = try values.decode([MemoryManagerDecision].self, forKey: .memories)
        affect = try values.decode(CognitiveSubstrate.AffectAppraisal.self, forKey: .affect)
        caring = try values.decode(CaringAppraisalVerdict.self, forKey: .caring)
        cares = try values.decode([CognitiveCareJudgment].self, forKey: .cares)
        promises = try values.decode([MemoryManagerPromise].self, forKey: .promises)
        appAuthored = try values.decode(Bool.self, forKey: .appAuthored)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        surface = try values.decode(String.self, forKey: .surface)
    }
}

/// Use the configured Memory model for judgment; rule-based invention cannot establish a memory.
public struct AfterTurnMemoryFailure: Error, Codable, Sendable, Hashable {
    public enum Reason: String, Codable, Sendable, Hashable {
        case deadline, cancelled, provider, invalidJSON, missingSections
        case invalidCaring, invalidAffect, invalidMemories, invalidCares
        case authExpired, codexCLISessionExpired, rateLimited, overloaded, contextTooLong
        case network, outputLimit, refused, requestRejected, invalidProviderResponse, routingUnavailable, modelUnavailable, trustUnavailable

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

/// Each batched exchange retains the request and context it would have received alone.
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

/// No incoming message returns nil; failures throw bounded recovery evidence. An empty memory array is a valid abstention.
public protocol MemoryManaging: Sendable {
    /// Read the judging model's key without changing the request; unkeyed predictions earn no standing.
    func predictionModelKey() async -> String?
    /// The judging route as it stands now: surface, provider account and model; nil when the route cannot be read.
    func judgmentRouteKey() async -> String?
    func interpret(_ request: MemoryManagerRequest, context: AfterTurnContext?,
                   factsEnabled: Bool, call: LLMCall) async throws -> AfterTurnInterpretation?
    /// Several owed exchanges in one call, one section each, in input order. A nil entry is a section the reply lacked or got wrong: that exchange stays owed.
    /// Throws when the call itself fails.
    func interpretBatch(_ inputs: [MemoryBatchInput]) async throws -> [AfterTurnInterpretation?]
    func relevantRecallIDs(query: String, candidates: [MemoryManagerExistingMemory], generation: String?, topK: Int?) async
        -> Result<Set<String>, AfterTurnMemoryFailure>
}

// MARK: - Lane constants, prompt, parse, gate

public enum MemoryManagerLane {
    /// Source provenance identifies the judgment pass.
    public static let sourcePrefix = "memory-manager"
    /// Nothing below this stages, whatever the action says.
    public static let confidenceFloor = 0.8
    /// Four exchanges keep a batch near one turn's prompt scale while sharing its rules.
    public static let batchLimit = 4
    public static let recallTopK = 8
    public static let pendingCap = 24
    /// Bound memories to sentences rather than paragraphs.
    public static let statementCap = 200
    public static let statementFloor = 12
    /// Use the same embedding to select forgotten claims and known memories for judgment.
    public static let forgottenTopK = 8
    /// Carry the superseded target so acceptance can archive the exact old row.
    public static let supersedesKey = "supersedes_memory_id"
    /// Retain the target's staging-time fingerprint so acceptance cannot demote wording the user never reviewed.
    public static let supersedesHashKey = "supersedes_content_hash"
    public static let whyKey = "why_it_matters"
    /// Keep this classification distinct from moment rows because MemoryMoments keys on that value.
    public static let lane = "fact"

    // MARK: parse

    public static func parse(_ array: [Any]) throws -> [MemoryManagerDecision] {
        for (index, candidate) in array.enumerated() {
            if let object = candidate as? [String: Any], let raw = object["statement"] as? String,
               raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).count > statementCap {
                throw FoundationModelsError.decodeFailed("memory candidate \(index) exceeds the \(statementCap)-character statement bound")
            }
        }
        // An empty list is abstention; a candidate that is not the declared shape is a failed reply, held for retry, never a silent drop.
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
        guard !normalizedStatement.isEmpty, normalizedStatement.count <= statementCap else { return nil }
        let statement = normalizedStatement
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

    /// Decode only the writer's ISO-8601 field, never the statement's prose. A date-time without an offset is in the Mac's local time zone.
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

    /// Interpretation owns multilingual semantics; native validation checks only bounded shape and exact attributed evidence.
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
            caring: interpretation.caring, cares: interpretation.cares, promises: interpretation.promises,
            appAuthored: interpretation.appAuthored,
            model: interpretation.model, surface: interpretation.surface)
    }

    /// Share the store's normalized fingerprint so review and acceptance identify the same target.
    public static func contentFingerprint(_ text: String) -> String {
        MemoryStorage.contentHash(text)
    }

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
