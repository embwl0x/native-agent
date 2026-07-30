import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore

/// Closed evidence vocabulary used by Outcome Tissue V2. The distinctions are
/// intentional: an absent receipt is never silently converted to failure or
/// zero use.
public enum OutcomeEvidenceState: String, Codable, Sendable, Equatable, CaseIterable {
    case observed
    case verified
    case unverified
    case unknown
    case censored
    case notApplicable = "not_applicable"
}

/// Optional immutable intervention binding. Production leaves this nil. A
/// controlled harness may bind one before entering the real reducer/turn code;
/// attaching an assignment after observing the outcome is not supported.
public enum OutcomeInterventionContext {
    @TaskLocal public static var assignment: CausalInterventionAssignment?
}

public struct ResponseOutcomeToolReference: Codable, Sendable, Equatable {
    public let callID: String
    public let tool: String
    public let resultClass: String

    public init(callID: String, tool: String, resultClass: String) {
        self.callID = callID
        self.tool = tool
        self.resultClass = resultClass
    }
}

public struct ResponseOutcomeMotorReference: Codable, Sendable, Equatable {
    /// Universal opaque correlation identity. Domain read models expose the
    /// same SHA-256 identity so late settlement can be checked without
    /// persisting action payloads.
    public let actionID: String
    /// Bounded canonical owner locator needed only to ask the named owner for
    /// its read model. It is an identifier, never an action argument or grant.
    /// Older anchors decode with nil and remain honestly unresolvable.
    public let ownerActionID: String?
    public let domain: String
    public let verification: OutcomeEvidenceState

    public init(
        actionID: String,
        ownerActionID: String? = nil,
        domain: String,
        verification: OutcomeEvidenceState
    ) {
        self.actionID = actionID
        self.ownerActionID = ownerActionID
        self.domain = domain
        self.verification = verification
    }
}

/// Payload-free observation encoded on the same canonical assistant row as the
/// response. Only facts already known before the transcript lock are included.
/// Later reactions, delivery, and motor settlement remain append-only receipts.
public struct ResponseOutcomeObservationV2: Codable, Sendable, Equatable {
    public static let schema = "response.outcome-observation.v2"

    public let schema: String
    public let turnID: String
    public let messageID: String
    public let sessionID: String
    public let surface: String
    public let observedAt: String
    public let responsePersistence: String
    public let contextGenerationID: Int64?
    public let contextSelectionReceiptID: String?
    public let providerModel: String?
    public let reasoningEffort: String?
    public let turnElapsedMs: Int?
    public let tools: [ResponseOutcomeToolReference]
    public let motorActions: [ResponseOutcomeMotorReference]
    public let dimensionStates: [String: OutcomeEvidenceState]
    public let interventionAssignment: CausalInterventionAssignment?

    public init(
        turnID: String,
        messageID: String,
        sessionID: String,
        surface: String,
        observedAt: String,
        responsePersistence: String,
        contextGenerationID: Int64?,
        contextSelectionReceiptID: String?,
        providerModel: String?,
        reasoningEffort: String?,
        turnElapsedMs: Int?,
        tools: [ResponseOutcomeToolReference],
        motorActions: [ResponseOutcomeMotorReference],
        dimensionStates: [String: OutcomeEvidenceState],
        interventionAssignment: CausalInterventionAssignment?
    ) {
        self.schema = Self.schema
        self.turnID = turnID
        self.messageID = messageID
        self.sessionID = sessionID
        self.surface = surface
        self.observedAt = observedAt
        self.responsePersistence = responsePersistence
        self.contextGenerationID = contextGenerationID
        self.contextSelectionReceiptID = contextSelectionReceiptID
        self.providerModel = providerModel
        self.reasoningEffort = reasoningEffort
        self.turnElapsedMs = turnElapsedMs
        self.tools = tools
        self.motorActions = motorActions
        self.dimensionStates = dimensionStates
        self.interventionAssignment = interventionAssignment
    }

    public var jsonValue: JSONValue {
        (try? JSONValue.parse(JSONEncoder().encode(self))) ?? .null
    }

