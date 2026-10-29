import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `ProcedureTrajectory.swift` | Payload-free procedure trajectories, extraction, validation and rejection evidence |

// MARK: - Payload-free trajectory extraction

public enum ProcedureTerminalClass: String, Codable, Sendable, Equatable {
    case verifiedSuccess = "verified_success"
    case verifiedFailure = "verified_failure"
    case cancelled
}

public struct ProcedureTrajectoryStep: Codable, Sendable, Equatable {
    public let sequence: Int
    public let transitionKind: String
    public let beforeState: String?
    public let afterState: String?
    public let actionKind: String?
    public let evidenceKind: String?
    public let expectedNextEvidence: String?
    public let checkpointClass: String?
    public let retryClass: String?
    public let retryCount: Int?
    public let cancellationClass: String?
    public let motorPhase: String?
    public let verificationClass: String?
    public let terminalClass: ProcedureTerminalClass?
    public let externalEffectClass: String

    public init(
        sequence: Int,
        transitionKind: String,
        beforeState: String?,
        afterState: String?,
        actionKind: String?,
        evidenceKind: String?,
        expectedNextEvidence: String?,
        checkpointClass: String?,
        retryClass: String?,
        retryCount: Int?,
        cancellationClass: String?,
        motorPhase: String?,
        verificationClass: String?,
        terminalClass: ProcedureTerminalClass?,
        externalEffectClass: String
    ) {
        self.sequence = sequence
        self.transitionKind = transitionKind
        self.beforeState = beforeState
        self.afterState = afterState
        self.actionKind = actionKind
        self.evidenceKind = evidenceKind
        self.expectedNextEvidence = expectedNextEvidence
        self.checkpointClass = checkpointClass
        self.retryClass = retryClass
        self.retryCount = retryCount
        self.cancellationClass = cancellationClass
        self.motorPhase = motorPhase
        self.verificationClass = verificationClass
        self.terminalClass = terminalClass
        self.externalEffectClass = externalEffectClass
    }
}

/// A bounded, payload-free multi-step instance. Every identity is opaque and
/// every input field describes a type/schema, never a parameter value.
public struct ProcedureTrajectory: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let domain: String
    public let taskFamily: String
    public let inputClass: String
    public let inputInstanceIdentity: String
    public let parameterSchemaClass: String
    public let parameterSchemaIdentity: String
    public let procedureShapeIdentity: String
    public let authorityClass: String
    public let steps: [ProcedureTrajectoryStep]
    public let startedAt: String
    public let endedAt: String
    public let durationMilliseconds: Int
    public let terminalClass: ProcedureTerminalClass
    public let externalEffectClasses: [String]
    public let providerCallCount: Int?
    public let toolCallCount: Int?
    public let providerCostMicros: Int?
    public let toolCostMicros: Int?
    public let removableOrchestrationProviderCallCount: Int?
    public let retryCount: Int
    public let cancellationObserved: Bool
}

public enum ProcedureTrajectoryRejectionReason: String, Codable, Sendable, Equatable, Hashable {
    case missingMetadata = "missing_metadata"
    case invalidIdentity = "invalid_identity"
    case unorderedSequence = "unordered_sequence"
    case tooFewTransitions = "too_few_transitions"
    case tooManyTransitions = "too_many_transitions"
    case tooFewStateChanges = "too_few_state_changes"
    case tooFewActionEvidenceSteps = "too_few_action_evidence_steps"
    case inconsistentContract = "inconsistent_contract"
    case invalidChronology = "invalid_chronology"
    case durationExceeded = "duration_exceeded"
    case invalidTerminal = "invalid_terminal"
    case invalidCost = "invalid_cost"
    /// Generated or frozen evidence cannot establish a production routine.
    case nonProductionEvidence = "non_production_evidence"
}

public struct ProcedureTrajectoryRejection: Sendable, Equatable {
    public let trajectoryIdentity: String?
    public let reasons: [ProcedureTrajectoryRejectionReason]
}

public struct ProcedureTrajectoryExtractionReport: Sendable, Equatable {
    public let trajectories: [ProcedureTrajectory]
    public let rejections: [ProcedureTrajectoryRejection]
    public let rowsWithoutTrajectoryIdentity: Int
}

public enum ProcedureTrajectoryExtractor {
    public static let maximumSteps = 16
    public static let defaultMaximumDuration: TimeInterval = 14 * 24 * 60 * 60

