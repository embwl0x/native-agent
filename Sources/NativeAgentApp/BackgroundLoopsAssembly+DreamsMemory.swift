import Foundation
import Darwin
import NativeAgentCore
import BackgroundLoops
import ChatOrchestration
import CognitiveSubstrate
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

// MARK: - Dreams and Memory Loops

extension BackgroundLoopsAssembly {
    // RETIRED 2026-08-31: `makeREMCycleLoop` / the `rem_cycle` background lane.
    //
    // Weekly REM has exactly one owner — the `nativeagent-weekly-rem`
    // TriggerScheduler job (Sun 04:30 America/Chicago) →
    // SchedulerDueJobRunner.executeREM → NativeClient.runRem →
    // SwiftNativeDreamREMCycle. That path resolves the persona root through
    // PersistenceCore.defaultPersonaRoot (DreamREMCycle.swift:486), so the
    // BUG-C phantom-persona-dir guard the deleted factory carried still holds,
    // and it stages proposals through `makeREMProposalStager` below — the same
    // stager the deleted loop used.
    //
    // Live evidence for the retirement: every row in `data/rem_proposals.jsonl`
    // and every `rem.proposal` approval card is stamped Sunday ~09:30Z (the
    // scheduler job's minute). The duplicate loop's weekly tick never produced
    // a proposal, so it was on course to trip DoctorLoopHealth's dormancy bound
    // (~2026-09-18) and slander a healthy capability.

    /// rem.proposal approval stager: ONE ApprovalInbox record per pending
    /// proposal (NativeClient.resolveApproval's rem.proposal executor applies
    /// approve/deny) plus a card in notifications/inbox.jsonl — the store the
    /// Inbox UI actually reads (NOT the dead inbox/items.jsonl). Returns the
    /// approval id; the proposal store stamps it onto the row so a pipeline
    /// re-run can't double-stage. Mirrors WeeklySelfImprovementLoop's
    /// injected-staging shape (module stays ApprovalInbox-free).
    static func makeREMProposalStager(dataRoot: URL) -> REMApprovalStager {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let securityCenter = SwiftNativeSecurityCenter(dataRoot: dataRoot)
        return { row in
            let yolo = await securityCenter.fullMacYoloAuthority(
                tool: "rem.proposal",
                origin: SecurityOriginContext(
                    surface: "desk",
                    source: "rem_proposal_stager",
                    isRemote: false
                )
            )
            if yolo.admitted || yolo.state == .explicitlyBlocked {
                // The REM store holds its own flock while invoking this
                // closure, so applying the proposal here would recursively
                // acquire that lock. Record an exact non-prompt outcome and
                // leave the proposal pending/unstamped for a later safe lane.
                // Never turn an active Full Mac window into a prompt.
                writeREMFullMacOutcome(
                    dataRoot: dataRoot,
                    row: row,
                    status: yolo.admitted ? "deferred" : "refused",
                    detail: yolo.admitted
                        ? "Full Mac admitted, but REM application is deferred because the proposal store lock is active; no approval was staged."
                        : "rem.proposal is explicitly blocked; no approval was staged."
                )
                return nil
            }
            // IDEMPOTENT ensure, not blind create (gpt-5.5 review 2026-06-10):
            // a crash between approval-create and the store's stamp write
            // leaves an unstamped row; the next pass must REUSE the existing
            // pending approval instead of staging a duplicate. The dedupe
            // read FAILS CLOSED — if list() throws we cannot know whether a
            // prior approval exists, and falling through to create could
            // double-stage; return nil and let the next pass retry.
            let pendingREM: [ApprovalRecord]
            do {
                pendingREM = try await inbox.list(
                    filter: ApprovalFilter(status: "pending", action: "rem.proposal"))
            } catch {
                FileHandle.standardError.write(Data(
                    "REMProposalStager: dedupe list failed for \(row.id): \(error)\n".utf8))
                return nil
            }
            if let existing = pendingREM.first(where: { rec in
                guard case .object(let p) = rec.payload,
                      case .object(let proposal)? = p["proposal"],
                      case .string(let pid)? = proposal["id"] else { return false }
                return pid == row.id
            }) {
                do {
                    try await ensureREMProposalInboxCard(
                        dataRoot: dataRoot, approvalId: existing.id, row: row)
                    return existing.id
                } catch {
                    FileHandle.standardError.write(Data(
                        "REMProposalStager: card ensure failed for \(row.id): \(error)\n".utf8))
                    return nil
                }
            }
            let cardTitle = "REM growth lesson"
            let body: JSONValue = .object([
                "title": .string(cardTitle),
                "action": .string("rem.proposal"),
                "risk": .string("medium"),
                // User (2026-07-03): the card should show WHAT SHE PULLED OUT
                // and nothing else — no boilerplate paragraph, no [target]
                // prefix, no payload echo. Empty reason = the Approvals view
                // hides that line entirely; the preview carries her words
                // verbatim and nothing more.
                "reason": .string(""),
                "payload": .object([
                    "kind": .string("rem.proposal"),
                    "proposal": .object([
                        "id": .string(row.id),
                        "targetDoc": .string(row.targetDoc),
                        "proposalText": .string(row.proposalText),
                        "evidenceDates": .array(row.evidenceDates.map { .string($0) }),
                        "confidence": .double(row.confidence),
                        "createdAt": .string(row.createdAt),
                    ]),
                ]),
                "payloadPreview": .string(row.proposalText),
            ])
            do {
                let rec = try await inbox.create(body)
                // Card failure must FAIL the stage (return nil → row stays
                // unstamped → retried next pass, where the dedupe above
                // reuses this approval record and re-attempts the card).
                // Returning the id anyway would stamp the row terminal with
                // no visible card (gpt-5.5 review 2026-06-10).
                try await ensureREMProposalInboxCard(
                    dataRoot: dataRoot, approvalId: rec.id, row: row)
                return rec.id
            } catch {
                FileHandle.standardError.write(Data(
                    "REMProposalStager: stage failed for \(row.id): \(error)\n".utf8))
                return nil
            }
        }
    }