    public init?(jsonValue: JSONValue) {
        guard let data = try? jsonValue.serializedData(pretty: false),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.schema == Self.schema,
              Self.closedToken(decoded.turnID, maximum: 128) != nil,
              Self.closedToken(decoded.messageID, maximum: 128) != nil,
              Self.closedToken(decoded.sessionID, maximum: 128) != nil,
              Self.closedToken(decoded.surface, maximum: 128) != nil,
              Self.parseDate(decoded.observedAt) != nil,
              ["persisted", "partial", "cancelled", "failed"].contains(decoded.responsePersistence),
              decoded.tools.count <= 64,
              decoded.motorActions.count <= 64,
              decoded.turnElapsedMs.map({ (0...(24 * 60 * 60 * 1_000)).contains($0) }) ?? true,
              decoded.contextGenerationID.map({ $0 >= 0 }) ?? true,
              decoded.dimensionStates.keys.allSatisfy({ Self.closedToken($0, maximum: 64) != nil }),
              decoded.tools.allSatisfy(Self.validTool),
              decoded.motorActions.allSatisfy(Self.validMotor),
              Self.validAssignment(decoded.interventionAssignment)
        else { return nil }
        self = decoded
    }

    public static func make(
        turnID rawTurnID: String?,
        messageID rawMessageID: String,
        sessionID rawSessionID: String,
        surface rawSurface: String,
        observedAt: Date,
        responsePersistence: String,
        result: TurnEngineResult? = nil,
        context: TurnContext? = nil,
        interventionAssignment explicitInterventionAssignment: CausalInterventionAssignment? = nil
    ) -> Self? {
        guard let turnID = OutcomeTraceIdentity.normalized(rawTurnID),
              let messageID = closedToken(rawMessageID, maximum: 128),
              let sessionID = closedToken(rawSessionID, maximum: 128),
              let surface = closedToken(rawSurface, maximum: 128),
              ["persisted", "partial", "cancelled", "failed"].contains(responsePersistence)
        else { return nil }

        let observation = context.map(TurnEngineResult.TerminalObservation.init(context:))
            ?? result?.terminalObservation
        let packet = context?.fluidContextTurn?.packet
        let toolReferences = Array((result?.toolDispatches ?? []).prefix(64).enumerated()).compactMap {
            index, dispatch -> ResponseOutcomeToolReference? in
            guard let tool = closedToken(dispatch.name, maximum: 128) else { return nil }
            let sourceID = dispatch.id ?? "sequence:\(index)"
            let opaqueID = CausalTransitionEvidence.opaqueIdentity("\(turnID)|tool|\(sourceID)")
            return ResponseOutcomeToolReference(
                callID: opaqueID,
                tool: tool,
                resultClass: ChatToolOutcome.exactResultClass(dispatch.result).rawValue
            )
        }
        var seenMotorReferences = Set<String>()
        let motorReferences = Array((result?.toolDispatches ?? []).prefix(64)).compactMap {
            dispatch -> ResponseOutcomeMotorReference? in
            guard let reference = motorReference(dispatch: dispatch) else { return nil }
            let key = "\(reference.domain)|\(reference.actionID)"
            guard seenMotorReferences.insert(key).inserted else { return nil }
            return reference
        }
        var states: [String: OutcomeEvidenceState] = [
            "responsePersistence": .observed,
            "context": packet == nil ? .censored : .observed,
            // The response result proves the model string, not the exact
            // provider transport. The historical join promotes this only
            // after it finds the canonical llm.call receipt for the turn.
            "provider": result == nil ? .censored : .unknown,
            "tools": result == nil
                ? .censored
                : (toolReferences.isEmpty
                    ? .notApplicable
                    : (toolReferences.allSatisfy { $0.resultClass != "unknown" }
                        ? .observed : .unverified)),
            "motor": motorReferences.isEmpty
                ? (toolReferences.isEmpty ? .notApplicable : .unknown)
                : aggregateMotorEvidence(motorReferences.map(\.verification)),
            "reaction": .unknown,
        ]
        if responsePersistence != "persisted" { states["responsePersistence"] = .unverified }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Self(
            turnID: turnID,
            messageID: messageID,
            sessionID: sessionID,
            surface: surface,
            observedAt: formatter.string(from: observedAt),
            responsePersistence: responsePersistence,
            contextGenerationID: packet?.generationID,
            contextSelectionReceiptID: packet.flatMap {
                closedToken($0.receipt.id, maximum: 128)
            },
            providerModel: result.flatMap { closedToken($0.modelUsed, maximum: 256) },
            reasoningEffort: observation.flatMap { closedToken($0.reasoningEffort, maximum: 64) },
            turnElapsedMs: result.map { min(24 * 60 * 60 * 1_000, max(0, $0.elapsedMs)) },
            tools: toolReferences,
            motorActions: motorReferences,
            dimensionStates: states,
            interventionAssignment: {
                // An explicit live assignment is authoritative for this
                // observation. If it is malformed, fail closed; never replace
                // it with an unrelated task-local laboratory assignment.
                if let explicitInterventionAssignment {
                    return validAssignment(explicitInterventionAssignment)
                        ? explicitInterventionAssignment
                        : nil
                }
                return validAssignment(OutcomeInterventionContext.assignment)
                    ? OutcomeInterventionContext.assignment
                    : nil
            }()
        )
    }

