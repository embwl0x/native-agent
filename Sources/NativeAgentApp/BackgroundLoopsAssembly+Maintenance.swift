import Foundation
import Darwin
import NativeAgentCore
import BackgroundLoops
import ChatOrchestration
import Context
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

// MARK: - Maintenance Loops

extension BackgroundLoopsAssembly {
    // Maintenance factories remain independently testable; the app-owned
    // production manifest decides which ones have real ingress and consumers.
    static func makeAutoDoctorLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval? = nil
    ) -> some LoopRunner {
        let config = NativeClient.readAutoDoctorConfig(dataRoot: dataRoot)
        let configuredInterval = config.intervalSeconds
            .map(TimeInterval.init)
            .flatMap { $0.isFinite && $0 >= 3600 ? $0 : nil }
        let interval = intervalSeconds ?? configuredInterval ?? (7 * 24 * 60 * 60)
        return ConfiguredDoctorAutoRunLoop(
            enabled: config.enabled ?? true,
            doctor: DoctorAutoRunLoop(
                interval: interval,
                doctorChecks: SwiftNativeDoctorChecks()
            )
        )
    }

    static func makeFullMacExpiryLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 24 * 60 * 60
    ) -> some LoopRunner {
        FullMacExpiryRunner(
            interval: intervalSeconds,
            dataRoot: dataRoot
        )
    }

    /// The mounted six-hour retention wake handles date-named trace expiry,
    /// old orphan lock sidecars, and excess pre-compaction transcript backups.
    /// The generic sweep is bounded, so it drains large historical residue
    /// across wakes instead of turning a maintenance tick into a disk walk.
    static func makeTurnTraceRetentionLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 6 * 60 * 60
    ) -> some LoopRunner {
        TurnTraceRetentionRunner(
            interval: intervalSeconds,
            dataRoot: dataRoot
        )
    }

    /// Weekly, app-owned self-improvement analyzer (replaces the dead janitor
    /// sweep). Reads a week of real usage, asks the app's own LLM what to
    /// improve, and stages runtime-class findings as one-tap-approvable items
    /// via the approval inbox. Gated on the `enableAutonomy` trust switch.
    static func makeWeeklySelfImprovementLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        llm: any LLMClient
    ) -> WeeklySelfImprovementLoop {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let securityCenter = SwiftNativeSecurityCenter(dataRoot: dataRoot)
        return WeeklySelfImprovementLoop(
            llm: llm,
            dataRoot: dataRoot,
            isEnabled: {
                guard UserDefaults.standard.bool(forKey: "selfImprovementEnabled") else {
                    return false
                }
                // Full Mac already supplies temporary runtime authority. A
                // background suggestion is not a validated action executor,
                // so suppress its approval producer instead of prompting or
                // permanently changing policy while YOLO is active.
                let yolo = await securityCenter.fullMacYoloAuthority(
                    tool: "self_improvement.apply",
                    origin: SecurityOriginContext(
                        surface: "desk",
                        source: "weekly_self_improvement",
                        isRemote: false
                    )
                )
                return !yolo.admitted
            },
            stageProposal: { proposal in
                let body: JSONValue = .object([
                    "title": .string(proposal.title),
                    "action": .string("self_improvement.apply"),
                    "payload": .object([
                        "kind": .string("self_improvement"),
                        "evidence": .string(proposal.evidence),
                        "proposedChange": .string(proposal.proposedChange),
                        "apply": .object([
                            "op": .string(proposal.applyOp ?? ""),
                            "target": .string(proposal.applyTarget ?? ""),
                        ]),
                    ]),
                    // Surface the exact op + target so the approval card shows
                    // WHAT one tap will do (e.g. "[disable_skill: foo] ...").
                    "payloadPreview": .string(
                        "[" + (proposal.applyOp ?? "")
                        + (proposal.applyTarget.map { ": \($0)" } ?? "")
                        + "] " + String(proposal.proposedChange.prefix(180))
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
                do {
                    _ = try await store.propose(
                        source: .weekly,
                        title: finding.title,
                        evidence: finding.evidence
                            + "\n\nproposed change: " + finding.proposedChange)
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
    static func makeEvolutionProposalRetentionLoop(
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
    static func makeDataRootDiskHygieneLoop(
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

    static let diskHygieneCardId = "disk-hygiene"

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
    static func fileDiskHygieneNotice(dataRoot: URL, report: DiskHygieneReport) async -> Bool {
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
            // F1: directory offenders survive the existence filter as-is — a
            // branch is not a Clean Up target (nothing here ever trashes a
            // directory), it is the "where did the growth go" line.
            largeDirectories: report.largeDirectories
        )
        guard report.tripped else { return true }
        let now = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        if report.totalOverBudget {
            lines.append("data/ total is \(DataRootDiskHygiene.humanSize(report.totalBytes)) "
                + "(over the \(DataRootDiskHygiene.humanSize(DataRootDiskHygiene.defaultTotalThreshold)) budget).")
        }
        for offender in report.largeDirectories.prefix(10) {
            lines.append("▸ \(offender.relativePath)/ — "
                + "\(DataRootDiskHygiene.humanSize(offender.sizeBytes)) across the whole branch")
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
            + "\n\nClean Up moves these files to the Trash (recoverable).")
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
                         "description": .string("Move these files to the Trash")]),
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
            await InboxPushNotifier.notifyIfAttentionWorthy(
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
    /// (the card may be up to a day stale), moves the CURRENT offenders to the
    /// Trash via `DataRootDiskHygiene.cleanup` (reversible; protected stores
    /// and anything outside the data root are refused), then rewrites the card
    /// with the results, marked read. Throws when there were offenders but
    /// nothing could be moved, so the button surfaces failure instead of a
    /// silent green. This is the ONLY deletion path — no loop calls it.
    static func cleanUpDiskHygiene(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> String {
        let report = DataRootDiskHygiene.scan(dataRoot: dataRoot)
        let now = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        var summary: String
        var nothingMovedError: NSError?
        if report.largeFiles.isEmpty {
            summary = "Nothing to clean — no oversized files right now"
            lines.append("A fresh scan found no oversized files"
                + (report.totalOverBudget
                    ? ", but data/ total is \(DataRootDiskHygiene.humanSize(report.totalBytes)) "
                        + "(over the 2GB budget) from many smaller files — worth a look by hand."
                    : "; data/ total is \(DataRootDiskHygiene.humanSize(report.totalBytes))."))
        } else {
            let result = DataRootDiskHygiene.cleanup(
                dataRoot: dataRoot,
                relativePaths: report.largeFiles.map(\.relativePath))
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
                    + "\(result.skipped.count) file(s) skipped"
                nothingMovedError = NSError(
                    domain: "NativeAgentSwiftOnly", code: -424,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Disk cleanup could not move anything to the Trash: "
                        + lines.joined(separator: "; ")])
            } else {
                summary = "Cleaned up \(result.trashed.count) file(s), freed "
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
    private static func upsertDiskHygieneCard(
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

/// Cheap Full Mac expiry check split out from Auto Doctor. It stages at most
/// one "expiring soon" card and one "expired" card per expiry cycle, without
/// forcing a full Doctor run every five minutes.
private struct FullMacExpiryRunner: EventDeadlineLoopRunner {
    let interval: TimeInterval
    let dataRoot: URL

    var loopId: String { "full_mac_expiry" }
    var tickTimeoutOverride: TimeInterval? { 30 }

    func physiologyEvents() -> AsyncStream<Void> {
        EventDeadlinePhysiology.storeAndFileEvents(paths: [
            BackgroundLoopsAssembly.trustPolicyPath(dataRoot: dataRoot),
        ])
    }

    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        let policy = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
        let macPolicy = MacControlPolicy.fromTrustPolicyObject(policy)
        guard case .active(let expiresAt) = FullMacExpiry.state(
            macPolicy.trustPolicy ?? MacControlTrustPolicy(),
            now: now
        ) else { return nil }
        let warning = expiresAt.addingTimeInterval(-FullMacExpiry.warningWindow)
        if warning > now { return warning }
        return expiresAt > now ? expiresAt : nil
    }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        switch await FullMacExpiryNotifier(dataRoot: dataRoot).runOnce() {
        case .completed(let detail): return .completed(result: detail)
        case .skipped(let reason): return .skipped(reason: reason)
        case .failed(let error): return .failed(error: error)
        }
    }
}

/// M7: prunes `turn_traces/` to the newest ~14 days, taking each day's orphaned
/// `.lock` sidecar with it. Never silent — a sweep that removes anything says so.
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
            let traceReport = try TurnTraceRetention.enforce(dataRoot: dataRoot, now: now)
            let lockReport = try await FileLockSidecarLifecycle.reapOrphanedSidecars(
                dataRoot: dataRoot,
                now: now
            )
            let backupReport = await ChatCompactionBackupRetention.enforce(dataRoot: dataRoot)
            let legacyContextReport = await SwiftNativeContextClient(dataRoot: dataRoot)
                .pruneLegacyReceipts(at: now)
            try await MaintenanceSweepFeed.append(
                traceReport: traceReport,
                lockReport: lockReport,
                dataRoot: dataRoot,
                completedAt: now
            )
            try await MaintenanceSweepFeed.appendCompactionBackupRetention(
                removedArtifactPaths: backupReport.removedArtifactPaths,
                sessionsScanned: backupReport.sessionsScanned,
                failures: backupReport.failures,
                truncated: backupReport.truncated,
                dataRoot: dataRoot,
                completedAt: now
            )
            try await MaintenanceSweepFeed.appendLegacyContextReceiptRetention(
                removedArtifactPaths: legacyContextReport.removedArtifactPaths,
                discovered: legacyContextReport.discovered,
                protected: legacyContextReport.protected,
                failedRemovals: legacyContextReport.failedRemovals,
                unavailable: legacyContextReport.unavailable,
                dataRoot: dataRoot,
                completedAt: now
            )
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
            return .completed(result: "maintenance retention completed\(bounded)\(backupBounded)\(legacyContext)")
        } catch {
            NSLog("turn_trace_retention: sweep failed: %@", String(describing: error))
            return .failed(error: String(describing: error))
        }
    }
}
