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
    public static let requiredDimensionKeys: Set<String> = [
        "responsePersistence", "context", "provider", "tools", "motor", "reaction",
    ]

    public let schema: String
    public let turnID: String
    public let messageID: String
    public let sessionID: String
    public let surface: String
    public let observedAt: String
    public let responsePersistence: String
    public let contextGenerationID: Int64?
    public let contextSelectionReceiptID: String?
    /// The provider route admitted with the turn context. This is not
    /// inferred from a model name: callers that do not retain the admitted
    /// context leave it absent and the provider evidence remains unknown.
    public let providerID: String?
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
        providerID: String? = nil,
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
        self.providerID = providerID
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
              NativeAgentChatSessionID.normalizedPathComponent(decoded.sessionID)
                == decoded.sessionID,
              Self.closedToken(decoded.surface, maximum: 128) != nil,
              Self.parseDate(decoded.observedAt) != nil,
              ["persisted", "partial", "cancelled", "failed"].contains(decoded.responsePersistence),
              decoded.tools.count <= 64,
              decoded.motorActions.count <= 64,
              decoded.turnElapsedMs.map({ (0...(24 * 60 * 60 * 1_000)).contains($0) }) ?? true,
              decoded.contextGenerationID.map({ $0 >= 0 }) ?? true,
              decoded.providerID.map({ Self.closedToken($0, maximum: 128) != nil }) ?? true,
              decoded.providerModel.map({ Self.closedToken($0, maximum: 256) != nil }) ?? true,
              Set(decoded.dimensionStates.keys) == Self.requiredDimensionKeys,
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
              let sessionID = NativeAgentChatSessionID.normalizedPathComponent(rawSessionID),
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
            // A model string alone cannot name a transport. A production
            // context does carry the admitted provider route, however, so
            // preserve that pre-dispatch fact on the canonical assistant row
            // instead of leaving a permanently unwired historical join.
            "provider": context?.providerId == nil
                ? (result == nil ? .censored : .unknown)
                : .observed,
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
            providerID: context.flatMap { closedToken($0.providerId, maximum: 128) },
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

/// Population-level health for the six closed outcome dimensions. A missing
/// observation is counted separately rather than becoming six zero buckets,
/// and a dimension dominated by one non-terminal state remains visible as a
/// wiring lead instead of looking like measured negative evidence.
public struct OutcomeDimensionStateAudit: Sendable, Equatable {
    public let sourceStatus: String
    public let totalRows: Int
    public let absentObservations: Int
    public let distributions: [String: [OutcomeEvidenceState: Int]]
    public let permanentlyNonterminalDimensions: [String]
    public let rankedLeads: [String]

    public var jsonValue: JSONValue {
        let stateRows = distributions.mapValues { counts in
            JSONValue.object(Dictionary(uniqueKeysWithValues: counts.map {
                ($0.key.rawValue, .int(Int64($0.value)))
            }))
        }
        return .object([
            "status": .string(
                sourceStatus != "measured"
                    ? sourceStatus
                    : (absentObservations > 0 || !permanentlyNonterminalDimensions.isEmpty
                        ? "degraded" : "ok")
            ),
            "source_status": .string(sourceStatus),
            "assistant_rows": .int(Int64(totalRows)),
            "valid_observations": .int(Int64(totalRows - absentObservations)),
            "absent_observations": .int(Int64(absentObservations)),
            "absent_is_zero": .bool(false),
            "distributions": .object(stateRows),
            "permanently_nonterminal_dimensions": .array(
                permanentlyNonterminalDimensions.map { .string($0) }
            ),
            "ranked_leads": .array(rankedLeads.map { .string($0) }),
        ])
    }

    public static func make(
        _ observations: [ResponseOutcomeObservationV2?],
        sourceStatus: String = "measured"
    ) -> OutcomeDimensionStateAudit {
        var distributions = Dictionary(
            uniqueKeysWithValues: ResponseOutcomeObservationV2.requiredDimensionKeys.map {
                ($0, [OutcomeEvidenceState: Int]())
            }
        )
        var present = 0
        for observation in observations {
            guard let observation else { continue }
            present += 1
            for dimension in ResponseOutcomeObservationV2.requiredDimensionKeys {
                guard let state = observation.dimensionStates[dimension] else { continue }
                distributions[dimension, default: [:]][state, default: 0] += 1
            }
        }
        let dark = distributions.compactMap { dimension, counts -> String? in
            guard present > 0 else { return nil }
            let dominant = max(counts[.unknown, default: 0], counts[.censored, default: 0])
            return Double(dominant) / Double(present) > 0.95 ? dimension : nil
        }.sorted()
        let absent = observations.count - present
        var leads = dark.map { "\($0): this dimension has no promoter wired" }
        if absent > 0 {
            leads.insert(
                "outcome observation absent on \(absent) of \(observations.count) assistant rows",
                at: 0
            )
        }
        return OutcomeDimensionStateAudit(
            sourceStatus: sourceStatus,
            totalRows: observations.count,
            absentObservations: absent,
            distributions: distributions,
            permanentlyNonterminalDimensions: dark,
            rankedLeads: leads
        )
    }
}

/// Bounded reader for the canonical persisted assistant population. It reuses
/// `SessionHistoryReader`, so transcript framing, malformed-row handling and
/// session identity rules cannot drift into a second parser. Legacy/corrupt
/// assistant rows with no decodable outcome become explicit absent
/// observations in the audit rather than disappearing from its denominator.
public struct OutcomeDimensionStatePopulationReader: Sendable {
    private let dataRoot: URL
    private let since: Date?

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        since: Date? = nil
    ) {
        self.dataRoot = dataRoot
        self.since = since
    }

    public func read() async throws -> OutcomeDimensionStateAudit {
        let directory = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return .make([], sourceStatus: "absent")
        }
        guard isDirectory.boolValue else {
            throw PersistenceCoreError.ioFailure(
                "chat messages population path is not a directory: \(directory.path)"
            )
        }

        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey]
                  ),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.lastPathComponent < rhs.0.lastPathComponent
        }

        let history = SessionHistoryReader(dataRoot: dataRoot)
        var observations: [ResponseOutcomeObservationV2?] = []
        for (url, _) in candidates {
            let sessionID = url.deletingPathExtension().lastPathComponent
            let messages = try await history.messages(
                forSessionId: sessionID
            )
            for message in messages where message.role == "assistant" {
                if let since {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let timestamp = formatter.date(from: message.timestamp)
                        ?? ISO8601DateFormatter().date(from: message.timestamp)
                    guard let timestamp, timestamp >= since else { continue }
                }
                guard case .object(let row)? = message.extras,
                      case .object(let metadata)? = row["metadata"],
                      let raw = metadata["outcomeObservation"] else {
                    observations.append(nil)
                    continue
                }
                observations.append(ResponseOutcomeObservationV2(jsonValue: raw))
            }
        }
        return .make(observations)
    }
}
