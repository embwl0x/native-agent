import Foundation

/// Evidence class is explicit so an accelerated clock can never be reported as
/// an elapsed installed soak. Production records use `installedElapsed`; tests
/// and time-compressed laboratories use `generatedAccelerated`.
public enum InstalledPhysiologyEvidenceClass: String, Codable, Sendable, Equatable {
    case installedElapsed = "installed_elapsed"
    case generatedAccelerated = "generated_accelerated"
}

public enum InstalledPhysiologyEventKind: String, Codable, Sendable, Equatable {
    case runtimeStarted = "runtime_started"
    case runtimeStopped = "runtime_stopped"
    case cognitiveEventAccepted = "cognitive_event_accepted"
    case microcycleScheduled = "microcycle_scheduled"
    case microcycleFinished = "microcycle_finished"
    case residualDeadlineArmed = "residual_deadline_armed"
    case residualDeadlineFired = "residual_deadline_fired"
    case recorderLoss = "recorder_loss"
}

/// Closed, payload-free classification of the cognition traffic represented by
/// an admission or microcycle row. The app maps its authoritative
/// `CognitiveTurnKind` into this persistence vocabulary; the evidence store
/// does not infer workload class from reasons or prose.
public enum InstalledPhysiologyTurnClass: String, Codable, Sendable, Equatable {
    case live
    case system
    case debug
    case verification

    /// Lived chat and canonical system work both exercise production resident
    /// physiology. Debug/verification traffic remains visible but cannot make
    /// that path look fast.
    public var qualifiesForResidentLatency: Bool {
        self == .live || self == .system
    }

    /// A live user/assistant turn is the only population allowed to certify
    /// ordinary-chat admission and settlement latency.
    public var qualifiesForOrdinaryTurnLatency: Bool { self == .live }
}

/// Cumulative process counters sampled only when real physiology already has
/// work to record. Reading these counters creates no timer or heartbeat.
public struct InstalledPhysiologyProcessSample: Codable, Sendable, Equatable {
    public let systemUptimeSeconds: Double
    public let userCPUSeconds: Double
    public let systemCPUSeconds: Double
    public let interruptWakeups: UInt64
    public let packageIdleWakeups: UInt64
    /// Optional for backward decoding of evidence written before sampler
    /// availability was recorded. A missing value is deliberately not proof
    /// that the native counter boundary succeeded.
    public let cpuCountersAvailable: Bool?
    public let wakeCountersAvailable: Bool?

    public init(
        systemUptimeSeconds: Double,
        userCPUSeconds: Double,
        systemCPUSeconds: Double,
        interruptWakeups: UInt64,
        packageIdleWakeups: UInt64,
        cpuCountersAvailable: Bool? = true,
        wakeCountersAvailable: Bool? = true
    ) {
        self.systemUptimeSeconds = Self.nonnegative(systemUptimeSeconds)
        self.userCPUSeconds = Self.nonnegative(userCPUSeconds)
        self.systemCPUSeconds = Self.nonnegative(systemCPUSeconds)
        self.interruptWakeups = interruptWakeups
        self.packageIdleWakeups = packageIdleWakeups
        self.cpuCountersAvailable = cpuCountersAvailable
        self.wakeCountersAvailable = wakeCountersAvailable
    }

    private static func nonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}

/// One payload-free installed-body receipt. It never stores a prompt, response,
/// user identifier, session identifier, tool payload, provider output, or path.
public struct InstalledPhysiologySoakRecord: Codable, Sendable, Equatable {
    public static let schema = "installed-physiology-soak.v1"
    /// Bump only when the measured architecture or timing boundary changes in
    /// a way that makes earlier latency populations non-comparable. Old rows
    /// remain retained; a fresh runtime-start row opens the new claim window.
    public static let currentMeasurementEpoch = "resident-live-latency-v3"

    public let schema: String
    public let measurementEpoch: String?
    public let evidenceClass: InstalledPhysiologyEvidenceClass
    public let simulated: Bool
    public let eventID: String
    public let runtimeInstanceID: String
    public let processIdentifier: Int32
    public let sequence: UInt64
    public let kind: InstalledPhysiologyEventKind
    public let recordedAt: Date
    public let reason: String?
    /// Nil only for legacy rows and event kinds without a cognition workload.
    /// Current cognitive admission/schedule/finish rows always carry the exact
    /// app-owned class.
    public let turnClass: InstalledPhysiologyTurnClass?
    public let correlationDigestSHA256: String?
    public let scheduledSignalCount: UInt64?
    public let executedMicrocycleCount: UInt64?
    public let eventAcceptanceMilliseconds: Double?
    /// Diagnostic decomposition of event admission. These are observational
    /// only and let an installed soak locate a regression without adding a
    /// sampler, timer, or control path.
    public let cognitiveSubstrateAcceptanceMilliseconds: Double?
    public let somaticAcceptanceMilliseconds: Double?
    public let residualSchedulingAcceptanceMilliseconds: Double?
    /// Duration of the completed cognition microcycle itself. Kept separate
    /// from event acceptance so a slow settlement cannot inflate ingress
    /// latency. Older v1 rows may have stored this value in
    /// `eventAcceptanceMilliseconds`; the analyzer recognizes that shape only
    /// for `microcycle_finished` rows.
    public let microcycleExecutionMilliseconds: Double?
    public let chatTurnLatencyMilliseconds: Double?
    public let scheduledDeadlineAt: Date?
    public let deadlineErrorMilliseconds: Double?
    public let residualWasDue: Bool?
    public let localRepairPerformed: Bool?
    public let operationalConsolidationPerformed: Bool?
    /// Explicit backpressure evidence. A saturated in-memory recorder emits a
    /// bounded loss receipt instead of silently pretending every row survived.
    public let droppedRecordCount: UInt64?
    public let process: InstalledPhysiologyProcessSample
    public let controlAuthority: Bool

