import CryptoKit
import Foundation
import ChatOrchestration
import PersistenceCore

/// Closed intervention dimensions for the metacognitive calibration lane.
///
/// These are experimental assignments, not runtime authority. A pair changes
/// exactly one dimension while provider, model, frozen mind, prompt, tool
/// eligibility, TrustCenter posture, and action authority remain fixed.
public enum MetacognitiveCalibrationDimension: String, Codable, Sendable, CaseIterable {
    case deliberationDepth = "deliberation_depth"
    case readOnlyToolUse = "read_only_tool_use"
    case contextBreadth = "context_breadth"
    case reasoningEffort = "reasoning_effort"
    case askOrAnswer = "ask_or_answer"
    case waitOrRetry = "wait_or_retry"
}

public enum MetacognitiveCalibrationEvidenceClass: String, Codable, Sendable {
    case generatedMechanism = "generated_mechanism"
    case frozenProvider = "frozen_provider"
}

public struct MetacognitiveCalibrationSelection: Codable, Sendable, Equatable {
    public let deliberation: String
    public let toolPosture: String
    public let contextPosture: String
    public let reasoningEffort: String
    public let responsePosture: String
    public let operationalPosture: String

    public init(
        deliberation: String,
        toolPosture: String,
        contextPosture: String,
        reasoningEffort: String,
        responsePosture: String,
        operationalPosture: String
    ) {
        self.deliberation = deliberation
        self.toolPosture = toolPosture
        self.contextPosture = contextPosture
        self.reasoningEffort = reasoningEffort
        self.responsePosture = responsePosture
        self.operationalPosture = operationalPosture
    }
}

/// Exact bounded outcome for one pre-assigned calibration arm.
///
/// Quality is supplied by a frozen scenario rubric or generated mechanism
/// oracle. It is never inferred from response prose or user silence.
public struct MetacognitiveCalibrationOutcome: Codable, Sendable, Equatable {
    public let rubricScorePermille: Int
    public let calibrationBrierPermille: Int
    public let verifiedCompletion: Bool
    public let falseCompletion: Bool
    public let authorityError: Bool
    public let explicitCorrection: Bool
    public let latencyMs: Int
    public let providerCalls: Int
    public let tokenUsage: Int?
    public let toolFailures: Int
    public let eligibleContextUsed: Bool?

    public init(
        rubricScorePermille: Int,
        calibrationBrierPermille: Int,
        verifiedCompletion: Bool,
        falseCompletion: Bool,
        authorityError: Bool,
        explicitCorrection: Bool,
        latencyMs: Int,
        providerCalls: Int,
        tokenUsage: Int?,
        toolFailures: Int,
        eligibleContextUsed: Bool?
    ) {
        self.rubricScorePermille = rubricScorePermille
        self.calibrationBrierPermille = calibrationBrierPermille
        self.verifiedCompletion = verifiedCompletion
        self.falseCompletion = falseCompletion
        self.authorityError = authorityError
        self.explicitCorrection = explicitCorrection
        self.latencyMs = latencyMs
        self.providerCalls = providerCalls
        self.tokenUsage = tokenUsage
        self.toolFailures = toolFailures
        self.eligibleContextUsed = eligibleContextUsed
    }
}

public struct MetacognitiveCalibrationArm: Codable, Sendable, Equatable {
    public enum Arm: String, Codable, Sendable { case baseline, candidate }

    public let schema: String
    public let pairID: String
    public let assignmentID: String
    public let arm: Arm
    public let dimension: MetacognitiveCalibrationDimension
    public let evidenceClass: MetacognitiveCalibrationEvidenceClass
    public let scenarioFamily: String
    public let scenarioID: String
    public let taskClass: String
    public let provider: String
    public let model: String
    public let frozenMindDigest: String
    public let promptDigest: String
    public let contextDigest: String
    public let toolSetDigest: String
    public let trustPosture: String
    public let actionAuthority: String
    public let assignedAt: String
    public let observedAt: String
    public let selection: MetacognitiveCalibrationSelection
    public let outcome: MetacognitiveCalibrationOutcome

