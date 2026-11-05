import Foundation
import NativeAgentCore
import PersistenceCore
import Experiences
import NativeAgentShared
// Blueprint: | `DoctorStatusProjection.swift` | `DoctorReadout`: `healthReadings`, `persistDoctorSnapshot`, `recordReadings`, `repairProjection` |

public enum DoctorReadout {
    /// A snapshot from another process launch cannot describe this launch's window.
    private static let launchID = UUID().uuidString

    public static func repairProjection(_ rows: [CheckResult], dataRoot: URL) async -> [CheckResult] {
        let rows = rows.filter { $0.repairExperience == nil }
        do {
            let open = try await ExperienceStore.at(dataRoot).projection()
            let repairs = open.filter {
                $0.owes["repair"]?.phase.isSettled == false
                    && $0.evidence.contains { $0.source == "doctor" }
            }
            let owed = repairs.map { experience -> CheckResult in
                let reading = rows.first { experience.outcome?.domain == "doctor.check:" + $0.id }
                // Retained evidence keeps its human step; only a current measured owner can supply executable repair.
                let tap = reading?.repairTap ?? RepairDebt(experience).tap
                let checkID = (experience.outcome?.domain).flatMap { $0.hasPrefix("doctor.check:") ? String($0.dropFirst("doctor.check:".count)) : nil }
                // Preserve evidence filenames and current severity; remedies and calls retain separate fields.
                let words = experience.face?.words ?? experience.id
                return CheckResult(source: reading?.repairOwner ?? RepairDebt(experience).owner, nextCall: reading?.repairCall,
                    id: experience.id, title: reading?.title ?? checkID ?? "Repair owed", status: reading?.status ?? "unmeasured",
                    detail: reading.map { $0.detail.trimmingCharacters(
                        in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) + "; repair owed since \(experience.at)." } ?? words,
                    harm: reading?.harm, receipt: reading?.receipt, repairApplied: reading?.repairApplied, human_action: tap,
                    repair_available: reading?.repair_available, automaticRepairEligible: reading?.automaticRepairEligible,
                    ask: reading?.ask, owner: reading?.owner, repairExperience: experience)
            }
            // Keep measurements inspectable while unresolved failures render from their owning experience at current severity.
            let owedIDs = Set(owed.map(\.checkID))
            return rows.filter { !owedIDs.contains($0.id) || $0.ask != nil } + owed
        } catch {
            return rows + [CheckResult(source: "experiences/experiences.sqlite",
                id: "doctor.repair_store", title: "Repairs owed", status: "fail",
                detail: "Repair obligations could not be read: \(error.localizedDescription)",
                human_action: ToolFailureError.fileRepairInstruction(dataRoot.appendingPathComponent("experiences/experiences.sqlite"),
                    shape: """
                        This SQLite experience store retains original experiences, claims, evidence and obligation phases. Preserve their identities \
                        and settlement history.
                        """))]
        }
    }

    /// Only this check's passing, off or unneeded postcondition settles its repair; unknown readings and restarts cannot.
    public static func recordReadings(_ rows: [CheckResult], dataRoot: URL) async {
        let measurement = UUID().uuidString
        for row in rows where row.repairExperience == nil {
            let operation = "doctor.check:" + row.id
            let evidence = Experience.Ref(source: "doctor", id: measurement + ":" + row.id)
            if DoctorSafeRepairPolicy.isAdverse(row.status), row.ask == nil,
               let owner = row.repairOwner, row.repairCall != nil || row.repairTap != nil {
                // Add evidence to the open repair so repeated failure does not create duplicate obligations.
                await ExperienceStore.record(dataRoot, "repair:" + operation) { store in
                    if let open = try await store.open().first(where: { $0.owes["repair"]?.phase.isSettled == false
                        && $0.outcome?.domain == operation }) {
                        return try await store.append([.evidence(evidence), .face(.init(words: row.repairFace, artifacts: []))], to: open.id)
                    }
                    try await RepairOwed.owe(store, id: evidence.id, kind: .act, evidence: [evidence],
                        operation: operation, owner: owner, words: row.repairFace,
                        nextCall: row.repairCall, tap: row.repairTap)
                }.value
            } else if ["ok", "off", "not needed"].contains(row.status) {
                // Off or unneeded settles the prior obligation; later runs must not render debt for intentionally inactive work.
                await RepairOwed.settle(dataRoot, operation: operation, evidence: evidence).value
            }
        }
    }

    public static func healthReadings(
        now: String,
        cachePath: URL,
        liveChecks: [CheckResult],
        runCoreChecks: () async -> [CheckResult]
    ) async -> (checks: [CheckResult], measuredAt: String) {
        do {
            if let cached = try readCachedReadings(at: cachePath) {
                let liveIDs = Set(liveChecks.map(\.id))
                return (cached.checks.filter { !liveIDs.contains($0.id) } + liveChecks, cached.measuredAt)
            }
        } catch {
            return ([cacheFailure(error, path: cachePath)] + liveChecks, now)
        }
        let measuredAt = ISO8601DateFormatter().string(from: Date())
        let raw = await runCoreChecks()
        let executable = DoctorSafeRepairPolicy.executableCoreIDs(for: raw)
        let core = raw.map { $0.settled(liveAvailable: false, coreAvailable: executable.contains($0.id)) }
        await recordReadings(core, dataRoot: cachePath.deletingLastPathComponent().deletingLastPathComponent())
        do {
            try await persistDoctorSnapshot(core, to: cachePath, runAt: now, measuredAt: measuredAt, inPlace: true)
        } catch {
            return (core + [cacheFailure(error, path: cachePath)] + liveChecks, measuredAt)
        }
        return (core + liveChecks, measuredAt)
    }