    public init(
        evidenceClass: InstalledPhysiologyEvidenceClass,
        measurementEpoch: String? = Self.currentMeasurementEpoch,
        eventID: String,
        runtimeInstanceID: String,
        processIdentifier: Int32,
        sequence: UInt64,
        kind: InstalledPhysiologyEventKind,
        recordedAt: Date,
        reason: String? = nil,
        turnClass: InstalledPhysiologyTurnClass? = nil,
        correlationDigestSHA256: String? = nil,
        scheduledSignalCount: UInt64? = nil,
        executedMicrocycleCount: UInt64? = nil,
        eventAcceptanceMilliseconds: Double? = nil,
        cognitiveSubstrateAcceptanceMilliseconds: Double? = nil,
        somaticAcceptanceMilliseconds: Double? = nil,
        residualSchedulingAcceptanceMilliseconds: Double? = nil,
        microcycleExecutionMilliseconds: Double? = nil,
        chatTurnLatencyMilliseconds: Double? = nil,
        scheduledDeadlineAt: Date? = nil,
        deadlineErrorMilliseconds: Double? = nil,
        residualWasDue: Bool? = nil,
        localRepairPerformed: Bool? = nil,
        operationalConsolidationPerformed: Bool? = nil,
        droppedRecordCount: UInt64? = nil,
        process: InstalledPhysiologyProcessSample,
        controlAuthority: Bool = false
    ) {
        self.schema = Self.schema
        self.measurementEpoch = measurementEpoch.map { String($0.prefix(96)) }
        self.evidenceClass = evidenceClass
        self.simulated = evidenceClass != .installedElapsed
        self.eventID = String(eventID.prefix(96))
        self.runtimeInstanceID = String(runtimeInstanceID.prefix(96))
        self.processIdentifier = processIdentifier
        self.sequence = sequence
        self.kind = kind
        self.recordedAt = recordedAt
        self.reason = reason.map { String($0.prefix(160)) }
        self.turnClass = turnClass
        self.correlationDigestSHA256 = correlationDigestSHA256
        self.scheduledSignalCount = scheduledSignalCount
        self.executedMicrocycleCount = executedMicrocycleCount
        self.eventAcceptanceMilliseconds = Self.optionalNonnegative(eventAcceptanceMilliseconds)
        self.cognitiveSubstrateAcceptanceMilliseconds = Self.optionalNonnegative(
            cognitiveSubstrateAcceptanceMilliseconds
        )
        self.somaticAcceptanceMilliseconds = Self.optionalNonnegative(somaticAcceptanceMilliseconds)
        self.residualSchedulingAcceptanceMilliseconds = Self.optionalNonnegative(
            residualSchedulingAcceptanceMilliseconds
        )
        self.microcycleExecutionMilliseconds = Self.optionalNonnegative(microcycleExecutionMilliseconds)
        self.chatTurnLatencyMilliseconds = Self.optionalNonnegative(chatTurnLatencyMilliseconds)
        self.scheduledDeadlineAt = scheduledDeadlineAt
        self.deadlineErrorMilliseconds = deadlineErrorMilliseconds.flatMap {
            $0.isFinite ? min(86_400_000, max(-86_400_000, $0)) : nil
        }
        self.residualWasDue = residualWasDue
        self.localRepairPerformed = localRepairPerformed
        self.operationalConsolidationPerformed = operationalConsolidationPerformed
        self.droppedRecordCount = droppedRecordCount
        self.process = process
        self.controlAuthority = controlAuthority
    }

    public var isStructurallyValid: Bool {
        schema == Self.schema
            && !eventID.isEmpty
            && !runtimeInstanceID.isEmpty
            && sequence > 0
            && !controlAuthority
            && simulated == (evidenceClass != .installedElapsed)
            && correlationDigestSHA256.map(Self.isSHA256) != false
            && (kind != .recorderLoss || (droppedRecordCount ?? 0) > 0)
            && (measurementEpoch != Self.currentMeasurementEpoch
                || !Self.requiresTurnClass(kind)
                || turnClass != nil)
    }

    private static func requiresTurnClass(_ kind: InstalledPhysiologyEventKind) -> Bool {
        switch kind {
        case .cognitiveEventAccepted, .microcycleScheduled, .microcycleFinished:
            true
        case .runtimeStarted, .runtimeStopped, .residualDeadlineArmed,
             .residualDeadlineFired, .recorderLoss:
            false
        }
    }

    private static func optionalNonnegative(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? min(1_000_000_000, max(0, $0)) : nil }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

public struct InstalledPhysiologySoakReport: Codable, Sendable, Equatable {
    public static let schema = "installed-physiology-soak-report.v1"