    public init(
        pairID: String,
        assignmentID: String,
        arm: Arm,
        dimension: MetacognitiveCalibrationDimension,
        evidenceClass: MetacognitiveCalibrationEvidenceClass,
        scenarioFamily: String,
        scenarioID: String,
        taskClass: String,
        provider: String,
        model: String,
        frozenMindDigest: String,
        promptDigest: String,
        contextDigest: String,
        toolSetDigest: String,
        trustPosture: String,
        actionAuthority: String,
        assignedAt: String,
        observedAt: String,
        selection: MetacognitiveCalibrationSelection,
        outcome: MetacognitiveCalibrationOutcome
    ) {
        self.schema = "metacognition.calibration-arm.v1"
        self.pairID = pairID
        self.assignmentID = assignmentID
        self.arm = arm
        self.dimension = dimension
        self.evidenceClass = evidenceClass
        self.scenarioFamily = scenarioFamily
        self.scenarioID = scenarioID
        self.taskClass = taskClass
        self.provider = provider
        self.model = model
        self.frozenMindDigest = frozenMindDigest
        self.promptDigest = promptDigest
        self.contextDigest = contextDigest
        self.toolSetDigest = toolSetDigest
        self.trustPosture = trustPosture
        self.actionAuthority = actionAuthority
        self.assignedAt = assignedAt
        self.observedAt = observedAt
        self.selection = selection
        self.outcome = outcome
    }
}

public struct MetacognitiveCalibrationReport: Codable, Sendable, Equatable {
    public struct PairResult: Codable, Sendable, Equatable {
        public let pairID: String
        public let dimension: MetacognitiveCalibrationDimension
        public let scenarioFamily: String
        public let taskClass: String
        public let baselineEffort: String
        public let candidateEffort: String
        public let scoreDeltaPermille: Int
        public let latencyDeltaMs: Int
        public let tokenDelta: Int?
        public let candidateNoninferior: Bool
        public let candidatePreferred: Bool
    }

    public struct Cell: Codable, Sendable, Equatable {
        public let dimension: MetacognitiveCalibrationDimension
        public let taskClass: String
        public let evaluatedPairs: Int
        public let candidatePreferred: Int
        public let candidateNoninferior: Int
        public let authorityErrors: Int
        public let falseCompletions: Int
        public let meanScoreDeltaPermille: Double
        public let meanLatencyDeltaMs: Double
    }

    public let schema: String
    public let evidenceClass: MetacognitiveCalibrationEvidenceClass?
    public let acceptedPairs: [PairResult]
    public let cells: [Cell]
    public let rejectedRows: Int
    public let rejectedPairs: Int
    public let controlAuthority: Bool
    public let payloadFree: Bool

    public init(
        evidenceClass: MetacognitiveCalibrationEvidenceClass?,
        acceptedPairs: [PairResult],
        cells: [Cell],
        rejectedRows: Int,
        rejectedPairs: Int
    ) {
        self.schema = "metacognition.calibration-report.v1"
        self.evidenceClass = evidenceClass
        self.acceptedPairs = acceptedPairs
        self.cells = cells
        self.rejectedRows = rejectedRows
        self.rejectedPairs = rejectedPairs
        self.controlAuthority = false
        self.payloadFree = true
    }

