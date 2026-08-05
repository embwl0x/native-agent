import Foundation
import Darwin
import NativeAgentCore
import BackgroundLoops
import ChatOrchestration
import DoctorChecks
import MemoryV2
import PersistenceCore
import ProviderRouting
import DreamREMCycle
import TelegramBot
import ApprovalInbox
import WorkshopExecution
import TrustCenter
import MacControl
import SelfImprovement

// MARK: - Heartbeat and Self-Healing

extension BackgroundLoopsAssembly {
    // MARK: - U2b wave 3 lane A: heartbeat + self-healing

    /// Interval health heartbeat (U2b wave 3, plan design #6). Reads
    /// `HEARTBEAT.md` from the persona dir, gathers a compact live signal
    /// block (pending evolution / stuck executions / Full-Mac expiry / Doctor),
    /// and surfaces deterministic anomalies as stable inbox cards. Clean
    /// assessments skip the LLM; anomalous assessments use the app's own LLM
    /// (heartbeat surface picker) only to phrase the alert. The checklist read,
    /// assessment gather, and notice surface are injected so the BackgroundLoops
    /// module stays dependency-clean (same rule as makeWeeklySelfImprovementLoop).
    static func makeHeartbeatLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        llm: any LLMClient
    ) -> HeartbeatLoop {
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        // Live-verify hook: a terminal-launched bundle can shrink the interval
        // (NATIVE_AGENT_HEARTBEAT_INTERVAL_SECONDS=60) to watch a real tick.
        // The normal `open`-launched app never has this set → twice daily.
        // Floor at 1s: interval ≤ 0 reaches Task.sleep(0) in the scheduler —
        // a tight busy loop hammering the LLM (gpt-5.5 review catch).
        let interval = ProcessInfo.processInfo
            .environment["NATIVE_AGENT_HEARTBEAT_INTERVAL_SECONDS"]
            .flatMap(TimeInterval.init)
            .flatMap { $0.isFinite && $0 >= 1 ? $0 : nil } ?? HeartbeatLoop.defaultInterval
        return HeartbeatLoop(
            interval: interval,
            llm: llm,
            loadChecklist: {
                let path = personaRoot.appendingPathComponent("HEARTBEAT.md")
                return try? String(contentsOf: path, encoding: .utf8)
            },
            gatherAssessment: {
                let closed = await closeResolvedDoctorSelfHealProposals(dataRoot: dataRoot)
                return await gatherHeartbeatAssessment(
                    dataRoot: dataRoot,
                    interval: interval,
                    closedResolvedDoctorProposals: closed
                )
            },
            surfaceNotice: { notice in
                // FIX 3 (A4.5): propagate the inbox-write failure so the loop
                // returns .failed instead of falsely claiming the card surfaced.
                try await upsertHeartbeatNoticeCard(dataRoot: dataRoot, notice: notice)
            }
        )
    }

    /// Self-healing hook (U2b wave 3 item 2). Watches the auto-doctor loop's
    /// latest.json for a healthy→fail transition and errors.jsonl for a burst;
    /// on either, runs a diagnostic LLM pass (diagnostics surface picker) and
    /// files a `needs_diff` evolution proposal with redacted evidence. The
    /// proposal filing is injected so the module gains no SelfImprovement dep
    /// (same rule as WeeklySelfImprovementLoop's fileCodeFinding).
    static func makeSelfHealingHook(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        llm: any LLMClient
    ) -> some EventDeadlineLoopRunner {
        let hook = SelfHealingHook(
            // Domain faults are the primary wake path. The inherited cadence
            // is deliberately only a missed-event integrity verification.
            interval: 24 * 60 * 60,
            llm: llm,
            dataRoot: dataRoot,
            fileProposal: { title, evidence in
                // Rethrow: the hook stamps its cooldown + consumes the doctor
                // transition only on durable success. Swallowing a store-write
                // failure here would burn the cooldown with no proposal filed.
                let store = EvolutionProposalStore(dataRoot: dataRoot)
                _ = try await store.propose(
                    source: .selfHeal, title: title, evidence: evidence)
            },
            closeDoctorFailureProposals: {
                _ = await closeResolvedDoctorSelfHealProposals(dataRoot: dataRoot)
            }
        )
        return SelfHealingEventDeadlineRunner(hook: hook, dataRoot: dataRoot)
    }

    private struct SelfHealingEventDeadlineRunner: EventDeadlineLoopRunner {
        let hook: SelfHealingHook
        let dataRoot: URL

        var loopId: String { hook.loopId }
        var interval: TimeInterval { hook.interval }
        var tickTimeoutOverride: TimeInterval? { hook.tickTimeoutOverride }
        let eventCoalescingDelay: TimeInterval = 0.5

        func tick() async { await hook.tick() }
        func tickOutcome() async -> LoopTickOutcome { await hook.tickOutcome() }

        func physiologyEvents() -> AsyncStream<Void> {
            EventDeadlinePhysiology.storeAndFileEvents(
                paths: [
                    dataRoot.appendingPathComponent("doctor", isDirectory: true)
                        .appendingPathComponent("latest.json"),
                    dataRoot.appendingPathComponent("logs", isDirectory: true)
                        .appendingPathComponent("errors.jsonl"),
                ]
            )
        }

        func nextMeaningfulDeadline(after now: Date) async -> Date? {
            hook.nextMeaningfulDeadline(after: now)
        }
    }

    /// Closes unresolved Doctor-failure self-heal proposals once the current
    /// Doctor snapshot is green again. This keeps the proposal queue honest
    /// after restarts: a no-longer-reproducing Doctor failure should not stay
    /// in `needs_diff` and keep feeding heartbeat alerts.
    @discardableResult
    static func closeResolvedDoctorSelfHealProposals(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> Int {
        guard currentDoctorSnapshotHealthy(dataRoot: dataRoot) == true else { return 0 }

        let store = EvolutionProposalStore(dataRoot: dataRoot)
        let active: [EvolutionProposal]
        do {
            active = try await store.list(statuses: [.needsDiff])
        } catch {
            FileHandle.standardError.write(Data(
                "SelfHealingHook: resolved Doctor proposal scan failed: \(error)\n".utf8))
            return 0
        }

        let staleDoctorProposals = active.filter(isResolvedDoctorSelfHealProposal)
        guard !staleDoctorProposals.isEmpty else { return 0 }

        var closed = 0
        for proposal in staleDoctorProposals {
            do {
                let result = try await store.transition(
                    id: proposal.id,
                    to: .denied,
                    require: [.needsDiff],
                    receipt: "closed automatically: Doctor currently reports healthy and the original failure no longer reproduces",
                    denyReason: "superseded: Doctor is currently healthy before a diff was attached"
                )
                if result.applied { closed += 1 }
            } catch {
                FileHandle.standardError.write(Data(
                    "SelfHealingHook: resolved Doctor proposal close failed for \(proposal.id): \(error)\n".utf8))
            }
        }

        if closed > 0 {
            FileHandle.standardError.write(Data(
                "SelfHealingHook: closed \(closed) resolved Doctor self-heal proposal(s)\n".utf8))
        }
        return closed
    }

    private static func currentDoctorSnapshotHealthy(dataRoot: URL) -> Bool? {
        let doctorPath = dataRoot.appendingPathComponent("doctor", isDirectory: true)
            .appendingPathComponent("latest.json")
        guard let data = try? Data(contentsOf: doctorPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Malformed shape = unknown, not healthy (gpt-5.5 wave-1 NEEDS_FIX).
        guard let checks = obj["checks"] as? [[String: Any]] else {
            return nil
        }
        return !checks.contains { ($0["status"] as? String) == "fail" }
    }

    private static func isResolvedDoctorSelfHealProposal(_ proposal: EvolutionProposal) -> Bool {
        guard proposal.source == .selfHeal, proposal.status == .needsDiff else { return false }
        let title = proposal.title.lowercased()
        let evidence = proposal.evidence.lowercased()
        return title.contains("doctor failure")
            || evidence.contains("doctor health transitioned healthy")
            || evidence.contains("doctor snapshot (failing)")
    }

    private struct HeartbeatIssue: Sendable {
        let id: String
        let summary: String
        let detail: String
        let priority: Int
        let actions: [HeartbeatNoticeAction]
    }

    private static let heartbeatExecutionStuckAge: TimeInterval = 6 * 60 * 60
    private static let heartbeatSelfHealStaleAge: TimeInterval = 6 * 60 * 60
    private static let heartbeatInstalledUnverifiedAge: TimeInterval = 60 * 60
    private static let heartbeatErrorLogTailBytes = 256 * 1024

    /// Composes the heartbeat's live signal block and deterministic verdict.
    /// Clean facts return `.clean` so the loop does not spend an LLM call.
    static func gatherHeartbeatAssessment(
        dataRoot: URL,
        interval: TimeInterval = HeartbeatLoop.defaultInterval,
        closedResolvedDoctorProposals: Int = 0,
        now: Date = Date()
    ) async -> HeartbeatAssessment {
        var sections: [String] = []
        var issues: [HeartbeatIssue] = []

        let doctor = heartbeatDoctorSection(dataRoot: dataRoot)
        sections.append(doctor.line)
        if let issue = doctor.issue { issues.append(issue) }

        let evolution = await heartbeatEvolutionSection(
            dataRoot: dataRoot,
            now: now,
            currentDoctorHealthy: doctor.healthy,
            closedResolvedDoctorProposals: closedResolvedDoctorProposals
        )
        sections.append(evolution.line)
        issues.append(contentsOf: evolution.issues)

        let executions = heartbeatExecutionsSection(dataRoot: dataRoot, now: now)
        sections.append(executions.line)
        if let issue = executions.issue { issues.append(issue) }

        let fullMac = await heartbeatFullMacSection(dataRoot: dataRoot, now: now)
        sections.append(fullMac.line)
        if let issue = fullMac.issue { issues.append(issue) }

        let errors = heartbeatErrorBurstSection(dataRoot: dataRoot, now: now)
        sections.append(errors.line)
        if let issue = errors.issue { issues.append(issue) }

        let staleTasks = await heartbeatStaleTaskSection(dataRoot: dataRoot)
        sections.append(staleTasks.line)
        if let issue = staleTasks.issue { issues.append(issue) }

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

    private static func heartbeatDoctorSection(
        dataRoot: URL
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
        let fails = checks.filter { ($0["status"] as? String) == "fail" }
        let warns = checks.filter { ($0["status"] as? String) == "warn" }
        var line = "Doctor: \(fails.count) failing, \(warns.count) warning, \(checks.count) total."
        if !fails.isEmpty {
            line += " Failing: " + fails.compactMap { $0["id"] as? String }.joined(separator: ", ") + "."
        }
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

    private static func heartbeatEvolutionSection(
        dataRoot: URL,
        now: Date,
        currentDoctorHealthy: Bool?,
        closedResolvedDoctorProposals: Int
    ) async -> (line: String, issues: [HeartbeatIssue]) {
        let store = EvolutionProposalStore(dataRoot: dataRoot)
        guard let active = try? await store.list(statuses: [
            .needsDiff, .proposed, .building, .candidateGreen, .staged, .approved, .installed,
        ]) else {
            return ("Pending evolution: unreadable proposal store.", [
                HeartbeatIssue(
                    id: "evolution-store-unreadable",
                    summary: "Evolution proposal store could not be read.",
                    detail: "Heartbeat could not read data/evolution/proposals.json, so it cannot verify self-evolution state.",
                    priority: 30,
                    actions: []
                )
            ])
        }

        var line: String
        if active.isEmpty {
            line = "Pending evolution: none in flight."
        } else {
            let titles = active.prefix(5).map { "\($0.status.rawValue): \($0.title)" }
            line = "Pending evolution (\(active.count)): " + titles.joined(separator: "; ")
        }
        if closedResolvedDoctorProposals > 0 {
            line += " Closed \(closedResolvedDoctorProposals) resolved Doctor self-heal proposal(s) before assessment."
        }

        var issues: [HeartbeatIssue] = []
        let selfHealNeedsDiff = active.filter { $0.source == .selfHeal && $0.status == .needsDiff }
        let resolvedDoctorSelfHeal = selfHealNeedsDiff.filter(isResolvedDoctorSelfHealProposal)
        if currentDoctorHealthy == true, !resolvedDoctorSelfHeal.isEmpty {
            issues.append(HeartbeatIssue(
                id: "doctor-self-heal-stale",
                summary: "\(resolvedDoctorSelfHeal.count) resolved Doctor self-heal proposal(s) still need closure.",
                detail: "Doctor is currently healthy, but \(resolvedDoctorSelfHeal.count) Doctor-failure self-heal proposal(s) are still in needs_diff.",
                priority: 15,
                actions: [
                    HeartbeatNoticeAction(
                        id: "repair",
                        label: "Repair",
                        description: "Close resolved Doctor self-heal proposals"
                    )
                ]
            ))
        } else {
            let staleSelfHeal = selfHealNeedsDiff.filter {
                heartbeatAgeSeconds(updatedAt: $0.updatedAt, createdAt: $0.createdAt, now: now)
                    .map { $0 >= heartbeatSelfHealStaleAge } ?? false
            }
            if !staleSelfHeal.isEmpty {
                let titles = staleSelfHeal.prefix(3).map(\.title).joined(separator: "; ")
                issues.append(HeartbeatIssue(
                    id: "self-heal-needs-diff",
                    summary: "\(staleSelfHeal.count) self-heal proposal(s) still need a diff.",
                    detail: "Self-heal proposal(s) have been in needs_diff for over \(Int(heartbeatSelfHealStaleAge / 3600))h: \(titles).",
                    priority: 25,
                    actions: []
                ))
            }
        }

        let unverifiedInstalls = active.filter {
            $0.status == .installed
                && (heartbeatAgeSeconds(updatedAt: $0.updatedAt, createdAt: $0.createdAt, now: now)
                    .map { $0 >= heartbeatInstalledUnverifiedAge } ?? false)
        }
        if !unverifiedInstalls.isEmpty {
            issues.append(HeartbeatIssue(
                id: "evolution-installed-unverified",
                summary: "\(unverifiedInstalls.count) installed evolution run(s) need verification.",
                detail: "Installed evolution run(s) have not reached verified after \(Int(heartbeatInstalledUnverifiedAge / 60))m.",
                priority: 20,
                actions: []
            ))
        }

        return (line, issues)
    }

    private static func heartbeatExecutionsSection(
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
                let mp = sub.appendingPathComponent("mission.json")
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
        let line = "Workshop executions: \(active) active, \(blocked) blocked on approval."
        guard !stale.isEmpty else { return (line, nil) }
        let rows = stale.prefix(5).map {
            "\($0.title) [\($0.status), \(FullMacExpiry.compactInterval($0.age)) old]"
        }.joined(separator: "; ")
        let hasBlocked = stale.contains { $0.status == "blocked_on_approval" }
        return (
            line + " Stale: " + rows + ".",
            HeartbeatIssue(
                id: "execution-stuck", // compatibility wire ID: persisted in heartbeat status/dedup state
                summary: "\(stale.count) Workshop execution(s) look stuck.",
                detail: "\(stale.count) Workshop execution(s) have been queued/running/blocked longer than \(Int(heartbeatExecutionStuckAge / 3600))h: \(rows).",
                priority: 35,
                actions: hasBlocked
                    ? [HeartbeatNoticeAction(
                        id: "open_approvals",
                        label: "Open Approvals",
                        description: "Review approvals blocking Workshop tasks"
                    )]
                    : []
            )
        )
    }

    private static func heartbeatFullMacSection(
        dataRoot: URL,
        now: Date
    ) async -> (line: String, issue: HeartbeatIssue?) {
        let policyObj = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
        let macPolicy = MacControlPolicy.fromTrustPolicyObject(policyObj)
        let fullMacState = FullMacExpiry.state(macPolicy.trustPolicy ?? MacControlTrustPolicy(), now: now)
        let line = "Full Mac: " + FullMacExpiry.statusLine(fullMacState, now: now)
        switch fullMacState {
        case .active(let expiresAt) where expiresAt.timeIntervalSince(now) <= FullMacExpiry.warningWindow:
            return (line, HeartbeatIssue(
                id: "full-mac-expiring",
                summary: "Full Mac grant is expiring soon.",
                detail: FullMacExpiry.statusLine(fullMacState, now: now),
                priority: 40,
                actions: []
            ))
        case .expired, .unreadable:
            return (line, HeartbeatIssue(
                id: "full-mac-unavailable",
                summary: "Full Mac access is unavailable.",
                detail: FullMacExpiry.statusLine(fullMacState, now: now),
                priority: 40,
                actions: []
            ))
        default:
            return (line, nil)
        }
    }

    private static func heartbeatErrorBurstSection(
        dataRoot: URL,
        now: Date
    ) -> (line: String, issue: HeartbeatIssue?) {
        let path = dataRoot.appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("errors.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: path) else {
            return ("Errors: no recent error burst (no errors.jsonl).", nil)
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(heartbeatErrorLogTailBytes)
            ? size - UInt64(heartbeatErrorLogTailBytes)
            : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return ("Errors: errors.jsonl unreadable.", HeartbeatIssue(
                id: "errors-log-unreadable",
                summary: "Error log could not be read.",
                detail: "Heartbeat could not read data/logs/errors.jsonl.",
                priority: 30,
                actions: []
            ))
        }

        let cutoff = now.addingTimeInterval(-SelfHealingHook.errorBurstWindow)
        var kept: [String] = []
        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let rawTs = obj["createdAt"] as? String
                    ?? obj["at"] as? String
                    ?? obj["ts"] as? String
                    ?? obj["timestamp"] as? String,
                  let ts = parseHeartbeatISO(rawTs) else { continue }
            if ts < cutoff { continue }
            kept.append(line.prefix(280).description)
        }

        let line = "Errors: \(kept.count) recent row(s) in the last \(Int(SelfHealingHook.errorBurstWindow / 60))m."
        guard kept.count >= SelfHealingHook.errorBurstThreshold else { return (line, nil) }
        let samples = kept.prefix(3).joined(separator: "\n")
        return (line, HeartbeatIssue(
            id: "error-burst",
            summary: "\(kept.count) errors logged in \(Int(SelfHealingHook.errorBurstWindow / 60))m.",
            detail: "A recent error burst crossed the \(SelfHealingHook.errorBurstThreshold)-row threshold. Recent samples:\n\(samples)",
            priority: 18,
            actions: []
        ))
    }

    private static func heartbeatStaleTaskSection(
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

    private static func heartbeatAlertBody(primary: HeartbeatIssue, issues: [HeartbeatIssue]) -> String {
        var parts = [primary.detail]
        let others = issues.filter { $0.id != primary.id }
        if !others.isEmpty {
            parts.append("Other heartbeat findings: " + others.map(\.summary).joined(separator: " "))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func heartbeatAgeSeconds(
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

    private static func parseHeartbeatISO(_ raw: String) -> Date? {
        ISO8601DateFormatter().date(from: raw)
            ?? {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f.date(from: raw)
            }()
    }

    private static func heartbeatISO(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private static func writeHeartbeatStatus(
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
                    "actions": .array(issue.actions.map(Self.heartbeatActionJSON)),
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
    private static func upsertHeartbeatNoticeCard(dataRoot: URL, notice: HeartbeatNotice) async throws {
        let inboxPath = heartbeatInboxPath(dataRoot: dataRoot)
        let body = notice.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardId = heartbeatCardID(conditionId: notice.conditionId)
        let now = heartbeatISO(Date())
        let actions = (notice.actions + [
            HeartbeatNoticeAction(id: "archive", label: "Archive", description: "Archive this card"),
            HeartbeatNoticeAction(id: "dismiss", label: "Dismiss", description: "Dismiss this card"),
        ])
        let card: JSONValue = .object([
            "id": .string(cardId),
            "created_at": .string(now),
            "source": .string("heartbeat"),
            "severity": .string("actionable"),
            "title": .string("Heartbeat flagged something"),
            "summary": .string(String(body.prefix(500))),
            "detail": .string(body),
            "condition_id": .string(notice.conditionId),
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .array([]),
            "related_groups": .array([]),
            "actions": .array(actions.map(Self.heartbeatActionJSON)),
            "status": .string("unread"),
            "read_at": .null,
        ])
        let persistence = SwiftNativePersistenceCore()
        do {
            let inserted = try await persistence.withFileLock(inboxPath) { () async throws -> Bool in
                let rows = try await persistence.tailJSONL(inboxPath, limit: Int.max, maxBytes: nil)
                guard InboxRewriteGuard.rewriteIsSafe(rows: rows, path: inboxPath) else {
                    InboxRewriteGuard.refuse("HeartbeatLoop", path: inboxPath)
                    return false
                }
                var mutated: [JSONValue] = []
                mutated.reserveCapacity(rows.count + 1)
                var found = false
                for row in rows {
                    guard case .object(let obj) = row,
                          case .string(let id)? = obj["id"],
                          id == cardId else {
                        mutated.append(row)
                        continue
                    }
                    mutated.append(card)
                    found = true
                }
                if !found { mutated.append(card) }
                try writeHeartbeatJSONLRows(mutated, to: inboxPath)
                return !found
            }
            if inserted {
                await InboxPushNotifier.notifyIfAttentionWorthy(
                    dataRoot: dataRoot,
                    itemId: cardId,
                    title: "Heartbeat flagged something",
                    summary: String(body.prefix(500)),
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

    private static func retireInactiveHeartbeatCards(
        dataRoot: URL,
        activeConditionIDs: Set<String>
    ) async {
        let inboxPath = heartbeatInboxPath(dataRoot: dataRoot)
        let persistence = SwiftNativePersistenceCore()
        let now = heartbeatISO(Date())
        do {
            try await persistence.withFileLock(inboxPath) { () async throws -> Void in
                let rows = try await persistence.tailJSONL(inboxPath, limit: Int.max, maxBytes: nil)
                guard !rows.isEmpty else { return }
                var changed = false
                var mutated: [JSONValue] = []
                mutated.reserveCapacity(rows.count)
                for row in rows {
                    guard case .object(var obj) = row,
                          case .string(let source)? = obj["source"],
                          source == "heartbeat",
                          case .string(let id)? = obj["id"],
                          id.hasPrefix("heartbeat-") else {
                        mutated.append(row)
                        continue
                    }
                    let conditionID: String
                    if case .string(let explicit)? = obj["condition_id"], !explicit.isEmpty {
                        conditionID = explicit
                    } else {
                        conditionID = String(id.dropFirst("heartbeat-".count))
                    }
                    if activeConditionIDs.contains(conditionID) {
                        mutated.append(row)
                        continue
                    }
                    let status: String
                    if case .string(let raw)? = obj["status"] {
                        status = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    } else {
                        status = "unread"
                    }
                    if status == "archived" || status == "dismissed" {
                        mutated.append(row)
                        continue
                    }
                    obj["status"] = .string("archived")
                    obj["read_at"] = .string(now)
                    mutated.append(.object(obj))
                    changed = true
                }
                guard changed else { return }
                try writeHeartbeatJSONLRows(mutated, to: inboxPath)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "HeartbeatLoop: stale card retirement failed: \(error)\n".utf8))
        }
    }

    private static func heartbeatInboxPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    private static func heartbeatCardID(conditionId: String) -> String {
        let cleaned = conditionId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "heartbeat-\(cleaned.isEmpty ? "unknown" : cleaned)"
    }

    private static func heartbeatActionJSON(_ action: HeartbeatNoticeAction) -> JSONValue {
        .object([
            "id": .string(action.id),
            "label": .string(action.label),
            "description": .string(action.description ?? action.label),
        ])
    }

    private static func writeHeartbeatJSONLRows(_ rows: [JSONValue], to path: URL) throws {
        let serialized = try rows.map { try $0.serialize(pretty: false) }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = Data((serialized.joined(separator: "\n") + (serialized.isEmpty ? "" : "\n")).utf8)
        try payload.write(to: path, options: [.atomic])
        _ = chmod(path.path, 0o600)
    }

    static func repairHeartbeatInboxItem(
        id: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> String {
        let conditionID = id.hasPrefix("heartbeat-")
            ? String(id.dropFirst("heartbeat-".count))
            : id
        switch conditionID {
        case "doctor-self-heal-stale":
            let closed = await closeResolvedDoctorSelfHealProposals(dataRoot: dataRoot)
            guard closed > 0 else {
                throw NSError(
                    domain: "NativeAgentSwiftOnly",
                    code: -430,
                    userInfo: [NSLocalizedDescriptionKey:
                        "No resolved Doctor self-heal proposal could be closed. Doctor may still be failing or the proposal was already handled."]
                )
            }
            return "Closed \(closed) resolved Doctor self-heal proposal(s)."
        default:
            throw NSError(
                domain: "NativeAgentSwiftOnly",
                code: -410,
                userInfo: [NSLocalizedDescriptionKey:
                    "Heartbeat condition \(conditionID) does not have a native repair action."]
            )
        }
    }

    // MARK: - U2b wave 2: evolution approval staging glue

    /// Turns GREEN evolution candidates into explicit-human-only approval
    /// cards (plan wave 2). For every proposal at candidate_green/staged:
    ///   • a pending self_evolution.apply approval already exists → ensure
    ///     the visible card + heal the staged status (crash retry path);
    ///   • the newest matching approval was approved/denied → the executor's
    ///     lane, skip;
    ///   • canceled (or no approval yet) → stage a fresh card.
    /// Idempotency is the REM ensure-not-create shape: the dedupe list FAILS
    /// CLOSED (an unreadable inbox stages nothing rather than risking a
    /// duplicate), and card id == approval id so resolve retires the card.
    ///
    /// SAFETY (plan design #7): risk is pinned "critical", the record is
    /// created PENDING and never resolved here, and no auto-approve path
    /// exists for this action — evolution installs always cross a human.
    /// `onlyProposalId` (U4 Wave D, gpt-5.5 review SHOULD-FIX): when set, stage
    /// ONLY that proposal (the `self_install` chat trigger names one explicit
    /// id — staging unrelated green candidates B/C because the caller asked for
    /// A is least-surprise-violating). The background reconcile loop passes nil
    /// → stage all eligible, as before.
    static func stageEvolutionApprovals(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        onlyProposalId: String? = nil
    ) async {
        let store = EvolutionProposalStore(dataRoot: dataRoot)
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        var stageable: [EvolutionProposal]
        do {
            stageable = try await store.list(statuses: [.candidateGreen, .staged])
        } catch {
            FileHandle.standardError.write(Data(
                "EvolutionStager: proposal scan failed: \(error)\n".utf8))
            return
        }
        if let onlyProposalId {
            stageable = stageable.filter { $0.id == onlyProposalId }
        }
        guard !stageable.isEmpty else { return }
        let approvals: [ApprovalRecord]
        do {
            approvals = try await inbox.list(
                filter: ApprovalFilter(action: NativeClient.selfEvolutionAction))
        } catch {
            FileHandle.standardError.write(Data(
                "EvolutionStager: dedupe list failed — staging skipped: \(error)\n".utf8))
            return
        }
        for proposal in stageable {
            guard let runId = proposal.candidateRunId,
                  let diffSha = proposal.diffSHA256 else { continue }
            let matching = approvals
                .filter { rec in
                    guard case .object(let p) = rec.payload,
                          case .string(let pid)? = p["proposalId"] else { return false }
                    return pid == proposal.id
                }
                .sorted { $0.createdAt > $1.createdAt }
            if let pending = matching.first(where: { $0.status == "pending" }) {
                // Heal the crash window between approval-create and the
                // staged transition / card append.
                try? await ensureEvolutionApprovalCard(
                    dataRoot: dataRoot, approvalId: pending.id, proposal: proposal)
                if proposal.status == .candidateGreen {
                    _ = try? await store.transition(
                        id: proposal.id, to: .staged, require: [.candidateGreen],
                        receipt: "staged under approval \(pending.id) (healed)")
                }
                continue
            }
            if let latest = matching.first, latest.decision != "canceled" {
                // approved/denied → the executor owns the next move.
                continue
            }
            // Fresh card (first staging, or re-stage after a canceled card).
            let evidence = await candidateEvidenceSummary(
                dataRoot: dataRoot, runId: runId)
            let body: JSONValue = .object([
                "title": .string("Self-evolution install: \(proposal.title)"),
                "action": .string(NativeClient.selfEvolutionAction),
                "risk": .string(EvolutionProposal.pinnedRisk),
                "reason": .string(
                    "A self-evolution candidate built and tested GREEN in an isolated worktree. "
                    + "Approving commits the change to the live repo"
                    + " and stages a self-install (which only fires once systemRebuild.enabled is on). "
                    + "Denying retires it permanently."),
                "payload": .object([
                    "kind": .string("self_evolution"),
                    "proposalId": .string(proposal.id),
                    "runId": .string(runId),
                    "diffSHA256": .string(diffSha),
                    "expectedHead": .string(proposal.expectedHead ?? ""),
                    "evidence": .string(evidence),
                    "source": .string(proposal.source.rawValue),
                ]),
                "payloadPreview": .string(
                    "[evolution: \(runId)] \(String(proposal.title.prefix(140))) — \(evidence)"),
            ])
            do {
                let rec = try await inbox.create(body)
                try await ensureEvolutionApprovalCard(
                    dataRoot: dataRoot, approvalId: rec.id, proposal: proposal)
                if proposal.status == .candidateGreen {
                    _ = try? await store.transition(
                        id: proposal.id, to: .staged, require: [.candidateGreen],
                        receipt: "staged under approval \(rec.id)")
                } else {
                    try? await store.appendReceipt(
                        id: proposal.id, kind: "re_staged",
                        detail: "fresh card \(rec.id) after cancel")
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "EvolutionStager: stage failed for \(proposal.id): \(error)\n".utf8))
            }
        }
    }

    /// Build/test evidence one-liner from the candidate's persisted verdict.
    private static func candidateEvidenceSummary(dataRoot: URL, runId: String) async -> String {
        let repoRoot = NativeClient.evolutionRepoRoot(dataRoot: dataRoot)
        let builder = EvolutionCandidateBuilder(repoRoot: repoRoot, dataRoot: dataRoot)
        guard let result = try? await builder.loadResult(runId: runId) else {
            return "candidate result unavailable"
        }
        let tests = result.testFilters.isEmpty
            ? (result.testsSkippedReason ?? "full suite")
            : result.testFilters.joined(separator: ", ")
        return "build exit \(result.buildExit.map(String.init) ?? "-"), "
            + "tests (\(tests)) exit \(result.testExit.map(String.init) ?? "-"), "
            + "\(result.touchedPaths.count) file(s) touched"
    }

    /// Card id == approval id (InboxView routes approve/reject through
    /// inboxAction(id) → resolveApproval(id)). Same scan-before-append-
    /// under-flock mechanics as the REM card helper; throws on IO failure so
    /// the stager's caller treats it as stage-failed and retries next pass.
    private static func ensureEvolutionApprovalCard(
        dataRoot: URL,
        approvalId: String,
        proposal: EvolutionProposal
    ) async throws {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let card: JSONValue = .object([
            "id": .string(approvalId),
            "created_at": .string(fmt.string(from: Date())),
            "source": .string("self_evolution"),
            "severity": .string("actionable"),
            "title": .string("Self-evolution install: \(proposal.title)"),
            "summary": .string(String(proposal.evidence.prefix(500))),
            "detail": .string(
                "Approve to commit this verified change to the live repo and stage a "
                + "self-install (fires only once systemRebuild.enabled is on). "
                + "Deny to retire it permanently.\n\nrun: \(proposal.candidateRunId ?? "?")"
                + "\ndiff sha256: \(proposal.diffSHA256 ?? "?")"),
            "related_mission_id": .null,
            "related_approval_id": .string(approvalId),
            "related_paths": .array([
                .string(dataRoot.appendingPathComponent("evolution/proposals.json").path),
            ]),
            "related_groups": .array([]),
            "actions": .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See full detail")]),
                .object(["id": .string("approve"), "label": .string("Approve"),
                         "description": .string("Commit the change and stage the self-install")]),
                .object(["id": .string("reject"), "label": .string("Deny"),
                         "description": .string("Retire this proposal permanently")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ]),
            "status": .string("unread"),
            "read_at": .null,
        ])
        let persistence = SwiftNativePersistenceCore()
        let inserted = try await persistence.withFileLock(inboxPath) { () async throws -> Bool in
            let rows = try await persistence.tailJSONL(inboxPath, limit: Int.max, maxBytes: nil)
            let exists = rows.contains { row in
                guard case .object(let obj) = row,
                      case .string(let id)? = obj["id"] else { return false }
                return id == approvalId
            }
            if exists { return false }
            try await persistence.appendJSONL(card, to: inboxPath)
            return true
        }
        if inserted {
            await InboxPushNotifier.notifyIfAttentionWorthy(
                dataRoot: dataRoot,
                itemId: approvalId,
                title: "Self-evolution install: \(proposal.title)",
                summary: String(proposal.evidence.prefix(500)),
                source: "self_evolution",
                severity: "actionable"
            )
        }
    }
}

// MARK: - Inbox whole-file rewrite guard
//
// The notification inbox upserts read the whole file with `tailJSONL` and then
// rewrite it in place. That read is LOSSY by design: it decodes non-UTF8 bytes
// with replacement and `compactMap`s away every line it cannot parse. So a torn
// or corrupted inbox comes back as `[]`, and rewriting from that silently wipes
// every pending card the user had not seen yet.
//
// Zero rows is only legitimate when the file genuinely holds nothing on disk —
// which must still allow the very first card to be appended.
enum InboxRewriteGuard {
    /// True when it is safe to rewrite `path` from `rows`.
    static func rewriteIsSafe(rows: [JSONValue], path: URL) -> Bool {
        if !rows.isEmpty { return true }
        guard FileManager.default.fileExists(atPath: path.path) else { return true }
        guard let size = (try? FileManager.default.attributesOfItem(
            atPath: path.path
        )[.size]) as? NSNumber else {
            // Present but unstattable: assume it holds cards and refuse.
            return false
        }
        return size.intValue == 0
    }

    /// Logs the refusal on the way out so a skipped upsert is never silent.
    static func refuse(_ label: String, path: URL) {
        FileHandle.standardError.write(Data(
            ("\(label): inbox read returned no rows for a non-empty file at "
             + "\(path.path) — skipping whole-file rewrite to avoid wiping "
             + "pending cards\n").utf8))
    }
}
