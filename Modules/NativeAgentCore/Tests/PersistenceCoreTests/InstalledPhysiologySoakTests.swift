import Foundation
import Testing
@testable import PersistenceCore

@Suite("Installed physiology soak evidence")
struct InstalledPhysiologySoakTests {
    @Test("generated accelerated days can never satisfy installed elapsed claim")
    func generatedTimeCannotClaimInstalledSoak() {
        let rows = proofRows(evidenceClass: .generatedAccelerated)
        let report = InstalledPhysiologySoakAnalyzer.analyze(
            records: rows,
            generatedAt: rows.last!.recordedAt
        )

        #expect(report.elapsedSeconds > 3 * 24 * 60 * 60)
        #expect(report.elapsedUTCDayCount >= 3)
        #expect(!report.realMultiDayClaimEligible)
        #expect(report.claimBlockers.contains("evidence is generated, mixed, or absent"))
    }

    @Test("clean installed evidence qualifies while an open current session is not a crash")
    func installedEvidenceEligibility() {
        let rows = proofRows(evidenceClass: .installedElapsed)
        let report = InstalledPhysiologySoakAnalyzer.analyze(
            records: rows,
            generatedAt: rows.last!.recordedAt
        )

        #expect(report.realMultiDayClaimEligible)
        #expect(report.uncleanRestartCount == 0)
        #expect(report.quiescentObservationSeconds > 3 * 24 * 60 * 60)
        #expect(report.recorderDroppedRecordCount == 0)
    }

    @Test("resident latency alone cannot qualify without ordinary chat observations")
    func ordinaryChatSamplesAreRequiredSeparately() {
        let rows = proofRows(evidenceClass: .installedElapsed, includeChatLatency: false)
        let report = InstalledPhysiologySoakAnalyzer.analyze(records: rows)

        #expect(report.chatTurnCount == 0)
        #expect(report.claimBlockers.contains("fewer than 20 ordinary chat latency samples"))
        #expect(!report.realMultiDayClaimEligible)
    }

    @Test("sequence gaps and explicit recorder loss block the claim")
    func sequenceAndBackpressureLossAreVisible() {
        var rows = proofRows(evidenceClass: .installedElapsed)
        rows.remove(at: 2)
        let last = rows.last!
        rows.append(record(
            evidenceClass: .installedElapsed,
            runtime: "runtime-a",
            sequence: last.sequence + 1,
            kind: .recorderLoss,
            at: last.recordedAt.addingTimeInterval(1),
            uptime: last.process.systemUptimeSeconds + 1,
            cpu: last.process.userCPUSeconds + 0.001,
            dropped: 17
        ))
        let report = InstalledPhysiologySoakAnalyzer.analyze(records: rows)

        #expect(report.sequenceGapCount > 0)
        #expect(report.recorderDroppedRecordCount == 17)
        #expect(!report.realMultiDayClaimEligible)
        #expect(report.claimBlockers.contains("recorder backpressure dropped evidence"))
    }

    @Test("store rotates old UTC day files and reads the newest retained window")
    func boundedDayRotation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("installed-soak-rotation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InstalledPhysiologySoakStore(dataRoot: root)
        let start = Date(timeIntervalSince1970: 1_900_000_000)

        for day in 0..<(InstalledPhysiologySoakStore.maximumRetainedDayFiles + 2) {
            try await store.append(record(
                evidenceClass: .generatedAccelerated,
                runtime: "rotation",
                sequence: UInt64(day + 1),
                kind: day == 0 ? .runtimeStarted : .cognitiveEventAccepted,
                at: start.addingTimeInterval(Double(day) * 86_400),
                uptime: Double(day) * 86_400,
                cpu: Double(day) * 0.01
            ))
        }

        let directory = root
            .appendingPathComponent("evals", isDirectory: true)
            .appendingPathComponent("installed_physiology_soak", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        let report = await store.loadReport(now: start.addingTimeInterval(40 * 86_400))

        #expect(files.count == InstalledPhysiologySoakStore.maximumRetainedDayFiles)
        #expect(report.recordCount == InstalledPhysiologySoakStore.maximumRetainedDayFiles)
        #expect(report.firstRecordedAt == start.addingTimeInterval(2 * 86_400))
    }

    @Test("wall clock jumps cannot manufacture quiescent CPU evidence")
    func quiescenceUsesMonotonicUptime() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var rows: [InstalledPhysiologySoakRecord] = []
        rows.reserveCapacity(5)
        for index in 0..<5 {
            let row = record(
                evidenceClass: .installedElapsed,
                runtime: "wall-jump",
                sequence: UInt64(index + 1),
                kind: index == 0 ? .runtimeStarted : .cognitiveEventAccepted,
                at: start.addingTimeInterval(Double(index) * 86_400),
                uptime: Double(index),
                cpu: Double(index) * 0.01
            )
            rows.append(row)
        }
        let report = InstalledPhysiologySoakAnalyzer.analyze(records: rows)
        #expect(report.elapsedSeconds > 3 * 24 * 60 * 60)
        #expect(report.quiescentObservationSeconds == 0)
        #expect(!report.realMultiDayClaimEligible)
        #expect(report.claimBlockers.contains("less than 24 hours of bounded quiescent observation"))
    }

