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
// Blueprint: | `HeartbeatHealthAssessment.swift` | Heartbeat health from owner-reported conditions; time windows project recorded evidence |
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
        _ = await heartbeatErrorBurstIssue(dataRoot: dataRoot, now: now) { deadlines.append($0) }
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

        let jobs = heartbeatJobsIssue(dataRoot: dataRoot)
        if let issue = jobs { issues.append(issue) }

        let errors = await heartbeatErrorBurstIssue(dataRoot: dataRoot, now: now)
        if let issue = errors { issues.append(issue) }

        let blockedTasks = await heartbeatBlockedTaskIssue(dataRoot: dataRoot)
        if let issue = blockedTasks { issues.append(issue) }

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
        struct DoctorSnapshot: Decodable { let checks: [CheckResult] }
        let snapshot: DoctorSnapshot
        do {
            snapshot = try JSONDecoder().decode(DoctorSnapshot.self, from: Data(contentsOf: doctorPath))
        } catch CocoaError.fileReadNoSuchFile {
            return HeartbeatIssue(
                id: "doctor-missing",
                summary: "Doctor has no latest health snapshot.",
                detail: "Doctor has not written data/doctor/latest.json yet, so heartbeat cannot verify the health checklist.",
                priority: 20,
                actions: []
            )
        } catch {
            return HeartbeatIssue(
                id: "doctor-unavailable",
                summary: "Doctor finding ownership is unavailable.",
                detail: """
                    The body report could not be read: \(error.localizedDescription). Repair doctor/latest.json before judging its findings.
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
            detail: "Doctor currently reports \(fails.count) failing check(s): \(failedIDs).",
            priority: 10,
            actions: []
        )
    }
    private func heartbeatJobsIssue(dataRoot: URL) -> HeartbeatIssue? {
        let jobs: [AgentJob]
        do { jobs = try AgentJobStore(dataRoot: dataRoot).jobs() }
        catch {
            return HeartbeatIssue(id: "job-evidence-unavailable", summary: "Job health could not be measured.",
                detail: "\(error.localizedDescription). Repair agents/jobs.json before judging their health.", priority: 30, actions: [])
        }
        let waiting = jobs.filter { $0.state == .needsYou }
        guard !waiting.isEmpty else { return nil }
        let rows = waiting.prefix(5).map {
            "\($0.isOwn ? "your line" : $0.name): \(String($0.brief.prefix(60))) [\($0.state.rawValue)]"
        }.joined(separator: "; ")
        return HeartbeatIssue(
            id: "job-needs-you",
            summary: "\(waiting.count) job(s) need your decision.",
            detail: "The job owner is waiting for you: \(rows).",
            priority: 35,
            actions: [HeartbeatCardAction.openApprovals.noticeAction]
        )
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
    private func heartbeatBlockedTaskIssue(dataRoot: URL) async -> HeartbeatIssue? {
        let tasks: [TaskLedgerTaskState]
        do { tasks = try await SwiftNativeTaskLedger(dataRoot: dataRoot).listTasks(includeTerminal: false) }
        catch {
            return HeartbeatIssue(id: "task-evidence-unavailable", summary: "Task health could not be measured.",
                detail: "\(error.localizedDescription). Repair the task ledger before judging its claims.", priority: 30, actions: [])
        }
        let blocked = tasks.filter { $0.status == .blocked }
        guard !blocked.isEmpty else { return nil }
        let rows = blocked.prefix(5).map { task -> String in
            let ownership = task.owner.map { "owner \($0.rawValue)" } ?? "unassigned"
            let label = task.title ?? task.taskId
            return "\(label) (\(ownership), reported \(task.updatedTs))"
        }
        return HeartbeatIssue(
            id: "tasks-blocked",
            summary: "\(blocked.count) task(s) report a blocker.",
            detail: "The task ledger reports blocked work: " + rows.joined(separator: "; "),
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
}