    private static func motorReference(
        dispatch: TurnEngineResult.ToolDispatchRecord
    ) -> ResponseOutcomeMotorReference? {
        guard case .object(let object) = dispatch.result,
              let binding = ToolCausalBoundary.motorReference(
                  tool: dispatch.name,
                  output: dispatch.result
              ) else { return nil }
        let verification: OutcomeEvidenceState = {
            if case .bool(true)? = object["procedure_verified"] { return .verified }
            if case .bool(false)? = object["procedure_verified"] { return .unverified }
            if case .bool(true)? = object["verifyPassed"] { return .verified }
            if case .bool(true)? = object["verified"] { return .verified }
            if case .bool(false)? = object["verifyPassed"] { return .unverified }
            if case .bool(false)? = object["verified"] { return .unverified }
            if case .string(let raw)? = object["verification"] {
                if raw == "verified" { return .verified } // legacy compatibility
                if let canonical = MotorVerificationState(rawValue: raw) {
                    return outcomeEvidence(for: canonical)
                }
            }
            // Browser's owner defines an observed successful WKWebView
            // navigation (`opened`) as satisfied verification. Preserve that
            // exact owner fact in the response anchor even if the process
            // exits before the detached motor trace reaches disk.
            if binding.domain == .browser, case .bool(let opened)? = object["opened"] {
                return opened ? .verified : .unverified
            }
            return .unknown
        }()
        return ResponseOutcomeMotorReference(
            actionID: binding.actionIdentity,
            ownerActionID: safeOwnerActionID(binding.ownerActionID),
            domain: binding.domain.rawValue,
            verification: verification
        )
    }

    private static func outcomeEvidence(
        for verification: MotorVerificationState
    ) -> OutcomeEvidenceState {
        switch verification {
        case .satisfied, .failed:
            // "Verified" describes evidence quality, not whether the action
            // itself succeeded. Phase/domain state retain outcome polarity.
            return .verified
        case .unverified:
            return .unverified
        case .unknown:
            return .unknown
        case .notStarted, .pending, .notRequired:
            return .observed
        }
    }

    fileprivate static func aggregateMotorEvidence(
        _ states: [OutcomeEvidenceState]
    ) -> OutcomeEvidenceState {
        guard !states.isEmpty else { return .notApplicable }
        if states.allSatisfy({ $0 == .verified }) { return .verified }
        if states.contains(.unknown) { return .unknown }
        if states.contains(.unverified) { return .unverified }
        if states.contains(.censored) { return .censored }
        return .observed
    }

    /// Raw owner locators are transcript metadata, so retain only the two
    /// identifier forms NativeAgent's participating owners mint: UUIDs and
    /// SHA-256 identities. Arbitrary action payload, paths, or model-supplied
    /// labels never enter the anchor; the universal opaque actionID remains
    /// sufficient for the durable motor-trace join.
    private static func safeOwnerActionID(_ raw: String) -> String? {
        if UUID(uuidString: raw) != nil { return raw }
        return isOpaqueSHA256(raw) ? raw : nil
    }

    private static func validTool(_ value: ResponseOutcomeToolReference) -> Bool {
        closedToken(value.callID, maximum: 128) != nil
            && closedToken(value.tool, maximum: 128) != nil
            && ["succeeded", "failed", "cancelled", "timeout", "unknown"].contains(value.resultClass)
    }

    private static func validMotor(_ value: ResponseOutcomeMotorReference) -> Bool {
        isOpaqueSHA256(value.actionID)
            && (value.ownerActionID.map { safeOwnerActionID($0) == $0 } ?? true)
            && closedToken(value.domain, maximum: 128) != nil
    }

