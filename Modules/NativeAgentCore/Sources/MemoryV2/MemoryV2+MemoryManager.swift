// MemoryV2+MemoryManager.swift
// THE MEMORY MANAGER (2026-09-11)
//
// User, 2026-09-11: the proposals waiting on the Memories page are junk — "user
// wants an ant", "user values unnecessary user-side failure points" (a bot's
// own brief), verbatim quotes used as headlines. Every fix before this one was
// one more rejection regex on top of a regex extractor.
//
// This replaces the extractor AND the regex gate with the shape Mem0 / LangMem
// / ChatGPT memory use: one pass, on the agent's REAL model, that sees the
// exchange AND what is already remembered, and decides. It returns actions, not
// strings: add / update / skip. The gate below is deliberately small — five
// checks on the SHAPE of what came back, not a catalogue of phrasings.
//
// The moments lane (MemoryV2+Moments.swift) is untouched and runs beside this.

import Foundation
import NativeAgentCore
import PersistenceCore
import CognitiveSubstrate

// MARK: - What the manager returns

public enum MemoryManagerAction: String, Sendable, Equatable {
    /// A new memory about the person.
    case add
    /// This changes a memory that already exists; `updatesId` names it.
    case update
    /// Nothing here worth keeping. The common answer.
    case skip
}

public struct MemoryManagerDecision: Sendable, Equatable {
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

    public init(
        statement: String,
        kind: String,
        whyItMatters: String,
        confidence: Double,
        action: MemoryManagerAction,
        updatesId: String? = nil,
        correctionSubject: String? = nil,
        standingEvidence: String? = nil
    ) {
        self.statement = statement
        self.kind = kind
        self.whyItMatters = whyItMatters
        self.confidence = confidence
        self.action = action
        self.updatesId = updatesId
        self.correctionSubject = correctionSubject
        self.standingEvidence = standingEvidence
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
    /// Statements already waiting for the person on the Memories page.
    public let pending: [String]
    /// The person's configured name, so a memory is about "User", never "the person".
    public let personName: String?
    public let standingAgent: Bool

    public init(
        userMessage: String,
        assistantMessage: String,
        existing: [MemoryManagerExistingMemory] = [],
        pending: [String] = [],
        personName: String? = nil,
        standingAgent: Bool = false
    ) {
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
        self.existing = existing
        self.pending = pending
        self.personName = personName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? personName : nil
        self.standingAgent = standingAgent
    }
}

public struct AfterTurnInterpretation: Sendable {
    public let memories: [MemoryManagerDecision]
    public let moment: MomentCandidate?
    public let affect: CognitiveSubstrate.AffectAppraisal
    public let caring: CaringAppraisalVerdict
    public let model: String?
    public let surface: String

    public init(memories: [MemoryManagerDecision], moment: MomentCandidate?,
                affect: CognitiveSubstrate.AffectAppraisal, caring: CaringAppraisalVerdict,
                model: String?, surface: String) {
        self.memories = memories
        self.moment = moment
        self.affect = affect
        self.caring = caring
        self.model = model
        self.surface = surface
    }
}

/// The seam. The production conformer (`MindMemoryManager`) asks the model on
/// the Providers "Memory" row, exactly as `MindMomentExtractor` does. There is
/// deliberately NO rule-based conformer: a memory invented by a pattern is what
/// this file exists to delete.
///
public struct AfterTurnMemoryFailure: Error, Codable, Sendable, Hashable {
    public enum Reason: String, Codable, Sendable, Hashable {
        case deadline, cancelled, provider, invalidJSON, missingSections
        case invalidCaring, invalidAffect, invalidMemories, invalidMoment
        case authExpired, codexCLISessionExpired, rateLimited, overloaded, contextTooLong
        case network, refused, invalidProviderResponse, routingUnavailable, modelUnavailable
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
        case .invalidMoment: return .moment
        default: return .provider
        }
    }
}