    public let schema: String
    public let generatedAt: Date
    public let evidenceClasses: [InstalledPhysiologyEvidenceClass]
    public let recordCount: Int
    /// Older rows remain durably retained, but instrumentation written before
    /// native counter availability or the current measurement contract cannot
    /// poison a corrected 72-hour soak for the full retention window. Only a
    /// later compatible `runtime_started` receipt may establish this boundary.
    public let counterCompatibleEpochStartedAt: Date?
    /// Exact measurement contract represented by the retained claim window.
    /// Nil means only legacy/generated rows were available.
    public let measurementEpoch: String?
    public let ignoredPreCounterEpochRecordCount: Int
    public let malformedOrInvalidRecordCount: Int
    public let retentionSaturatedFileCount: Int
    public let firstRecordedAt: Date?
    public let lastRecordedAt: Date?
    public let elapsedSeconds: TimeInterval
    public let elapsedUTCDayCount: Int
    public let runtimeSessionCount: Int
    public let cleanStopCount: Int
    public let uncleanRestartCount: Int
    public let sequenceGapCount: Int
    public let recorderDroppedRecordCount: UInt64
    public let acceptedCognitiveEventCount: Int
    public let microcycleWakeCount: Int
    public let residentAcceptanceSampleCount: Int
    public let residentMicrocycleSampleCount: Int
    public let ordinaryTurnAcceptanceSampleCount: Int
    public let ordinaryTurnMicrocycleSampleCount: Int
    public let excludedDiagnosticAcceptanceCount: Int
    public let excludedDiagnosticMicrocycleCount: Int
    public let unexpectedMicrocycleWakeCount: Int
    public let residualDeadlineFireCount: Int
    public let residualDueFireCount: Int
    public let residualRepairCount: Int
    public let chatTurnCount: Int
    public let chatLatencyP95Milliseconds: Double?
    public let cognitiveAcceptanceP95Milliseconds: Double?
    public let microcycleExecutionP95Milliseconds: Double?
    public let ordinaryTurnAcceptanceP95Milliseconds: Double?
    public let ordinaryTurnMicrocycleP95Milliseconds: Double?
    public let deadlineAbsoluteErrorP95Milliseconds: Double?
    /// Whole-process CPU averaged over naturally bounded quiescent intervals
    /// (at least one minute between consecutive physiology receipts). No sampler
    /// wakes were added to obtain this value.
    public let quiescentObservationSeconds: TimeInterval
    public let quiescentAverageCPUPercent: Double?
    public let quiescentWakeupsPerHour: Double?
    public let realMultiDayClaimEligible: Bool
    public let claimBlockers: [String]

    public init(
        generatedAt: Date,
        evidenceClasses: [InstalledPhysiologyEvidenceClass],
        recordCount: Int,
        counterCompatibleEpochStartedAt: Date?,
        measurementEpoch: String?,
        ignoredPreCounterEpochRecordCount: Int,
        malformedOrInvalidRecordCount: Int,
        retentionSaturatedFileCount: Int,
        firstRecordedAt: Date?,
        lastRecordedAt: Date?,
        elapsedSeconds: TimeInterval,
        elapsedUTCDayCount: Int,
        runtimeSessionCount: Int,
        cleanStopCount: Int,
        uncleanRestartCount: Int,
        sequenceGapCount: Int,
        recorderDroppedRecordCount: UInt64,
        acceptedCognitiveEventCount: Int,
        microcycleWakeCount: Int,
        residentAcceptanceSampleCount: Int,
        residentMicrocycleSampleCount: Int,
        ordinaryTurnAcceptanceSampleCount: Int,
        ordinaryTurnMicrocycleSampleCount: Int,
        excludedDiagnosticAcceptanceCount: Int,
        excludedDiagnosticMicrocycleCount: Int,
        unexpectedMicrocycleWakeCount: Int,
        residualDeadlineFireCount: Int,
        residualDueFireCount: Int,
        residualRepairCount: Int,
        chatTurnCount: Int,
        chatLatencyP95Milliseconds: Double?,
        cognitiveAcceptanceP95Milliseconds: Double?,
        microcycleExecutionP95Milliseconds: Double?,
        ordinaryTurnAcceptanceP95Milliseconds: Double?,
        ordinaryTurnMicrocycleP95Milliseconds: Double?,
        deadlineAbsoluteErrorP95Milliseconds: Double?,
        quiescentObservationSeconds: TimeInterval,
        quiescentAverageCPUPercent: Double?,
        quiescentWakeupsPerHour: Double?,
        realMultiDayClaimEligible: Bool,
        claimBlockers: [String]
    ) {
        self.schema = Self.schema
        self.generatedAt = generatedAt
        self.evidenceClasses = evidenceClasses
        self.recordCount = recordCount
        self.counterCompatibleEpochStartedAt = counterCompatibleEpochStartedAt
        self.measurementEpoch = measurementEpoch
        self.ignoredPreCounterEpochRecordCount = ignoredPreCounterEpochRecordCount
        self.malformedOrInvalidRecordCount = malformedOrInvalidRecordCount
        self.retentionSaturatedFileCount = retentionSaturatedFileCount
        self.firstRecordedAt = firstRecordedAt
        self.lastRecordedAt = lastRecordedAt
        self.elapsedSeconds = elapsedSeconds
        self.elapsedUTCDayCount = elapsedUTCDayCount
        self.runtimeSessionCount = runtimeSessionCount
        self.cleanStopCount = cleanStopCount
        self.uncleanRestartCount = uncleanRestartCount
        self.sequenceGapCount = sequenceGapCount
        self.recorderDroppedRecordCount = recorderDroppedRecordCount
        self.acceptedCognitiveEventCount = acceptedCognitiveEventCount
        self.microcycleWakeCount = microcycleWakeCount
        self.residentAcceptanceSampleCount = residentAcceptanceSampleCount
        self.residentMicrocycleSampleCount = residentMicrocycleSampleCount
        self.ordinaryTurnAcceptanceSampleCount = ordinaryTurnAcceptanceSampleCount
        self.ordinaryTurnMicrocycleSampleCount = ordinaryTurnMicrocycleSampleCount
        self.excludedDiagnosticAcceptanceCount = excludedDiagnosticAcceptanceCount
        self.excludedDiagnosticMicrocycleCount = excludedDiagnosticMicrocycleCount
        self.unexpectedMicrocycleWakeCount = unexpectedMicrocycleWakeCount
        self.residualDeadlineFireCount = residualDeadlineFireCount
        self.residualDueFireCount = residualDueFireCount
        self.residualRepairCount = residualRepairCount
        self.chatTurnCount = chatTurnCount
        self.chatLatencyP95Milliseconds = chatLatencyP95Milliseconds
        self.cognitiveAcceptanceP95Milliseconds = cognitiveAcceptanceP95Milliseconds
        self.microcycleExecutionP95Milliseconds = microcycleExecutionP95Milliseconds
        self.ordinaryTurnAcceptanceP95Milliseconds = ordinaryTurnAcceptanceP95Milliseconds
        self.ordinaryTurnMicrocycleP95Milliseconds = ordinaryTurnMicrocycleP95Milliseconds
        self.deadlineAbsoluteErrorP95Milliseconds = deadlineAbsoluteErrorP95Milliseconds
        self.quiescentObservationSeconds = quiescentObservationSeconds
        self.quiescentAverageCPUPercent = quiescentAverageCPUPercent
        self.quiescentWakeupsPerHour = quiescentWakeupsPerHour
        self.realMultiDayClaimEligible = realMultiDayClaimEligible
        self.claimBlockers = claimBlockers
    }

