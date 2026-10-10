import Foundation
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import Desk
import ApprovalInbox
import WorkshopExecution
import TrustCenter
import NotificationInbox
import Privacy

// MARK: - Heartbeat and Self-Healing

public struct HeartbeatBackgroundWork: Sendable {
    private let port: any HeartbeatBackgroundWorkPort

    public init(port: any HeartbeatBackgroundWorkPort) { self.port = port }

    // MARK: - U2b wave 3 lane A: heartbeat + self-healing

    /// Interval health heartbeat (U2b wave 3, plan design #6). Reads
    /// `HEARTBEAT.md` from the persona dir, gathers a compact live signal
    /// block (stuck executions / Full-Mac expiry / Doctor),
    /// and surfaces deterministic anomalies as stable inbox cards. Clean
    /// assessments make no notice; anomalies use their per-condition template. The checklist read,
    /// assessment gather, and notice surface are injected so the BackgroundLoops
    /// module stays dependency-clean (same rule as makeWeeklySelfImprovementLoop).
    public func makeHeartbeatLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> HeartbeatLoop {
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        // Live-verify hook: a terminal-launched bundle can shrink the interval
        // (NATIVE_AGENT_HEARTBEAT_INTERVAL_SECONDS=60) to watch a real tick.
        // The normal `open`-launched app never has this set → twice daily.
        // Floor at 1s: interval ≤ 0 reaches Task.sleep(0) in the scheduler —
        // a tight busy loop.
        let interval = ProcessInfo.processInfo
            .environment["NATIVE_AGENT_HEARTBEAT_INTERVAL_SECONDS"]
            .flatMap(TimeInterval.init)
            .flatMap { $0.isFinite && $0 >= 1 ? $0 : nil } ?? HeartbeatLoop.defaultInterval
        return HeartbeatLoop(
            interval: interval,
            loadChecklist: {
                let path = personaRoot.appendingPathComponent("HEARTBEAT.md")
                return try? String(contentsOf: path, encoding: .utf8)
            },
            gatherAssessment: {
                await gatherHeartbeatAssessment(
                    dataRoot: dataRoot,
                    interval: interval
                )
            },
            surfaceNotice: { notice in
                // FIX 3 (A4.5): propagate the inbox-write failure so the loop
                // returns .failed instead of falsely claiming the card surfaced.
                try await upsertHeartbeatNoticeCard(dataRoot: dataRoot, notice: notice)
            }
        )
    }

    /// Drop the rows an UNATTENDED sweep is not allowed to judge.
    ///
    /// 2026-09-02 incident: two new Doctor-only diagnostic rows graded a
    /// rolling history window, went red on pre-fix history, and this sweep
    /// pushed "Doctor has 2 failing checks" to User's phone. Those rows are for
    /// a person LOOKING at Doctor. The exclusion list is derived from the real
    /// check registry (`DoctorHeartbeatPolicy`), never restated here, so a
    /// check's own `heartbeatEligible` flag is the single source of truth.
    ///
    /// Returns the rows the heartbeat may judge plus how many it skipped, so
    /// the signal line can SAY it looked at fewer rows than Doctor shows
    /// rather than silently narrowing.
    public func heartbeatEligibleDoctorRows(
        _ rows: [[String: Any]]
    ) -> (eligible: [[String: Any]], skipped: Int) {
        let eligible = rows.filter { row in
            guard let id = row["id"] as? String else { return true }
            return DoctorHeartbeatPolicy.isEligible(id)
        }
        return (eligible, rows.count - eligible.count)
    }

    private struct HeartbeatIssue: Sendable {
        let id: String
        let summary: String
        let detail: String
        let priority: Int
        let actions: [HeartbeatNoticeAction]
    }

    public struct DurableResidueSummary: Sendable, Equatable {
        let staleWorkflowRunCount: Int
        let staleWorkflowRunIDs: [String]
        let preservedCodexReplyCount: Int
        let terminalBridgeMessageCount: Int
        let terminalBridgeMessages: [String]
        let staleBridgeMessageCount: Int
        let staleBridgeMessages: [String]
        let veryOldDeskItemCount: Int
        let veryOldDeskItems: [String]
        let membershipDigest: String

        var isEmpty: Bool {
            staleWorkflowRunCount == 0
                && preservedCodexReplyCount == 0
                && terminalBridgeMessageCount == 0
                && staleBridgeMessageCount == 0
                && veryOldDeskItemCount == 0
        }

        var signature: String {
            [
                String(staleWorkflowRunCount),
                String(preservedCodexReplyCount),
                String(terminalBridgeMessageCount),
                String(staleBridgeMessageCount),
                String(veryOldDeskItemCount),
                membershipDigest,
            ].joined(separator: "|")
        }