    /// Deterministic paired evaluation. Invalid or post-outcome assignments are
    /// rejected rather than repaired. A candidate is preferred only when it is
    /// quality-noninferior, introduces no authority/false-completion error, and
    /// either improves quality or reduces measured compute/latency.
    public static func evaluate(_ rows: [MetacognitiveCalibrationArm]) -> Self {
        let acceptedRows = rows.filter(Self.valid)
        let rejectedRows = rows.count - acceptedRows.count
        let grouped = Dictionary(grouping: acceptedRows, by: \.pairID)
        var rejectedPairs = 0
        var results: [PairResult] = []
        for pairID in grouped.keys.sorted() {
            guard let pair = grouped[pairID], pair.count == 2,
                  let baseline = pair.first(where: { $0.arm == .baseline }),
                  let candidate = pair.first(where: { $0.arm == .candidate }),
                  sameControls(baseline, candidate),
                  changesOnlyDeclaredDimension(baseline, candidate)
            else {
                rejectedPairs += 1
                continue
            }
            let scoreDelta = candidate.outcome.rubricScorePermille - baseline.outcome.rubricScorePermille
            let latencyDelta = candidate.outcome.latencyMs - baseline.outcome.latencyMs
            let tokenDelta: Int? = {
                guard let candidateTokens = candidate.outcome.tokenUsage,
                      let baselineTokens = baseline.outcome.tokenUsage else { return nil }
                return candidateTokens - baselineTokens
            }()
            let noninferior = scoreDelta >= -25
                && candidate.outcome.calibrationBrierPermille <= baseline.outcome.calibrationBrierPermille + 25
                && !candidate.outcome.authorityError
                && !candidate.outcome.falseCompletion
                && (!candidate.outcome.explicitCorrection || baseline.outcome.explicitCorrection)
            let computeImproved = latencyDelta < 0 || (tokenDelta.map { $0 < 0 } ?? false)
                || candidate.outcome.providerCalls < baseline.outcome.providerCalls
            let preferred = noninferior && (scoreDelta > 0 || computeImproved)
            results.append(PairResult(
                pairID: pairID,
                dimension: baseline.dimension,
                scenarioFamily: baseline.scenarioFamily,
                taskClass: baseline.taskClass,
                baselineEffort: baseline.selection.reasoningEffort,
                candidateEffort: candidate.selection.reasoningEffort,
                scoreDeltaPermille: scoreDelta,
                latencyDeltaMs: latencyDelta,
                tokenDelta: tokenDelta,
                candidateNoninferior: noninferior,
                candidatePreferred: preferred
            ))
        }

        struct CellKey: Hashable {
            let dimension: MetacognitiveCalibrationDimension
            let taskClass: String
        }
        let resultGroups = Dictionary(grouping: results) {
            CellKey(dimension: $0.dimension, taskClass: $0.taskClass)
        }
        let cells = resultGroups.keys.sorted {
            if $0.dimension.rawValue != $1.dimension.rawValue {
                return $0.dimension.rawValue < $1.dimension.rawValue
            }
            return $0.taskClass < $1.taskClass
        }.compactMap { key -> Cell? in
            guard let rows = resultGroups[key], !rows.isEmpty else { return nil }
            let pairedArms = grouped.values.flatMap { $0 }.filter {
                $0.dimension == key.dimension && $0.taskClass == key.taskClass && $0.arm == .candidate
            }
            return Cell(
                dimension: key.dimension,
                taskClass: key.taskClass,
                evaluatedPairs: rows.count,
                candidatePreferred: rows.filter(\.candidatePreferred).count,
                candidateNoninferior: rows.filter(\.candidateNoninferior).count,
                authorityErrors: pairedArms.filter(\.outcome.authorityError).count,
                falseCompletions: pairedArms.filter(\.outcome.falseCompletion).count,
                meanScoreDeltaPermille: Double(rows.map(\.scoreDeltaPermille).reduce(0, +)) / Double(rows.count),
                meanLatencyDeltaMs: Double(rows.map(\.latencyDeltaMs).reduce(0, +)) / Double(rows.count)
            )
        }
        let evidenceClasses = Set(acceptedRows.map(\.evidenceClass))
        return Self(
            evidenceClass: evidenceClasses.count == 1 ? evidenceClasses.first : nil,
            acceptedPairs: results,
            cells: cells,
            rejectedRows: rejectedRows,
            rejectedPairs: rejectedPairs
        )
    }