    private static func isOpaqueSHA256(_ raw: String) -> Bool {
        raw.count == 64 && raw.unicodeScalars.allSatisfy(
            CharacterSet(charactersIn: "0123456789abcdef").contains
        )
    }

    private static func validAssignment(_ value: CausalInterventionAssignment?) -> Bool {
        guard let value else { return true }
        guard assignmentToken(value.assignmentID, maximum: 128),
              assignmentToken(value.intervention, maximum: 128),
              optionalAssignmentToken(value.experimentID, maximum: 128),
              optionalAssignmentToken(value.taskScenarioFamily, maximum: 128),
              optionalAssignmentToken(value.treatment, maximum: 64),
              optionalAssignmentToken(value.baseline, maximum: 64),
              optionalAssignmentToken(value.chosenAlternative, maximum: 64),
              validAssignmentTokens(value.eligibleAlternatives, maximumCount: 8, maximum: 64),
              validAssignmentTokens(value.confounderFlags, maximumCount: 16, maximum: 128),
              validAssignmentTokens(value.coverageFlags, maximumCount: 16, maximum: 128) else {
            return false
        }
        if let eligible = value.eligibleAlternatives {
            guard Set(eligible).count == eligible.count,
                  value.chosenAlternative.map(eligible.contains) ?? true,
                  value.treatment.map(eligible.contains) ?? true,
                  value.baseline.map(eligible.contains) ?? true else { return false }
        } else if value.chosenAlternative != nil {
            return false
        }
        if value.evidenceClass == .controlledProduction {
            guard value.intervention == "reasoning_effort",
                  value.experimentID != nil,
                  value.taskScenarioFamily != nil,
                  let treatment = value.treatment,
                  value.baseline != nil,
                  value.chosenAlternative == treatment,
                  value.eligibleAlternatives != nil,
                  value.confounderFlags != nil,
                  value.coverageFlags?.count == 2 else { return false }
        }
        return true
    }

    private static func optionalAssignmentToken(_ raw: String?, maximum: Int) -> Bool {
        raw.map { assignmentToken($0, maximum: maximum) } ?? true
    }

    private static func validAssignmentTokens(
        _ values: [String]?, maximumCount: Int, maximum: Int
    ) -> Bool {
        guard let values else { return true }
        return values.count <= maximumCount
            && values.allSatisfy { assignmentToken($0, maximum: maximum) }
    }

    private static func assignmentToken(_ raw: String, maximum: Int) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:"))
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw == trimmed && !raw.isEmpty && raw.count <= maximum
            && raw.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func closedToken(_ raw: String?, maximum: Int) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:/"))
        guard raw == trimmed, !trimmed.isEmpty, trimmed.count <= maximum,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    fileprivate static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

// MARK: - Bounded report-only historical reconstruction

public struct OutcomeTissueHistoricalReport: Sendable, Equatable {
    public struct ExactReaction: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case thumbsUp = "thumbs_up"
            case thumbsDown = "thumbs_down"
            case explicitRetry = "explicit_retry"
        }

        public let kind: Kind
        public let evidenceID: String
        public let observedAt: Date
    }

    public struct Turn: Sendable, Equatable {
        public let anchor: ResponseOutcomeObservationV2
        public let providerFactCount: Int
        public let motorFactCount: Int
        public let explicitReactionCount: Int
        public let currentExactReaction: ExactReaction?
        public let dimensionStates: [String: OutcomeEvidenceState]
    }

    public let turns: [Turn]
    public let transcriptAnchorCount: Int
    public let rejectedAnchorCount: Int
    public let rejectedTraceRowCount: Int
    public let rejectionReasons: [String: Int]
    public let dimensionCoverage: [String: [OutcomeEvidenceState: Int]]
    public let sourceBytesRead: Int
}

/// Read-only join over canonical transcript anchors and the explicitly
/// supported `TurnTraceEvent` day-file schema. It never writes or repairs a
/// source and rejects duplicate/ambiguous joins rather than choosing one.
public struct OutcomeTissueHistoricalReconstructor: Sendable {
    public static let maximumDays = 14
    public static let maximumRows = 100_000
    public static let maximumBytes = 64 * 1_024 * 1_024