    public static func extract(
        _ evidence: [CausalTransitionEvidence],
        maximumDuration: TimeInterval = defaultMaximumDuration
    ) -> ProcedureTrajectoryExtractionReport {
        let boundedDuration = max(1, min(maximumDuration, defaultMaximumDuration))
        var rowsWithoutIdentity = 0
        var grouped: [String: [CausalTransitionEvidence]] = [:]
        for row in evidence {
            guard let trajectoryID = row.trajectoryID else {
                rowsWithoutIdentity += 1
                continue
            }
            grouped[trajectoryID, default: []].append(row)
        }

        var trajectories: [ProcedureTrajectory] = []
        var rejections: [ProcedureTrajectoryRejection] = []
        for identity in grouped.keys.sorted() {
            guard let rows = grouped[identity] else { continue }
            let result = extractOne(identity: identity, rows: rows, maximumDuration: boundedDuration)
            switch result {
            case .success(let trajectory): trajectories.append(trajectory)
            case .failure(let reasons):
                rejections.append(ProcedureTrajectoryRejection(
                    trajectoryIdentity: identity,
                    reasons: reasons
                ))
            }
        }
        return ProcedureTrajectoryExtractionReport(
            trajectories: trajectories,
            rejections: rejections,
            rowsWithoutTrajectoryIdentity: rowsWithoutIdentity
        )
    }

    private enum OneResult {
        case success(ProcedureTrajectory)
        case failure([ProcedureTrajectoryRejectionReason])
    }