public enum AfterTurnInterpretationFailure: String, Error, Sendable {
    case provider, authentication, deadline, cancellation
    case envelope, caring, affect, memories, moment
}

/// No incoming message returns nil; failures throw bounded recovery evidence.
/// An empty memory array is a valid abstention.
public protocol MemoryManaging: Sendable {
    func interpret(_ request: MemoryManagerRequest, context: AfterTurnContext?,
                   factsEnabled: Bool, momentsEnabled: Bool) async throws -> AfterTurnInterpretation?
    func relevantRecallIDs(query: String, candidates: [MemoryManagerExistingMemory], generation: String?, topK: Int?) async
        -> Result<Set<String>, AfterTurnMemoryFailure>
}

// MARK: - Lane constants, prompt, parse, gate

public enum MemoryManagerLane {
    /// Distinct from both `adaptive-promoter:` (the deleted regex lane) and
    /// `moment-promoter:` so a row's provenance names the pass that made it.
    public static let sourcePrefix = "memory-manager"
    /// These writers emit free-form content, so model-selected kinds never
    /// authorize promotion. Human Keep remains the existing admission gate.
    public static func requiresHumanApproval(source: String?, metadata: JSONValue?) -> Bool {
        if source?.hasPrefix("\(sourcePrefix):") == true
            || source?.hasPrefix("standing-correction:") == true { return true }
        // Staging may merge into an older pending row and retain its source.
        // This marker is stamped by this writer, never decoded from the model.
        if case .object(let meta) = metadata, meta["requires_approval"] == .bool(true) { return true }
        return false
    }
    /// Nothing below this stages, whatever the action says.
    public static let confidenceFloor = 0.8
    /// How many existing memories the manager is shown.
    public static let recallTopK = 8
    /// How many pending proposals the manager is shown.
    public static let pendingCap = 24
    /// A memory is a sentence, not a paragraph.
    public static let statementCap = 200
    public static let statementFloor = 12
    /// Cosine similarity at or above which a statement is "already in there".
    public static let duplicateSimilarity = 0.90
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
    /// that word and the two lanes must stay separable on the Memories page.
    public static let lane = "fact"

    // MARK: parse