    private static func writeREMFullMacOutcome(
        dataRoot: URL,
        row: REMProposalRow,
        status: String,
        detail: String
    ) {
        let path = dataRoot
            .appendingPathComponent("rem_deferred", isDirectory: true)
            .appendingPathComponent("\(row.id).json")
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let value: JSONValue = .object([
            "proposal_id": .string(row.id),
            "status": .string(status),
            "detail": .string(detail),
            "at": .string(ISO8601DateFormatter().string(from: Date())),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            try? data.write(to: path, options: .atomic)
        }
    }

    /// Card id == approval id: InboxView's approve/reject buttons route
    /// inboxAction(id) → resolveApproval(id), so the ids MUST match.
    /// Idempotent: scans for an existing card with this id before appending,
    /// so the stager's retry/dedupe path can't duplicate cards. Throws on
    /// IO failure — the caller treats that as stage-failed.
    private static func ensureREMProposalInboxCard(
        dataRoot: URL,
        approvalId: String,
        row: REMProposalRow
    ) async throws {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let card: JSONValue = .object([
            "id": .string(approvalId),
            "created_at": .string(fmt.string(from: Date())),
            "source": .string("rem_cycle"),
            "severity": .string("actionable"),
            "title": .string("REM growth lesson"),
            "summary": .string(String(row.proposalText.prefix(220))),
            "detail": .string(
                "Approve to add this compact lesson to GROWTH.md; deny to tombstone it."),
            "related_mission_id": .null,
            "related_approval_id": .string(approvalId),
            "related_paths": .array([
                .string(dataRoot.appendingPathComponent("rem_proposals.jsonl").path),
            ]),
            "related_groups": .array([]),
            "actions": .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See full detail")]),
                .object(["id": .string("approve"), "label": .string("Approve"),
                         "description": .string("Add this compact GROWTH.md lesson")]),
                .object(["id": .string("reject"), "label": .string("Deny"),
                         "description": .string("Tombstone this lesson")]),
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
                title: "REM growth lesson",
                summary: String(row.proposalText.prefix(220)),
                source: "rem_cycle",
                severity: "actionable"
            )
        }
    }

    // `loadGatePolicy` went with `makeREMCycleLoop` (2026-08-31): it existed
    // only to hand that loop a DreamREMGatePolicy. The surviving REM owner
    // reads the same trust policy through NativeClient.swiftREMGateChecked /
    // SwiftNativeDreamREMCycle.loadGatePolicy, so nothing lost a gate.

    static func makeMemoryConsolidationLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        // U3 wave-1 item 6 (2026-06-10): cutover-residue retirement. The old
        // wiring ticked MemoryConsolidationLoop over a JSONL adapter reading
        // <dataRoot>/memory_embeddings.jsonl — a file that no longer exists
        // (live store = memory/memory.sqlite), so every weekly scheduler wake
        // was a guaranteed no-op. The slot now runs the REAL MemoryV2
        // MemoryConsolidator the same way the manual "Run hygiene" path does,
        // and advances <dataRoot>/memory/hygiene_last_run.json. Same loopId,
        // so NSBackgroundActivityScheduler's "memory_consolidation" slot and
        // runTickOnce routing are untouched. The retired JSONL loop type was
        // removed; this is the sole implementation behind the live slot.
        MemoryConsolidationHygieneRunner(dataRoot: dataRoot)
    }

