import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import Desk
import ApprovalInbox
import WorkshopExecution
import AgentWorkspace
import NotificationInbox
import Privacy
import Cognition
// Blueprint: | `HeartbeatHealthAssessment.swift` | HeartbeatBackgroundWork compact health assessment and exact age deadlines |
extension HeartbeatBackgroundWork {
    private struct HeartbeatIssue: Sendable {
        let id: String
        let summary: String
        let detail: String
        let priority: Int
        let actions: [HeartbeatNoticeAction]
    }
    internal func nextHeartbeatAssessmentDeadline(dataRoot: URL, after now: Date) async -> Date? {
        var deadlines: [Date] = []
        _ = heartbeatExecutionsIssue(dataRoot: dataRoot, now: now) { deadlines.append($0) }
        _ = heartbeatErrorBurstIssue(dataRoot: dataRoot, now: now) { deadlines.append($0) }
        _ = await heartbeatStaleTaskIssue(dataRoot: dataRoot, now: now) { deadlines.append($0) }
        guard !Task.isCancelled else { return nil }
        _ = await heartbeatDurableResidueSummary(dataRoot: dataRoot, now: now) { deadlines.append($0) }
        guard !Task.isCancelled else { return nil }
        return deadlines.filter { $0 > now }.min()
    }
    /// Composes the heartbeat's deterministic verdict and stable inbox cards.
    public func gatherHeartbeatAssessment(
        dataRoot: URL,
        now: Date = Date(),
        bridgeConfigRoot: URL? = nil
    ) async -> HeartbeatAssessment {
        var issues: [HeartbeatIssue] = []

        let doctor = heartbeatDoctorIssue(dataRoot: dataRoot)
        if let issue = doctor { issues.append(issue) }

        let executions = heartbeatExecutionsIssue(dataRoot: dataRoot, now: now)
        if let issue = executions { issues.append(issue) }

        let errors = heartbeatErrorBurstIssue(dataRoot: dataRoot, now: now)
        if let issue = errors { issues.append(issue) }

        let staleTasks = await heartbeatStaleTaskIssue(dataRoot: dataRoot, now: now)
        if let issue = staleTasks { issues.append(issue) }

        let residue = await heartbeatDurableResidueSummary(
            dataRoot: dataRoot,
            bridgeConfigRoot: bridgeConfigRoot,
            now: now
        )
        await reconcileDurableResidueCard(dataRoot: dataRoot, summary: residue, now: now)

        let sortedIssues = issues.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority < rhs.priority
        }
        let activeConditionIDs = Set(sortedIssues.map(\.id))
        await retireInactiveHeartbeatCards(dataRoot: dataRoot, activeConditionIDs: activeConditionIDs)