    /// App-side recorder liveness can fail independently of the durable rows
    /// already readable from disk. Preserve every measured field while making
    /// that incomplete evidence incapable of qualifying.
    public func addingClaimBlocker(_ blocker: String) -> Self {
        let bounded = String(blocker.prefix(200))
        let blockers = claimBlockers.contains(bounded) ? claimBlockers : claimBlockers + [bounded]
        return Self(
            generatedAt: generatedAt,
            evidenceClasses: evidenceClasses,
            recordCount: recordCount,
            counterCompatibleEpochStartedAt: counterCompatibleEpochStartedAt,
            measurementEpoch: measurementEpoch,
            ignoredPreCounterEpochRecordCount: ignoredPreCounterEpochRecordCount,
            malformedOrInvalidRecordCount: malformedOrInvalidRecordCount,
            retentionSaturatedFileCount: retentionSaturatedFileCount,
            firstRecordedAt: firstRecordedAt,
            lastRecordedAt: lastRecordedAt,
            elapsedSeconds: elapsedSeconds,
            elapsedUTCDayCount: elapsedUTCDayCount,
            runtimeSessionCount: runtimeSessionCount,
            cleanStopCount: cleanStopCount,
            uncleanRestartCount: uncleanRestartCount,
            sequenceGapCount: sequenceGapCount,
            recorderDroppedRecordCount: recorderDroppedRecordCount,
            acceptedCognitiveEventCount: acceptedCognitiveEventCount,
            microcycleWakeCount: microcycleWakeCount,
            residentAcceptanceSampleCount: residentAcceptanceSampleCount,
            residentMicrocycleSampleCount: residentMicrocycleSampleCount,
            ordinaryTurnAcceptanceSampleCount: ordinaryTurnAcceptanceSampleCount,
            ordinaryTurnMicrocycleSampleCount: ordinaryTurnMicrocycleSampleCount,
            excludedDiagnosticAcceptanceCount: excludedDiagnosticAcceptanceCount,
            excludedDiagnosticMicrocycleCount: excludedDiagnosticMicrocycleCount,
            unexpectedMicrocycleWakeCount: unexpectedMicrocycleWakeCount,
            residualDeadlineFireCount: residualDeadlineFireCount,
            residualDueFireCount: residualDueFireCount,
            residualRepairCount: residualRepairCount,
            chatTurnCount: chatTurnCount,
            chatLatencyP95Milliseconds: chatLatencyP95Milliseconds,
            cognitiveAcceptanceP95Milliseconds: cognitiveAcceptanceP95Milliseconds,
            microcycleExecutionP95Milliseconds: microcycleExecutionP95Milliseconds,
            ordinaryTurnAcceptanceP95Milliseconds: ordinaryTurnAcceptanceP95Milliseconds,
            ordinaryTurnMicrocycleP95Milliseconds: ordinaryTurnMicrocycleP95Milliseconds,
            deadlineAbsoluteErrorP95Milliseconds: deadlineAbsoluteErrorP95Milliseconds,
            quiescentObservationSeconds: quiescentObservationSeconds,
            quiescentAverageCPUPercent: quiescentAverageCPUPercent,
            quiescentWakeupsPerHour: quiescentWakeupsPerHour,
            realMultiDayClaimEligible: false,
            claimBlockers: blockers
        )
    }
}

/// Pure, payload-free analyzer. Generated time remains useful for mechanism
/// tests but can never satisfy the real multi-day acceptance predicate.
public enum InstalledPhysiologySoakAnalyzer {
    /// A nearest-rank p95 needs at least 20 observations before one sample can
    /// occupy the upper five-percent tail. Fewer rows may still be displayed,
    /// but cannot qualify a longitudinal architecture claim.
    public static let minimumLatencySampleCount = 20
    public static let maximumQuiescentAverageCPUPercent = 0.5
    public static let maximumQuiescentWakeupsPerHour = 18_000.0

