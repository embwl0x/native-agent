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
import NotificationInbox

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
    /// latest.json for a healthy→fail transition and the live error sinks
    /// (`SelfHealingHook.errorFeeds`) for a burst;
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
                ] + SelfHealingHook.errorFeeds.map { $0.url(dataRoot: dataRoot) },
                loopId: loopId
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
    static func heartbeatEligibleDoctorRows(
        _ rows: [[String: Any]]
    ) -> (eligible: [[String: Any]], skipped: Int) {
        let eligible = rows.filter { row in
            guard let id = row["id"] as? String else { return true }
            return DoctorHeartbeatPolicy.isEligible(id)
        }
        return (eligible, rows.count - eligible.count)
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
        // Self-heal decisions are unattended too: a Doctor-only row must not
        // hold a resolved proposal open, exactly as it must not raise an alert.
        let judged = heartbeatEligibleDoctorRows(checks).eligible
        // Every row excluded ⇒ nothing was judged. Unknown, not healthy.
        guard !judged.isEmpty else { return nil }
        return !judged.contains { ($0["status"] as? String) == "fail" }
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

    struct DurableResidueSummary: Sendable, Equatable {
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

    private static let heartbeatExecutionStuckAge: TimeInterval = 6 * 60 * 60
    private static let heartbeatSelfHealStaleAge: TimeInterval = 6 * 60 * 60
    /// A failed candidate is not terminal: it can return to `proposed` after
    /// correction, but it is otherwise easy to leave indefinitely in the one
    /// proposal array. Name that stalled branch before it becomes invisible
    /// behind later, healthy proposals.
    private static let heartbeatCandidateFailedAge: TimeInterval = 6 * 60 * 60
    private static let heartbeatInstalledUnverifiedAge: TimeInterval = 60 * 60

    /// Composes the heartbeat's live signal block and deterministic verdict.
    /// Clean facts return `.clean` so the loop does not spend an LLM call.
    static func gatherHeartbeatAssessment(
        dataRoot: URL,
        interval: TimeInterval = HeartbeatLoop.defaultInterval,
        closedResolvedDoctorProposals: Int = 0,
        now: Date = Date(),
        bridgeConfigRoot: URL? = nil
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
        // Doctor-only rows are skipped ENTIRELY here: not counted in the
        // totals, not eligible to raise an alert, not part of the health
        // verdict. They stay fully visible in the Doctor UI.
        let (judged, skipped) = heartbeatEligibleDoctorRows(checks)
        let skippedNote = skipped > 0
            ? " \(skipped) Doctor-only row(s) excluded from the heartbeat by design."
            : ""

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

        let fails = judged.filter { ($0["status"] as? String) == "fail" }
        let warns = judged.filter { ($0["status"] as? String) == "warn" }
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

    private static func heartbeatEvolutionSection(
        dataRoot: URL,
        now: Date,
        currentDoctorHealthy: Bool?,
        closedResolvedDoctorProposals: Int
    ) async -> (line: String, issues: [HeartbeatIssue]) {
        let store = EvolutionProposalStore(dataRoot: dataRoot)
        guard let active = try? await store.list(statuses: [
            .needsDiff, .proposed, .building, .candidateGreen, .candidateFailed,
            .staged, .approved, .installed,
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
                    HeartbeatCardAction.repair.noticeAction
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

        let failedCandidates = active.filter {
            $0.status == .candidateFailed
                && (heartbeatAgeSeconds(updatedAt: $0.updatedAt, createdAt: $0.createdAt, now: now)
                    .map { $0 >= heartbeatCandidateFailedAge } ?? false)
        }
        if !failedCandidates.isEmpty {
            let titles = failedCandidates.prefix(3).map(\.title).joined(separator: "; ")
            issues.append(HeartbeatIssue(
                id: "evolution-candidate-failed",
                summary: "\(failedCandidates.count) evolution candidate(s) failed and need a new diff.",
                detail: "Candidate build/test failures have remained unresolved for over \(Int(heartbeatCandidateFailedAge / 3600))h: \(titles).",
                priority: 18,
                actions: []
            ))
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
            "\($0.title) [\($0.status), \(Self.heartbeatCompactAge($0.age)) old]"
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
    static func heartbeatCompactAge(_ seconds: TimeInterval) -> String {
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
    private static func heartbeatFullMacSection(
        dataRoot: URL
    ) async -> (line: String, issue: HeartbeatIssue?) {
        let policyObj = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
        let macPolicy = MacControlPolicy.fromTrustPolicyObject(policyObj)
        let active = MacControlGate.fullMacActive(
            macPolicy.trustPolicy ?? MacControlTrustPolicy()
        )
        return ("Full Mac: " + (active ? "on" : "off"), nil)
    }

    private static func heartbeatErrorBurstSection(
        dataRoot: URL,
        now: Date
    ) -> (line: String, issue: HeartbeatIssue?) {
        let statuses = SelfHealingHook.scanErrorFeeds(dataRoot: dataRoot, now: now)
        let windowMinutes = Int(SelfHealingHook.errorBurstWindow / 60)
        let perFeed = statuses
            .map { "\($0.feed.label) \($0.summary(now: now))" }
            .joined(separator: ", ")
        let total = statuses.reduce(0) { $0 + $1.recentCount }
        let line = "Errors (last \(windowMinutes)m): \(perFeed)."

        // A feed nobody has written in a week proves nothing. When EVERY
        // watched sink is silent the heartbeat is blind, and reporting that as
        // "0 recent errors … ok" is the lie this guard exists to stop — for
        // three months `logs/errors.jsonl` was the only watched feed and it had
        // no writer at all.
        guard statuses.contains(where: { !$0.silent }) else {
            let days = Int(SelfHealingHook.feedSilentAfter / 86_400)
            return (line, HeartbeatIssue(
                id: "error-feeds-silent",
                summary: "No error feed has been written in \(days)d — error signal is dark.",
                detail: "Heartbeat watches "
                    + SelfHealingHook.errorFeeds.map { $0.relativePath }.joined(separator: ", ")
                    + ". Every one of them is silent, so \"no recent errors\" means "
                    + "\"nothing is reporting\", not \"nothing is wrong\".\n\(perFeed)",
                priority: 30,
                actions: []
            ))
        }

        guard total >= SelfHealingHook.errorBurstThreshold else { return (line, nil) }
        let samples = statuses
            .flatMap { status in status.recentLines.map { "[\(status.feed.label)] \($0)" } }
            .suffix(3)
            .joined(separator: "\n")
        return (line, HeartbeatIssue(
            id: "error-burst",
            summary: "\(total) errors logged in \(windowMinutes)m.",
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

    /// Read-only review projection over durable state that should not be
    /// replayed or silently deleted. It is informational rather than a
    /// heartbeat failure: the old rows may be intentional historical residue,
    /// but should have one bounded place where they remain visible.
    static func heartbeatDurableResidueSummary(
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

        let defaultDataRoot = PersistenceCore.defaultDataRoot().standardizedFileURL
        let configRoot = bridgeConfigRoot ?? (
            dataRoot.standardizedFileURL == defaultDataRoot
                ? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config", isDirectory: true)
                : dataRoot.appendingPathComponent("bridge-config", isDirectory: true)
        )
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
    static func reconcileDurableResidueCard(
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

    private static func heartbeatAlertBody(primary: HeartbeatIssue, issues: [HeartbeatIssue]) -> String {
        var parts = [primary.detail]
        let others = issues.filter { $0.id != primary.id }
        if !others.isEmpty {
            parts.append("Other heartbeat findings: " + others.map(\.summary).joined(separator: " "))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func heartbeatStableDigest(_ value: String) -> String {
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
    private static func heartbeatBridgeAcknowledgmentHorizon(dataRoot: URL) -> Date? {
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
    static func upsertHeartbeatNoticeCard(dataRoot: URL, notice: HeartbeatNotice) async throws {
        let inboxPath = heartbeatInboxPath(dataRoot: dataRoot)
        let body = notice.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardId = heartbeatCardID(conditionId: notice.conditionId)
        let now = heartbeatISO(Date())
        let actions = try HeartbeatCardAction.cardActions(authored: notice.actions)
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
        do {
            let inserted = try await LiveNotificationInbox(path: inboxPath)
                .upsert(card, id: cardId)
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
                    if status == "archived" || status == "dismissed" {
                        mutated.append(line.raw)
                        continue
                    }
                    obj["status"] = .string("archived")
                    obj["read_at"] = .string(now)
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
            // `.approved` is the non-prompt Full Mac deferred-install resume
            // state: promotion succeeded, but the rebuild gate was closed.
            stageable = try await store.list(statuses: [.candidateGreen, .staged, .approved])
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
            let payload: JSONValue = .object([
                "kind": .string("self_evolution"),
                "proposalId": .string(proposal.id),
                "runId": .string(runId),
                "diffSHA256": .string(diffSha),
                "expectedHead": .string(proposal.expectedHead ?? ""),
                "evidence": .string(await candidateEvidenceSummary(
                    dataRoot: dataRoot, runId: runId)),
                "source": .string(proposal.source.rawValue),
            ])
            let yolo = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
                .fullMacYoloAuthority(
                    tool: NativeClient.selfEvolutionAction,
                    origin: SecurityOriginContext(
                        surface: "desk",
                        source: "background_evolution_stager",
                        isRemote: false
                    )
                )
            if yolo.admitted {
                await NativeClient.applyFullMacAdmittedSelfEvolution(
                    payload: payload,
                    deps: .production(dataRoot: dataRoot)
                )
                continue
            }
            if yolo.state == .explicitlyBlocked {
                try? await store.appendReceipt(
                    id: proposal.id,
                    kind: "full_mac_refused",
                    detail: "self_evolution.apply is explicitly blocked; no approval was staged"
                )
                continue
            }
            if proposal.status == .approved {
                // Only the Full Mac admitted lane creates this approval-free
                // deferred state. Outside that grant, leave it deferred and
                // never translate it back into a prompt.
                continue
            }
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
                "payload": payload,
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
        let inserted = try await LiveNotificationInbox(path: inboxPath)
            .appendUnique(card, id: approvalId)
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
// The notification inbox upserts read the whole file and rewrite it in place.
// The old read (`tailJSONL`) was LOSSY: it decoded non-UTF8 bytes with
// replacement and `compactMap`ed away every line it could not parse, so a
// single malformed row among valid rows was silently dropped on rewrite, and a
// fully torn inbox came back as `[]` — rewriting from that wiped every pending
// card the user had not seen yet.
//
// The honest shape: `readLines` returns every PHYSICAL line with its original
// bytes, decoded when possible. Rewrite sites mutate only the rows they own
// and pass every other line — decoded or not — through `writeLines` verbatim,
// so corruption is preserved rather than amplified. A trailing torn line
// (crash residue; the flock serializes live appenders) keeps its bytes and
// gains only a terminating newline.
enum InboxRewriteGuard {
    /// One physical line of the inbox file. `row` is nil when the line does
    /// not parse as JSON; such lines must be carried through rewrites as
    /// `raw`, byte-identical.
    struct Line {
        let raw: Data
        let row: JSONValue?
    }

    /// Whole-file read that loses nothing: every physical line comes back,
    /// with its decoded row when it parses. Interior blank lines are kept
    /// (as empty `raw`) so the rewrite preserves them too.
    static func readLines(_ path: URL) throws -> [Line] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return [] }
        let slices: [Data] = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        // Copy each slice: Data slices keep parent byte offsets, and parsers
        // must see zero-based bytes.
        var parts = slices.map { Data($0) }
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts.map { Line(raw: $0, row: try? JSONValue.parse($0)) }
    }

    /// Atomic whole-file replacement from physical lines. An empty array
    /// truncates the file (matches the old serializer's behavior).
    static func writeLines(_ lines: [Data], to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var payload = Data()
        payload.reserveCapacity(lines.reduce(0) { $0 + $1.count + 1 })
        for line in lines {
            payload.append(line)
            payload.append(0x0A)
        }
        try payload.write(to: path, options: [.atomic])
        _ = chmod(path.path, 0o600)
    }

    /// True when it is safe to rewrite `path` from `lines`. With `readLines`
    /// a non-empty file always yields at least one line, so a refusal here
    /// means the read and the file disagree — refuse rather than risk wiping
    /// cards. Zero lines is only legitimate when the file genuinely holds
    /// nothing on disk, which must still allow the very first card.
    static func rewriteIsSafe(lines: [Line], path: URL) -> Bool {
        if !lines.isEmpty { return true }
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
            ("\(label): inbox read returned no lines for a non-empty file at "
             + "\(path.path) — skipping whole-file rewrite to avoid wiping "
             + "pending cards\n").utf8))
    }
}