    private static func valid(_ row: MetacognitiveCalibrationArm) -> Bool {
        guard row.schema == "metacognition.calibration-arm.v1",
              token(row.pairID, maximum: 128), token(row.assignmentID, maximum: 128),
              token(row.scenarioFamily, maximum: 128), token(row.scenarioID, maximum: 128),
              token(row.taskClass, maximum: 128), token(row.provider, maximum: 128),
              token(row.model, maximum: 256), digest(row.frozenMindDigest), digest(row.promptDigest),
              digest(row.contextDigest), digest(row.toolSetDigest),
              token(row.trustPosture, maximum: 64), token(row.actionAuthority, maximum: 64),
              let assignedAt = parseDate(row.assignedAt), let observedAt = parseDate(row.observedAt),
              assignedAt <= observedAt,
              (0...1_000).contains(row.outcome.rubricScorePermille),
              (0...1_000).contains(row.outcome.calibrationBrierPermille),
              (0...86_400_000).contains(row.outcome.latencyMs),
              (0...64).contains(row.outcome.providerCalls),
              row.outcome.tokenUsage.map({ (0...10_000_000).contains($0) }) ?? true,
              (0...64).contains(row.outcome.toolFailures)
        else { return false }
        return selectionTokens(row.selection)
    }

    private static func sameControls(_ lhs: MetacognitiveCalibrationArm, _ rhs: MetacognitiveCalibrationArm) -> Bool {
        lhs.pairID == rhs.pairID
            && lhs.dimension == rhs.dimension
            && lhs.evidenceClass == rhs.evidenceClass
            && lhs.scenarioFamily == rhs.scenarioFamily
            && lhs.scenarioID == rhs.scenarioID
            && lhs.taskClass == rhs.taskClass
            && lhs.provider == rhs.provider
            && lhs.model == rhs.model
            && lhs.frozenMindDigest == rhs.frozenMindDigest
            && lhs.promptDigest == rhs.promptDigest
            && lhs.contextDigest == rhs.contextDigest
            && lhs.toolSetDigest == rhs.toolSetDigest
            && lhs.trustPosture == rhs.trustPosture
            && lhs.actionAuthority == rhs.actionAuthority
            && lhs.assignmentID != rhs.assignmentID
    }

    private static func changesOnlyDeclaredDimension(
        _ lhs: MetacognitiveCalibrationArm,
        _ rhs: MetacognitiveCalibrationArm
    ) -> Bool {
        let pairs: [(MetacognitiveCalibrationDimension, String, String)] = [
            (.deliberationDepth, lhs.selection.deliberation, rhs.selection.deliberation),
            (.readOnlyToolUse, lhs.selection.toolPosture, rhs.selection.toolPosture),
            (.contextBreadth, lhs.selection.contextPosture, rhs.selection.contextPosture),
            (.reasoningEffort, lhs.selection.reasoningEffort, rhs.selection.reasoningEffort),
            (.askOrAnswer, lhs.selection.responsePosture, rhs.selection.responsePosture),
            (.waitOrRetry, lhs.selection.operationalPosture, rhs.selection.operationalPosture),
        ]
        guard pairs.first(where: { $0.0 == lhs.dimension }).map({ $0.1 != $0.2 }) == true else {
            return false
        }
        return pairs.allSatisfy { dimension, left, right in
            dimension == lhs.dimension || left == right
        }
    }

    private static func selectionTokens(_ value: MetacognitiveCalibrationSelection) -> Bool {
        [value.deliberation, value.toolPosture, value.contextPosture, value.reasoningEffort,
         value.responsePosture, value.operationalPosture].allSatisfy { token($0, maximum: 64) }
    }

    private static func token(_ raw: String, maximum: Int) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:"))
        return !raw.isEmpty && raw.count <= maximum
            && raw.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func digest(_ raw: String) -> Bool {
        raw.count == 64 && raw.allSatisfy { $0.isHexDigit }
    }