    public static func analyze(
        records rawRecords: [InstalledPhysiologySoakRecord],
        malformedOrInvalidRecordCount: Int = 0,
        retentionSaturatedFileCount: Int = 0,
        generatedAt: Date = Date()
    ) -> InstalledPhysiologySoakReport {
        let retainedRecords = rawRecords.filter(\.isStructurallyValid).sorted {
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
            if $0.runtimeInstanceID != $1.runtimeInstanceID {
                return $0.runtimeInstanceID < $1.runtimeInstanceID
            }
            return $0.sequence < $1.sequence
        }
        let epoch = counterCompatibleEpoch(in: retainedRecords)
        let records = epoch.records
        let invalidCount = malformedOrInvalidRecordCount + (rawRecords.count - retainedRecords.count)
        let firstAt = records.first?.recordedAt
        let lastAt = records.last?.recordedAt
        let elapsed = max(0, lastAt?.timeIntervalSince(firstAt ?? lastAt ?? generatedAt) ?? 0)
        let classes = Array(Set(records.map(\.evidenceClass))).sorted { $0.rawValue < $1.rawValue }
        let sessions = Dictionary(grouping: records, by: \.runtimeInstanceID)
        var sequenceGaps = 0
        var cleanStops = 0
        var uncleanRestarts = 0
        var unexpectedWakes = 0
        var quiescentSeconds = 0.0
        var quiescentCPUSeconds = 0.0
        var quiescentWakeups: UInt64 = 0

        let currentOpenSessionID = sessions
            .filter { $0.value.last?.kind != .runtimeStopped }
            .max { lhs, rhs in
                (lhs.value.map(\.recordedAt).max() ?? .distantPast)
                    < (rhs.value.map(\.recordedAt).max() ?? .distantPast)
            }?.key
        for (sessionID, rows) in sessions {
            let ordered = rows.sorted { $0.sequence < $1.sequence }
            // A retained suffix is not a complete runtime session. Requiring
            // the first receipt and sequence boundary prevents daily/global
            // caps from silently converting truncated evidence into proof.
            if let first = ordered.first,
               first.sequence != 1 || first.kind != .runtimeStarted {
                sequenceGaps += 1
            }
            if ordered.last?.kind == .runtimeStopped { cleanStops += 1 }
            else if !ordered.isEmpty, sessionID != currentOpenSessionID { uncleanRestarts += 1 }
            for pair in zip(ordered, ordered.dropFirst()) {
                if pair.1.sequence != pair.0.sequence + 1 { sequenceGaps += 1 }
                let uptime = pair.1.process.systemUptimeSeconds - pair.0.process.systemUptimeSeconds
                // CPU and wake counters are process-monotonic, so their
                // denominator must be the same monotonic clock. A forward wall
                // clock correction must not manufacture hours of quiescence or
                // dilute measured CPU/wake rates.
                if uptime.isFinite, uptime >= 60,
                   pair.1.process.userCPUSeconds >= pair.0.process.userCPUSeconds,
                   pair.1.process.systemCPUSeconds >= pair.0.process.systemCPUSeconds,
                   pair.1.process.interruptWakeups >= pair.0.process.interruptWakeups,
                   pair.1.process.packageIdleWakeups >= pair.0.process.packageIdleWakeups {
                    quiescentSeconds += uptime
                    quiescentCPUSeconds += (pair.1.process.userCPUSeconds - pair.0.process.userCPUSeconds)
                        + (pair.1.process.systemCPUSeconds - pair.0.process.systemCPUSeconds)
                    quiescentWakeups += (pair.1.process.interruptWakeups - pair.0.process.interruptWakeups)
                        + (pair.1.process.packageIdleWakeups - pair.0.process.packageIdleWakeups)
                }
            }
            // Bind every finish to one exact, preceding schedule generation.
            // A cumulative schedule from an old burst cannot authorize an
            // arbitrary number of later finishes.
            var pendingScheduleCounts: [UInt64: Int] = [:]
            for row in ordered {
                if row.kind == .microcycleScheduled,
                   let count = row.scheduledSignalCount {
                    pendingScheduleCounts[count, default: 0] += 1
                } else if row.kind == .microcycleFinished {
                    guard let count = row.scheduledSignalCount,
                          let pending = pendingScheduleCounts[count],
                          pending > 0 else {
                        unexpectedWakes += 1
                        continue
                    }
                    if pending == 1 { pendingScheduleCounts.removeValue(forKey: count) }
                    else { pendingScheduleCounts[count] = pending - 1 }
                }
            }
        }

        let calendar = Calendar(identifier: .iso8601)
        let utc = TimeZone(secondsFromGMT: 0)!
        let utcDays = Set(records.map {
            var components = calendar.dateComponents(in: utc, from: $0.recordedAt)
            components.hour = nil; components.minute = nil; components.second = nil; components.nanosecond = nil
            return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
        })
        let chatLatencies = records.compactMap(\.chatTurnLatencyMilliseconds)
        // A v1 recorder bug wrote microcycle duration into the event-acceptance
        // field. Kind filtering keeps those durable legacy rows from corrupting
        // ingress latency while retaining their duration as microcycle evidence.
        let acceptedEventRows = records.filter { $0.kind == .cognitiveEventAccepted }
        let microcycleFinishRows = records.filter { $0.kind == .microcycleFinished }
        let residentAcceptanceRows = acceptedEventRows.filter {
            $0.turnClass?.qualifiesForResidentLatency == true
        }
        let residentMicrocycleRows = microcycleFinishRows.filter {
            $0.turnClass?.qualifiesForResidentLatency == true
        }
        let ordinaryAcceptanceRows = acceptedEventRows.filter {
            $0.turnClass?.qualifiesForOrdinaryTurnLatency == true
        }
        let ordinaryMicrocycleRows = microcycleFinishRows.filter {
            $0.turnClass?.qualifiesForOrdinaryTurnLatency == true
        }
        let acceptanceLatencies = residentAcceptanceRows
            .compactMap(\.eventAcceptanceMilliseconds)
        let microcycleExecutionLatencies = residentMicrocycleRows
            .compactMap { $0.microcycleExecutionMilliseconds ?? $0.eventAcceptanceMilliseconds }
        let ordinaryAcceptanceLatencies = ordinaryAcceptanceRows
            .compactMap(\.eventAcceptanceMilliseconds)
        let ordinaryMicrocycleLatencies = ordinaryMicrocycleRows
            .compactMap { $0.microcycleExecutionMilliseconds ?? $0.eventAcceptanceMilliseconds }
        let deadlineErrors = records.compactMap(\.deadlineErrorMilliseconds).map(abs)
        let deadlineRows = records.filter { $0.kind == .residualDeadlineFired }
        let recorderDrops = records.reduce(UInt64(0)) { partial, row in
            partial &+ (row.droppedRecordCount ?? 0)
        }
        let installedOnly = classes == [.installedElapsed]
        let installedSamplerCountersComplete = records
            .filter { $0.evidenceClass == .installedElapsed }
            .allSatisfy {
                $0.process.cpuCountersAvailable == true
                    && $0.process.wakeCountersAvailable == true
            }

        var blockers: [String] = []
        if !installedOnly { blockers.append("evidence is generated, mixed, or absent") }
        if installedOnly, epoch.startedAt == nil {
            blockers.append("compatible current measurement runtime start is missing")
        }
        if installedOnly, !installedSamplerCountersComplete {
            blockers.append("native process physiology counters were unavailable")
        }
        if elapsed < 3 * 24 * 60 * 60 { blockers.append("less than 72 elapsed wall-clock hours") }
        if utcDays.count < 3 { blockers.append("fewer than three UTC calendar days") }
        if invalidCount > 0 { blockers.append("malformed or invalid evidence exists") }
        if retentionSaturatedFileCount > 0 { blockers.append("retention capacity was saturated") }
        if sequenceGaps > 0 { blockers.append("append sequence gaps exist") }
        if recorderDrops > 0 { blockers.append("recorder backpressure dropped evidence") }
        if uncleanRestarts > 0 { blockers.append("unclean runtime restarts exist") }
        if unexpectedWakes > 0 { blockers.append("unexpected microcycle wakes exist") }
        if quiescentSeconds < 24 * 60 * 60 { blockers.append("less than 24 hours of bounded quiescent observation") }
        // These are architecture budgets, not claims that whole-process CPU or
        // wake counts belong to cognition. CPU/wakes require a matched baseline;
        // the two directly instrumented cognition latencies can fail the soak
        // on their own and must never be report-only decoration.
        let acceptanceP95 = percentile95(acceptanceLatencies)
        let microcycleP95 = percentile95(microcycleExecutionLatencies)
        let ordinaryAcceptanceP95 = percentile95(ordinaryAcceptanceLatencies)
        let ordinaryMicrocycleP95 = percentile95(ordinaryMicrocycleLatencies)
        let quiescentCPUPercent = quiescentSeconds > 0
            ? (quiescentCPUSeconds / quiescentSeconds) * 100 : nil
        let quiescentWakeRate = quiescentSeconds > 0
            ? Double(quiescentWakeups) * 3_600 / quiescentSeconds : nil
        if let quiescentCPUPercent,
           quiescentCPUPercent >= maximumQuiescentAverageCPUPercent {
            blockers.append("quiescent process CPU does not meet <0.5 percent")
        }
        if let quiescentWakeRate,
           quiescentWakeRate >= maximumQuiescentWakeupsPerHour {
            blockers.append("quiescent process wake rate does not meet <18000 per hour")
        }
        if installedOnly, acceptanceLatencies.count < minimumLatencySampleCount {
            blockers.append("fewer than 20 production resident acceptance latency samples")
        }
        if installedOnly, microcycleExecutionLatencies.count < minimumLatencySampleCount {
            blockers.append("fewer than 20 production resident microcycle latency samples")
        }
        if installedOnly, ordinaryAcceptanceLatencies.count < minimumLatencySampleCount {
            blockers.append("fewer than 20 ordinary-turn acceptance latency samples")
        }
        if installedOnly, ordinaryMicrocycleLatencies.count < minimumLatencySampleCount {
            blockers.append("fewer than 20 ordinary-turn microcycle latency samples")
        }
        if installedOnly, chatLatencies.count < minimumLatencySampleCount {
            blockers.append("fewer than 20 ordinary chat latency samples")
        }
        if let acceptanceP95, acceptanceP95 >= 25 {
            blockers.append("production resident acceptance p95 does not meet <25 ms")
        }
        if let microcycleP95, microcycleP95 >= 25 {
            blockers.append("production resident microcycle p95 does not meet <25 ms")
        }
        if let ordinaryAcceptanceP95, ordinaryAcceptanceP95 >= 25 {
            blockers.append("ordinary-turn acceptance p95 does not meet <25 ms")
        }
        if let ordinaryMicrocycleP95, ordinaryMicrocycleP95 >= 25 {
            blockers.append("ordinary-turn microcycle p95 does not meet <25 ms")
        }

        return InstalledPhysiologySoakReport(
            generatedAt: generatedAt,
            evidenceClasses: classes,
            recordCount: records.count,
            counterCompatibleEpochStartedAt: epoch.startedAt,
            measurementEpoch: epoch.measurementEpoch,
            ignoredPreCounterEpochRecordCount: epoch.ignoredRecordCount,
            malformedOrInvalidRecordCount: invalidCount,
            retentionSaturatedFileCount: retentionSaturatedFileCount,
            firstRecordedAt: firstAt,
            lastRecordedAt: lastAt,
            elapsedSeconds: elapsed,
            elapsedUTCDayCount: utcDays.count,
            runtimeSessionCount: sessions.count,
            cleanStopCount: cleanStops,
            uncleanRestartCount: uncleanRestarts,
            sequenceGapCount: sequenceGaps,
            recorderDroppedRecordCount: recorderDrops,
            acceptedCognitiveEventCount: acceptedEventRows.count,
            microcycleWakeCount: microcycleFinishRows.count,
            residentAcceptanceSampleCount: acceptanceLatencies.count,
            residentMicrocycleSampleCount: microcycleExecutionLatencies.count,
            ordinaryTurnAcceptanceSampleCount: ordinaryAcceptanceLatencies.count,
            ordinaryTurnMicrocycleSampleCount: ordinaryMicrocycleLatencies.count,
            excludedDiagnosticAcceptanceCount: acceptedEventRows.count - residentAcceptanceRows.count,
            excludedDiagnosticMicrocycleCount: microcycleFinishRows.count - residentMicrocycleRows.count,
            unexpectedMicrocycleWakeCount: unexpectedWakes,
            residualDeadlineFireCount: deadlineRows.count,
            residualDueFireCount: deadlineRows.filter { $0.residualWasDue == true }.count,
            residualRepairCount: deadlineRows.filter {
                $0.localRepairPerformed == true || $0.operationalConsolidationPerformed == true
            }.count,
            chatTurnCount: chatLatencies.count,
            chatLatencyP95Milliseconds: percentile95(chatLatencies),
            cognitiveAcceptanceP95Milliseconds: acceptanceP95,
            microcycleExecutionP95Milliseconds: microcycleP95,
            ordinaryTurnAcceptanceP95Milliseconds: ordinaryAcceptanceP95,
            ordinaryTurnMicrocycleP95Milliseconds: ordinaryMicrocycleP95,
            deadlineAbsoluteErrorP95Milliseconds: percentile95(deadlineErrors),
            quiescentObservationSeconds: quiescentSeconds,
            quiescentAverageCPUPercent: quiescentCPUPercent,
            quiescentWakeupsPerHour: quiescentWakeRate,
            realMultiDayClaimEligible: blockers.isEmpty,
            claimBlockers: blockers
        )
    }