        var signalLine: String {
            "Durable review residue: \(staleWorkflowRunCount) old non-terminal workflow run(s), "
                + "\(preservedCodexReplyCount) preserved Codex reply/replies "
                + "(automatic replay inactive by design), "
                + "\(terminalBridgeMessageCount) terminal bridge delivery failure(s), "
                + "\(staleBridgeMessageCount) bridge message(s) unconsumed over 24h, "
                + "\(veryOldDeskItemCount) open Desk item(s) older than 30d."
        }
    }

    private let heartbeatExecutionStuckAge: TimeInterval = 6 * 60 * 60
    /// A failed candidate is not terminal: it can return to `proposed` after
    /// correction, but it is otherwise easy to leave indefinitely in the one
    /// proposal array. Name that stalled branch before it becomes invisible
    /// behind later, healthy proposals.

    /// Composes the heartbeat's live signal block and deterministic verdict.
    /// Clean facts return `.clean` so the loop does not spend an LLM call.
    public func gatherHeartbeatAssessment(
        dataRoot: URL,
        interval: TimeInterval = HeartbeatLoop.defaultInterval,
        now: Date = Date(),
        bridgeConfigRoot: URL? = nil
    ) async -> HeartbeatAssessment {
        var sections: [String] = []
        var issues: [HeartbeatIssue] = []

        var doctorOwners: [DoctorOwner: [String]]?
        do {
            let body = try await BodyReport.read(dataRoot: dataRoot, now: now)
            doctorOwners = body.doctorOwners
            let owners = [DoctorOwner.app, .owner, .agent, .builder].compactMap { owner in
                body.doctorOwners[owner].map { "\(owner.rawValue) [\($0.joined(separator: ", "))]" }
            }
            sections.append("Body: \(body.organsLine); harness open \(body.openHarness.count)"
                + (body.openHarness.first.map { ", newest \"\($0.title)\"" } ?? "")
                + (owners.isEmpty ? "" : "; Doctor findings by owner: " + owners.joined(separator: ", ")) + ".")
        } catch {
            sections.append("Body: the body report could not be read (\(error.localizedDescription)).")
        }

        let doctor = heartbeatDoctorSection(dataRoot: dataRoot, doctorOwners: doctorOwners)
        sections.append(doctor.line)
        if let issue = doctor.issue { issues.append(issue) }

        let executions = heartbeatExecutionsSection(dataRoot: dataRoot, now: now)
        sections.append(executions.line)
        if let issue = executions.issue { issues.append(issue) }

        let fullMac = await heartbeatFullMacSection(dataRoot: dataRoot)
        sections.append(fullMac.line)
        if let issue = fullMac.issue { issues.append(issue) }

        let errors = heartbeatErrorBurstSection(dataRoot: dataRoot, now: now)
        sections.append(errors.line)
        if let issue = errors.issue { issues.append(issue) }

        let staleTasks = await heartbeatStaleTaskSection(dataRoot: dataRoot)
        sections.append(staleTasks.line)
        if let issue = staleTasks.issue { issues.append(issue) }


        let residue = await heartbeatDurableResidueSummary(
            dataRoot: dataRoot,
            bridgeConfigRoot: bridgeConfigRoot,
            now: now
        )
        sections.append(residue.signalLine)
        await reconcileDurableResidueCard(dataRoot: dataRoot, summary: residue, now: now)

        let signals = sections.joined(separator: "\n")
        let sortedIssues = issues.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority < rhs.priority
        }
        let activeConditionIDs = Set(sortedIssues.map(\.id))
        await retireInactiveHeartbeatCards(dataRoot: dataRoot, activeConditionIDs: activeConditionIDs)

        if let primary = sortedIssues.first {
            let detail = heartbeatAlertBody(primary: primary, issues: sortedIssues)
            let assessment = HeartbeatAssessment(
                signals: signals,
                deterministicOK: false,
                conditionId: primary.id,
                fallbackAlert: detail,
                actions: primary.actions
            )
            await writeHeartbeatStatus(
                dataRoot: dataRoot,
                interval: interval,
                now: now,
                signals: signals,
                issues: sortedIssues,
                assessment: assessment
            )
            return assessment
        }

