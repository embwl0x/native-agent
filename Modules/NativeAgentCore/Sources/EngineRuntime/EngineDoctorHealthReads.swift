import Foundation
import DoctorChecks
import NativeAgentCore
import BackgroundLoops
import BackgroundWork
import Synchronization
// Blueprint: | `EngineDoctorHealthReads.swift` | Shared live health cards and bounded completed-report reuse |

extension EngineDoctorRuntime {
    public static var supportSnapshotDoctorReuseTTL: TimeInterval { 90 }

    public static func mergeReport(_ current: DoctorReport, liveChecks: [CheckResult]) -> DoctorReport {
        let liveIDs = Set(liveChecks.map(\.id))
        // Preserve core measurements and their owed projection.
        let checks = current.checks.filter { !liveIDs.contains($0.checkID) } + liveChecks
        return DoctorReport(status: DoctorReadout.doctorRollup(checks.map(\.status)), repaired: current.repaired, checks: checks)
    }

    public func getHealthCard() async throws -> HealthCard {
        // Refresh live owners on each read; `DoctorReadout` owns offline caching.
        let now = ISO8601DateFormatter().string(from: Date())
        let liveChecks = await liveDoctorCoverageChecks()
        let reading = await DoctorReadout.healthReadings(
            now: now,
            cachePath: dataRoot.appendingPathComponent("doctor/latest.json"),
            liveChecks: liveChecks,
            runCoreChecks: { await makeDoctorChecks(root: dataRoot).runAll() }
        )
        let rows = await DoctorReadout.repairProjection(reading.checks, dataRoot: dataRoot)
        return HealthCard(overall: DoctorReadout.doctorRollup(rows.map(\.status)),
                          subsystems: rows.map(HealthCardSubsystem.init), createdAt: reading.measuredAt)
    }

    public static func reusableSupportReport(
        report: DoctorReport?, completedAt: Date?, now: Date = Date()
    ) -> DoctorReport? {
        guard let report, let completedAt else { return nil }
        let age = now.timeIntervalSince(completedAt)
        return age >= 0 && age < supportSnapshotDoctorReuseTTL ? report : nil
    }
}