    private static func percentile95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[max(0, index)]
    }

    private struct CounterCompatibleEpoch {
        let records: [InstalledPhysiologySoakRecord]
        let startedAt: Date?
        let ignoredRecordCount: Int
        let measurementEpoch: String?
    }

    /// Selects a new claim window only after a fresh installed runtime proves
    /// both native counter families and the current measurement contract. A
    /// later compatible sample in the same old runtime is insufficient:
    /// restart identity is the fail-closed instrumentation boundary.
    private static func counterCompatibleEpoch(
        in records: [InstalledPhysiologySoakRecord]
    ) -> CounterCompatibleEpoch {
        let lastIncompatibleIndex = records.lastIndex(where: {
            $0.evidenceClass == .installedElapsed
                && ($0.measurementEpoch != InstalledPhysiologySoakRecord.currentMeasurementEpoch
                    || $0.process.cpuCountersAvailable != true
                    || $0.process.wakeCountersAvailable != true)
        })
        guard records.contains(where: { $0.evidenceClass == .installedElapsed }) else {
            return CounterCompatibleEpoch(
                records: records,
                startedAt: nil,
                ignoredRecordCount: 0,
                measurementEpoch: records.last?.measurementEpoch
            )
        }

        let candidateStart = records.indices.first(where: { index in
            index > (lastIncompatibleIndex ?? -1)
                && records[index].evidenceClass == .installedElapsed
                && records[index].kind == .runtimeStarted
                && records[index].measurementEpoch == InstalledPhysiologySoakRecord.currentMeasurementEpoch
                && records[index].process.cpuCountersAvailable == true
                && records[index].process.wakeCountersAvailable == true
        })
        guard let candidateStart else {
            return CounterCompatibleEpoch(
                records: records,
                startedAt: nil,
                ignoredRecordCount: 0,
                measurementEpoch: records.last?.measurementEpoch
            )
        }

        return CounterCompatibleEpoch(
            records: Array(records[candidateStart...]),
            startedAt: records[candidateStart].recordedAt,
            ignoredRecordCount: candidateStart,
            measurementEpoch: records[candidateStart].measurementEpoch
        )
    }
}

