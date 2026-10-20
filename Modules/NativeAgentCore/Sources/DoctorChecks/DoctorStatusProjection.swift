import Foundation
import NativeAgentCore
import PersistenceCore
import Experiences

/// Cached health projection; host probes and display redaction arrive from the caller.
public enum DoctorStatusProjection {
    public static func repairProjection(_ rows: [CheckResult], dataRoot: URL) async -> [CheckResult] {
        let projected = Dictionary(rows.compactMap { row in row.repairExperience.map { ($0.id, row) } },
                                   uniquingKeysWith: { first, _ in first })
        let rows = rows.filter { $0.repairExperience == nil }
        do {
            let open = try await ExperienceStore.at(dataRoot).projection()
            let repairs = open.filter {
                $0.owes["repair"]?.phase.isSettled == false
                    && $0.claims.contains { $0.claim.hasPrefix("operation: doctor.check:") }
            }
            let owed = repairs.map { experience -> CheckResult in
                let operation = experience.claims.first { $0.claim.hasPrefix("operation: doctor.check:") }!.claim
                let checkID = String(operation.dropFirst("operation: doctor.check:".count))
                let reading = rows.first { $0.id == checkID }
                // A merge that remeasured only live rows keeps a core row as it
                // was last projected, under the reading that run took.
                if reading == nil, let row = projected[experience.id] { return row }
                func claim(_ name: String) -> String? {
                    experience.claims.first { $0.claim.hasPrefix(name + ": ") }.map { String($0.claim.dropFirst(name.count + 2)) }
                }
                let tap = claim("tap")
                let nativeRepair = claim("next_call") == ToolFailureError.call("app", ["action": .string("doctor.repair"), "args": .object(["check_id": .string(checkID)])])
                // A reading that is no longer adverse (an unknown: this launch
                // has too little to say yet) is what is in effect now; the debt
                // stays owed beside it, dated, since only a pass settles it.
                // Shown alone under its old status, it read a past launch's
                // verdict as this one's (0.6.9: Prompt Prefix Cache "fail, since
                // this build launched at 00:13:44Z" three launches later).
                let current = reading.flatMap { DoctorSafeRepairPolicy.isAdverse($0.status) ? nil : $0 }
                let words = experience.face?.words ?? checkID
                return CheckResult(id: experience.id, title: reading?.title ?? checkID, status: current?.status ?? claim("check.status") ?? "warn",
                    detail: current.map { $0.detail + " Repair still owed since \(experience.at): " + words } ?? words,
                    harm: claim("check.harm"), receipt: claim("check.receipt"), human_action: tap,
                    repair_available: reading?.repair_available ?? nativeRepair, ask: tap == nil ? nil : reading?.ask ?? .permission,
                    repairExperience: experience)
            }
            // Measurements remain inspectable; their unresolved failures are
            // rendered from the experience that owns them, including unknowns,
            // under the status the check reads now.
            let owedIDs = Set(owed.map(\.checkID))
            return rows.filter { !owedIDs.contains($0.id) || $0.ask != nil } + owed
        } catch {
            return rows + [CheckResult(source: "experiences/experiences.sqlite",
                nextCall: ToolFailureError.fileRepairCall(dataRoot.appendingPathComponent("experiences/experiences.sqlite"), dataRoot: dataRoot,
                    shape: "This SQLite experience store retains original experiences, claims, evidence and obligation phases. Preserve their identities and settlement history."),
                id: "doctor.repair_store", title: "Repairs owed", status: "fail",
                detail: "Repair obligations could not be read: \(error.localizedDescription)")]
        }
    }