    @Test("missing native CPU or wake counters cannot qualify installed evidence")
    func unavailableNativeCountersBlockInstalledClaim() {
        var rows = proofRows(evidenceClass: .installedElapsed)
        let index = rows.firstIndex { $0.kind == .cognitiveEventAccepted }!
        let original = rows[index]
        rows[index] = record(
            evidenceClass: .installedElapsed,
            runtime: original.runtimeInstanceID,
            sequence: original.sequence,
            kind: original.kind,
            at: original.recordedAt,
            uptime: original.process.systemUptimeSeconds,
            cpu: original.process.userCPUSeconds,
            cpuCountersAvailable: true,
            wakeCountersAvailable: false
        )
        let report = InstalledPhysiologySoakAnalyzer.analyze(records: rows)

        #expect(!report.realMultiDayClaimEligible)
        #expect(report.claimBlockers.contains("native process physiology counters were unavailable"))
    }

    @Test("a counter-complete runtime start opens a new claim epoch without deleting legacy rows")
    func counterCompatibleRuntimeStartsNewClaimEpoch() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var legacy: [InstalledPhysiologySoakRecord] = []
        for index in 0..<3 {
            legacy.append(record(
                evidenceClass: .installedElapsed,
                runtime: "legacy-runtime",
                sequence: UInt64(index + 1),
                kind: index == 0 ? .runtimeStarted : .cognitiveEventAccepted,
                at: start.addingTimeInterval(Double(index) * 60),
                uptime: Double(index) * 60,
                cpu: Double(index) * 0.01,
                cpuCountersAvailable: nil,
                wakeCountersAvailable: nil
            ))
        }
        let epochStart = start.addingTimeInterval(86_400)
        let compatible = proofRows(
            evidenceClass: .installedElapsed,
            start: epochStart,
            runtime: "compatible-runtime"
        )

        let report = InstalledPhysiologySoakAnalyzer.analyze(records: legacy + compatible)