    /// Serialize all latest.json writers under one lock; full runs replace rows and core-only reads update in place. Preserve unmeasured live rows and their
    /// oldest measuredAt; only a missing file can start fresh.
    public static func persistDoctorSnapshot(
        _ results: [CheckResult], to path: URL, runAt: String, measuredAt: String, inPlace: Bool = false
    ) async throws {
        try await SwiftNativePersistenceCore.withFileLock(path) {
            var rows = results
            var measured = measuredAt
            if inPlace, FileManager.default.fileExists(atPath: path.path) {
                let previous = try JSONDecoder().decode(CachedDoctorPayload.self, from: Data(contentsOf: path))
                if previous.launchID == launchID {
                    let fresh = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let previousIDs = Set(previous.checks.map(\.id))
                    rows = previous.checks.map { fresh[$0.id] ?? $0 } + results.filter { !previousIDs.contains($0.id) }
                    if previous.checks.contains(where: { fresh[$0.id] == nil }) {
                        measured = min(previous.measuredAt, measuredAt)
                    }
                }
            }
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try await SwiftNativePersistenceCore.writeJSON(.object([
                "checks": try JSONValue.parse(try enc.encode(rows)), "runAt": .string(runAt), "measuredAt": .string(measured),
                "launchID": .string(launchID),
            ]), to: path)
        }
    }

    private static func cacheFailure(_ error: Error, path: URL) -> CheckResult {
        CheckResult(source: path.path, id: "doctor.cache", title: "Saved health readings", status: "fail",
            detail: "Doctor readings could not be read or published: \(error.localizedDescription)",
            human_action: ToolFailureError.fileRepairInstruction(
                path, shape: "Preserve the measured checks and their runAt, measuredAt and launchID; repair the unreadable Doctor snapshot."))
    }

    private static func readCachedReadings(at path: URL) throws -> (checks: [CheckResult], measuredAt: String)? {
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        let payload = try JSONDecoder().decode(CachedDoctorPayload.self, from: data)
        guard !payload.launchID.isEmpty,
              let runAt = NativeTimestampFormat.parseISO8601FractionalFirst(payload.runAt),
              NativeTimestampFormat.parseISO8601FractionalFirst(payload.measuredAt) != nil else {
            throw PersistenceCoreError.ioFailure(
                "Invalid Doctor snapshot metadata at \(path.path): launchID, runAt and measuredAt must identify the retained measurements.")
        }
        guard payload.launchID == launchID else { return nil }
        let age = Date().timeIntervalSince(runAt)
        guard age >= 0 else {
            throw PersistenceCoreError.ioFailure(
                "Doctor snapshot runAt is in the future at \(path.path); verify the clock and repair its measurement metadata.")
        }
        guard age < 60 else { return nil }
        return (payload.checks, payload.measuredAt)
    }

    private struct CachedDoctorPayload: Decodable {
        let checks: [CheckResult]
        let runAt: String
        let measuredAt: String
        let launchID: String
    }

    public static func supportSnapshotOfflineRollup(_ checks: [CheckResult]) -> String {
        doctorRollup(
            checks
                .filter { !$0.id.hasPrefix("live.") }
                .map(\.status)
        )
    }

    public static func doctorRollup(_ statuses: [String]) -> String {
        let buckets = statuses.map(DoctorPlainCopy.bucket)
        if buckets.contains("failing") { return "fail" }
        if buckets.contains("warning") { return "warn" }
        if buckets.isEmpty || buckets.contains("unclear") { return "unknown" }
        if buckets.contains("reading") { return "unmeasured" }
        return "ok"
    }
}

extension DoctorReadout {
    public static func categoryID(for id: String) -> String {
        switch id {
        case "codex_login", "llm", "codex_login_helper", "live.providers": "Provider"
        case "live.background_loops", "live.bridges",
             // Prefix-cache health describes the running app, not stored data.
             "prompt_prefix_health", "model.shims": "Runtime"
        // Group cognition separately so missing capsules remain visible as cognition findings.
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
    public static func sectionTitle(for group: String) -> String {
        switch group {
        case "Provider": "AI provider"
        case "Runtime": "The app itself"
        case "Cognition": "Inner state"
        case "Connectors": "Connected services"
        case "Data": "Your data"
        case "Tools": "Tools"
        case "Autonomy": "Actions I take on my own"
        case "Release": "Stored data health"
        default: group
        }
    }

    public struct Summary: Equatable {
        public var healthy = 0
        public var warning = 0
        public var failing = 0
        public var unclear = 0
        public var reading = 0
        public var off = 0
        public var notNeeded = 0

        public var total: Int { healthy + warning + failing + unclear + reading + off + notNeeded }

        public var statusText: String {
            if failing > 0 { return "failed" }
            if warning > 0 { return "warn" }
            if total == 0 { return "unknown" }
            if unclear > 0 { return "unknown" }
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
        // Off or unneeded proves neither a fault nor healthy work.
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
        // Inactive parts cannot establish the health of everything.
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

    /// Humanize loop labels while retaining raw identifiers in Details for diagnosis.
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
