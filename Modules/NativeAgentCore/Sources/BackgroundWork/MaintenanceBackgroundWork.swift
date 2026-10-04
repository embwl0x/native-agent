import Foundation
import NativeAgentCore
import BackgroundLoops
import ChatOrchestration
import Context
import DoctorChecks
import PersistenceCore
import TurnTrace
import ApprovalInbox
import WorkshopExecution
import SelfImprovement

// MARK: - Maintenance Loops

public struct MaintenanceBackgroundWork: Sendable {
    private let port: any MaintenanceBackgroundWorkPort

    public init(port: any MaintenanceBackgroundWorkPort) { self.port = port }

    // Maintenance factories remain independently testable; the app-owned
    // production manifest decides which ones have real ingress and consumers.
    /// `freshMeasurement` rebuilds the two memoizing behavioural checks so this
    /// runner MEASURES. A caller that runs because something just became true
    /// (the first real turn landing) must pass `true`, or it republishes the
    /// launch measurement under a new timestamp — Astra audit 2026-09-11
    /// finding 6. The periodic sweep leaves it `false` and keeps the memo.
    public func makeAutoDoctorLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval? = nil,
        freshMeasurement: Bool = false
    ) -> some LoopRunner {
        let config = port.autoDoctorConfig(dataRoot: dataRoot)
        let configuredInterval = config.intervalSeconds
            .map(TimeInterval.init)
            .flatMap { $0.isFinite && $0 >= 3600 ? $0 : nil }
        let interval = intervalSeconds ?? configuredInterval ?? (7 * 24 * 60 * 60)
        let checks = SwiftNativeDoctorChecks(
            checks: freshMeasurement
                ? SwiftNativeDoctorChecks.freshMeasurementChecks()
                : SwiftNativeDoctorChecks.defaultChecks
        )
        return ConfiguredDoctorAutoRunLoop(
            enabled: config.enabled ?? true,
            doctor: DoctorAutoRunLoop(
                interval: interval,
                runChecks: { try await port.runAutoDoctor(checks: checks, dataRoot: dataRoot) }
            )
        )
    }

    /// The mounted six-hour retention wake handles date-named trace expiry,
    /// old orphan lock sidecars, and excess pre-compaction transcript backups.
    /// The generic sweep is bounded, so it drains large historical residue
    /// across wakes instead of turning a maintenance tick into a disk walk.
    public func makeTurnTraceRetentionLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 6 * 60 * 60
    ) -> some LoopRunner {
        TurnTraceRetentionRunner(
            interval: intervalSeconds,
            dataRoot: dataRoot
        )
    }

    /// Off-disk backup of Agent into iCloud Drive: daily, and within one wake of
    /// an identity (persona) write. See `OffDiskBackupRunner`.
    public func makeOffDiskBackupLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        OffDiskBackupRunner(port: port, interval: 24 * 60 * 60, dataRoot: dataRoot)
    }

    /// Weekly, app-owned self-improvement analyzer (replaces the dead janitor
    /// sweep). Reads a week of real usage, asks the app's own LLM what to
    /// improve, and stages runtime-class findings as one-tap-approvable items
    /// via the approval inbox. Gated on the shared unattended-work gate.
    public func selfImprovementSwitchOn() -> Bool {
        // On unless the person switched it off (User: fresh installs turn every
        // feature on). Matches the @AppStorage defaults on the two switches
        // that write this key (SelfImprovementView, SetupFeatureRows).
        UserDefaults.standard.object(forKey: "selfImprovementEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "selfImprovementEnabled")
    }

    public func makeWeeklySelfImprovementLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        llm: any LLMClient
    ) -> WeeklySelfImprovementLoop {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        return WeeklySelfImprovementLoop(
            llm: llm,
            dataRoot: dataRoot,
            isEnabled: {
                guard selfImprovementSwitchOn() else { return false }
                // 2026-09-13: this used to return `!yolo.admitted`, so the one
                // posture User says opens everything — admitted Full Mac YOLO —
                // was the one posture that silenced the loop, while damaged
                // authority (never admitted) RAN it, and Safe with autonomy off
                // ran it too. The unattended-work gate is the single answer to
                // "may the agent work while nobody is looking".
                return await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot)
            },
            stageProposal: { proposal in
                // SKIP-IF-PRESENT (2026-09-06). A sweep that failed partway
                // rolls its weekly marker back, so the next tick re-runs the
                // whole pass — and every proposal that HAD staged got a second
                // card under a fresh UUID. The finding's own content digest
                // rides in the payload and is checked against the pending
                // queue first. Only PENDING rows suppress: a finding the user
                // already approved or denied is free to return in a later week.
                let findingId = proposal.findingId
                if let existing = try? await inbox.list(
                    filter: ApprovalFilter(status: "pending", action: "self_improvement.apply")
                ), existing.contains(where: { record in
                    guard case .object(let payload) = record.payload,
                          case .string(let staged)? = payload["findingId"] else { return false }
                    return staged == findingId
                }) {
                    return
                }
                let body: JSONValue = .object([
                    "title": .string(proposal.title),
                    "action": .string("self_improvement.apply"),
                    "payload": .object([
                        "kind": .string("self_improvement"),
                        "findingId": .string(findingId),
                        "evidence": .string(proposal.evidence),
                        "proposedChange": .string(proposal.proposedChange),
                        "apply": .object([
                            "op": .string(proposal.applyOp ?? ""),
                            "target": .string(proposal.applyTarget ?? ""),
                        ]),
                    ]),
                    // WHAT one tap will do, in words: the op slug
                    // ("[run_memory_hygiene]") stays in the payload, never on
                    // the card (User, 2026-09-25). A skill op names its skill.
                    "payloadPreview": .string(
                        {
                            switch (proposal.applyOp, proposal.applyTarget) {
                            case ("disable_skill"?, let target?): return "Turn off the \(target) skill. "
                            case ("enable_skill"?, let target?): return "Turn on the \(target) skill. "
                            case ("run_memory_hygiene"?, _): return "Approving runs memory hygiene: duplicates merge and test noise clears. "
                            // Any other op still says what the tap runs, in words.
                            case (let op?, _) where !op.isEmpty:
                                return "Approving runs: " + op.replacingOccurrences(of: "_", with: " ") + ". "
                            default: return ""
                            }
                        }() + String(proposal.proposedChange.prefix(180))
                    ),
                ])
                do {
                    _ = try await inbox.create(body)
                } catch {
                    // FIX 3 (A4.5): rethrow so the loop rolls back its weekly
                    // marker (retry next tick) and returns .failed — a swallowed
                    // create() silently dropped the proposal while the pass still
                    // reported "weekly proposals staged".
                    FileHandle.standardError.write(Data(
                        "WeeklySelfImprovement: stage failed for \(proposal.title): \(error)\n".utf8))
                    throw error
                }
            },
            // U2b wave 2: code-class findings stop dying in the digest —
            // they file into the evolution proposal store as `needs_diff`
            // (prose, no patch yet; the diff lane is a deliberate act by
            // Agent/Claude/the user, plan A4). Filed proposals carry the engine's
            // pinned risk=critical + autoApprove=false; nothing here stages
            // an approval card — only a GREEN candidate ever reaches
            // stageEvolutionApprovals.
            fileCodeFinding: { finding in
                let store = EvolutionProposalStore(dataRoot: dataRoot)
                let evidence = finding.evidence
                    + "\n\nproposed change: " + finding.proposedChange
                // Same skip-if-present as the approvals stager above
                // (2026-09-06): a retried sweep re-files every code finding it
                // already filed. Live rows only — a terminal proposal
                // (verified/reverted/denied) is settled and must not block the
                // finding from returning.
                //
                // Second pass, same day: this matched on the title plus the
                // EVIDENCE TEXT, and the evidence carries the week's
                // timestamps — so no two passes ever agreed and the guard never
                // fired. It keys on the finding's own content digest now, the
                // one the approvals stager uses, which is computed over the
                // fields with dates normalised out.
                let findingId = finding.findingId
                if let existing = try? await store.list(),
                   existing.contains(where: {
                       $0.source == .weekly && !$0.status.isTerminal
                           && $0.findingId == findingId
                   }) {
                    return
                }
                do {
                    _ = try await store.propose(
                        source: .weekly,
                        title: finding.title,
                        evidence: evidence,
                        findingId: findingId)
                } catch {
                    // FIX 3 (A4.5): rethrow — a swallowed propose() dropped the
                    // code finding silently while the pass reported success.
                    FileHandle.standardError.write(Data(
                        "WeeklySelfImprovement: evolution filing failed for \(finding.title): \(error)\n".utf8))
                    throw error
                }
            },
            // MEASURE leg (north-star, 2026-06-15): feed the real week-over-week
            // execution-outcome trend into the weekly analysis so the improvement
            // brain sees whether Agent is actually completing more jobs in fewer
            // steps — not just chat/error/doctor proxies. Read-only runner bound
            // to the same dataRoot (the scoreboard only scans mission.json; the
            // planner/executor are unused, hence the bare default construction).
            workshopOutcomes: {
                let runner = SwiftNativeWorkshopRunner(root: dataRoot)
                return WorkshopOutcomeScoreboard.formatForPrompt(await runner.weeklyOutcomeStats())
            }
        )
    }

    /// Weekly retention sweep for the evolution proposal store (tightness round
    /// 2 P-M2). `EvolutionProposalStore.sweep()` drops TERMINAL proposals older
    /// than 30 days; it had zero production callers, so `proposals.json` only ever
    /// grew. Dependency-clean: the prune is an injected closure so BackgroundLoops
    /// gains no SelfImprovement dependency.
    public func makeEvolutionProposalRetentionLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> EvolutionProposalRetentionLoop {
        EvolutionProposalRetentionLoop(
            sweep: {
                try await EvolutionProposalStore(dataRoot: dataRoot).sweep()
            }
        )
    }

    /// Daily disk-hygiene watchdog (tightness round 2, item 6 — User: "make sure
    /// we dont pile up logs like that again burning tons of hard disk" after a
    /// 194MB dead-daemon log was found). Walks `dataRoot` once per day and, when a
    /// single file exceeds 1GB or the tree exceeds 2GB, files ONE notification
    /// card listing the offenders. The loop itself NEVER deletes anything — the
    /// card's "Clean Up" action (user click, `cleanUpDiskHygiene`) is the only
    /// path that moves files, and only to the Trash. Dependency-clean: the
    /// inbox write is an injected closure wired to the same `notifications/inbox.jsonl`
    /// upsert path HeartbeatLoop uses.
    public func makeDataRootDiskHygieneLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> DataRootDiskHygieneCheck {
        DataRootDiskHygieneCheck(
            // A4.8 ride-along: the scheduler sleeps `interval` BEFORE the first
            // tick, so a bare 24h interval starves under frequent deploys (the
            // restart resets the sleep — disk_hygiene_last_run sat 3 days stale
            // by 2026-07-24). Hourly tick + the existing once-per-day
            // reservation = runs once a day, robust to restarts.
            interval: 60 * 60,
            dataRoot: dataRoot,
            fileNotice: { report in
                await fileDiskHygieneNotice(dataRoot: dataRoot, report: report)
            }
        )
    }

    // The weekly self-improvement loop's on/off gate is the
    // "selfImprovementEnabled" UserDefaults flag, owned by the Self-Improvement
    // tab's switch (SelfImprovementView). Read inline in makeWeeklySelfImprovementLoop.

    // MARK: - Disk-hygiene notification

    public let diskHygieneCardId = "disk-hygiene"

    /// Upsert ONE stable disk-hygiene card to `notifications/inbox.jsonl`, keyed
    /// by a fixed id so the daily re-check updates one card instead of stacking
    /// duplicates. Mirrors `upsertHeartbeatNoticeCard`. The scan never deletes
    /// anything — the card carries a "Clean Up" action so the human has the
    /// lever, and an archived card STAYS archived while the finding is
    /// unchanged (an identical daily re-scan must not resurrect it; a changed
    /// report should).
    // Internal (not private) so the sticky-archive contract test can drive the
    // real upsert path — the tooth for "an unchanged re-scan must not
    // resurrect an archived card."
    public func fileDiskHygieneNotice(dataRoot: URL, report: DiskHygieneReport) async -> Bool {
        // Re-validate before writing (gpt-5.5 review: a user-initiated Clean Up
        // can land between this tick's scan and this write; a card listing
        // already-trashed files would sit stale for a day). Offenders that no
        // longer exist are dropped; if nothing actionable remains, skip the
        // write entirely and keep whatever card is already there.
        let report = DiskHygieneReport(
            largeFiles: report.largeFiles.filter {
                FileManager.default.fileExists(
                    atPath: dataRoot.appendingPathComponent($0.relativePath).path)
            },
            totalBytes: report.totalBytes,
            totalOverBudget: report.totalOverBudget,
            truncated: report.truncated,
            depthTruncated: report.depthTruncated,
            largeDirectories: report.largeDirectories.filter {
                FileManager.default.fileExists(
                    atPath: dataRoot.appendingPathComponent($0.relativePath).path)
            }
        )
        guard report.tripped else { return true }
        let now = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        if report.totalOverBudget {
            lines.append("data/ total is \(DataRootDiskHygiene.humanSize(report.totalBytes)) "
                + "(over the \(DataRootDiskHygiene.humanSize(DataRootDiskHygiene.defaultTotalThreshold)) budget).")
        }
        for offender in report.largeDirectories.prefix(10) {
            // A residue store is listed at ANY size and is not a "large branch"
            // finding at all — it is a directory that must not be here. Say
            // which one it is, or the card reads as ordinary growth.
            let residue = DataRootDiskHygiene.isResidue(relativePath: offender.relativePath)
                ? " — residue: this store should not be here" : ""
            lines.append("▸ \(offender.relativePath)/ — "
                + "\(DataRootDiskHygiene.humanSize(offender.sizeBytes)) across the whole branch\(residue)")
        }
        for offender in report.largeFiles.prefix(20) {
            lines.append("• \(offender.relativePath) — \(DataRootDiskHygiene.humanSize(offender.sizeBytes))")
        }
        if report.truncated {
            lines.append("(scan hit its file budget — totals may undercount; largest offenders shown)")
        }
        let detail = ("Large files and directories under the app data directory "
            + "(nothing was deleted):\n"
            + lines.joined(separator: "\n")
            + "\n\nClean Up moves only disposable residue to the Trash (recoverable). Other app data is kept.")
        let summary = report.totalOverBudget
            ? "data/ is \(DataRootDiskHygiene.humanSize(report.totalBytes)); "
                + "\(report.largeFiles.count) large file(s), "
                + "\(report.largeDirectories.count) large director(ies)"
            : "\(report.largeFiles.count) large file(s), "
                + "\(report.largeDirectories.count) large director(ies) in data/"
        let card: JSONValue = .object([
            "id": .string(diskHygieneCardId),
            "created_at": .string(now),
            "source": .string("disk_hygiene"),
            "severity": .string("actionable"),
            "title": .string("Disk usage is piling up"),
            "summary": .string(String(summary.prefix(500))),
            "detail": .string(detail),
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .array(report.largeFiles.prefix(20).map {
                .string(dataRoot.appendingPathComponent($0.relativePath).path)
            }),
            "related_groups": .array([]),
            "actions": .array([
                .object(["id": .string("act"), "label": .string("Clean Up"),
                         "description": .string("Move disposable residue to the Trash")]),
                .object(["id": .string("archive"), "label": .string("Archive"),
                         "description": .string("Archive this card")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ]),
            "status": .string("unread"),
            "read_at": .null,
        ])
        guard let inserted = await upsertDiskHygieneCard(
            dataRoot: dataRoot, card: card, preserveStatusWhenDetailUnchanged: true)
        else { return false }
        if inserted {
            await port.notifyIfAttentionWorthy(
                dataRoot: dataRoot,
                itemId: diskHygieneCardId,
                title: "Disk usage is piling up",
                summary: String(summary.prefix(500)),
                source: "disk_hygiene",
                severity: "actionable"
            )
        }
        return true
    }

    /// User clicked "Clean Up" on the disk-hygiene card. Re-scans `dataRoot`
    /// (the card may be up to a day stale), moves only declared residue to the
    /// Trash via `DataRootDiskHygiene.cleanup` (reversible; protected stores
    /// and anything outside the data root are refused), then rewrites the card
    /// with the results, marked read. Throws when there were offenders but
    /// nothing could be moved, so the button surfaces failure instead of a
    /// silent green. This is the ONLY deletion path — no loop calls it.
    public func cleanUpDiskHygiene(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> String {
        let report = DataRootDiskHygiene.scan(dataRoot: dataRoot)
        let residuePaths = report.largeDirectories
            .filter { DataRootDiskHygiene.isResidue(relativePath: $0.relativePath) }
            .map(\.relativePath)
        let now = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        var summary: String
        var nothingMovedError: NSError?
        if residuePaths.isEmpty {
            summary = "Nothing to clean — no disposable residue right now"
            lines.append("A fresh scan found no disposable residue. Other app data was kept"
                + (report.totalOverBudget
                    ? ", but data/ total is \(DataRootDiskHygiene.humanSize(report.totalBytes)) "
                        + "(over the \(DataRootDiskHygiene.humanSize(DataRootDiskHygiene.defaultTotalThreshold)) budget) — worth a look by hand."
                    : "; data/ total is \(DataRootDiskHygiene.humanSize(report.totalBytes))."))
        } else {
            let result = DataRootDiskHygiene.cleanup(
                dataRoot: dataRoot,
                relativePaths: residuePaths)
            for outcome in result.trashed {
                lines.append("• Moved to Trash: \(outcome.relativePath) — "
                    + DataRootDiskHygiene.humanSize(outcome.sizeBytes))
            }
            for outcome in result.skipped {
                lines.append("• Skipped: \(outcome.relativePath) — "
                    + (outcome.skippedReason ?? "unknown reason"))
            }
            if result.trashed.isEmpty {
                // Still rewrite the card below with the skip reasons before
                // throwing (gpt-5.5 review: throwing first left the stale
                // actionable card up with only an error toast to explain).
                summary = "Cleanup couldn't move anything — "
                    + "\(result.skipped.count) item(s) skipped"
                nothingMovedError = NSError(
                    domain: "NativeAgentSwiftOnly", code: -424,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Disk cleanup could not move anything to the Trash: "
                        + lines.joined(separator: "; ")])
            } else {
                summary = "Moved \(result.trashed.count) residue item(s) to Trash, totaling "
                    + DataRootDiskHygiene.humanSize(result.freedBytes) + " (in the Trash)"
            }
        }
        let card: JSONValue = .object([
            "id": .string(diskHygieneCardId),
            "created_at": .string(now),
            "source": .string("disk_hygiene"),
            "severity": .string("info"),
            "title": .string("Disk cleanup"),
            "summary": .string(String(summary.prefix(500))),
            "detail": .string("Disk cleanup ran at your request:\n" + lines.joined(separator: "\n")),
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .array([]),
            "related_groups": .array([]),
            "actions": .array([
                .object(["id": .string("archive"), "label": .string("Archive"),
                         "description": .string("Archive this card")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ]),
            "status": .string("read"),
            "read_at": .string(now),
        ])
        // Best-effort card rewrite — the cleanup itself already happened, so a
        // failed write must not surface as a failed cleanup.
        _ = await upsertDiskHygieneCard(
            dataRoot: dataRoot, card: card, preserveStatusWhenDetailUnchanged: false)
        if let nothingMovedError { throw nothingMovedError }
        return summary
    }

    /// Shared locked upsert for the single disk-hygiene card. Returns nil on
    /// write failure, else whether the card was newly inserted (true = new
    /// row appended, false = existing row replaced). With
    /// `preserveStatusWhenDetailUnchanged`, an existing row whose `detail`
    /// matches the new card keeps its `status`/`read_at` — the sticky-archive
    /// contract: identical finding, no resurrection.
    private func upsertDiskHygieneCard(
        dataRoot: URL,
        card: JSONValue,
        preserveStatusWhenDetailUnchanged: Bool
    ) async -> Bool? {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let persistence = SwiftNativePersistenceCore()
        do {
            let inserted = try await persistence.withFileLock(inboxPath) { () async throws -> Bool in
                let lines = try InboxRewriteGuard.readLines(inboxPath)
                guard InboxRewriteGuard.rewriteIsSafe(lines: lines, path: inboxPath) else {
                    InboxRewriteGuard.refuse("DiskHygieneLoop", path: inboxPath)
                    return false
                }
                var mutated: [Data] = []
                mutated.reserveCapacity(lines.count + 1)
                var found = false
                for line in lines {
                    guard case .object(let obj)? = line.row,
                          case .string(let id)? = obj["id"],
                          id == diskHygieneCardId else {
                        // Other rows AND undecodable lines: verbatim.
                        mutated.append(line.raw)
                        continue
                    }
                    var replacement = card
                    if preserveStatusWhenDetailUnchanged,
                       case .object(var newObj) = card,
                       case .string(let newDetail)? = newObj["detail"],
                       case .string(let oldDetail)? = obj["detail"],
                       newDetail == oldDetail {
                        newObj["status"] = obj["status"] ?? .string("unread")
                        newObj["read_at"] = obj["read_at"] ?? .null
                        replacement = .object(newObj)
                    }
                    mutated.append(Data(try replacement.serialize(pretty: false).utf8))
                    found = true
                }
                if !found { mutated.append(Data(try card.serialize(pretty: false).utf8)) }
                try InboxRewriteGuard.writeLines(mutated, to: inboxPath)
                return !found
            }
            return inserted
        } catch {
            // A failed upsert must report failure so the loop rolls back the
            // daily reservation and retries delivery on the next tick.
            FileHandle.standardError.write(Data(
                "DataRootDiskHygieneCheck: notice upsert failed: \(error)\n".utf8))
            return nil
        }
    }
}

/// Auto Doctor wrapper that honors the persisted toggle. The scheduler still
/// sees the canonical `doctor_auto_run` id, but disabled means the tick is a
/// no-op instead of running diagnostics.
private struct ConfiguredDoctorAutoRunLoop: LoopRunner {
    let enabled: Bool
    let doctor: DoctorAutoRunLoop

    var loopId: String { doctor.loopId }
    var interval: TimeInterval { doctor.interval }
    var tickTimeoutOverride: TimeInterval? { doctor.tickTimeoutOverride }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        guard enabled else { return .skipped(reason: "auto doctor disabled") }
        return await doctor.tickOutcome()
    }
}

/// M7: prunes `turn_traces/` to the newest ~14 days; the sidecar lifecycle
/// reclaims orphaned locks. A sweep that removes anything says so.
private struct TurnTraceRetentionRunner: LoopRunner {
    let interval: TimeInterval
    let dataRoot: URL

    var loopId: String { "turn_trace_retention" }
    var tickTimeoutOverride: TimeInterval? { 60 }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        do {
            let now = Date()
            let traceReport = try await TurnTraceRetention.enforce(dataRoot: dataRoot, now: now)
            let lockReport = try await FileLockSidecarLifecycle.reapOrphanedSidecars(
                dataRoot: dataRoot,
                now: now
            )
            let backupReport = await ChatCompactionBackupRetention.enforce(dataRoot: dataRoot)
            let legacyContextReport = try await SwiftNativeContextClient(dataRoot: dataRoot)
                .pruneLegacyReceipts(at: now)
            // 2026-09-01 (User): this pass no longer writes
            // `data/logs/maintenance_sweep.jsonl`. It had accumulated 2,921 rows
            // / 613 KB with no production reader — only an eval instrument and
            // its own test. The sweep itself is unchanged; what it removed is
            // still reported through the NSLog lines and the tick outcome below,
            // which is what anyone actually reads.
            if traceReport.removedDays > 0 || traceReport.removedLocks > 0 {
                NSLog("turn_trace_retention: removed %d day file(s) and %d lock(s), kept %d day(s)",
                      traceReport.removedDays, traceReport.removedLocks, traceReport.keptDays)
            }
            if lockReport.reaped > 0 || lockReport.deferred > 0 || lockReport.failures > 0 {
                NSLog("file_lock_sidecar_lifecycle: reaped %d orphan lock(s), deferred %d, failures %d",
                      lockReport.reaped, lockReport.deferred, lockReport.failures)
            }
            if lockReport.failures > 0 {
                return .failed(error: "lock-sidecar sweep had \(lockReport.failures) failed candidate(s)")
            }
            if backupReport.removed > 0 || backupReport.failures > 0 || backupReport.truncated {
                NSLog("chat_compaction_backup_retention: removed %d backup(s), scanned %d session(s), failures %d, truncated %@",
                      backupReport.removed, backupReport.sessionsScanned, backupReport.failures,
                      backupReport.truncated.description)
            }
            if backupReport.failures > 0 {
                return .failed(error: "compaction-backup sweep had \(backupReport.failures) failed session(s)")
            }
            if legacyContextReport.unavailable || legacyContextReport.failedRemovals > 0 {
                return .failed(error: "legacy-context sweep unavailable=\(legacyContextReport.unavailable) failures=\(legacyContextReport.failedRemovals)")
            }
            let bounded = lockReport.deferred > 0
                ? "; \(lockReport.deferred) orphan lock(s) deferred"
                : ""
            let backupBounded = backupReport.truncated
                ? "; compaction-backup scan bounded at \(backupReport.sessionsScanned) sessions"
                : ""
            let legacyContext = legacyContextReport.removed > 0
                ? "; removed \(legacyContextReport.removed) legacy context receipt(s)"
                : ""
            // A sweep that removed nothing and deferred nothing did no work.
            // Reporting it `.completed` every hour kept the dormancy clock
            // fresh regardless of whether retention was actually running.
            let swept = traceReport.removedDays + traceReport.removedLocks
                + lockReport.reaped + backupReport.removed + legacyContextReport.removed
            guard swept > 0 else {
                return .skipped(reason: "nothing past any retention cutoff\(bounded)")
            }
            return .completed(
                result: "maintenance retention removed \(swept) artifact(s)"
                    + "\(bounded)\(backupBounded)\(legacyContext)")
        } catch {
            NSLog("turn_trace_retention: sweep failed: %@", String(describing: error))
            return .failed(error: String(describing: error))
        }
    }
}

/// Versioned off-disk backup (`port.createOffDiskBackup`). The newest
/// `auto-*` folder in iCloud Drive is the clock: a backup runs when it is a day
/// old, or when a persona doc or the personality profile changed after it — at most once per
/// five-minute wake, so a burst of identity writes lands as one version. With
/// iCloud Drive off the tick is an `unavailable:` skip (a WARN row in Doctor);
/// any other failure is `.failed` and an NSLog line.
private struct OffDiskBackupRunner: LoopRunner {
    let port: any MaintenanceBackgroundWorkPort
    let interval: TimeInterval
    let dataRoot: URL

    var loopId: String { "offdisk_backup" }
    var tickTimeoutOverride: TimeInterval? { 15 * 60 }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        // Only the live root goes to iCloud; an alternate (test) root must never
        // write into, or prune, User's backup folder.
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else {
            return .skipped(reason: "alternate data root")
        }
        let parent = port.offDiskBackupParent()
        guard FileManager.default.fileExists(atPath: parent.deletingLastPathComponent().path) else {
            return .skipped(reason: port.unavailableSkipPrefix + "iCloud Drive is off — no off-disk backup")
        }
        do {
            let now = Date()
            let newest = try port.offDiskAutomaticBackups(in: parent).first?.date
            let trigger: String
            // Below the daily check interval, so a once-a-day tick never skips a day.
            if let newest, now.timeIntervalSince(newest) < 20 * 60 * 60 {
                guard let changed = try identityChangedAt(), changed > newest else {
                    return .skipped(reason: "newest off-disk backup is current")
                }
                trigger = "identity change"
            } else {
                trigger = "daily"
            }
            let folder = try await port.createOffDiskBackup(
                reason: "automatic off-disk backup (\(trigger))",
                dataRoot: dataRoot,
                parent: parent,
                now: now
            )
            NSLog("offdisk_backup: wrote %@ (%@)", folder.path, trigger)
            return .completed(result: "off-disk backup \(folder.lastPathComponent) (\(trigger))")
        } catch {
            NSLog("offdisk_backup: FAILED — Agent has no fresh off-disk copy: %@", String(describing: error))
            return .failed(error: "off-disk backup failed: \(error.localizedDescription)")
        }
    }

    /// Newest modification among the persona root's own files (SOUL.md,
    /// GROWTH.md, ...) and the personality profile, which is where identity
    /// writes land.
    private func identityChangedAt() throws -> Date? {
        let fm = FileManager.default
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        guard fm.fileExists(atPath: personaRoot.appendingPathComponent("SOUL.md").path) else {
            throw NSError(domain: "NativeAgentBackup", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Live persona root has no SOUL.md: \(personaRoot.path)",
            ])
        }
        var files = try fm.contentsOfDirectory(
            at: personaRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { !$0.lastPathComponent.hasSuffix(".lock") }
        let profile = dataRoot.appendingPathComponent("memory/profile.json")
        if fm.fileExists(atPath: profile.path) { files.append(profile) }
        return try files.compactMap { url -> Date? in
            let values = try url.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            return values.isRegularFile == true ? values.contentModificationDate : nil
        }.max()
    }
}
