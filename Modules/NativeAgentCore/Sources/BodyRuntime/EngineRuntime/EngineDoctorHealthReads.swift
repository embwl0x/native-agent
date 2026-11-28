import Foundation
import NativeAgentCore
import SenseCore
import Synchronization
// Blueprint: | `EngineDoctorHealthReads.swift` | Merge live Doctor checks into reports and bound completed-report reuse for support snapshots |

extension EngineDoctorRuntime {
    public static var supportSnapshotDoctorReuseTTL: TimeInterval { 90 }

    public static func mergeReport(_ current: DoctorReport, liveChecks: [CheckResult]) -> DoctorReport {
        let liveIDs = Set(liveChecks.map(\.id))
        // Preserve core measurements and their owed projection.
        let checks = current.checks.filter { !liveIDs.contains($0.checkID) } + liveChecks
        return DoctorReport(status: DoctorReadout.doctorRollup(checks.map(\.status)), repaired: current.repaired, checks: checks)
    }

    public static func reusableSupportReport(
        report: DoctorReport?, completedAt: Date?, now: Date = Date()
    ) -> DoctorReport? {
        guard let report, let completedAt else { return nil }
        let age = now.timeIntervalSince(completedAt)
        return age >= 0 && age < supportSnapshotDoctorReuseTTL ? report : nil
    }
}
