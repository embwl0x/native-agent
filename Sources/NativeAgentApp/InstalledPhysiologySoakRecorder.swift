import CryptoKit
import Darwin
import Foundation
import CognitiveSubstrate
import PersistenceCore

/// App-owned evidence recorder for real installed physiology. It owns no timer:
/// rows are enqueued only by launch/termination, sensory events, microcycle
/// transitions, or exact residual deadlines that already occurred.
actor InstalledPhysiologySoakRecorder {
    typealias ProcessSampler = @Sendable () -> InstalledPhysiologyProcessSample

    private let runtimeInstanceID: String
    private let processIdentifier: Int32
    private let evidenceClass: InstalledPhysiologyEvidenceClass
    private let now: @Sendable () -> Date
    private let processSampler: ProcessSampler
    private let store: InstalledPhysiologySoakStore
    private let coalescingDelayNanoseconds: UInt64
    private let flushDrainDeadlineNanoseconds: UInt64
    private var sequence: UInt64 = 0
    private var pending: [InstalledPhysiologySoakRecord] = []
    private var drainTask: Task<Void, Never>?
    private var drainInProgress = false
    private var droppedByBackpressure: UInt64 = 0
    private var consecutiveWriteFailures = 0
    private var lastWriteError: String?
    private var chatStartedAtByRunDigest: [String: Date] = [:]
    private var chatRunOrder: [String] = []
    private var lastArmedResidualDeadline: Date?
    private static let maximumPendingChatRuns = 64
    static let maximumPendingRecords = 256
    static let defaultCoalescingDelayNanoseconds: UInt64 = 250_000_000
    static let defaultFlushDrainDeadlineNanoseconds: UInt64 = 5_000_000_000
    static let maximumAutomaticWriteRetries = 5

    init(
        dataRoot: URL,
        runtimeInstanceID: String,
        evidenceClass: InstalledPhysiologyEvidenceClass = .installedElapsed,
        now: @escaping @Sendable () -> Date = { Date() },
        processSampler: @escaping ProcessSampler = { InstalledProcessPhysiologySampler.sample() },
        store: InstalledPhysiologySoakStore? = nil,
        coalescingDelayNanoseconds: UInt64 = InstalledPhysiologySoakRecorder.defaultCoalescingDelayNanoseconds,
        flushDrainDeadlineNanoseconds: UInt64 = InstalledPhysiologySoakRecorder.defaultFlushDrainDeadlineNanoseconds
    ) {
        self.runtimeInstanceID = runtimeInstanceID
        self.processIdentifier = ProcessInfo.processInfo.processIdentifier
        self.evidenceClass = evidenceClass
        self.now = now
        self.processSampler = processSampler
        self.store = store ?? InstalledPhysiologySoakStore(dataRoot: dataRoot)
        self.coalescingDelayNanoseconds = coalescingDelayNanoseconds
        self.flushDrainDeadlineNanoseconds = min(
            flushDrainDeadlineNanoseconds,
            60_000_000_000
        )
    }

    func recordRuntimeStarted(reason: String?) {
        enqueue(kind: .runtimeStarted, reason: reason)
    }

    func recordRuntimeStopped(reason: String?) {
        enqueue(kind: .runtimeStopped, reason: reason)
    }

    func recordCognitiveEvent(
        _ event: CognitiveEvent,
        scheduledSignalCount: UInt64,
        acceptanceMilliseconds: Double,
        cognitiveSubstrateMilliseconds: Double? = nil,
        somaticMilliseconds: Double? = nil,
        residualSchedulingMilliseconds: Double? = nil
    ) {
        let runDigest = Self.runDigest(event)
        var chatLatency: Double?
        if event.turnKind == .live, let runDigest {
            switch event.kind {
            case .userMessageReceived:
                // A retried/duplicated ingress for the same run must not move
                // the start forward and make the measured latency look lower.
                if chatStartedAtByRunDigest[runDigest] == nil {
                    chatStartedAtByRunDigest[runDigest] = event.occurredAt
                    chatRunOrder.append(runDigest)
                }
                while chatRunOrder.count > Self.maximumPendingChatRuns {
                    let stale = chatRunOrder.removeFirst()
                    chatStartedAtByRunDigest.removeValue(forKey: stale)
                }
            case .assistantTurnCompleted:
                // Provider failure can be an intermediate retry. End-to-end
                // chat latency closes only when the assistant turn completes;
                // a terminal failure remains honestly unmeasured here.
                if let started = chatStartedAtByRunDigest.removeValue(forKey: runDigest) {
                    chatRunOrder.removeAll { $0 == runDigest }
                    let duration = event.occurredAt.timeIntervalSince(started) * 1_000
                    if duration.isFinite, duration >= 0 { chatLatency = duration }
                }
            default:
                break
            }
        }
        enqueue(
            kind: .cognitiveEventAccepted,
            reason: event.kind.rawValue,
            turnClass: Self.physiologyTurnClass(event.turnKind),
            correlationDigestSHA256: Self.digest("event|\(event.id)"),
            scheduledSignalCount: scheduledSignalCount,
            eventAcceptanceMilliseconds: acceptanceMilliseconds,
            cognitiveSubstrateAcceptanceMilliseconds: cognitiveSubstrateMilliseconds,
            somaticAcceptanceMilliseconds: somaticMilliseconds,
            residualSchedulingAcceptanceMilliseconds: residualSchedulingMilliseconds,
            chatTurnLatencyMilliseconds: chatLatency
        )
    }

    func recordMicrocycleScheduled(_ telemetry: CognitiveMicrocycleTelemetry) {
        enqueue(
            kind: .microcycleScheduled,
            reason: telemetry.lastReason,
            turnClass: telemetry.lastTurnClass,
            scheduledSignalCount: telemetry.scheduledSignalCount,
            executedMicrocycleCount: telemetry.executedCount
        )
    }

    func recordMicrocycleFinished(_ telemetry: CognitiveMicrocycleTelemetry) {
        enqueue(
            kind: .microcycleFinished,
            reason: telemetry.lastOutcome,
            turnClass: telemetry.lastTurnClass,
            scheduledSignalCount: telemetry.scheduledSignalCount,
            executedMicrocycleCount: telemetry.executedCount,
            microcycleExecutionMilliseconds: telemetry.lastDurationMilliseconds.map(Double.init)
        )
    }

    func recordResidualDeadlineArmed(
        deadline: Date?,
        opportunity: OrganismResidualRepairOpportunity
    ) {
        guard deadline != lastArmedResidualDeadline else { return }
        lastArmedResidualDeadline = deadline
        guard let deadline else { return }
        enqueue(
            kind: .residualDeadlineArmed,
            reason: "residual_or_prediction_deadline",
            correlationDigestSHA256: Self.digest(
                "residual|\(opportunity.evidenceGeneration)|\(deadline.timeIntervalSince1970)"
            ),
            scheduledDeadlineAt: deadline,
            residualWasDue: opportunity.ready
        )
    }

    func recordResidualDeadlineFired(
        scheduledAt: Date,
        firedAt: Date,
        wasDue: Bool,
        localRepairPerformed: Bool,
        operationalConsolidationPerformed: Bool
    ) {
        if lastArmedResidualDeadline == scheduledAt { lastArmedResidualDeadline = nil }
        enqueue(
            kind: .residualDeadlineFired,
            reason: wasDue ? "due" : "revalidated_not_due",
            correlationDigestSHA256: Self.digest("deadline|\(scheduledAt.timeIntervalSince1970)"),
            scheduledDeadlineAt: scheduledAt,
            deadlineErrorMilliseconds: firedAt.timeIntervalSince(scheduledAt) * 1_000,
            residualWasDue: wasDue,
            localRepairPerformed: localRepairPerformed,
            operationalConsolidationPerformed: operationalConsolidationPerformed
        )
    }

    func report() async -> InstalledPhysiologySoakReport {
        let drained = await flush()
        let report = await store.loadReport(now: now())
        return drained
            ? report
            : report.addingClaimBlocker("physiology recorder durability barrier did not complete")
    }

    func diagnostics() -> (pending: Int, dropped: UInt64, lastError: String?) {
        (pending.count, droppedByBackpressure, lastWriteError)
    }

    @discardableResult
    func flush() async -> Bool {
        drainTask?.cancel()
        drainTask = nil
        let deadline = DispatchTime.now().uptimeNanoseconds &+ flushDrainDeadlineNanoseconds
        while drainInProgress {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                lastWriteError = "physiology durability barrier timed out with persistence in flight"
                return false
            }
            try? await Task.sleep(nanoseconds: min(5_000_000, flushDrainDeadlineNanoseconds))
        }
        // A report or clean termination is an explicit durability barrier,
        // not another background retry heartbeat. Give the pending batch one
        // fresh bounded synchronous retry budget, then stop quiet if storage
        // is still unavailable. Diagnostics retain the unsaved count/error.
        if !pending.isEmpty || droppedByBackpressure > 0 {
            consecutiveWriteFailures = 0
        }
        var attempts = 0
        while (!pending.isEmpty || droppedByBackpressure > 0),
              attempts < Self.maximumAutomaticWriteRetries {
            drainTask?.cancel()
            drainTask = nil
            await drainBufferedRecords()
            attempts += 1
        }
        drainTask?.cancel()
        drainTask = nil
        let complete = !drainInProgress && pending.isEmpty && droppedByBackpressure == 0
        if !complete, lastWriteError == nil {
            lastWriteError = "physiology durability barrier exhausted its bounded retry budget"
        }
        return complete
    }

    private func enqueue(
        kind: InstalledPhysiologyEventKind,
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
        operationalConsolidationPerformed: Bool? = nil
    ) {
        guard pending.count < Self.maximumPendingRecords else {
            droppedByBackpressure &+= 1
            // The full buffer may be retained from an exhausted failure
            // budget. A new event is a meaningful signal to re-open that
            // bounded budget rather than leaving evidence wedged until exit.
            scheduleCoalescedDrainIfNeeded(resetFailureBudget: true)
            return
        }
        sequence &+= 1
        pending.append(InstalledPhysiologySoakRecord(
            evidenceClass: evidenceClass,
            eventID: UUID().uuidString.lowercased(),
            runtimeInstanceID: runtimeInstanceID,
            processIdentifier: processIdentifier,
            sequence: sequence,
            kind: kind,
            recordedAt: now(),
            reason: reason,
            turnClass: turnClass,
            correlationDigestSHA256: correlationDigestSHA256,
            scheduledSignalCount: scheduledSignalCount,
            executedMicrocycleCount: executedMicrocycleCount,
            eventAcceptanceMilliseconds: eventAcceptanceMilliseconds,
            cognitiveSubstrateAcceptanceMilliseconds: cognitiveSubstrateAcceptanceMilliseconds,
            somaticAcceptanceMilliseconds: somaticAcceptanceMilliseconds,
            residualSchedulingAcceptanceMilliseconds: residualSchedulingAcceptanceMilliseconds,
            microcycleExecutionMilliseconds: microcycleExecutionMilliseconds,
            chatTurnLatencyMilliseconds: chatTurnLatencyMilliseconds,
            scheduledDeadlineAt: scheduledDeadlineAt,
            deadlineErrorMilliseconds: deadlineErrorMilliseconds,
            residualWasDue: residualWasDue,
            localRepairPerformed: localRepairPerformed,
            operationalConsolidationPerformed: operationalConsolidationPerformed,
            process: processSampler()
        ))
        scheduleCoalescedDrainIfNeeded(resetFailureBudget: true)
    }

    private func scheduleCoalescedDrainIfNeeded(resetFailureBudget: Bool = false) {
        if resetFailureBudget,
           consecutiveWriteFailures >= Self.maximumAutomaticWriteRetries {
            consecutiveWriteFailures = 0
        }
        guard drainTask == nil, !drainInProgress else { return }
        let multiplier = UInt64(1 << min(consecutiveWriteFailures, 7))
        let delay = min(30_000_000_000, coalescingDelayNanoseconds &* multiplier)
        drainTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.drainBufferedRecords()
        }
    }

    private func drainBufferedRecords() async {
        guard !drainInProgress else { return }
        drainInProgress = true
        drainTask = nil
        var appendFailed = false
        defer {
            drainInProgress = false
            let unsaved = !pending.isEmpty || droppedByBackpressure > 0
            if unsaved,
               !appendFailed || consecutiveWriteFailures < Self.maximumAutomaticWriteRetries {
                scheduleCoalescedDrainIfNeeded()
            }
        }
        while !pending.isEmpty || droppedByBackpressure > 0 {
            if droppedByBackpressure > 0 {
                let dropped = droppedByBackpressure
                droppedByBackpressure = 0
                sequence &+= 1
                pending.append(InstalledPhysiologySoakRecord(
                    evidenceClass: evidenceClass,
                    eventID: UUID().uuidString.lowercased(),
                    runtimeInstanceID: runtimeInstanceID,
                    processIdentifier: processIdentifier,
                    sequence: sequence,
                    kind: .recorderLoss,
                    recordedAt: now(),
                    reason: "bounded_buffer_backpressure",
                    droppedRecordCount: dropped,
                    process: processSampler()
                ))
            }
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            do {
                try await store.append(batch)
                lastWriteError = nil
                consecutiveWriteFailures = 0
            } catch {
                appendFailed = true
                consecutiveWriteFailures += 1
                lastWriteError = String(String(describing: error).prefix(240))
                // Preserve order and exact sequence across transient failures.
                // A later event or termination flush retries the same batch.
                pending.insert(contentsOf: batch, at: 0)
                return
            }
        }
    }

    private static func runDigest(_ event: CognitiveEvent) -> String? {
        guard case .string(let raw)? = event.metadata["runId"] else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : digest("run|\(value)")
    }

    /// Canonical `CognitiveTurnKind` → `InstalledPhysiologyTurnClass` projection.
    /// Internal so `NativeCognitionRuntime` shares this exhaustive switch instead
    /// of keeping a drift-prone private copy (C10a).
    static func physiologyTurnClass(
        _ turnKind: CognitiveTurnKind
    ) -> InstalledPhysiologyTurnClass {
        switch turnKind {
        case .live: .live
        case .system: .system
        case .debug: .debug
        case .verification: .verification
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum InstalledProcessPhysiologySampler {
    static func sample() -> InstalledPhysiologyProcessSample {
        var userSeconds = 0.0
        var systemSeconds = 0.0
        var interruptWakeups: UInt64 = 0
        var packageIdleWakeups: UInt64 = 0
        var cpuCountersAvailable = false
        var wakeCountersAvailable = false

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<rusage_info_v4>.size,
            alignment: MemoryLayout<rusage_info_v4>.alignment
        )
        defer { raw.deallocate() }
        raw.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: MemoryLayout<rusage_info_v4>.size
        )
        // `rusage_info_t` is a C `void *`, but `proc_pid_rusage` declares its
        // buffer as `rusage_info_t *`. The API still writes the requested
        // structure directly into the storage at that address. Passing the
        // address of a Swift pointer variable here would therefore overwrite
        // that small stack variable with `rusage_info_v4` and trip the stack
        // protector. Rebind the allocated structure storage itself instead.
        let buffer = raw.assumingMemoryBound(
            to: Optional<UnsafeMutableRawPointer>.self
        )
        if proc_pid_rusage(getpid(), RUSAGE_INFO_V4, buffer) == 0 {
            let info = raw.load(as: rusage_info_v4.self)
            userSeconds = Double(info.ri_user_time) / 1_000_000_000
            systemSeconds = Double(info.ri_system_time) / 1_000_000_000
            interruptWakeups = info.ri_interrupt_wkups
            packageIdleWakeups = info.ri_pkg_idle_wkups
            cpuCountersAvailable = true
            wakeCountersAvailable = true
        } else {
            var usage = rusage()
            if getrusage(RUSAGE_SELF, &usage) == 0 {
                userSeconds = Double(usage.ru_utime.tv_sec)
                    + Double(usage.ru_utime.tv_usec) / 1_000_000
                systemSeconds = Double(usage.ru_stime.tv_sec)
                    + Double(usage.ru_stime.tv_usec) / 1_000_000
                cpuCountersAvailable = true
            }
        }
        return InstalledPhysiologyProcessSample(
            systemUptimeSeconds: ProcessInfo.processInfo.systemUptime,
            userCPUSeconds: userSeconds,
            systemCPUSeconds: systemSeconds,
            interruptWakeups: interruptWakeups,
            packageIdleWakeups: packageIdleWakeups,
            cpuCountersAvailable: cpuCountersAvailable,
            wakeCountersAvailable: wakeCountersAvailable
        )
    }
}