    static func cognitionReplaySourceCommitSink(
        dataRoot: URL,
        runtime: NativeCognitionRuntime? = nil,
        kind: SomaticSignalKind,
        sourceOrgan: String
    ) -> @Sendable () async -> Void {
        let replayRuntime = runtime ?? cognitionRuntime(for: dataRoot)
        return {
            await replayRuntime.ingestOrganismSignal(
                kind: kind,
                sourceOrgan: sourceOrgan,
                prewarmContext: false
            )
        }
    }

    /// Self-half delta provider for the nightly dream prompt. Pulls recent
    /// MemoryV2 records and returns each as one pre-formatted line. The
    /// DreamCycleRunner applies the `_DREAM_DELTA_CHAR_BUDGET` /
    /// `_DREAM_DELTA_COUNT_LIMIT` caps internally.
    ///
    /// Exposed as `static` (not `private`) so the scheduler-driven path
    /// (NativeClient.runDream → SwiftNativeDreamREMCycle) can wire the
    /// same provider; otherwise the scheduled nightly bypasses this
    /// assembly entirely and the Self-half is permanently empty.
    static func makeDreamMemoryDeltaProvider(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> DreamMemoryDeltaProvider {
        let memory = SwiftNativeMemoryV2.resolvedOwner(
            dataRoot: dataRoot,
            alternateRootEmbedder: MockEmbeddingProvider()
        )
        return { @Sendable in
            // The daemon-era design fed `layer="persona_feedback"` deltas.
            // The current Swift chat path doesn't write that tag, AND the
            // MemoryV2 SQLite bridge hardcodes every read-back row to
            // `layer="semantic"` with `tags=nil` (MemoryV2+SharedInstance
            // L134). A strict layer/tag filter would therefore reject every
            // production record. Until the bridge preserves layer + tags
            // through `extras`, the practical Self-half is "every memory
            // record created within the dream recency window," prefer
            // persona-feedback-tagged rows when they actually appear, and
            // let DreamCycleRunner's char/count budgets bound the volume.
            //
            // NOTE: NativeAgentApp has its own legacy `MemoryRecord` and a
            // stub `MemoryV2` class in scope, so we can't name either type
            // directly. Field access via inference; every field used here
            // is documented on the real MemoryV2.MemoryRecord shape.
            let recencyWindow: TimeInterval = 24 * 60 * 60
            let cutoff = Date().addingTimeInterval(-recencyWindow)
            // Reuse the runner's parser instead of inlining a copy — the
            // earlier inline regex `[+-Z]` was a character RANGE (a typo
            // for a character class) and mis-parsed every microsecond
            // timestamp, which would let stale tagged rows survive and
            // drop fresh general rows. One source of truth now.

            do {
                let records = try await memory.listMemory(kind: nil)
                // Newest-first.
                let sorted = records.sorted { $0.createdAt > $1.createdAt }

                var tagged: [String] = []
                var general: [String] = []
                for rec in sorted {
                    // Skill pointers are recall-only rows — a launch sync
                    // must not read as "35 new memories" in tonight's dream
                    // (gpt-5.5 review HIGH, 2026-07-03).
                    if rec.id.hasPrefix(SwiftNativeMemoryV2.skillPointerIDPrefix) { continue }
                    let text = rec.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty { continue }
                    // Recency cutoff — only material absorbed within the
                    // dream window counts as "new since the last dream."
                    if let parsed = DreamCycleRunner.parseDaemonISO(rec.createdAt),
                       parsed < cutoff {
                        continue
                    }
                    // Honor an explicit status field when present.
                    if let status = rec.status?.lowercased(),
                       status == "rejected" || status == "deleted" {
                        continue
                    }
                    let tags = rec.tags ?? []
                    let layer = (rec.layer ?? "").lowercased()
                    let line = "\(rec.createdAt) — \(text)"
                    if tags.contains("persona-feedback")
                        || layer == "persona_feedback"
                        || layer == "persona-feedback" {
                        tagged.append(line)
                    } else {
                        general.append(line)
                    }
                }
                return tagged.isEmpty ? general : tagged
            } catch {
                return []
            }
        }
    }

    /// Felt-tone provider for the nightly dream prompt. Pulls ONE bounded,
    /// read-time summary of what the day FELT like from the cognitive substrate's
    /// felt layer (per-node emotional tags + derived mood) via the existing
    /// `substrateForIntegration()` seam — a PURE read (peekNodes + derivedMood; no
    /// mutation, no persistence). Returns nil when nothing was felt or cognition/
    /// affect is disabled (the substrate's `feltDaySummary` owns that gate), in
    /// which case DreamCycleRunner omits the felt section entirely. Rides the
    /// existing nightly dream call — no new LLM call.
    ///
    /// Exposed as `static` (not `private`) so the scheduler-driven path
    /// (NativeClient.runDream → SwiftNativeDreamREMCycle) can wire the same
    /// provider, mirroring makeDreamMemoryDeltaProvider — otherwise the scheduled
    /// nightly bypasses this assembly and the felt tone is permanently absent.
    static func makeDreamFeltSummaryProvider(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> DreamFeltSummaryProvider {
        let runtime = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        return { @Sendable in
            let substrate = await runtime.substrateForIntegration()
            return await substrate.feltDaySummary(at: Date())
        }
    }

    /// Provenance for the felt tone above (desk 903 phase 2): WHERE the day's
    /// feelings came from, so a dream that felt a journal entry can cite it.
    /// Reads the substrate's `feltDayOrigins(at:)` — the SAME last-24h felt
    /// population `feltDaySummary` integrates over, subject/metadata only, and
    /// the same pure read through the `substrateForIntegration()` seam.
    ///
    /// Empty is the ordinary answer (cognition/affect off, nothing felt, or
    /// nothing felt that came from the journal) and is never a gap: the runner
    /// treats a missing origin as "cite nothing" and still dreams.
    ///
    /// `static` for the same reason as the providers above — the scheduler-driven
    /// path builds its own runner and must wire the identical provider.
    static func makeDreamFeltOriginProvider(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> DreamFeltOriginProvider {
        let runtime = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        return { @Sendable in
            let substrate = await runtime.substrateForIntegration()
            return await substrate.feltDayOrigins(at: Date()).map {
                DreamFeltOrigin(
                    subjectType: $0.subjectType,
                    subjectID: $0.subjectID,
                    metadata: $0.metadata
                )
            }
        }
    }

    /// Receipt channel for the dream lane. DreamREMCycle holds no substrate
    /// reference by design, so the receipt it owns is handed out here to whoever
    /// does — the substrate's own best-effort ledger write, which keeps every
    /// existing gate (cognition/persistence off → silent no-op).
    static func makeDreamReceiptSink(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> DreamReceiptSink {
        let runtime = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        return { @Sendable kind, payload in
            let substrate = await runtime.substrateForIntegration()
            await substrate.recordReceipt(kind: kind, payload: payload)
        }
    }

    /// The return channel of the felt dream (U2a, 2026-07-09): the dream's own mood
    /// line nudges her SLOW disposition layer — the day's considered conclusion, not
    /// just the day's events. `feltDaySummary` carries the day's feeling into the
    /// dream; this carries the dream's feeling back out.
    ///
    /// The substrate owns every gate: cognition/affect off, a mixed or unfelt mood
    /// line, the ±cap and the day-scale decay. Fired at most once per calendar day
    /// (one dream per day) and only after the diary entry committed.
    ///
    /// Exposed as `static` (not `private`) for the same reason as the two providers
    /// above: the scheduler-driven path (NativeClient.runDream →
    /// SwiftNativeDreamREMCycle) builds its own runner and must wire the same sink,
    /// or the scheduled nightly dream never reaches her disposition.
    static func makeDreamMoodSink(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> DreamDatedMoodSink {
        let runtime = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        return { @Sendable mood, dateKey in
            let substrate = await runtime.substrateForIntegration()
            return await substrate.integrateDreamDisposition(
                moodLine: mood,
                at: Date(),
                // Item 7 (2026-09-02): the night's residue is claimed PER
                // COMMITTED DREAM. Without this the substrate falls back to the
                // local calendar day, and that is not the same thing — a
                // scheduled 03:30 dream keys to the PREVIOUS day
                // (`DreamREMSchedule.dreamEntryDateKey`), so a day-keyed residue
                // would let one night mint twice and another not at all.
                //
                // 2026-09-06: the key comes from the RUNNER now, not from a
                // scan of the `.mood_integrated_*` markers on disk. Those
                // markers accumulate, and the scan took the greatest one — so
                // whenever any newer marker existed (a pressure-fired dream
                // stamped today beside a 03:30 scheduled one keyed to
                // yesterday) it named a different night, and the mint's
                // one-night-one-residue guard suppressed the real one.
                dreamId: "dream:\(dateKey)"
            )
        }
    }
}
