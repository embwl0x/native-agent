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

// MARK: - Dreams and Memory Loops

extension BackgroundLoopsAssembly {
    static func makeREMCycleLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        llm: any LLMClient,
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> REMCycleLoop {
        // REM consolidates dream_diary entries against persona docs. The
        // consolidator is stateless — it asks the LLM and returns proposals.
        // Tombstone + GROWTH cap are caller-side; pass concrete actors that
        // read/write the runtime persona paths.
        //
        // BUG-C FIX: resolve persona root via PersistenceCore.defaultPersonaRoot
        // (env var > stamped bundle > `<dataRoot>/memory`),
        // NOT hardcoded `<dataRoot>/persona`. The earlier hardcode silently
        // diverged from the daemon whenever NATIVE_AGENT_PERSONA_ROOT was
        // set OR the stamped repo put persona/ outside dataRoot. With the
        // resolver all REM cycles read/write the same SOUL/VOICE/GROWTH/USER
        // docs. REMTombstoneStore default already targets
        // <dataRoot>/harness/.rem_tombstones.json (fixed inside the actor).
        let diary = DreamDiaryReader(dataRoot: dataRoot)
        let consolidator = SwiftNativeREMConsolidator(llm: llm, diary: diary)
        let tombstones = REMTombstoneStore(dataRoot: dataRoot)
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        let growth = GrowthDocManager(personaRoot: personaRoot)
        // PATCH-2026-06-03 F5 fix #3+#4: wire the FULL REMConsolidator so the
        // weekly tick applies the evidence-date floor, per-doc cap, tombstone
        // skip, GROWTH eviction, archival, AND emits rem_pins.json — which
        // ChatOrchestration+TurnEngine.buildTurnContext reads for the
        // recent-REM-approved persona-drift injection on every chat turn.
        // REM-approval pipeline (2026-06-10): one stager instance feeds both
        // the full consolidator (step 7b) and the loop's legacy path, so every
        // pending proposal lands as exactly one approvable record.
        let stager = makeREMProposalStager(dataRoot: dataRoot)
        let full = REMConsolidator(
            dataRoot: dataRoot,
            personaRoot: personaRoot,
            llm: llm,
            gate: loadGatePolicy(dataRoot: dataRoot),
            stageApproval: stager
        )
        return REMCycleLoop(
            consolidator: consolidator,
            tombstones: tombstones,
            growth: growth,
            dataRoot: dataRoot,
            personaRoot: personaRoot,
            fullConsolidator: full,
            stageApproval: stager,
            replaySourceCommitted: cognitionReplaySourceCommitSink(
                dataRoot: dataRoot,
                runtime: cognitionRuntime,
                kind: .remIntegrated,
                sourceOrgan: "rem"
            )
        )
    }

    /// rem.proposal approval stager: ONE ApprovalInbox record per pending
    /// proposal (NativeClient.resolveApproval's rem.proposal executor applies
    /// approve/deny) plus a card in notifications/inbox.jsonl — the store the
    /// Inbox UI actually reads (NOT the dead inbox/items.jsonl). Returns the
    /// approval id; the proposal store stamps it onto the row so a pipeline
    /// re-run can't double-stage. Mirrors WeeklySelfImprovementLoop's
    /// injected-staging shape (module stays ApprovalInbox-free).
    static func makeREMProposalStager(dataRoot: URL) -> REMApprovalStager {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        return { row in
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
        let persistence = SwiftNativePersistenceCore()
        let inserted = try await persistence.withFileLock(inboxPath) { () async throws -> Bool in
            // Scan-before-append inside the same critical section: the
            // stager's crash-retry path re-ensures the card for an existing
            // approval id, and a duplicate card would render twice in the UI.
            // Scan errors propagate (stage fails, retried next pass) — a
            // swallowed read failure here would append the duplicate anyway.
            // WHOLE-file scan: notifications/inbox.jsonl is uncapped, so any
            // bounded window could miss an old card and dup it (gpt-5.5
            // review 2026-06-10). The path runs only on stager retry — rare.
            let rows = try await persistence.tailJSONL(
                inboxPath, limit: Int.max, maxBytes: nil)
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
                title: "REM growth lesson",
                summary: String(row.proposalText.prefix(220)),
                source: "rem_cycle",
                severity: "actionable"
            )
        }
    }

    /// Decode the persisted trust policy into a DreamREMGatePolicy. Returns
    /// the daemon defaults when the policy file is absent/unreadable so the
    /// dream/REM cycles never silently turn on without explicit opt-in.
    static func loadGatePolicy(dataRoot: URL) -> DreamREMGatePolicy {
        let path = dataRoot.appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONValue.parse(data),
              case .object(let root) = parsed
        else { return DreamREMGatePolicy() }
        func obj(_ key: String) -> [String: JSONValue] {
            if case .object(let o)? = root[key] { return o }
            return [:]
        }
        let training = obj("trainingPolicy")
        let personality = obj("personalityPolicy")
        let dreamScheduler: Bool = {
            if case .bool(let b)? = training["dream_scheduler"] { return b }
            return false
        }()
        let dreamEnabled: Bool = {
            if case .bool(let b)? = personality["dream_cycle_enabled"] { return b }
            return true
        }()
        let remEnabled: Bool = {
            if case .bool(let b)? = training["rem_cycle_enabled"] { return b }
            return true
        }()
        return DreamREMGatePolicy(
            dreamScheduler: dreamScheduler,
            dreamCycleEnabled: dreamEnabled,
            remCycleEnabled: remEnabled
        )
    }

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
        // runTickOnce routing are untouched. The MemoryConsolidationLoop TYPE
        // stays in the BackgroundLoops module (tests pin it); only the
        // production wiring retires.
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
        let standardized = dataRoot.standardizedFileURL
        let memory: SwiftNativeMemoryV2 = {
            if standardized == PersistenceCore.defaultDataRoot().standardizedFileURL {
                return .shared
            }
            guard let storage = try? MemoryStorage(dataRoot: standardized) else {
                return SwiftNativeMemoryV2()
            }
            return SwiftNativeMemoryV2(
                embedder: MockEmbeddingProvider(),
                storage: MemoryStorageBridge(storage: storage)
            )
        }()
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
    ) -> DreamMoodSink {
        let runtime = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        return { @Sendable mood in
            let substrate = await runtime.substrateForIntegration()
            await substrate.integrateDreamDisposition(moodLine: mood, at: Date())
        }
    }
}