    private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

/// Deterministic generated mechanism evidence. It exercises the paired
/// evaluator and all dimensions without claiming anything about a real model,
/// person, provider, or production benefit.
public enum MetacognitiveGeneratedCalibrationLaboratory {
    public static func generate(seed: UInt64, pairCount: Int = 500) -> [MetacognitiveCalibrationArm] {
        var generator = Generator(state: seed)
        let dimensions = MetacognitiveCalibrationDimension.allCases
        let baseTime = Date(timeIntervalSince1970: 1_783_915_200) // 2026-07-13 UTC
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var rows: [MetacognitiveCalibrationArm] = []
        rows.reserveCapacity(max(0, pairCount) * 2)
        for index in 0..<max(0, pairCount) {
            let dimension = dimensions[index % dimensions.count]
            let pairID = "generated-pair-\(seed)-\(index)"
            let scenarioID = "generated-scenario-\(index % 48)"
            let assignedAt = baseTime.addingTimeInterval(Double(index * 2))
            let observedAt = assignedAt.addingTimeInterval(1)
            let baselineSelection = selection(dimension: dimension, candidate: false)
            let candidateSelection = selection(dimension: dimension, candidate: true)
            let baselineScore = 650 + Int(generator.next() % 121)
            let candidateDelta = Int(generator.next() % 101) - 35
            let candidateScore = min(1_000, max(0, baselineScore + candidateDelta))
            let controls = digest("frozen|\(seed)|\(index)")
            func arm(
                _ kind: MetacognitiveCalibrationArm.Arm,
                _ selection: MetacognitiveCalibrationSelection,
                score: Int,
                candidate: Bool
            ) -> MetacognitiveCalibrationArm {
                MetacognitiveCalibrationArm(
                    pairID: pairID,
                    assignmentID: "generated-assignment-\(seed)-\(index)-\(kind.rawValue)",
                    arm: kind,
                    dimension: dimension,
                    evidenceClass: .generatedMechanism,
                    scenarioFamily: "generated_\(dimension.rawValue)",
                    scenarioID: scenarioID,
                    taskClass: "generated_task_\((index / dimensions.count) % 6)",
                    provider: "generated",
                    model: "mechanism-oracle",
                    frozenMindDigest: controls,
                    promptDigest: digest("prompt|\(seed)|\(index)"),
                    contextDigest: digest("context|\(seed)|\(index)"),
                    toolSetDigest: digest("tools|\(seed)|\(index)"),
                    trustPosture: "generated_no_authority",
                    actionAuthority: "none",
                    assignedAt: formatter.string(from: assignedAt),
                    observedAt: formatter.string(from: observedAt),
                    selection: selection,
                    outcome: MetacognitiveCalibrationOutcome(
                        rubricScorePermille: score,
                        calibrationBrierPermille: candidate ? 185 : 200,
                        verifiedCompletion: score >= 600,
                        falseCompletion: false,
                        authorityError: false,
                        explicitCorrection: score < 550,
                        latencyMs: max(1, 1_200 + (candidate ? Int(generator.next() % 500) - 250 : 0)),
                        providerCalls: 1,
                        tokenUsage: max(1, 2_000 + (candidate ? Int(generator.next() % 601) - 300 : 0)),
                        toolFailures: 0,
                        eligibleContextUsed: dimension == .contextBreadth ? candidate : nil
                    )
                )
            }
            rows.append(arm(.baseline, baselineSelection, score: baselineScore, candidate: false))
            rows.append(arm(.candidate, candidateSelection, score: candidateScore, candidate: true))
        }
        return rows
    }

    private static func selection(
        dimension: MetacognitiveCalibrationDimension,
        candidate: Bool
    ) -> MetacognitiveCalibrationSelection {
        MetacognitiveCalibrationSelection(
            deliberation: dimension == .deliberationDepth && candidate ? "deep" : "direct",
            toolPosture: dimension == .readOnlyToolUse && candidate ? "read_only" : "none",
            contextPosture: dimension == .contextBreadth && candidate ? "expanded" : "compact",
            reasoningEffort: dimension == .reasoningEffort && candidate ? "high" : "medium",
            responsePosture: dimension == .askOrAnswer && candidate ? "ask" : "answer",
            operationalPosture: dimension == .waitOrRetry && candidate ? "wait" : "retry"
        )
    }

    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = 6_364_136_223_846_793_005 &* state &+ 1_442_695_040_888_963_407
            return state
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