    private static func extractOne(
        identity: String,
        rows: [CausalTransitionEvidence],
        maximumDuration: TimeInterval
    ) -> OneResult {
        var reasons: [ProcedureTrajectoryRejectionReason] = []
        if rows.contains(where: { $0.evidenceClass == .controlledSynthetic }) {
            reasons.append(.nonProductionEvidence)
        }
        if !isOpaqueIdentity(identity) { reasons.append(.invalidIdentity) }
        if rows.count < 3 { reasons.append(.tooFewTransitions) }
        if rows.count > maximumSteps { reasons.append(.tooManyTransitions) }

        let sorted = rows.sorted {
            let lhs = $0.sequenceNumber ?? Int.max
            let rhs = $1.sequenceNumber ?? Int.max
            if lhs != rhs { return lhs < rhs }
            return $0.operationId < $1.operationId
        }
        let sequences = sorted.compactMap(\.sequenceNumber)
        if sequences.count != sorted.count
            || Set(sequences).count != sequences.count
            || zip(sequences, sequences.dropFirst()).contains(where: { lhs, rhs in lhs >= rhs }) {
            reasons.append(.unorderedSequence)
        }

        guard let first = sorted.first, let last = sorted.last else {
            return .failure(unique(reasons + [.tooFewTransitions]))
        }
        let contracts: [[String?]] = sorted.map {
            [
                $0.domain, $0.taskFamily, $0.inputClass, $0.inputInstanceIdentity,
                $0.parameterSchemaClass, $0.parameterSchemaIdentity,
                $0.procedureShapeIdentity, $0.authorityClass,
            ]
        }
        guard let contract = contracts.first,
              contract.allSatisfy({ token($0, maximum: 128) != nil }),
              contracts.allSatisfy({ $0 == contract }),
              let domain = first.domain.nonEmptyToken,
              let taskFamily = first.taskFamily?.nonEmptyToken,
              let inputClass = first.inputClass?.nonEmptyToken,
              let inputIdentity = first.inputInstanceIdentity,
              let schemaClass = first.parameterSchemaClass?.nonEmptyToken,
              let schemaIdentity = first.parameterSchemaIdentity,
              let shapeIdentity = first.procedureShapeIdentity,
              let authorityClass = first.authorityClass?.nonEmptyToken
        else {
            reasons.append(.missingMetadata)
            return .failure(unique(reasons))
        }
        if !isOpaqueIdentity(inputIdentity)
            || !isOpaqueIdentity(schemaIdentity)
            || !isOpaqueIdentity(shapeIdentity) {
            reasons.append(.invalidIdentity)
        }
        if sorted.contains(where: { row in
            token(row.kind, maximum: 128) == nil
                || token(row.beforeState, maximum: 128) == nil && row.beforeState != nil
                || token(row.afterState, maximum: 128) == nil && row.afterState != nil
                || token(row.actionKind, maximum: 128) == nil && row.actionKind != nil
                || token(row.evidenceKind, maximum: 128) == nil && row.evidenceKind != nil
                || token(row.expectedNextEvidence, maximum: 128) == nil && row.expectedNextEvidence != nil
                || token(row.checkpointClass, maximum: 128) == nil && row.checkpointClass != nil
                || token(row.retryClass, maximum: 128) == nil && row.retryClass != nil
                || token(row.cancellationClass, maximum: 128) == nil && row.cancellationClass != nil
        }) {
            reasons.append(.missingMetadata)
        }

        let stateChanges = sorted.filter { $0.beforeState != $0.afterState }.count
        if stateChanges < 3 { reasons.append(.tooFewStateChanges) }
        let actionEvidenceCount = sorted.filter { $0.actionKind != nil || $0.evidenceKind != nil }.count
        if actionEvidenceCount < 2 { reasons.append(.tooFewActionEvidenceSteps) }

        let dates = sorted.compactMap { parseDate($0.occurredAt) }
        if dates.count != sorted.count,
           !reasons.contains(.invalidChronology) { reasons.append(.invalidChronology) }
        let startDate = dates.first ?? .distantPast
        let endDate = dates.last ?? .distantFuture
        let duration = endDate.timeIntervalSince(startDate)
        if duration < 0 || zip(dates, dates.dropFirst()).contains(where: { lhs, rhs in lhs > rhs }) {
            reasons.append(.invalidChronology)
        }
        if duration > maximumDuration { reasons.append(.durationExceeded) }

        let terminal = last.terminalClass.flatMap(ProcedureTerminalClass.init(rawValue:))
        if terminal == nil
            || sorted.dropLast().contains(where: { $0.terminalClass != nil })
            || (terminal != .cancelled && last.verificationClass != "verified")
            || (terminal == .cancelled && last.cancellationClass == nil) {
            reasons.append(.invalidTerminal)
        }

        let integerFacts = sorted.flatMap {
            [
                $0.retryCount, $0.latencyMilliseconds, $0.providerCallCount,
                $0.toolCallCount, $0.providerCostMicros, $0.toolCostMicros,
                $0.removableOrchestrationProviderCallCount,
            ]
        }.compactMap { $0 }
        if integerFacts.contains(where: { $0 < 0 || $0 > 1_000_000_000_000 }) {
            reasons.append(.invalidCost)
        }
        if sorted.contains(where: { token($0.externalEffectClass, maximum: 64) == nil }) {
            reasons.append(.missingMetadata)
        }
        guard reasons.isEmpty, let terminal else { return .failure(unique(reasons)) }

        let steps = sorted.map { row in
            ProcedureTrajectoryStep(
                sequence: row.sequenceNumber ?? 0,
                transitionKind: row.kind,
                beforeState: row.beforeState,
                afterState: row.afterState,
                actionKind: row.actionKind,
                evidenceKind: row.evidenceKind,
                expectedNextEvidence: row.expectedNextEvidence,
                checkpointClass: row.checkpointClass,
                retryClass: row.retryClass,
                retryCount: row.retryCount,
                cancellationClass: row.cancellationClass,
                motorPhase: row.motorPhase,
                verificationClass: row.verificationClass,
                terminalClass: row.terminalClass.flatMap(ProcedureTerminalClass.init(rawValue:)),
                externalEffectClass: row.externalEffectClass ?? "unknown"
            )
        }
        let durationMilliseconds = Int(min(Double(Int.max), max(0, duration * 1_000)))
        return .success(ProcedureTrajectory(
            id: identity,
            domain: domain,
            taskFamily: taskFamily,
            inputClass: inputClass,
            inputInstanceIdentity: inputIdentity,
            parameterSchemaClass: schemaClass,
            parameterSchemaIdentity: schemaIdentity,
            procedureShapeIdentity: shapeIdentity,
            authorityClass: authorityClass,
            steps: steps,
            startedAt: first.occurredAt,
            endedAt: last.occurredAt,
            durationMilliseconds: durationMilliseconds,
            terminalClass: terminal,
            externalEffectClasses: Array(Set(steps.map(\.externalEffectClass))).sorted(),
            providerCallCount: sumIfObserved(sorted.map(\.providerCallCount)),
            toolCallCount: sumIfObserved(sorted.map(\.toolCallCount)),
            providerCostMicros: sumIfObserved(sorted.map(\.providerCostMicros)),
            toolCostMicros: sumIfObserved(sorted.map(\.toolCostMicros)),
            removableOrchestrationProviderCallCount:
                sumIfObserved(sorted.map(\.removableOrchestrationProviderCallCount)),
            retryCount: sorted.compactMap(\.retryCount).max() ?? sorted.filter { $0.retryClass != nil }.count,
            cancellationObserved: terminal == .cancelled || sorted.contains { $0.cancellationClass != nil }
        ))
    }

    private static func sumIfObserved(_ values: [Int?]) -> Int? {
        let observed = values.compactMap { $0 }
        return observed.isEmpty ? nil : observed.reduce(0, +)
    }

    private static func unique(
        _ values: [ProcedureTrajectoryRejectionReason]
    ) -> [ProcedureTrajectoryRejectionReason] {
        var seen = Set<ProcedureTrajectoryRejectionReason>()
        return values.filter { seen.insert($0).inserted }
    }

    internal static func isOpaqueIdentity(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    fileprivate static func token(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:/"))
        guard !value.isEmpty, value.count <= maximum,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    private static func parseDate(_ value: String) -> Date? {
        NativeTimestampFormat.parseISO8601FractionalFirst(value)
    }
}

private extension String {
    var nonEmptyToken: String? {
        ProcedureTrajectoryExtractor.token(self, maximum: 128)
    }
}
