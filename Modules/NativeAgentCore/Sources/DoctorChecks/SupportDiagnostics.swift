import Foundation
// Blueprint: | `SupportDiagnostics.swift` | support diagnostics read model |

public struct SupportDiagnostics: Codable, Hashable, Sendable {
    public var app: String
    public var version: String
    public var doctorStatus: String?
    public var generatedAt: String

    /// The Support Snapshot reuses checks from a still-fresh Doctor report
    /// so the full offline Doctor pass is not re-run just for the rollup: the
    /// reuse path excludes exactly the app-added live-coverage checks
    /// (`live.*`) that `runAll` never produces, so the snapshot is
    /// byte-identical to a cold run. The export path (and any stale-cache
    /// caller) passes nil → full run.
    public static func read(reusingChecks checks: [CheckResult]?) async -> SupportDiagnostics {
        let doctorStatus: String
        if let checks {
            doctorStatus = DoctorReadout.supportSnapshotOfflineRollup(checks)
        } else {
            let statuses = await makeDoctorChecks().runAll().map(\.status)
            doctorStatus = DoctorReadout.doctorRollup(statuses)
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return SupportDiagnostics(
            app: "NativeAgent",
            version: version,
            doctorStatus: doctorStatus,
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }
}