    /// Each measurement owns its repair. A report, restart, or unknown reading
    /// cannot accept it; only this check's passing postcondition, or a reading
    /// that the part is off or not needed, can.
    public static func recordReadings(_ rows: [CheckResult], dataRoot: URL) async {
        let measurement = UUID().uuidString
        for row in rows where row.repairExperience == nil {
            let operation = "doctor.check:" + row.id
            let evidence = Experience.Ref(source: "doctor", id: measurement + ":" + row.id)
            if DoctorSafeRepairPolicy.isAdverse(row.status), row.ask == nil,
               let owner = row.repairOwner, row.repairCall != nil {
                // One failing check is one owed repair: a later failing reading
                // adds its evidence and current words to the open one.
                await ExperienceStore.record(dataRoot, operation) { store in
                    if let open = try await store.open().first(where: { $0.owes["repair"]?.phase.isSettled == false
                        && $0.claims.contains { $0.claim == "operation: " + operation } }) {
                        return try await store.append([.evidence(evidence), .face(.init(words: row.repairFace, artifacts: []))], to: open.id)
                    }
                    await RepairOwed.owe(dataRoot, id: evidence.id, kind: .act, evidence: [evidence],
                        operation: operation, owner: owner, words: row.repairFace,
                        nextCall: row.repairCall, tap: row.repairTap).value
                    let fields: [(String, String?)] = [("check.status", row.status), ("check.harm", row.harm), ("check.receipt", row.receipt)]
                    try await store.append(fields.compactMap { key, value in
                        value.map { .claim(.init(claim: key + ": " + $0, evidence: [evidence])) }
                    }, to: evidence.id)
                }.value
            } else if ["ok", "off", "not needed"].contains(row.status) {
                // Off by config or not needed owes nothing: the reading settles
                // a debt met while the part was meant to run, so no later run
                // renders it (0.6.9: Slack, never connected, stayed "fail").
                await RepairOwed.settle(dataRoot, operation: operation, evidence: evidence).value
            }
        }
    }

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
            let raw = try await runCoreChecks()
            let executable = DoctorSafeRepairPolicy.executableCoreIDs(for: raw)
            let core = raw.map { $0.settled(liveAvailable: false, coreAvailable: executable.contains($0.id)) }
            await recordReadings(core, dataRoot: cachePath.deletingLastPathComponent().deletingLastPathComponent())
            do {
                try await persistDoctorSnapshot(core, to: cachePath, runAt: now, measuredAt: measuredAt, inPlace: true)
            } catch {
                nativeLog("health_card: doctor snapshot cache write failed: \(error.localizedDescription)")
            }
            let subs: [HealthCardSubsystem] = (core + liveChecks).map { c in
                HealthCardSubsystem(
                    id: c.id,
                    label: c.title,
                    status: c.status,
                    detail: c.repairFace,
                    fixAction: c.repairCall ?? c.repairTap
                )
            }
            return HealthCard(overall: doctorRollup(subs.map(\.status)), subsystems: subs, createdAt: now)
        } catch {
            await recordReadings([CheckResult(source: "Doctor run", id: "doctor", title: "Doctor", status: "unmeasured",
                detail: "Doctor run failed: \(safeDetail(error.localizedDescription))")],
                dataRoot: cachePath.deletingLastPathComponent().deletingLastPathComponent())
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

    /// The one writer of `doctor/latest.json`: `{"checks", "runAt", "measuredAt"}`,
    /// under the file's lock so a full run and a health-card write never race.
    /// A full Doctor run replaces the rows; the health card's core-only reading
    /// updates its rows `inPlace`, keeping the live rows it did not measure, and
    /// `measuredAt` then stays the oldest reading still in the file. Only a
    /// missing file starts fresh: one that cannot be read or decoded throws.
    public static func persistDoctorSnapshot(
        _ results: [CheckResult], to path: URL, runAt: String, measuredAt: String, inPlace: Bool = false
    ) async throws {
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            var rows = results
            var measured = measuredAt
            if inPlace, FileManager.default.fileExists(atPath: path.path) {
                let previous = try JSONDecoder().decode(CachedDoctorPayload.self, from: Data(contentsOf: path))
                let fresh = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let previousIDs = Set(previous.checks.map(\.id))
                rows = previous.checks.map { fresh[$0.id] ?? $0 } + results.filter { !previousIDs.contains($0.id) }
                if previous.checks.contains(where: { fresh[$0.id] == nil }), let older = previous.measuredAt {
                    measured = min(older, measuredAt)
                }
            }
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try await persistence.writeJSON(.object([
                "checks": try JSONValue.parse(try enc.encode(rows)), "runAt": .string(runAt), "measuredAt": .string(measured),
            ]), to: path)
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
                detail: $0.repairFace,
                fixAction: $0.repairCall ?? $0.repairTap
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
                detail: check.repairFace,
                fixAction: check.repairCall ?? check.repairTap
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
        let measuredAt: String?
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

extension DoctorStatusProjection {
    public static func categoryID(for id: String) -> String {
        switch id {
        case "codex_login", "llm", "codex_login_helper", "live.providers": "Provider"
        case "daemon_lifecycle", "legacy_launch_agent", "launch_agent", "live.background_loops", "live.bridges",
             // Per-turn prompt-prefix cache health is a property of the running
             // app, not of stored data.
             "prompt_prefix_health": "Runtime"
        // Her subconscious is not a subsystem of the body — it gets its own
        // group so a capsule that stopped arriving reads as what it is.
        case "subconscious_vitals": "Cognition"
        case "searxng", "telegram", "connectors", "live.telegram", "live.search": "Connectors"
        case "storage", "chat_sessions", "session_identity", "persona_engine", "backups", "write_test", "live.memory": "Data"
        case "tools", "live.tools": "Tools"
        case "autonomy", "live.autonomy": "Autonomy"
        default: "Release"
        }
    }

    public static func groupedChecks(_ checks: [CheckResult]) -> [(String, [CheckResult])] {
        let order = [
            "Provider", "Runtime", "Cognition", "Connectors", "Data", "Tools",
            "Autonomy", "Release",
        ]
        let grouped = Dictionary(grouping: checks, by: { categoryID(for: $0.checkID) })
        let statusOrder = ["failing", "warning", "healthy", "reading", "off", "not needed", "unclear"]
        return order.compactMap { key in
            guard let values = grouped[key], !values.isEmpty else { return nil }
            return (key, values.sorted {
                let lhs = statusOrder.firstIndex(of: DoctorPlainCopy.bucket(for: $0.status)) ?? statusOrder.count
                let rhs = statusOrder.firstIndex(of: DoctorPlainCopy.bucket(for: $1.status)) ?? statusOrder.count
                return lhs == rhs ? $0.title < $1.title : lhs < rhs
            })
        }
    }


}

public enum DoctorPlainCopy {
    public struct Summary: Equatable {
        public var healthy = 0
        public var warning = 0
        public var failing = 0
        public var unclear = 0
        public var reading = 0
        public var off = 0
        public var notNeeded = 0

        public var total: Int { healthy + warning + failing + unclear + reading + off + notNeeded }

        /// Vocabulary understood by NativeAgentTheme.statusColor / StatusBadge.
        public var statusText: String {
            if failing > 0 { return "failed" }
            if warning > 0 { return "warn" }
            if total == 0 { return "unknown" }
            if reading > 0 { return "info" }
            return "ok"
        }
    }

    /// Readings stay distinct from health verdicts and use the info tint.
    public static func bucket(for status: String) -> String {
        switch status.lowercased() {
        case "ok", "done", "passed", "succeeded", "active", "valid", "ready", "scheduled":
            return "healthy"
        case "warn", "warning", "blocked", "needs_setup", "planned", "interrupted", "disabled":
            return "warning"
        case "fail", "failed", "error", "timeout", "quarantined":
            return "failing"
        case "unmeasured":
            return "reading"
        // Off by config or not needed: no fault, and no healthy work either.
        case "off", "not needed":
            return status.lowercased()
        default:
            return "unclear"
        }
    }

    public static func summarize(_ checks: [CheckResult]) -> Summary {
        var summary = Summary()
        for check in checks {
            switch bucket(for: check.status) {
            case "healthy": summary.healthy += 1
            case "warning": summary.warning += 1
            case "failing": summary.failing += 1
            case "off": summary.off += 1
            case "not needed": summary.notNeeded += 1
            case "reading": summary.reading += 1
            default: summary.unclear += 1
            }
        }
        return summary
    }

    public static func headline(for summary: Summary) -> String {
        if summary.total == 0 { return "No checks have run yet." }
        if summary.failing > 0 { return "Some parts of the app are not working." }
        if summary.warning > 0 { return "The app is running, but some parts need attention." }
        if summary.unclear > 0 { return "The app is running. Some checks came back unclear." }
        if summary.reading > 0 { return "The app is running. Some checks are readings." }
        // Off and not needed are not faults, but they are not "everything" either.
        let inactive = [(summary.off, "off"), (summary.notNeeded, "not needed")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return inactive.isEmpty ? "Everything looks healthy." : "Healthy; " + inactive.joined(separator: ", ") + "."
    }

    public static func detail(for summary: Summary) -> String {
        guard summary.total > 0 else {
            return "Press Repair to check everything and fix what is broken."
        }
        var parts = ["\(summary.healthy) working"]
        if summary.warning > 0 { parts.append("\(summary.warning) need attention") }
        if summary.failing > 0 { parts.append("\(summary.failing) not working") }
        if summary.unclear > 0 { parts.append("\(summary.unclear) unclear") }
        if summary.reading > 0 { parts.append("\(summary.reading) readings") }
        if summary.off > 0 { parts.append("\(summary.off) off") }
        if summary.notNeeded > 0 { parts.append("\(summary.notNeeded) not needed") }
        let checked = summary.total == 1 ? "1 area checked" : "\(summary.total) areas checked"
        return "\(checked): " + parts.joined(separator: ", ") + "."
    }

    /// Turn a loop identifier such as `github_tracking` into `Github tracking`.
    /// The raw identifier still renders inside the Details disclosure.
    public static func friendlyLoopName(_ loopId: String) -> String {
        let spaced = loopId
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard let first = spaced.first else { return loopId }
        return String(first).uppercased() + spaced.dropFirst()
    }

    public static func allLoopsHealthyText(count: Int) -> String {
        count == 1 ? "1 background task is running normally."
                   : "All \(count) background tasks are running normally."
    }

    public static func otherLoopsHealthyText(count: Int) -> String {
        count == 1 ? "1 other background task is running normally."
                   : "\(count) other background tasks are running normally."
    }
}