        if let primary = sortedIssues.first {
            let detail = heartbeatAlertBody(primary: primary, issues: sortedIssues)
            let assessment = HeartbeatAssessment(
                deterministicOK: false,
                conditionId: primary.id,
                fallbackAlert: detail,
                actions: primary.actions
            )
            return assessment
        }
        return HeartbeatAssessment.clean()
    }
    private func heartbeatDoctorIssue(dataRoot: URL) -> HeartbeatIssue? {
        let doctorPath = dataRoot.appendingPathComponent("doctor", isDirectory: true)
            .appendingPathComponent("latest.json")
        guard let text = try? String(contentsOf: doctorPath, encoding: .utf8),
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HeartbeatIssue(
                id: "doctor-missing",
                summary: "Doctor has no latest health snapshot.",
                detail: "Doctor has not written data/doctor/latest.json yet, so heartbeat cannot verify the health checklist.",
                priority: 20,
                actions: []
            )
        }
        // Malformed snapshots remain unverifiable, never a healthy empty list.
        guard obj["checks"] is [[String: Any]] else {
            return HeartbeatIssue(
                id: "doctor-malformed",
                summary: "Doctor snapshot has an unexpected shape.",
                detail: "data/doctor/latest.json exists but has no readable `checks` array, so heartbeat cannot verify the health checklist.",
                priority: 20,
                actions: []
            )
        }
        struct DoctorSnapshot: Decodable { let checks: [CheckResult] }
        guard let snapshot = try? JSONDecoder().decode(DoctorSnapshot.self, from: data) else {
            return HeartbeatIssue(
                id: "doctor-malformed",
                summary: "Doctor finding ownership is unavailable.",
                detail: "The body report could not be read, so heartbeat cannot verify the health checklist. Resolve the body report read error before judging failures.",
                priority: 20,
                actions: []
            )
        }
        let judged = snapshot.checks.filter { DoctorHeartbeatPolicy.isEligible($0.id) }
        let owned = Set(judged.filter {
            DoctorOwner.of($0, repairAvailable: $0.repair_available == true) != nil
        }.map(\.id))
        let fails = judged.filter { $0.status == "fail" && owned.contains($0.id) }
        guard !fails.isEmpty else { return nil }
        let failedIDs = fails.map(\.id).joined(separator: ", ")
        return HeartbeatIssue(
            id: "doctor-failing",
            summary: "Doctor has \(fails.count) failing check(s).",
            detail: failedIDs.isEmpty
                ? "Doctor currently reports \(fails.count) failing check(s)."
                : "Doctor currently reports \(fails.count) failing check(s): \(failedIDs).",
            priority: 10,
            actions: []
        )
    }
    private func heartbeatExecutionsIssue(
        dataRoot: URL,
        now: Date,
        deadline: (Date) -> Void = { _ in }
    ) -> HeartbeatIssue? {
        let executionsDir = dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
        var stale: [(id: String, title: String, status: String, age: TimeInterval)] = []
        if let subs = try? FileManager.default.contentsOfDirectory(
            at: executionsDir, includingPropertiesForKeys: nil) {
            for sub in subs {
                let mp = ExecutionRecordFile.canonicalPath(in: sub)
                guard let data = try? Data(contentsOf: mp),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = obj["status"] as? String else { continue }
                guard ["queued", "running", "blocked_on_approval"].contains(status) else { continue }
                let updated = obj["updated_at"] as? String
                let created = obj["created_at"] as? String
                guard let age = heartbeatAgeSeconds(updatedAt: updated, createdAt: created, now: now,
                        crossingAge: heartbeatExecutionStuckAge, deadline: deadline),
                      age >= heartbeatExecutionStuckAge else { continue }
                let id = obj["id"] as? String ?? sub.lastPathComponent
                let title = obj["title"] as? String ?? id
                stale.append((id: id, title: title, status: status, age: age))
            }
        }
        guard !stale.isEmpty else { return nil }
        let rows = stale.prefix(5).map {
            "\($0.title) [\($0.status), \(heartbeatCompactAge($0.age)) old]"
        }.joined(separator: "; ")
        let hasBlocked = stale.contains { $0.status == "blocked_on_approval" }
        return HeartbeatIssue(
            id: "execution-stuck", // compatibility wire ID: persisted in heartbeat status/dedup state
            summary: "\(stale.count) Desk execution(s) look stuck.",
            detail: "\(stale.count) Desk execution(s) have been queued/running/blocked longer than \(Int(heartbeatExecutionStuckAge / 3600))h: \(rows).",
            priority: 35,
            actions: hasBlocked
                ? [HeartbeatCardAction.openApprovals.noticeAction]
                : []
        )
    }
    /// "2h 13m" / "13m" / "under 1m".
    public func heartbeatCompactAge(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 { return "\(minutes)m" }
        return "under 1m"
    }
    private func heartbeatErrorBurstIssue(
        dataRoot: URL,
        now: Date,
        deadline: (Date) -> Void = { _ in }
    ) -> HeartbeatIssue? {
        let statuses = ErrorFeeds.scanErrorFeeds(dataRoot: dataRoot, now: now)
        statuses.compactMap(\.earliestExpiry).forEach(deadline)
        let windowMinutes = Int(ErrorFeeds.errorBurstWindow / 60)
        let total = statuses.reduce(0) { $0 + $1.recentCount }

        // Error-only sinks can be absent or quiet during healthy operation.
        // Availability is a file-access fact, not time since the last error.
        let unreadable = statuses.filter {
            let path = $0.feed.url(dataRoot: dataRoot).path
            return FileManager.default.fileExists(atPath: path)
                && !FileManager.default.isReadableFile(atPath: path)
        }
        if !unreadable.isEmpty {
            return HeartbeatIssue(
                id: "error-feeds-unreadable",
                summary: "Some error logs could not be read.",
                detail: "Unreadable error logs: "
                    + unreadable.map { $0.feed.relativePath }.joined(separator: ", "),
                priority: 30,
                actions: []
            )
        }
        guard total >= ErrorFeeds.errorBurstThreshold else { return nil }
        let samples = statuses
            .flatMap { status in status.recentLines.map { "[\(status.feed.label)] \($0)" } }
            .suffix(3)
            .map(NativeAgentSecretRedactor.redactText)
            .joined(separator: "\n")
        return HeartbeatIssue(
            id: "error-burst",
            summary: "\(total) errors logged in \(windowMinutes)m.",
            detail: "A recent error burst crossed the \(ErrorFeeds.errorBurstThreshold)-row threshold. Recent samples:\n\(samples)",
            priority: 18,
            actions: []
        )
    }
    private func heartbeatStaleTaskIssue(
        dataRoot: URL,
        now: Date,
        deadline: (Date) -> Void = { _ in }
    ) async -> HeartbeatIssue? {
        let stale = ((try? await SwiftNativeTaskLedger(dataRoot: dataRoot).listTasks(includeTerminal: false)) ?? []).filter { task in
            guard [.claimed, .update].contains(task.status), task.owner != nil,
                  let updated = DeskClock.parseISO(task.updatedTs) else { return false }
            deadline(updated.addingTimeInterval(heartbeatClaimStaleAge))
            return now.timeIntervalSince(updated) >= heartbeatClaimStaleAge
        }
        guard !stale.isEmpty else { return nil }
        let rows = stale.prefix(5).map { task -> String in
            let owner = task.owner?.rawValue ?? "?"
            let label = task.title ?? task.taskId
            return "\(label) (owner \(owner), since \(task.updatedTs))"
        }
        let line = "Stale task claims (\(stale.count) >24h no update): " + rows.joined(separator: "; ")
        return HeartbeatIssue(
            id: "task-claims-stale",
            summary: "\(stale.count) task claim(s) are stale.",
            detail: line,
            priority: 45,
            actions: []
        )
    }
    /// Read-only review projection over durable state that should not be
    /// replayed or silently deleted. It is informational rather than a
    /// heartbeat failure: the old rows may be intentional historical residue,
    /// but should have one bounded place where they remain visible.
    private func heartbeatAlertBody(primary: HeartbeatIssue, issues: [HeartbeatIssue]) -> String {
        var parts = [primary.detail]
        let others = issues.filter { $0.id != primary.id }
        if !others.isEmpty {
            parts.append("Other heartbeat findings: " + others.map(\.summary).joined(separator: " "))
        }
        return parts.joined(separator: "\n\n")
    }
    private func heartbeatAgeSeconds(
        updatedAt: String?,
        createdAt: String?,
        now: Date,
        crossingAge: TimeInterval,
        deadline: (Date) -> Void
    ) -> TimeInterval? {
        let raw = [updatedAt, createdAt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let raw, let date = NativeTimestampFormat.parseISO8601(raw) else { return nil }
        deadline(date.addingTimeInterval(crossingAge))
        return max(0, now.timeIntervalSince(date))
    }
    /// Upserts a stable heartbeat-alert card to notifications/inbox.jsonl.
    /// Card id is keyed by condition, not day, so a flapping condition updates
    /// one visible card instead of stacking daily duplicates.
}
