import Foundation
import PersistenceCore

/// Cached health projection; host probes and display redaction arrive from the caller.
public enum DoctorStatusProjection {
    public static func makeHealthCard(
        now: String,
        cachePath: URL,
        liveChecks: [CheckResult],
        safeDetail: (String) -> String,
        runCoreChecks: () async throws -> [CheckResult]
    ) async -> HealthCard {
        if let cached = readCachedHealthCard(at: cachePath, now: now) {
            return mergeHealthCard(cached: cached, liveChecks: liveChecks, now: now)
        }
        do {
            let measuredAt = ISO8601DateFormatter().string(from: Date())
            let core = try await runCoreChecks()
            await persistDoctorSnapshot(core, to: cachePath, runAt: now, measuredAt: measuredAt)
            let subs: [HealthCardSubsystem] = (core + liveChecks).map { c in
                HealthCardSubsystem(
                    id: c.id,
                    label: c.title,
                    status: c.status,
                    detail: c.detail,
                    fixAction: c.repair
                )
            }
            return HealthCard(overall: doctorRollup(subs.map(\.status)), subsystems: subs, createdAt: now)
        } catch {
            let err = HealthCardSubsystem(
                id: "doctor",
                label: "Doctor",
                status: "error",
                detail: "Doctor run failed: \(safeDetail(error.localizedDescription))",
                fixAction: nil
            )
            return HealthCard(overall: "error", subsystems: [err], createdAt: now)
        }
    }

    public static func persistDoctorSnapshot(
        _ results: [CheckResult], to path: URL, runAt: String, measuredAt: String
    ) async {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let checksValue = try JSONValue.parse(try enc.encode(results))
            let payload = JSONValue.object([
                "checks": checksValue, "runAt": .string(runAt), "measuredAt": .string(measuredAt),
            ])
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try await SwiftNativePersistenceCore().writeJSON(payload, to: path)
        } catch {
            nativeLog("health_card: doctor snapshot cache write failed: \(error.localizedDescription)")
        }
    }

    public static func readCachedHealthCard(at path: URL, now: String) -> HealthCard? {
        guard let data = try? Data(contentsOf: path),
              let payload = try? JSONDecoder().decode(CachedDoctorPayload.self, from: data),
              let runAtString = payload.runAt,
              let runAt = ISO8601DateFormatter().date(from: runAtString),
              Date().timeIntervalSince(runAt) < 60
        else { return nil }
        let subs = payload.checks.map {
            HealthCardSubsystem(
                id: $0.id,
                label: $0.title,
                status: $0.status,
                detail: $0.detail,
                fixAction: $0.repair
            )
        }
        let rollup = Self.doctorRollup(subs.map(\.status))
        return HealthCard(overall: rollup, subsystems: subs, createdAt: now)
    }

    public static func mergeHealthCard(cached: HealthCard, liveChecks: [CheckResult], now: String) -> HealthCard {
        let live = liveChecks.map { check in
            HealthCardSubsystem(
                id: check.id,
                label: check.title,
                status: check.status,
                detail: check.detail,
                fixAction: check.repair
            )
        }
        let liveIDs = Set(live.map(\.id))
        let subsystems = cached.subsystems.filter { !liveIDs.contains($0.id) } + live
        let overall = doctorRollup(subsystems.map(\.status))
        return HealthCard(overall: overall, subsystems: subsystems, createdAt: now)
    }

    private struct CachedDoctorPayload: Decodable {
        let checks: [CheckResult]
        let runAt: String?
    }

    public static func supportSnapshotRollup(_ statuses: [String]) -> String {
        if statuses.contains(where: { $0 == "fail" }) { return "fail" }
        if statuses.contains(where: { $0 == "warn" }) { return "warn" }
        return "ok"
    }

    public static func supportSnapshotOfflineRollup(_ checks: [CheckResult]) -> String {
        supportSnapshotRollup(
            checks
                .filter { !$0.id.hasPrefix("live.") }
                .map(\.status)
        )
    }

    public static func doctorRollup(_ statuses: [String]) -> String {
        if statuses.contains(where: { ["fail", "error"].contains($0.lowercased()) }) { return "fail" }
        if statuses.contains(where: { $0.lowercased() == "warn" }) { return "warn" }
        return "ok"
    }
}