/// Bounded JSONL persistence for installed soak evidence. The store never owns
/// a scheduler. Callers append only when a runtime event or exact deadline
/// already caused work.
public actor InstalledPhysiologySoakStore {
    public static let maximumRowsPerDay = 4_096
    public static let maximumReadRows = 32_768
    public static let maximumRetainedDayFiles = 31

    private let root: URL
    private let persistence: any PersistenceCoreProtocol

    public init(
        dataRoot: URL,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) {
        self.root = dataRoot
            .appendingPathComponent("evals", isDirectory: true)
            .appendingPathComponent("installed_physiology_soak", isDirectory: true)
        self.persistence = persistence
    }

    public func append(_ record: InstalledPhysiologySoakRecord) async throws {
        try await append([record])
    }

    /// Appends one coalesced recorder transaction with at most one physical
    /// write per UTC-day file. Production uses this path so a burst of somatic
    /// signals is not converted into a write-per-signal tax.
    public func append(_ records: [InstalledPhysiologySoakRecord]) async throws {
        guard records.allSatisfy(\.isStructurallyValid) else {
            throw InstalledPhysiologySoakStoreError.invalidRecord
        }
        guard !records.isEmpty else { return }
        let encoder = JSONEncoder()
        for rows in Dictionary(grouping: records, by: { dayPath(for: $0.recordedAt) }) {
            let path = rows.key
            let values = try rows.value.map { try JSONValue.parse(encoder.encode($0)) }
            try await persistence.withFileLock(path) {
                if let native = persistence as? SwiftNativePersistenceCore {
                    try await native.appendJSONL(values, to: path)
                } else {
                    for value in values { try await persistence.appendJSONL(value, to: path) }
                }
                let dropped = try enforceJSONLLineCap(
                    at: path,
                    maxLines: Self.maximumRowsPerDay,
                    trimWhenBytesExceed: 2 * 1_024 * 1_024
                )
                if dropped > 0 {
                    // Trimming is expected bounded retention, but never silent:
                    // the analyzer will also reject the retained suffix because
                    // it no longer begins at runtime sequence one.
                    NSLog(
                        "InstalledPhysiologySoakStore: retained cap removed %d rows from %@",
                        dropped,
                        path.lastPathComponent
                    )
                }
            }
        }
        pruneOldDayFiles()
    }

    public func loadReport(now: Date = Date()) async -> InstalledPhysiologySoakReport {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return InstalledPhysiologySoakAnalyzer.analyze(records: [], generatedAt: now)
        }
        var records: [InstalledPhysiologySoakRecord] = []
        var invalid = 0
        var retentionSaturatedFiles = 0
        let decoder = JSONDecoder()
        // Read newest retained evidence first. If the global read cap is hit,
        // the report describes current installed behavior rather than an old
        // prefix that happened to sort first.
        for file in files.filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else {
                invalid += 1
                continue
            }
            let lines = text.split(separator: "\n")
            if lines.count >= Self.maximumRowsPerDay {
                // A cap-sized file may have lost a partial or whole runtime
                // session. Sequence-one checks cannot detect whole-session
                // loss, so capacity itself is conservative loss evidence.
                retentionSaturatedFiles += 1
            }
            for line in lines {
                guard records.count < Self.maximumReadRows else { break }
                do {
                    let record = try decoder.decode(InstalledPhysiologySoakRecord.self, from: Data(line.utf8))
                    if record.isStructurallyValid { records.append(record) }
                    else { invalid += 1 }
                } catch {
                    invalid += 1
                }
            }
        }
        if records.count >= Self.maximumReadRows {
            retentionSaturatedFiles += 1
        }
        return InstalledPhysiologySoakAnalyzer.analyze(
            records: records,
            malformedOrInvalidRecordCount: invalid,
            retentionSaturatedFileCount: retentionSaturatedFiles,
            generatedAt: now
        )
    }

    private func dayPath(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return root.appendingPathComponent("\(formatter.string(from: date)).jsonl")
    }

    private func pruneOldDayFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let dayFiles = files.filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in dayFiles.dropFirst(Self.maximumRetainedDayFiles) {
            try? fm.removeItem(at: stale)
        }
    }
}

public enum InstalledPhysiologySoakStoreError: String, Error, Sendable, Equatable {
    case invalidRecord = "invalid_record"
}