        let clean = HeartbeatAssessment.clean(signals: signals)
        await writeHeartbeatStatus(
            dataRoot: dataRoot,
            interval: interval,
            now: now,
            signals: signals,
            issues: [],
            assessment: clean
        )
        return clean
    }

    private func heartbeatDoctorSection(
        dataRoot: URL, doctorOwners: [DoctorOwner: [String]]?
    ) -> (line: String, healthy: Bool?, issue: HeartbeatIssue?) {
        let doctorPath = dataRoot.appendingPathComponent("doctor", isDirectory: true)
            .appendingPathComponent("latest.json")
        guard let text = try? String(contentsOf: doctorPath, encoding: .utf8),
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (
                "Doctor: no latest.json (no health snapshot yet).",
                nil,
                HeartbeatIssue(
                    id: "doctor-missing",
                    summary: "Doctor has no latest health snapshot.",
                    detail: "Doctor has not written data/doctor/latest.json yet, so heartbeat cannot verify the health checklist.",
                    priority: 20,
                    actions: []
                )
            )
        }

        // Malformed/shape-shifted snapshot reads as UNVERIFIABLE, not as
        // "0 failing" (gpt-5.5 wave-1 NEEDS_FIX).
        guard let checks = obj["checks"] as? [[String: Any]] else {
            return (
                "Doctor: latest.json is unreadable (unexpected shape).",
                nil,
                HeartbeatIssue(
                    id: "doctor-malformed",
                    summary: "Doctor snapshot has an unexpected shape.",
                    detail: "data/doctor/latest.json exists but has no readable `checks` array, so heartbeat cannot verify the health checklist.",
                    priority: 20,
                    actions: []
                )
            )
        }
        // Doctor-only rows are skipped ENTIRELY here: not counted in the
        // totals, not eligible to raise an alert, not part of the health
        // verdict. They stay fully visible in the Doctor UI.
        let (judged, skipped) = heartbeatEligibleDoctorRows(checks)
        let skippedNote = skipped > 0
            ? " \(skipped) Doctor-only row(s) excluded from the heartbeat by design."
            : ""

        guard let doctorOwners else {
            return (
                "Doctor: finding owners are unavailable; resolve the body report read error above before judging failures.",
                nil,
                HeartbeatIssue(
                    id: "doctor-malformed",
                    summary: "Doctor finding ownership is unavailable.",
                    detail: "The body report could not be read, so heartbeat cannot verify the health checklist. Resolve the body report read error before judging failures.",
                    priority: 20,
                    actions: []
                )
            )
        }
        // Nothing left to judge is UNVERIFIABLE, not "healthy" — the same rule
        // the malformed-snapshot branch above follows.
        guard !judged.isEmpty else {
            return (
                "Doctor: \(checks.count) check(s) in the snapshot, none heartbeat-eligible."
                    + skippedNote,
                nil,
                nil
            )
        }
        let owned = Set(doctorOwners.values.flatMap { $0 })
        let fails = judged.filter { ($0["status"] as? String) == "fail" && owned.contains($0["id"] as? String ?? "") }
        let warns = judged.filter { ($0["status"] as? String) == "warn" && owned.contains($0["id"] as? String ?? "") }
        var line = "Doctor: \(fails.count) failing, \(warns.count) warning, \(judged.count) total."
        if !fails.isEmpty {
            line += " Failing: " + fails.compactMap { $0["id"] as? String }.joined(separator: ", ") + "."
        }
        line += skippedNote
        guard !fails.isEmpty else { return (line, true, nil) }
        let failedIDs = fails.compactMap { $0["id"] as? String }.joined(separator: ", ")
        return (
            line,
            false,
            HeartbeatIssue(
                id: "doctor-failing",
                summary: "Doctor has \(fails.count) failing check(s).",
                detail: failedIDs.isEmpty
                    ? "Doctor currently reports \(fails.count) failing check(s)."
                    : "Doctor currently reports \(fails.count) failing check(s): \(failedIDs).",
                priority: 10,
                actions: []
            )
        )
    }

    private func heartbeatExecutionsSection(
        dataRoot: URL,
        now: Date
    ) -> (line: String, issue: HeartbeatIssue?) {
        let executionsDir = dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
        var active = 0
        var blocked = 0
        var stale: [(id: String, title: String, status: String, age: TimeInterval)] = []
        if let subs = try? FileManager.default.contentsOfDirectory(
            at: executionsDir, includingPropertiesForKeys: nil) {
            for sub in subs {
                let mp = ExecutionRecordFile.resolve(in: sub)
                guard let data = try? Data(contentsOf: mp),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = obj["status"] as? String else { continue }
                if ["queued", "running", "blocked_on_approval"].contains(status) { active += 1 }
                if status == "blocked_on_approval" { blocked += 1 }
                guard ["queued", "running", "blocked_on_approval"].contains(status) else { continue }
                let updated = obj["updated_at"] as? String
                let created = obj["created_at"] as? String
                guard let age = heartbeatAgeSeconds(updatedAt: updated, createdAt: created, now: now),
                      age >= heartbeatExecutionStuckAge else { continue }
                let id = obj["id"] as? String ?? sub.lastPathComponent
                let title = obj["title"] as? String ?? id
                stale.append((id: id, title: title, status: status, age: age))
            }
        }
        let line = "Desk executions: \(active) active, \(blocked) blocked on approval."
        guard !stale.isEmpty else { return (line, nil) }
        let rows = stale.prefix(5).map {
            "\($0.title) [\($0.status), \(heartbeatCompactAge($0.age)) old]"
        }.joined(separator: "; ")
        let hasBlocked = stale.contains { $0.status == "blocked_on_approval" }
        return (
            line + " Stale: " + rows + ".",
            HeartbeatIssue(
                id: "execution-stuck", // compatibility wire ID: persisted in heartbeat status/dedup state
                summary: "\(stale.count) Desk execution(s) look stuck.",
                detail: "\(stale.count) Desk execution(s) have been queued/running/blocked longer than \(Int(heartbeatExecutionStuckAge / 3600))h: \(rows).",
                priority: 35,
                actions: hasBlocked
                    ? [HeartbeatCardAction.openApprovals.noticeAction]
                    : []
            )
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

    /// Full Mac has no timer (2026-09-10): the line states the saved grant,
    /// and there is nothing to warn about.
    private func heartbeatFullMacSection(
        dataRoot: URL
    ) async -> (line: String, issue: HeartbeatIssue?) {
        let policyObj = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
        let macPolicy = MacControlPolicy.fromTrustPolicyObject(policyObj)
        let active = MacControlGate.fullMacActive(
            macPolicy.trustPolicy ?? MacControlTrustPolicy()
        )
        return ("Full Mac: " + (active ? "on" : "off"), nil)
    }

    private func heartbeatErrorBurstSection(
        dataRoot: URL,
        now: Date
    ) -> (line: String, issue: HeartbeatIssue?) {
        let statuses = ErrorFeeds.scanErrorFeeds(dataRoot: dataRoot, now: now)
        let windowMinutes = Int(ErrorFeeds.errorBurstWindow / 60)
        let perFeed = statuses
            .map { "\($0.feed.label) \($0.recentCount) row(s)" }
            .joined(separator: ", ")
        let total = statuses.reduce(0) { $0 + $1.recentCount }
        let line = "Errors observed (last \(windowMinutes)m): \(perFeed)."

        // Error-only sinks can be absent or quiet during healthy operation.
        // Availability is a file-access fact, not time since the last error.
        let unreadable = statuses.filter {
            let path = $0.feed.url(dataRoot: dataRoot).path
            return FileManager.default.fileExists(atPath: path)
                && !FileManager.default.isReadableFile(atPath: path)
        }
        if !unreadable.isEmpty {
            return (line, HeartbeatIssue(
                id: "error-feeds-unreadable",
                summary: "Some error logs could not be read.",
                detail: "Unreadable error logs: "
                    + unreadable.map { $0.feed.relativePath }.joined(separator: ", "),
                priority: 30,
                actions: []
            ))
        }

        guard total >= ErrorFeeds.errorBurstThreshold else { return (line, nil) }
        let samples = statuses
            .flatMap { status in status.recentLines.map { "[\(status.feed.label)] \($0)" } }
            .suffix(3)
            .map(NativeAgentSecretRedactor.redactText)
            .joined(separator: "\n")
        return (line, HeartbeatIssue(
            id: "error-burst",
            summary: "\(total) errors logged in \(windowMinutes)m.",
            detail: "A recent error burst crossed the \(ErrorFeeds.errorBurstThreshold)-row threshold. Recent samples:\n\(samples)",
            priority: 18,
            actions: []
        ))
    }

    private func heartbeatStaleTaskSection(
        dataRoot: URL
    ) async -> (line: String, issue: HeartbeatIssue?) {
        let ledger = SwiftNativeTaskLedger(dataRoot: dataRoot)
        guard let stale = try? await ledger.staleClaims(), !stale.isEmpty else {
            return ("Stale task claims: none.", nil)
        }
        let rows = stale.prefix(5).map { task -> String in
            let owner = task.owner?.rawValue ?? "?"
            let label = task.title ?? task.taskId
            return "\(label) (owner \(owner), since \(task.updatedTs))"
        }
        let line = "Stale task claims (\(stale.count) >24h no update): " + rows.joined(separator: "; ")
        return (line, HeartbeatIssue(
            id: "task-claims-stale",
            summary: "\(stale.count) task claim(s) are stale.",
            detail: line,
            priority: 45,
            actions: []
        ))
    }

    /// Read-only review projection over durable state that should not be
    /// replayed or silently deleted. It is informational rather than a
    /// heartbeat failure: the old rows may be intentional historical residue,
    /// but should have one bounded place where they remain visible.
    public func heartbeatDurableResidueSummary(
        dataRoot: URL,
        bridgeConfigRoot: URL? = nil,
        now: Date = Date()
    ) async -> DurableResidueSummary {
        let workflowCutoff = now.addingTimeInterval(-60 * 60)
        let workflowDir = dataRoot
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("run_state", isDirectory: true)
        let activeWorkflowStatuses: Set<String> = [
            "queued", "ready", "running", "waiting_approval", "awaiting_approval",
            "blocked", "recovery_required",
        ]
        var workflowIDs: [String] = []
        if let files = try? FileManager.default.contentsOfDirectory(
            at: workflowDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for file in files where file.pathExtension.lowercased() == "json" {
                guard let data = try? Data(contentsOf: file),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = (object["status"] as? String)?.lowercased(),
                      activeWorkflowStatuses.contains(status),
                      let rawStamp = object["updatedAt"] as? String
                        ?? object["updated_at"] as? String
                        ?? object["createdAt"] as? String
                        ?? object["created_at"] as? String,
                      let stamp = parseHeartbeatISO(rawStamp),
                      stamp < workflowCutoff else { continue }
                workflowIDs.append((object["id"] as? String) ?? file.deletingPathExtension().lastPathComponent)
            }
        }

        // Scoped to THIS install: only the owner of the machine-wide rendezvous
        // reads `~/.config`, so a fresh root does not report another install's
        // undelivered replies as its own residue.
        let configRoot = bridgeConfigRoot ?? InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        let preservedDir = configRoot
            .appendingPathComponent("codex-nativeagent-bridge", isDirectory: true)
            .appendingPathComponent("reply-jobs", isDirectory: true)
            .appendingPathComponent("undelivered", isDirectory: true)
        let preservedFiles = ((try? FileManager.default.contentsOfDirectory(
            at: preservedDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { file in
            file.pathExtension.lowercased() == "json"
                && ((try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false)
        }

        // The Codex inbox is the durable authority for work NativeAgent tried
        // to hand to Codex. A terminal delivery or an old row with no consume
        // receipt must reach the same bounded review surface as undelivered
        // replies; otherwise the sender and the agent UI disagree about whether
        // delegated work actually crossed the bridge. Historical reply receipts
        // remain compatibility proof for rows written before consumedAt/readAt.
        let codexBridge = configRoot
            .appendingPathComponent("codex-nativeagent-bridge", isDirectory: true)
        let deliveredMessageIDs: Set<String> = {
            let path = codexBridge.appendingPathComponent("reply-deliveries.jsonl")
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
            var ids = Set<String>()
            for line in text.split(whereSeparator: \Character.isNewline) {
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let messageIDs = object["messageIds"] as? [String] else { continue }
                ids.formUnion(messageIDs)
            }
            return ids
        }()
        let bridgeCutoff = now.addingTimeInterval(-24 * 60 * 60)
        let acknowledgedBefore = heartbeatBridgeAcknowledgmentHorizon(dataRoot: dataRoot)
        var terminalBridgeMessages: [String] = []
        var staleBridgeMessages: [String] = []
        let codexInbox = codexBridge.appendingPathComponent("codex-inbox.jsonl")
        if let text = try? String(contentsOf: codexInbox, encoding: .utf8) {
            for line in text.split(whereSeparator: \Character.isNewline) {
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let id = (object["messageId"] as? String) ?? (object["id"] as? String) ?? "unknown"
                let topic = (object["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = (topic?.isEmpty == false ? topic! : id)
                let read = (object["read"] as? Bool) == true
                let consumed = read
                    || !((object["consumedAt"] as? String) ?? "").isEmpty
                    || !((object["readAt"] as? String) ?? "").isEmpty
                let delivery = ((object["deliveryStatus"] as? String) ?? "").lowercased()
                if !read, delivery == "dead_letter" {
                    let reason = (object["deliveryFailureReason"] as? String) ?? "terminal failure"
                    terminalBridgeMessages.append("\(label) (\(reason))")
                    continue
                }
                guard !consumed,
                      !deliveredMessageIDs.contains(id),
                      let created = parseHeartbeatISO(
                        (object["createdAt"] as? String) ?? (object["created_at"] as? String) ?? ""
                      ),
                      created < bridgeCutoff,
                      acknowledgedBefore.map({ created >= $0 }) ?? true else { continue }
                staleBridgeMessages.append(label)
            }
        }

        let deskCutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let deskItems = (try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items) ?? []
        let veryOldDeskItems = deskItems.compactMap { item -> String? in
            guard !item.status.isTerminal,
                  let stamp = parseHeartbeatISO(item.updatedAt),
                  stamp < deskCutoff else { return nil }
            return "\(item.alias): \(item.title)"
        }

        let sortedWorkflowIDs = workflowIDs.sorted()
        let sortedDeskItems = veryOldDeskItems.sorted()
        let membership = [
            sortedWorkflowIDs.joined(separator: "\n"),
            preservedFiles.map(\.lastPathComponent).sorted().joined(separator: "\n"),
            terminalBridgeMessages.sorted().joined(separator: "\n"),
            staleBridgeMessages.sorted().joined(separator: "\n"),
            sortedDeskItems.joined(separator: "\n"),
        ].joined(separator: "\n---\n")
        return DurableResidueSummary(
            staleWorkflowRunCount: sortedWorkflowIDs.count,
            staleWorkflowRunIDs: Array(sortedWorkflowIDs.prefix(8)),
            preservedCodexReplyCount: preservedFiles.count,
            terminalBridgeMessageCount: terminalBridgeMessages.count,
            terminalBridgeMessages: Array(terminalBridgeMessages.sorted().prefix(8)),
            staleBridgeMessageCount: staleBridgeMessages.count,
            staleBridgeMessages: Array(staleBridgeMessages.sorted().prefix(8)),
            veryOldDeskItemCount: sortedDeskItems.count,
            veryOldDeskItems: Array(sortedDeskItems.prefix(8)),
            membershipDigest: heartbeatStableDigest(membership)
        )
    }

    /// Maintains one sticky informational review card. An unchanged summary
    /// preserves read/archive state; a changed summary resurfaces the same id.
    /// Clearing every category archives the card. No underlying workflow,
    /// bridge reply, or Desk row is changed here.
    public func reconcileDurableResidueCard(
        dataRoot: URL,
        summary: DurableResidueSummary,
        now: Date = Date()
    ) async {
        let cardID = "system-health:durable-residue-review"
        let inbox = LiveNotificationInbox(path: heartbeatInboxPath(dataRoot: dataRoot))
        do {
            let rows = try await inbox.rows()
            let existing = rows.first { row in
                guard case .object(let object) = row,
                      case .string(let id)? = object["id"] else { return false }
                return id == cardID
            }
            if summary.isEmpty {
                if existing != nil {
                    _ = try await inbox.updateStatus(
                        id: cardID,
                        status: "archived",
                        readAt: heartbeatISO(now)
                    )
                }
                return
            }
            if case .object(let object)? = existing,
               case .string(let oldSignature)? = object["residue_signature"],
               oldSignature == summary.signature {
                return
            }

            var detail: [String] = [
                "This is a bounded review summary. NativeAgent did not replay, resume, archive, or delete any underlying state.",
                "Old non-terminal workflow runs: \(summary.staleWorkflowRunCount).",
                "Preserved Codex replies: \(summary.preservedCodexReplyCount). Automatic replay is inactive by design because delivery outcome is unknown.",
                "Terminal Codex bridge deliveries: \(summary.terminalBridgeMessageCount). These briefs remain retained and are never treated as consumed.",
                "Codex bridge messages unconsumed over 24h: \(summary.staleBridgeMessageCount). Historical reply receipts count as compatibility proof.",
                "Open Desk items older than 30 days: \(summary.veryOldDeskItemCount).",
            ]
            if !summary.staleWorkflowRunIDs.isEmpty {
                detail.append("Workflow ids: " + summary.staleWorkflowRunIDs.prefix(8).joined(separator: ", "))
            }
            if !summary.veryOldDeskItems.isEmpty {
                detail.append("Old Desk items: " + summary.veryOldDeskItems.prefix(8).joined(separator: "; "))
            }
            if !summary.terminalBridgeMessages.isEmpty {
                detail.append("Terminal bridge messages: " + summary.terminalBridgeMessages.prefix(8).joined(separator: "; "))
            }
            if !summary.staleBridgeMessages.isEmpty {
                detail.append("Unconsumed bridge messages: " + summary.staleBridgeMessages.prefix(8).joined(separator: "; "))
            }
            let timestamp = heartbeatISO(now)
            let card: JSONValue = .object([
                "id": .string(cardID),
                "created_at": .string(timestamp),
                "source": .string("system_health"),
                "severity": .string("info"),
                "title": .string("Durable items ready for occasional review"),
                "summary": .string(summary.signalLine),
                "detail": .string(detail.joined(separator: "\n")),
                "residue_signature": .string(summary.signature),
                "related_mission_id": .null,
                "related_approval_id": .null,
                "related_paths": .array([]),
                "related_groups": .array([]),
                "actions": .array([]),
                "status": .string("unread"),
                "read_at": .null,
            ])
            _ = try await inbox.upsert(card, id: cardID)
        } catch {
            FileHandle.standardError.write(Data(
                "HeartbeatLoop: durable residue review projection failed: \(error)\n".utf8
            ))
        }
    }

    private func heartbeatAlertBody(primary: HeartbeatIssue, issues: [HeartbeatIssue]) -> String {
        var parts = [primary.detail]
        let others = issues.filter { $0.id != primary.id }
        if !others.isEmpty {
            parts.append("Other heartbeat findings: " + others.map(\.summary).joined(separator: " "))
        }
        return parts.joined(separator: "\n\n")
    }

    private func heartbeatStableDigest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// Versioned triage receipts keep an already-reviewed historical failure
    /// era from reappearing as current bridge residue. This is the same
    /// `bridge.undelivered` authority used by the read-only system instrument:
    /// it suppresses only rows older than the exact horizon, never newer work
    /// and never terminal dead letters (which remain separately visible).
    private func heartbeatBridgeAcknowledgmentHorizon(dataRoot: URL) -> Date? {
        let path = dataRoot.deletingLastPathComponent()
            .appendingPathComponent("docs/eval_acknowledgments.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acknowledgments = root["acknowledgments"] as? [[String: Any]],
              let entry = acknowledgments.first(where: {
                ($0["detector"] as? String) == "bridge.undelivered"
              }),
              let horizon = entry["horizon"] as? String else { return nil }
        return parseHeartbeatISO(horizon)
    }

    private func heartbeatAgeSeconds(
        updatedAt: String?,
        createdAt: String?,
        now: Date
    ) -> TimeInterval? {
        let raw = [updatedAt, createdAt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let raw, let date = parseHeartbeatISO(raw) else { return nil }
        return max(0, now.timeIntervalSince(date))
    }

    private func parseHeartbeatISO(_ raw: String) -> Date? {
        ISO8601DateFormatter().date(from: raw)
            ?? {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f.date(from: raw)
            }()
    }

    private func heartbeatISO(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func writeHeartbeatStatus(
        dataRoot: URL,
        interval: TimeInterval,
        now: Date,
        signals: String,
        issues: [HeartbeatIssue],
        assessment: HeartbeatAssessment
    ) async {
        let path = dataRoot.appendingPathComponent("heartbeat", isDirectory: true)
            .appendingPathComponent("status.json")
        let payload: JSONValue = .object([
            "schema_version": .int(1),
            "last_tick_at": .string(heartbeatISO(now)),
            "cadence_seconds": .int(Int64(interval.rounded())),
            "next_tick_no_earlier_than": .string(heartbeatISO(now.addingTimeInterval(interval))),
            "status": .string(assessment.deterministicOK ? "ok" : "alert"),
            "condition_id": .string(assessment.conditionId),
            "summary": .string(assessment.deterministicOK ? "Heartbeat clean" : assessment.fallbackAlert),
            "active_condition_ids": .array(issues.map { .string($0.id) }),
            "issues": .array(issues.map { issue in
                .object([
                    "id": .string(issue.id),
                    "summary": .string(issue.summary),
                    "detail": .string(issue.detail),
                    "priority": .int(Int64(issue.priority)),
                    "actions": .array(issue.actions.map(heartbeatActionJSON)),
                ])
            }),
            "signals": .string(signals),
        ])
        do {
            try await SwiftNativePersistenceCore().writeJSON(payload, to: path)
        } catch {
            FileHandle.standardError.write(Data(
                "HeartbeatLoop: status write failed: \(error)\n".utf8))
        }
    }

    /// Upserts a stable heartbeat-alert card to notifications/inbox.jsonl.
    /// Card id is keyed by condition, not day, so a flapping condition updates
    /// one visible card instead of stacking daily duplicates.
    public func upsertHeartbeatNoticeCard(dataRoot: URL, notice: HeartbeatNotice) async throws {
        let inboxPath = heartbeatInboxPath(dataRoot: dataRoot)
        let body = notice.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardId = heartbeatCardID(conditionId: notice.conditionId)
        let now = heartbeatISO(Date())
        let actions = try HeartbeatCardAction.cardActions(authored: notice.actions)
        let card: [String: JSONValue] = [
            "id": .string(cardId),
            "created_at": .string(now),
            "source": .string("heartbeat"),
            "severity": .string("actionable"),
            "title": .string("Heartbeat flagged something"),
            "summary": .string(String(body.prefix(500))),
            "detail": .string(body),
            "condition_id": .string(notice.conditionId),
            "condition_active": .bool(true),
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .array([]),
            "related_groups": .array([]),
            "actions": .array(actions.map(heartbeatActionJSON)),
            "status": .string("unread"),
            "read_at": .null,
        ]
        do {
            let isNewOccurrence = try await LiveNotificationInbox(path: inboxPath)
                .upsert(id: cardId) { existing in
                    var updated = card
                    if case .object(let previous)? = existing,
                       previous["condition_active"] != .bool(false) {
                        for key in ["status", "read_at", "created_at"] {
                            if let value = previous[key] { updated[key] = value }
                        }
                        return (.object(updated), false)
                    }
                    return (.object(updated), true)
                }
            if isNewOccurrence {
                await port.notifyIfAttentionWorthy(
                    dataRoot: dataRoot,
                    itemId: cardId,
                    title: "Heartbeat flagged something",
                    summary: String(body.prefix(420)) + "\nFlagged at \(now)",
                    source: "heartbeat",
                    severity: "actionable"
                )
            }
        } catch {
            FileHandle.standardError.write(Data(
                "HeartbeatLoop: notice upsert failed: \(error)\n".utf8))
            throw error
        }
    }

    private func retireInactiveHeartbeatCards(
        dataRoot: URL,
        activeConditionIDs: Set<String>
    ) async {
        let inboxPath = heartbeatInboxPath(dataRoot: dataRoot)
        let persistence = SwiftNativePersistenceCore()
        let now = heartbeatISO(Date())
        do {
            try await persistence.withFileLock(inboxPath) { () async throws -> Void in
                let lines = try InboxRewriteGuard.readLines(inboxPath)
                guard !lines.isEmpty else { return }
                var changed = false
                var mutated: [Data] = []
                mutated.reserveCapacity(lines.count)
                for line in lines {
                    guard case .object(var obj)? = line.row,
                          case .string(let source)? = obj["source"],
                          source == "heartbeat",
                          case .string(let id)? = obj["id"],
                          id.hasPrefix("heartbeat-") else {
                        // Other rows AND undecodable lines: verbatim.
                        mutated.append(line.raw)
                        continue
                    }
                    let conditionID: String
                    if case .string(let explicit)? = obj["condition_id"], !explicit.isEmpty {
                        conditionID = explicit
                    } else {
                        conditionID = String(id.dropFirst("heartbeat-".count))
                    }
                    if activeConditionIDs.contains(conditionID) {
                        mutated.append(line.raw)
                        continue
                    }
                    let status: String
                    if case .string(let raw)? = obj["status"] {
                        status = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    } else {
                        status = "unread"
                    }
                    if (status == "archived" || status == "dismissed"),
                       obj["condition_active"] == .bool(false) {
                        mutated.append(line.raw)
                        continue
                    }
                    obj["condition_active"] = .bool(false)
                    if status != "archived" && status != "dismissed" {
                        obj["status"] = .string("archived")
                        obj["read_at"] = .string(now)
                    }
                    mutated.append(Data(try JSONValue.object(obj).serialize(pretty: false).utf8))
                    changed = true
                }
                guard changed else { return }
                try InboxRewriteGuard.writeLines(mutated, to: inboxPath)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "HeartbeatLoop: stale card retirement failed: \(error)\n".utf8))
        }
    }

    private func heartbeatInboxPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    private func heartbeatCardID(conditionId: String) -> String {
        let cleaned = conditionId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "heartbeat-\(cleaned.isEmpty ? "unknown" : cleaned)"
    }

    private func heartbeatActionJSON(_ action: HeartbeatNoticeAction) -> JSONValue {
        .object([
            "id": .string(action.id),
            "label": .string(action.label),
            "description": .string(action.description ?? action.label),
        ])
    }

    public func repairHeartbeatInboxItem(
        id: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> String {
        let conditionID = id.hasPrefix("heartbeat-")
            ? String(id.dropFirst("heartbeat-".count))
            : id
        switch conditionID {
        default:
            throw NSError(
                domain: "NativeAgentSwiftOnly",
                code: -410,
                userInfo: [NSLocalizedDescriptionKey:
                    "Heartbeat condition \(conditionID) does not have a native repair action."]
            )
        }
    }

}