    /// Decode the model's reply. Accepts an array (the contract), a bare object
    /// (small models do it), or `[]`. Throws only when the reply is not JSON at
    /// all — an empty array is a valid answer, not a failure.
    public static func parse(_ raw: String) throws -> [MemoryManagerDecision] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slice = MemoryMoments.jsonSlice(from: trimmed) else {
            throw FoundationModelsError.decodeFailed("no JSON in memory-manager reply")
        }
        guard let data = slice.data(using: .utf8) else {
            throw FoundationModelsError.decodeFailed("non-utf8 memory-manager reply")
        }
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FoundationModelsError.decodeFailed(String(describing: error))
        }
        let objects: [[String: Any]]
        if let array = decoded as? [Any] {
            objects = array.compactMap { $0 as? [String: Any] }
        } else if let single = decoded as? [String: Any] {
            objects = [single]
        } else {
            return []
        }
        return objects.compactMap(decision(from:))
    }

    private static func decision(from object: [String: Any]) -> MemoryManagerDecision? {
        guard let rawStatement = (object["statement"] ?? object["memory"]) as? String else {
            return nil
        }
        let statement = MemoryTextClip.sentenceClip(
            rawStatement
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            cap: statementCap
        )
        guard !statement.isEmpty else { return nil }
        let action = MemoryManagerAction(
            rawValue: ((object["action"] as? String) ?? "add")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        ) ?? .skip
        let kindRaw = ((object["kind"] as? String) ?? "fact")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let updatesId = (object["updates_id"] as? String ?? object["updatesId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = object["standing_evidence"] as? String
        return MemoryManagerDecision(
            statement: statement,
            kind: allowedKinds.contains(kindRaw) ? kindRaw : "fact",
            whyItMatters: ((object["why_it_matters"] as? String)
                ?? (object["whyItMatters"] as? String) ?? "")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: MemoryMoments.clamp(MemoryMoments.number(object["confidence"]) ?? 0, low: 0, high: 1),
            action: action,
            updatesId: (updatesId?.isEmpty == false) ? updatesId : nil,
            correctionSubject: object["subject"] as? String,
            standingEvidence: evidence
        )
    }

    static let allowedKinds: Set<String> = [
        "identity", "location", "employment", "schedule", "preference",
        "relationship", "goal", "skill", "fact", "correction",
    ]

    public static func correctionRejectionReason(
        _ decision: MemoryManagerDecision, userMessage: String, isPeer: Bool, personName: String? = nil
    ) -> String? {
        guard !isPeer else { return "a peer cannot author a standing human correction" }
        guard let evidence = decision.standingEvidence, !evidence.isEmpty,
              userMessage.contains(evidence) else { return "standing rule lacks verbatim human evidence" }
        let lower = evidence.lowercased().replacingOccurrences(of: "’", with: "'")
        let fullMessage = userMessage.lowercased().replacingOccurrences(of: "’", with: "'")
        guard lower.range(of: #"\b(?:never|always|stop doing)\b"#, options: .regularExpression) != nil else {
            return "not an explicit standing rule"
        }
        guard fullMessage.range(of: #"\b(?:this time|for now|today only|only today|just for today|just this|this turn|this task|for this build|this session|this run)\b"#,
                          options: .regularExpression) == nil else { return "one-off direction is not a standing rule" }
        let unquoted = unquotedHumanMessage(userMessage)
        guard unquoted.contains(evidence) else { return "quoted instruction is not a standing rule" }
        guard let subject = decision.correctionSubject,
              subject.range(of: #"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$"#, options: .regularExpression) != nil,
              subject.count <= 80,
              personName.map({ !subject.contains($0.lowercased()) }) ?? true,
              !AdaptiveCandidateHygiene.assistantNames.contains(where: { subject.contains($0.lowercased()) }) else {
            return "correction subject must be neutral"
        }
        let text = decision.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (statementFloor...statementCap).contains(text.count), !text.contains("\n"),
              !AdaptiveCandidateHygiene.contentStems(text.lowercased())
                .intersection(AdaptiveCandidateHygiene.contentStems(lower)).isEmpty else {
            return "correction is not grounded in its standing evidence"
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
    /// FIVE checks on the SHAPE of the answer, and that is the whole list. It is
    /// the second half of the injection defense (the prompt is the first) and it
    /// is deliberately not a catalogue of phrasings: the model decides what is
    /// worth keeping, this decides that what came back is a sentence about the
    /// person and not a quote, an errand, or a line about the agent.
    public static func statementRejectionReason(
        _ statement: String,
        userMessage: String,
        assistantMessage: String
    ) -> String? {
        let text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        // 1. A sentence, bounded.
        guard text.count >= statementFloor else { return "too short to be a memory" }
        guard text.count <= statementCap else { return "longer than a memory sentence" }

        let lowered = text.lowercased()
        // 2. Third person about the person — never the person's own voice, never
        //    the agent's, never "user ..." (User's complaint, 2026-09-11).
        if lowered.hasPrefix("user ") || lowered.hasPrefix("user's ")
            || lowered.hasPrefix("the user ") || lowered.hasPrefix("the user's ") {
            return "\"user ...\" is not how a person is described"
        }
        if text.range(
            of: #"(?:^|[\s("'])(?:I|I'm|I’m|I've|I’ve|I'd|I’d|I'll|I’ll|me|my|mine|myself|we|our|us)(?=$|[\s.,;:!?)"'])"#,
            options: .regularExpression
        ) != nil {
            return "first person is quoted speech, not a memory"
        }
        if lowered.range(of: #"\byou(?:r|rs|'re|’re)?\b"#, options: .regularExpression) != nil {
            return "addressed to the agent, not about the person"
        }
        for name in AdaptiveCandidateHygiene.assistantNames where !name.isEmpty {
            if lowered.range(
                of: #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"(?:'s|’s)?\b"#,
                options: .regularExpression
            ) != nil {
                return "about the agent, not the person"
            }
        }
        // 3. Not a quote, and not a span lifted out of the exchange.
        if text.hasPrefix("\"") || text.hasPrefix("“") || text.hasPrefix("'") {
            return "a quote is not a memory"
        }
        let folded = MemoryMoments.wordFold(text)
        if folded.count >= 16,
           MemoryMoments.wordFold(userMessage).contains(folded)
            || MemoryMoments.wordFold(assistantMessage).contains(folded) {
            return "copied out of the exchange rather than written about the person"
        }
        // 4. Not an errand. An imperative opener is something the agent was
        //    asked to do, which is the bot-brief shape User saw staged.
        if lowered.range(
            of: #"^(?:do|don't|dont|make|use|write|add|remove|delete|check|read|run|build|fix|keep|remember|note|ignore|send|open|close|set|put|give|tell|ask|report|summarize|summarise|draft|review)\b"#,
            options: .regularExpression
        ) != nil {
            return "an instruction to the agent is not a memory"
        }
        // 5. Grounded in the exchange. A statement whose content words are not
        //    in the turn was invented, whoever invented it.
        let words = AdaptiveCandidateHygiene.contentStems(lowered)
        guard !words.isEmpty else { return "no content words" }
        let turn = AdaptiveCandidateHygiene.contentStems(
            (userMessage + " " + assistantMessage).lowercased()
        )
        if words.intersection(turn).count < min(2, words.count) {
            return "not grounded in the exchange it came from"
        }
        return nil
    }

    // MARK: the update contract

    /// Hold an `update` to the promise it makes: it replaces ONE named row that
    /// the model was actually shown. An id the model invented, remembered from an
    /// earlier turn, or simply omitted would otherwise demote an unrelated memory
    /// at Keep time (2026-09-11 audit, finding 1).
    ///
    /// A decision that fails the check is NOT thrown away — the statement may
    /// still be new, so it degrades to `add` and faces the ordinary gates; the
    /// duplicate screen turns it into a skip when it repeats what is already kept.
    public static func reconciled(
        _ decision: MemoryManagerDecision,
        existing: [MemoryManagerExistingMemory]
    ) -> (decision: MemoryManagerDecision, target: MemoryManagerExistingMemory?) {
        guard decision.action == .update else { return (decision, nil) }
        if let id = decision.updatesId,
           let target = existing.first(where: { $0.id == id }) {
            return (decision, target)
        }
        return (MemoryManagerDecision(
            statement: decision.statement,
            kind: decision.kind,
            whyItMatters: decision.whyItMatters,
            confidence: decision.confidence,
            action: .add,
            updatesId: nil,
            correctionSubject: decision.correctionSubject,
            standingEvidence: decision.standingEvidence
        ), nil)
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
        updateTarget: MemoryManagerExistingMemory? = nil,
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
        if decision.kind == "correction", let subject = decision.correctionSubject {
            meta["correction_subject"] = .string(subject)
            meta["correction"] = .bool(true)
            meta["standing_evidence"] = decision.standingEvidence.map(JSONValue.string) ?? .null
            if let observedAt {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                meta["observed_at"] = .string(formatter.string(from: observedAt))
            }
        }
        // Only a VALIDATED target rides along: no target, no supersession claim.
        if decision.action == .update, let target = updateTarget,
           target.id == decision.updatesId, !target.id.isEmpty {
            meta[supersedesKey] = .string(target.id)
            meta[supersedesHashKey] = .string(contentFingerprint(target.content))
        }
        return meta
    }
}
