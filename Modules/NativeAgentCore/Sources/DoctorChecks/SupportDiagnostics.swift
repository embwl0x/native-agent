import Foundation
// Blueprint: | `SupportDiagnostics.swift` | support diagnostics read model |

public struct SupportDiagnostics: Codable, Hashable, Sendable {
    public var app: String
    public var version: String
    public var doctorStatus: String?
    public var generatedAt: String

    /// Reuse fresh offline checks so each rollup need not rerun Doctor; exclude app-only live.* rows that runAll cannot produce. Stale reads and exports
    /// request a full run so the export reflects current evidence.
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