        #expect(report.realMultiDayClaimEligible)
        #expect(report.recordCount == compatible.count)
        #expect(report.counterCompatibleEpochStartedAt == epochStart)
        #expect(report.ignoredPreCounterEpochRecordCount == legacy.count)
        #expect(!report.claimBlockers.contains("native process physiology counters were unavailable"))
    }

    @Test("complete samples cannot repair an incompatible runtime without a fresh start")
    func counterEpochRequiresFreshRuntimeStart() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var rows = proofRows(evidenceClass: .installedElapsed)
        rows[0] = record(
            evidenceClass: .installedElapsed,
            runtime: "runtime-a",
            sequence: 1,
            kind: .runtimeStarted,
            at: start,
            uptime: 0,
            cpu: 0,
            cpuCountersAvailable: nil,
            wakeCountersAvailable: nil
        )

        let report = InstalledPhysiologySoakAnalyzer.analyze(records: rows)

        #expect(!report.realMultiDayClaimEligible)
        #expect(report.counterCompatibleEpochStartedAt == nil)
        #expect(report.ignoredPreCounterEpochRecordCount == 0)
        #expect(report.claimBlockers.contains("native process physiology counters were unavailable"))
        #expect(report.claimBlockers.contains("compatible current measurement runtime start is missing"))
    }

    @Test("counter-complete installed rows without a runtime start fail closed")
    func installedEvidenceRequiresRuntimeStart() {
        let rows = Array(proofRows(evidenceClass: .installedElapsed).dropFirst())
        let report = InstalledPhysiologySoakAnalyzer.analyze(records: rows)

        #expect(!report.realMultiDayClaimEligible)
        #expect(report.counterCompatibleEpochStartedAt == nil)
        #expect(report.sequenceGapCount > 0)
        #expect(report.claimBlockers.contains("compatible current measurement runtime start is missing"))
        #expect(report.claimBlockers.contains("append sequence gaps exist"))
    }

    @Test("one old schedule cannot authorize repeated or mismatched finishes")
    func microcycleFinishesConsumeExactScheduleGeneration() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "wake-binding",
                sequence: 1,
                kind: .runtimeStarted,
                at: start,
                uptime: 0,
                cpu: 0
            ),
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "wake-binding",
                sequence: 2,
                kind: .microcycleScheduled,
                at: start.addingTimeInterval(1),
                uptime: 1,
                cpu: 0,
                scheduledSignalCount: 7
            ),
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "wake-binding",
                sequence: 3,
                kind: .microcycleFinished,
                at: start.addingTimeInterval(2),
                uptime: 2,
                cpu: 0,
                scheduledSignalCount: 7,
                executedMicrocycleCount: 1
            ),
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "wake-binding",
                sequence: 4,
                kind: .microcycleFinished,
                at: start.addingTimeInterval(3),
                uptime: 3,
                cpu: 0,
                scheduledSignalCount: 7,
                executedMicrocycleCount: 2
            ),
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "wake-binding",
                sequence: 5,
                kind: .microcycleFinished,
                at: start.addingTimeInterval(4),
                uptime: 4,
                cpu: 0,
                scheduledSignalCount: 8,
                executedMicrocycleCount: 3
            ),
        ]

        let report = InstalledPhysiologySoakAnalyzer.analyze(records: rows)
        #expect(report.unexpectedMicrocycleWakeCount == 2)
        #expect(report.claimBlockers.contains("unexpected microcycle wakes exist"))
    }

    @Test("daily retention trimming cannot qualify a retained suffix")
    func dailyRetentionTrimFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("installed-soak-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InstalledPhysiologySoakStore(dataRoot: root)
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let count = InstalledPhysiologySoakStore.maximumRowsPerDay + 1
        var rows: [InstalledPhysiologySoakRecord] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            rows.append(record(
                evidenceClass: .installedElapsed,
                runtime: "trimmed-runtime",
                sequence: UInt64(index + 1),
                kind: index == 0 ? .runtimeStarted : .cognitiveEventAccepted,
                at: start.addingTimeInterval(Double(index)),
                uptime: Double(index),
                cpu: Double(index) * 0.0001
            ))
        }

        try await store.append(rows)
        let report = await store.loadReport(now: start.addingTimeInterval(Double(count)))

        #expect(report.recordCount == InstalledPhysiologySoakStore.maximumRowsPerDay)
        #expect(!report.realMultiDayClaimEligible)
        #expect(report.counterCompatibleEpochStartedAt == nil)
        #expect(report.sequenceGapCount > 0)
        #expect(report.retentionSaturatedFileCount == 1)
        #expect(report.claimBlockers.contains("retention capacity was saturated"))
        #expect(report.claimBlockers.contains("compatible current measurement runtime start is missing"))
    }

    @Test("whole-session retention loss is visible even when the retained session starts at sequence one")
    func wholeSessionRetentionTrimFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("installed-soak-whole-session-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InstalledPhysiologySoakStore(dataRoot: root)
        let start = Date(timeIntervalSince1970: 1_900_100_000)
        var rows = [record(
            evidenceClass: .installedElapsed,
            runtime: "fully-trimmed-runtime",
            sequence: 1,
            kind: .runtimeStarted,
            at: start,
            uptime: 0,
            cpu: 0
        )]
        for index in 0..<InstalledPhysiologySoakStore.maximumRowsPerDay {
            rows.append(record(
                evidenceClass: .installedElapsed,
                runtime: "retained-runtime",
                sequence: UInt64(index + 1),
                kind: index == 0 ? .runtimeStarted : .cognitiveEventAccepted,
                at: start.addingTimeInterval(Double(index + 1)),
                uptime: Double(index + 1),
                cpu: Double(index + 1) * 0.0001,
                eventAcceptanceMilliseconds: index == 0 ? nil : 4
            ))
        }

        try await store.append(rows)
        let report = await store.loadReport(now: start.addingTimeInterval(5_000))

        #expect(report.recordCount == InstalledPhysiologySoakStore.maximumRowsPerDay)
        #expect(report.runtimeSessionCount == 1)
        #expect(report.sequenceGapCount == 0)
        #expect(report.counterCompatibleEpochStartedAt == start.addingTimeInterval(1))
        #expect(report.retentionSaturatedFileCount == 1)
        #expect(report.claimBlockers.contains("retention capacity was saturated"))
        #expect(!report.realMultiDayClaimEligible)
    }

    @Test("gross quiescent CPU and wake regressions block a multi-day claim")
    func quiescentResourceBudgetsAreEligibilityGates() {
        var rows = proofRows(evidenceClass: .installedElapsed)
        let index = rows.indices.last!
        let original = rows[index]
        rows[index] = record(
            evidenceClass: original.evidenceClass,
            runtime: original.runtimeInstanceID,
            sequence: original.sequence,
            kind: original.kind,
            at: original.recordedAt,
            uptime: original.process.systemUptimeSeconds,
            cpu: 10_000,
            microcycleExecutionMilliseconds: original.microcycleExecutionMilliseconds,
            scheduledSignalCount: original.scheduledSignalCount,
            executedMicrocycleCount: original.executedMicrocycleCount,
            turnClass: original.turnClass,
            interruptWakeups: 2_000_000,
            packageIdleWakeups: 2_000_000
        )

        let report = InstalledPhysiologySoakAnalyzer.analyze(records: rows)

        #expect(report.claimBlockers.contains("quiescent process CPU does not meet <0.5 percent"))
        #expect(report.claimBlockers.contains("quiescent process wake rate does not meet <18000 per hour"))
        #expect(!report.realMultiDayClaimEligible)
    }

    @Test("a new measurement epoch excludes old latency populations without deleting evidence")
    func measurementEpochStartsComparableClaimWindow() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = [
            record(
                evidenceClass: .installedElapsed,
                runtime: "legacy-latency",
                sequence: 1,
                kind: .runtimeStarted,
                at: start,
                uptime: 0,
                cpu: 0,
                measurementEpoch: nil
            ),
            record(
                evidenceClass: .installedElapsed,
                runtime: "legacy-latency",
                sequence: 2,
                kind: .cognitiveEventAccepted,
                at: start.addingTimeInterval(1),
                uptime: 1,
                cpu: 0.001,
                eventAcceptanceMilliseconds: 500,
                measurementEpoch: nil
            ),
            record(
                evidenceClass: .installedElapsed,
                runtime: "legacy-latency",
                sequence: 3,
                kind: .microcycleFinished,
                at: start.addingTimeInterval(2),
                uptime: 2,
                cpu: 0.002,
                microcycleExecutionMilliseconds: 700,
                measurementEpoch: nil
            ),
        ]
        let epochStart = start.addingTimeInterval(86_400)
        let current = proofRows(
            evidenceClass: .installedElapsed,
            start: epochStart,
            runtime: "current-latency"
        )

        let report = InstalledPhysiologySoakAnalyzer.analyze(records: legacy + current)

        #expect(report.recordCount == current.count)
        #expect(report.ignoredPreCounterEpochRecordCount == legacy.count)
        #expect(report.counterCompatibleEpochStartedAt == epochStart)
        #expect(report.measurementEpoch == InstalledPhysiologySoakRecord.currentMeasurementEpoch)
        #expect(report.cognitiveAcceptanceP95Milliseconds == 4)
        #expect(report.microcycleExecutionP95Milliseconds == 7)
    }

    @Test("event acceptance and microcycle execution remain separate")
    func latencyFamiliesRemainSeparate() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "latency-runtime",
                sequence: 1,
                kind: .cognitiveEventAccepted,
                at: at,
                uptime: 1,
                cpu: 0,
                eventAcceptanceMilliseconds: 4
            ),
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "latency-runtime",
                sequence: 2,
                kind: .microcycleFinished,
                at: at.addingTimeInterval(1),
                uptime: 2,
                cpu: 0,
                eventAcceptanceMilliseconds: 900,
                microcycleExecutionMilliseconds: 37
            ),
        ]

        let report = InstalledPhysiologySoakAnalyzer.analyze(records: rows)

        #expect(report.cognitiveAcceptanceP95Milliseconds == 4)
        #expect(report.microcycleExecutionP95Milliseconds == 37)
    }

    @Test("diagnostic traffic is excluded while live and system latency remain distinct")
    func diagnosticTrafficCannotManufactureLatencyQualification() {
        let at = Date(timeIntervalSince1970: 1_800_100_000)
        let rows = [
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "classified-latency",
                sequence: 1,
                kind: .cognitiveEventAccepted,
                at: at,
                uptime: 1,
                cpu: 0,
                eventAcceptanceMilliseconds: 4,
                turnClass: .live
            ),
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "classified-latency",
                sequence: 2,
                kind: .cognitiveEventAccepted,
                at: at.addingTimeInterval(1),
                uptime: 2,
                cpu: 0,
                eventAcceptanceMilliseconds: 19,
                turnClass: .system
            ),
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "classified-latency",
                sequence: 3,
                kind: .cognitiveEventAccepted,
                at: at.addingTimeInterval(2),
                uptime: 3,
                cpu: 0,
                eventAcceptanceMilliseconds: 999,
                turnClass: .debug
            ),
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "classified-latency",
                sequence: 4,
                kind: .microcycleScheduled,
                at: at.addingTimeInterval(3),
                uptime: 4,
                cpu: 0,
                scheduledSignalCount: 1,
                turnClass: .live
            ),
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "classified-latency",
                sequence: 5,
                kind: .microcycleFinished,
                at: at.addingTimeInterval(4),
                uptime: 5,
                cpu: 0,
                microcycleExecutionMilliseconds: 7,
                scheduledSignalCount: 1,
                executedMicrocycleCount: 1,
                turnClass: .live
            ),
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "classified-latency",
                sequence: 6,
                kind: .microcycleScheduled,
                at: at.addingTimeInterval(5),
                uptime: 6,
                cpu: 0,
                scheduledSignalCount: 2,
                turnClass: .system
            ),
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "classified-latency",
                sequence: 7,
                kind: .microcycleFinished,
                at: at.addingTimeInterval(6),
                uptime: 7,
                cpu: 0,
                microcycleExecutionMilliseconds: 21,
                scheduledSignalCount: 2,
                executedMicrocycleCount: 2,
                turnClass: .system
            ),
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "classified-latency",
                sequence: 8,
                kind: .microcycleScheduled,
                at: at.addingTimeInterval(7),
                uptime: 8,
                cpu: 0,
                scheduledSignalCount: 3,
                turnClass: .verification
            ),
            record(
                evidenceClass: .generatedAccelerated,
                runtime: "classified-latency",
                sequence: 9,
                kind: .microcycleFinished,
                at: at.addingTimeInterval(8),
                uptime: 9,
                cpu: 0,
                microcycleExecutionMilliseconds: 999,
                scheduledSignalCount: 3,
                executedMicrocycleCount: 3,
                turnClass: .verification
            ),
        ]

        let report = InstalledPhysiologySoakAnalyzer.analyze(records: rows)

        #expect(report.cognitiveAcceptanceP95Milliseconds == 19)
        #expect(report.ordinaryTurnAcceptanceP95Milliseconds == 4)
        #expect(report.microcycleExecutionP95Milliseconds == 21)
        #expect(report.ordinaryTurnMicrocycleP95Milliseconds == 7)
        #expect(report.residentAcceptanceSampleCount == 2)
        #expect(report.ordinaryTurnAcceptanceSampleCount == 1)
        #expect(report.excludedDiagnosticAcceptanceCount == 1)
        #expect(report.residentMicrocycleSampleCount == 2)
        #expect(report.ordinaryTurnMicrocycleSampleCount == 1)
        #expect(report.excludedDiagnosticMicrocycleCount == 1)
    }

    @Test("measured cognition latency above the architecture budget blocks eligibility")
    func latencyBudgetIsAnEligibilityGate() {
        var rows = proofRows(evidenceClass: .installedElapsed)
        for index in rows.indices where rows[index].kind == .cognitiveEventAccepted {
            let original = rows[index]
            rows[index] = record(
                evidenceClass: .installedElapsed,
                runtime: original.runtimeInstanceID,
                sequence: original.sequence,
                kind: .cognitiveEventAccepted,
                at: original.recordedAt,
                uptime: original.process.systemUptimeSeconds,
                cpu: original.process.userCPUSeconds,
                eventAcceptanceMilliseconds: 50
            )
        }

        let report = InstalledPhysiologySoakAnalyzer.analyze(records: rows)

        #expect(!report.realMultiDayClaimEligible)
        #expect(report.claimBlockers.contains("production resident acceptance p95 does not meet <25 ms"))
    }

    @Test("latency eligibility requires enough observations for a real p95 tail")
    func latencySampleCountsAreEligibilityGates() {
        var rows = proofRows(evidenceClass: .installedElapsed)
        var retainedAcceptance = 0
        var retainedMicrocycle = 0
        rows = rows.compactMap { row in
            if row.kind == .cognitiveEventAccepted {
                retainedAcceptance += 1
                if retainedAcceptance == InstalledPhysiologySoakAnalyzer.minimumLatencySampleCount {
                    return record(
                        evidenceClass: row.evidenceClass,
                        runtime: row.runtimeInstanceID,
                        sequence: row.sequence,
                        kind: row.kind,
                        at: row.recordedAt,
                        uptime: row.process.systemUptimeSeconds,
                        cpu: row.process.userCPUSeconds
                    )
                }
            }
            if row.kind == .microcycleFinished {
                retainedMicrocycle += 1
                if retainedMicrocycle == InstalledPhysiologySoakAnalyzer.minimumLatencySampleCount {
                    return record(
                        evidenceClass: row.evidenceClass,
                        runtime: row.runtimeInstanceID,
                        sequence: row.sequence,
                        kind: row.kind,
                        at: row.recordedAt,
                        uptime: row.process.systemUptimeSeconds,
                        cpu: row.process.userCPUSeconds,
                        executedMicrocycleCount: UInt64(retainedMicrocycle)
                    )
                }
            }
            return row
        }

        let report = InstalledPhysiologySoakAnalyzer.analyze(records: rows)
        #expect(!report.realMultiDayClaimEligible)
        #expect(report.claimBlockers.contains("fewer than 20 production resident acceptance latency samples"))
        #expect(report.claimBlockers.contains("fewer than 20 production resident microcycle latency samples"))
    }

    @Test("the documented strict latency budget rejects exactly 25 milliseconds")
    func latencyBudgetBoundaryIsStrict() {
        var rows = proofRows(evidenceClass: .installedElapsed)
        for index in rows.indices where rows[index].kind == .cognitiveEventAccepted {
            let row = rows[index]
            rows[index] = record(
                evidenceClass: row.evidenceClass,
                runtime: row.runtimeInstanceID,
                sequence: row.sequence,
                kind: row.kind,
                at: row.recordedAt,
                uptime: row.process.systemUptimeSeconds,
                cpu: row.process.userCPUSeconds,
                eventAcceptanceMilliseconds: 25
            )
        }
        let report = InstalledPhysiologySoakAnalyzer.analyze(records: rows)
        #expect(report.claimBlockers.contains("production resident acceptance p95 does not meet <25 ms"))
    }

    @Test("legacy microcycle rows decode without contaminating event acceptance")
    func legacyMicrocycleRowsRemainReadable() throws {
        let legacy = record(
            evidenceClass: .generatedAccelerated,
            runtime: "legacy-latency-runtime",
            sequence: 1,
            kind: .microcycleFinished,
            at: Date(timeIntervalSince1970: 1_800_000_000),
            uptime: 1,
            cpu: 0,
            eventAcceptanceMilliseconds: 743
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(InstalledPhysiologySoakRecord.self, from: data)

        #expect(decoded.microcycleExecutionMilliseconds == nil)
        let report = InstalledPhysiologySoakAnalyzer.analyze(records: [decoded])
        #expect(report.cognitiveAcceptanceP95Milliseconds == nil)
        #expect(report.microcycleExecutionP95Milliseconds == 743)
    }

    private func proofRows(
        evidenceClass: InstalledPhysiologyEvidenceClass,
        start: Date = Date(timeIntervalSince1970: 1_800_000_000),
        runtime: String = "runtime-a",
        includeChatLatency: Bool = true
    ) -> [InstalledPhysiologySoakRecord] {
        var rows: [InstalledPhysiologySoakRecord] = []
        rows.reserveCapacity(61)
        rows.append(record(
            evidenceClass: evidenceClass,
            runtime: runtime,
            sequence: 1,
            kind: .runtimeStarted,
            at: start,
            uptime: 0,
            cpu: 0
        ))
        var sequence: UInt64 = 2
        for sample in 0..<InstalledPhysiologySoakAnalyzer.minimumLatencySampleCount {
            for phase in 0..<3 {
                let ordinal = Double(sample * 3 + phase + 1)
                let elapsed = ordinal * (Double(4 * 86_400) / 60.0)
                let kind: InstalledPhysiologyEventKind = switch phase {
                case 0: .cognitiveEventAccepted
                case 1: .microcycleScheduled
                default: .microcycleFinished
                }
                rows.append(record(
                    evidenceClass: evidenceClass,
                    runtime: runtime,
                    sequence: sequence,
                    kind: kind,
                    at: start.addingTimeInterval(elapsed),
                    uptime: elapsed,
                    cpu: ordinal * 0.001,
                    eventAcceptanceMilliseconds: phase == 0 ? 4 : nil,
                    chatTurnLatencyMilliseconds: phase == 0 && includeChatLatency ? 1_500 : nil,
                    microcycleExecutionMilliseconds: phase == 2 ? 7 : nil,
                    scheduledSignalCount: phase == 0 ? nil : UInt64(sample + 1),
                    executedMicrocycleCount: phase == 2 ? UInt64(sample + 1) : nil
                ))
                sequence += 1
            }
        }
        return rows
    }

    private func record(
        evidenceClass: InstalledPhysiologyEvidenceClass,
        runtime: String,
        sequence: UInt64,
        kind: InstalledPhysiologyEventKind,
        at: Date,
        uptime: Double,
        cpu: Double,
        dropped: UInt64? = nil,
        cpuCountersAvailable: Bool? = true,
        wakeCountersAvailable: Bool? = true,
        eventAcceptanceMilliseconds: Double? = nil,
        chatTurnLatencyMilliseconds: Double? = nil,
        microcycleExecutionMilliseconds: Double? = nil,
        scheduledSignalCount: UInt64? = nil,
        executedMicrocycleCount: UInt64? = nil,
        turnClass: InstalledPhysiologyTurnClass? = .live,
        interruptWakeups: UInt64? = nil,
        packageIdleWakeups: UInt64? = nil,
        measurementEpoch: String? = InstalledPhysiologySoakRecord.currentMeasurementEpoch
    ) -> InstalledPhysiologySoakRecord {
        InstalledPhysiologySoakRecord(
            evidenceClass: evidenceClass,
            measurementEpoch: measurementEpoch,
            eventID: "event-\(runtime)-\(sequence)",
            runtimeInstanceID: runtime,
            processIdentifier: 42,
            sequence: sequence,
            kind: kind,
            recordedAt: at,
            turnClass: turnClass,
            scheduledSignalCount: scheduledSignalCount,
            executedMicrocycleCount: executedMicrocycleCount,
            eventAcceptanceMilliseconds: eventAcceptanceMilliseconds,
            microcycleExecutionMilliseconds: microcycleExecutionMilliseconds,
            chatTurnLatencyMilliseconds: chatTurnLatencyMilliseconds,
            droppedRecordCount: dropped,
            process: InstalledPhysiologyProcessSample(
                systemUptimeSeconds: uptime,
                userCPUSeconds: cpu,
                systemCPUSeconds: cpu / 2,
                interruptWakeups: interruptWakeups ?? sequence,
                packageIdleWakeups: packageIdleWakeups ?? sequence,
                cpuCountersAvailable: cpuCountersAvailable,
                wakeCountersAvailable: wakeCountersAvailable
            )
        )
    }
}
