import AgentConversations
import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import Desk
import ApprovalInbox
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
        _ = heartbeatJobsIssue(dataRoot: dataRoot, now: now) { deadlines.append($0) }
        _ = await heartbeatErrorBurstIssue(dataRoot: dataRoot, now: now) { deadlines.append($0) }
        _ = await heartbeatStaleTaskIssue(dataRoot: dataRoot, now: now) { deadlines.append($0) }
        guard !Task.isCancelled else { return nil }
        _ = await heartbeatDurableResidueSummary(dataRoot: dataRoot, now: now) { deadlines.append($0) }
        guard !Task.isCancelled else { return nil }
        return deadlines.filter { $0 > now }.min()
    }
    public func gatherHeartbeatAssessment(
        dataRoot: URL,
        now: Date = Date()
    ) async -> HeartbeatAssessment {
        var issues: [HeartbeatIssue] = []

        let doctor = heartbeatDoctorIssue(dataRoot: dataRoot)
        if let issue = doctor { issues.append(issue) }

        let jobs = heartbeatJobsIssue(dataRoot: dataRoot, now: now)
        if let issue = jobs { issues.append(issue) }

        let errors = await heartbeatErrorBurstIssue(dataRoot: dataRoot, now: now)
        if let issue = errors { issues.append(issue) }

        let staleTasks = await heartbeatStaleTaskIssue(dataRoot: dataRoot, now: now)
        if let issue = staleTasks { issues.append(issue) }

        let residue = await heartbeatDurableResidueSummary(
            dataRoot: dataRoot,
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
                detail: """
                    The body report could not be read, so heartbeat cannot verify the health checklist. Resolve the body report read error before judging \
                    failures.
                    """,
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
    /// A job of the agent's, a line included, that has not moved for the stuck age looks stuck; the deadline is when the next one would cross it.
    private func heartbeatJobsIssue(
        dataRoot: URL,
        now: Date,
        deadline: (Date) -> Void = { _ in }
    ) -> HeartbeatIssue? {
        let jobs: [AgentJob]
        do { jobs = try AgentJobStore(dataRoot: dataRoot).jobs() }
        catch {
            return HeartbeatIssue(id: "job-evidence-unavailable", summary: "Job health could not be measured.",
                detail: "\(error.localizedDescription). Repair agents/jobs.json before judging their health.", priority: 30, actions: [])
        }
        var stale: [(job: AgentJob, age: TimeInterval)] = []
        for job in jobs where !job.state.isTerminal {
            let age = max(0, now.timeIntervalSince(job.updatedAt))
            guard age >= heartbeatJobStuckAge else {
                deadline(job.updatedAt.addingTimeInterval(heartbeatJobStuckAge))
                continue
            }
            stale.append((job, age))
        }
        guard !stale.isEmpty else { return nil }
        let rows = stale.prefix(5).map {
            "\($0.job.isOwn ? "your line" : $0.job.name): \(String($0.job.brief.prefix(60))) [\($0.job.state.rawValue), \(heartbeatCompactAge($0.age)) unmoved]"
        }.joined(separator: "; ")
        let waits = stale.contains { $0.job.state == .needsYou }
        return HeartbeatIssue(
            id: "job-stuck",
            summary: "\(stale.count) job(s) look stuck.",
            detail: "\(stale.count) job(s) have not moved for \(Int(heartbeatJobStuckAge / 3600))h: \(rows).",
            priority: 35,
            actions: waits ? [HeartbeatCardAction.openApprovals.noticeAction] : []
        )
    }
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
    ) async -> HeartbeatIssue? {
        let statuses = await ErrorFeeds.scanErrorFeeds(dataRoot: dataRoot, now: now)
        statuses.compactMap(\.earliestExpiry).forEach(deadline)
        let windowMinutes = Int(ErrorFeeds.errorBurstWindow / 60)
        let total = statuses.reduce(0) { $0 + $1.recentCount }

        // Error-only sinks can be absent or quiet during healthy operation.
        // Availability is a read fact (file or record), not time since the last error.
        let unreadable = statuses.compactMap(\.unavailable)
        if !unreadable.isEmpty {
            return HeartbeatIssue(
                id: "error-feeds-unreadable",
                summary: "Some error logs could not be read.",
                detail: "Unreadable error logs: "
                    + unreadable.joined(separator: ", ") + ". Repair the retained logs before judging error health.",
                priority: 30,
                actions: []
            )
        }
        guard total >= ErrorFeeds.errorBurstThreshold else { return nil }
        let samples = statuses
            .flatMap { status in status.recentLines.map { "[\(status.label)] \($0)" } }
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
        let tasks: [TaskLedgerTaskState]
        do { tasks = try await SwiftNativeTaskLedger(dataRoot: dataRoot).listTasks(includeTerminal: false) }
        catch {
            return HeartbeatIssue(id: "task-evidence-unavailable", summary: "Task health could not be measured.",
                detail: "\(error.localizedDescription). Repair the task ledger before judging its claims.", priority: 30, actions: [])
        }
        let stale = tasks.filter { task in
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
    /// Durable residue needs one bounded review surface; informational visibility cannot replay or delete its state.
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
    /// Condition identity keeps a flapping alert on one card rather than creating daily duplicates.
}