    private let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    public func reconstruct(now: Date = Date()) throws -> OutcomeTissueHistoricalReport {
        let fileManager = FileManager.default
        var bytesRead = 0
        var rowCount = 0
        var reasons: [String: Int] = [:]
        var anchors: [ResponseOutcomeObservationV2] = []
        let cutoff = now.addingTimeInterval(-Double(Self.maximumDays) * 24 * 60 * 60)
        let messagesDirectory = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        let transcriptFiles = (try? fileManager.contentsOfDirectory(
            at: messagesDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path } ?? []

        outer: for file in transcriptFiles {
            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
            guard bytesRead + data.count <= Self.maximumBytes else {
                reasons["transcript_byte_limit", default: 0] += 1
                break
            }
            bytesRead += data.count
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard rowCount < Self.maximumRows else {
                    reasons["row_limit", default: 0] += 1
                    break outer
                }
                rowCount += 1
                guard let value = try? JSONValue.parse(Data(line)),
                      case .object(let object) = value,
                      case .object(let metadata)? = object["metadata"],
                      let raw = metadata["outcomeObservation"] else { continue }
                guard let anchor = ResponseOutcomeObservationV2(jsonValue: raw) else {
                    reasons["invalid_anchor_schema", default: 0] += 1
                    continue
                }
                guard ResponseOutcomeObservationV2.parseDate(anchor.observedAt).map({ $0 >= cutoff && $0 <= now }) == true else {
                    reasons["anchor_outside_window", default: 0] += 1
                    continue
                }
                guard case .string(let rowID)? = object["id"], rowID == anchor.messageID,
                      case .string(let sessionID)? = object["sessionId"], sessionID == anchor.sessionID,
                      case .string("assistant")? = object["role"] else {
                    reasons["anchor_transcript_mismatch", default: 0] += 1
                    continue
                }
                anchors.append(anchor)
            }
        }

        let groupedAnchors = Dictionary(grouping: anchors, by: \.turnID)
        let duplicateTurnIDs = Set(groupedAnchors.filter { $0.value.count != 1 }.map(\.key))
        if !duplicateTurnIDs.isEmpty {
            reasons["ambiguous_duplicate_anchor", default: 0] += duplicateTurnIDs.reduce(0) {
                $0 + (groupedAnchors[$1]?.count ?? 0)
            }
        }
        let uniqueAnchors = anchors.filter { !duplicateTurnIDs.contains($0.turnID) }

        var traceEvents: [TurnTraceEvent] = []
        var rejectedTraceRows = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for offset in 0..<Self.maximumDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let path = TurnTracePersistLane(dataRootOverride: dataRoot).path(for: day)
            guard fileManager.fileExists(atPath: path.path) else { continue }
            let data = try Data(contentsOf: path, options: [.mappedIfSafe])
            guard bytesRead + data.count <= Self.maximumBytes else {
                reasons["trace_byte_limit", default: 0] += 1
                break
            }
            bytesRead += data.count
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard rowCount < Self.maximumRows else {
                    reasons["row_limit", default: 0] += 1
                    break
                }
                rowCount += 1
                guard let value = try? JSONValue.parse(Data(line)),
                      let event = TurnTraceEvent(jsonRow: value) else {
                    rejectedTraceRows += 1
                    continue
                }
                traceEvents.append(event)
            }
        }

        struct ExactFeedback {
            let eventID: String
            let messageID: String
            let turnID: String
            let sessionID: String
            let reaction: String
            let observedAt: Date
        }
        var feedbackByTurn: [String: [ExactFeedback]] = [:]
        var seenFeedbackIDs = Set<String>()
        let feedbackPath = dataRoot
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent("feedback.jsonl")
        if fileManager.fileExists(atPath: feedbackPath.path) {
            let data = try Data(contentsOf: feedbackPath, options: [.mappedIfSafe])
            if bytesRead + data.count <= Self.maximumBytes {
                bytesRead += data.count
                for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    guard rowCount < Self.maximumRows else {
                        reasons["row_limit", default: 0] += 1
                        break
                    }
                    rowCount += 1
                    guard let value = try? JSONValue.parse(Data(line)),
                          case .object(let object) = value else {
                        reasons["invalid_feedback_row", default: 0] += 1
                        continue
                    }
                    guard object["schema"] == .string(OutcomeFeedbackStore.schema) else {
                        // Legacy feedback did not validate the transcript and
                        // is intentionally observational-only.
                        reasons["legacy_feedback_censored", default: 0] += 1
                        continue
                    }
                    guard case .string(let eventID)? = object["eventId"],
                          case .string(let messageID)? = object["messageId"],
                          case .string(let turnID)? = object["turnId"],
                          case .string(let sessionID)? = object["sessionId"],
                          case .string(let reaction)? = object["reaction"],
                          case .string(let observedAtRaw)? = object["observedAt"],
                          let observedAt = ResponseOutcomeObservationV2.parseDate(observedAtRaw),
                          Self.closedToken(eventID, maximum: 128),
                          Self.closedToken(messageID, maximum: 128),
                          Self.closedToken(turnID, maximum: 128),
                          Self.closedToken(sessionID, maximum: 128),
                          reaction == "thumbs_up" || reaction == "thumbs_down",
                          object["payloadFree"] == .bool(true),
                          object["controlAuthority"] == .bool(false),
                          Self.validOptionalSupersededEventID(object["supersedesEventId"]),
                          observedAt >= cutoff, observedAt <= now,
                          seenFeedbackIDs.insert(eventID).inserted else {
                        reasons["invalid_or_duplicate_feedback", default: 0] += 1
                        continue
                    }
                    feedbackByTurn[turnID, default: []].append(ExactFeedback(
                        eventID: eventID,
                        messageID: messageID,
                        turnID: turnID,
                        sessionID: sessionID,
                        reaction: reaction,
                        observedAt: observedAt
                    ))
                }
            } else {
                reasons["feedback_byte_limit", default: 0] += 1
            }
        }

        struct ExactMotorFact {
            let actionIdentity: String
            let domain: String
            let observedAt: Date
            let evidenceState: OutcomeEvidenceState
            let fingerprint: String
        }
        let exactMotorFacts: [ExactMotorFact] = traceEvents.compactMap { event in
            guard event.kind == "motor.state",
                  event.ts >= cutoff, event.ts <= now,
                  case .object(let payload) = event.payload,
                  payload["schema"] == .string("motor.action.read-model.v1"),
                  payload["payloadFree"] == .bool(true),
                  payload["controlAuthority"] == .bool(false),
                  case .string(let actionIdentity)? = payload["actionIdentity"],
                  actionIdentity.count == 64,
                  actionIdentity.unicodeScalars.allSatisfy(
                    CharacterSet(charactersIn: "0123456789abcdef").contains
                  ),
                  case .string(let domain)? = payload["domain"],
                  Self.closedToken(domain, maximum: 128),
                  case .string(let phaseRaw)? = payload["phase"],
                  MotorActionPhase(rawValue: phaseRaw) != nil,
                  case .string(let verificationRaw)? = payload["verification"],
                  let verification = MotorVerificationState(rawValue: verificationRaw),
                  case .string(let domainState)? = payload["domainState"],
                  Self.closedToken(domainState, maximum: 128)
            else { return nil }
            let evidenceState: OutcomeEvidenceState = switch verification {
            case .satisfied, .failed:
                .verified
            case .unverified:
                .unverified
            case .unknown:
                .unknown
            case .notStarted, .pending, .notRequired:
                .observed
            }
            return ExactMotorFact(
                actionIdentity: actionIdentity,
                domain: domain,
                observedAt: event.ts,
                evidenceState: evidenceState,
                fingerprint: CausalTransitionEvidence.opaqueIdentity([
                    domain, phaseRaw, verificationRaw, domainState,
                ].joined(separator: "|"))
            )
        }
        let motorFactsByIdentity = Dictionary(grouping: exactMotorFacts, by: \.actionIdentity)

        let tissue = MetacognitiveTurnOutcomeTissue.evaluate(events: traceEvents)
        let traced = Dictionary(uniqueKeysWithValues: tissue.turns.map { ($0.turnId, $0) })
        var coverage: [String: [OutcomeEvidenceState: Int]] = [:]
        let turns = uniqueAnchors.sorted { $0.turnID < $1.turnID }.map { anchor -> OutcomeTissueHistoricalReport.Turn in
            let trace = traced[anchor.turnID]
            let anchorDate = ResponseOutcomeObservationV2.parseDate(anchor.observedAt) ?? .distantFuture
            let matchingFeedback = (feedbackByTurn[anchor.turnID] ?? []).filter {
                $0.sessionID == anchor.sessionID
                    && $0.messageID == anchor.messageID
                    && $0.observedAt >= anchorDate
            }
            // One assistant response contributes at most one current reaction.
            // Superseding append-only receipts replace calibration weight;
            // repeated clicks can never amplify it.
            let exactFeedback = Dictionary(grouping: matchingFeedback, by: \.messageID)
                .compactMap { _, rows in
                    rows.max {
                        if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
                        return $0.eventID < $1.eventID
                    }
                }
            let feedbackReaction = exactFeedback.max {
                if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
                return $0.eventID < $1.eventID
            }.flatMap { row -> OutcomeTissueHistoricalReport.ExactReaction? in
                let kind: OutcomeTissueHistoricalReport.ExactReaction.Kind =
                    row.reaction == "thumbs_up" ? .thumbsUp : .thumbsDown
                return .init(kind: kind, evidenceID: row.eventID, observedAt: row.observedAt)
            }
            let retryReaction = trace?.explicitReactions.max {
                if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
                return $0.reactionTurnId < $1.reactionTurnId
            }.map {
                OutcomeTissueHistoricalReport.ExactReaction(
                    kind: .explicitRetry,
                    evidenceID: $0.reactionTurnId,
                    observedAt: $0.observedAt
                )
            }
            let currentReaction: OutcomeTissueHistoricalReport.ExactReaction? = {
                switch (feedbackReaction, retryReaction) {
                case (let feedback?, let retry?):
                    if feedback.observedAt != retry.observedAt {
                        return feedback.observedAt > retry.observedAt ? feedback : retry
                    }
                    return feedback.evidenceID > retry.evidenceID ? feedback : retry
                case (let feedback?, nil): return feedback
                case (nil, let retry?): return retry
                case (nil, nil): return nil
                }
            }()
            var states = anchor.dimensionStates
            states["provider"] = trace.map {
                $0.hasCompleteProviderCorrelation ? .observed : .censored
            } ?? states["provider"] ?? .censored
            states["reaction"] = (trace != nil || !exactFeedback.isEmpty) ? .observed : .censored
            var matchedMotorFactCount = 0
            if !anchor.motorActions.isEmpty {
                let motorStates: [OutcomeEvidenceState] = anchor.motorActions.map { reference in
                    let matching = (motorFactsByIdentity[reference.actionID] ?? [])
                        .filter { $0.domain == reference.domain }
                        .sorted {
                            if $0.observedAt != $1.observedAt {
                                return $0.observedAt < $1.observedAt
                            }
                            return $0.fingerprint < $1.fingerprint
                        }
                    if let latest = matching.last {
                        // Equal-time contradictory owner projections are
                        // ambiguous; retain only the turn-time fact instead of
                        // selecting a winner by file order.
                        let tied = matching.filter { $0.observedAt == latest.observedAt }
                        if Set(tied.map(\.fingerprint)).count == 1 {
                            matchedMotorFactCount += 1
                            return latest.evidenceState
                        }
                    }
                    return reference.verification
                }
                states["motor"] = ResponseOutcomeObservationV2.aggregateMotorEvidence(
                    motorStates
                )
            }
            for (dimension, state) in states {
                coverage[dimension, default: [:]][state, default: 0] += 1
            }
            return OutcomeTissueHistoricalReport.Turn(
                anchor: anchor,
                providerFactCount: trace?.providerFacts.count ?? 0,
                motorFactCount: matchedMotorFactCount,
                explicitReactionCount: (trace?.explicitReactions.count ?? 0) + exactFeedback.count,
                currentExactReaction: currentReaction,
                dimensionStates: states
            )
        }

        return OutcomeTissueHistoricalReport(
            turns: turns,
            transcriptAnchorCount: anchors.count,
            rejectedAnchorCount: reasons.filter { $0.key.contains("anchor") }.values.reduce(0, +),
            rejectedTraceRowCount: rejectedTraceRows,
            rejectionReasons: reasons,
            dimensionCoverage: coverage,
            sourceBytesRead: bytesRead
        )
    }

    private static func closedToken(_ value: String, maximum: Int) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:"))
        return !value.isEmpty && value.count <= maximum
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func validOptionalSupersededEventID(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        guard case .string(let identity) = value else { return false }
        return closedToken(identity, maximum: 128)
    }
}
