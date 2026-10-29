import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import CognitiveSubstrate
import MemoryV2
import PersistenceCore
import DreamREMCycle
import ApprovalInbox
import Cognition
import TrustCenter
import NotificationInbox
import AgentWorkspace
import Transcripts
// Blueprint: | `DreamBackgroundWork.swift` | `DreamBackgroundWork` enum; `runDream` lives the day's owed moments (night batch drain) before the dream; `runREM` routes typed decode failures and healthy settlement to the shared finding sink; `stagePendingREMProposalsAtLaunch`, `makeREMProposalStager` |

/// The app's notification delivery, after the Core-owned REM card is durable.
public typealias REMProposalNotificationPort = BackgroundWorkNotificationPort

// MARK: - Dreams and Memory Loops

public enum DreamBackgroundWork {
    public static func runDream(
        dataRoot: URL,
        cycle: SwiftNativeDreamREMCycle,
        cognitionRuntime: NativeCognitionRuntime,
        force: Bool,
        trigger: DreamTrigger,
        notifications: any REMProposalNotificationPort
    ) async throws -> DreamReport {
        // The day's owed moments (deferred ones included) are judged and
        // lived before the dream reads her day.
        await AdaptiveMemoryPromoter.shared.drainOwedAtNight(dataRoot: dataRoot)
        let result = try await cycle.runDream(force: force, trigger: trigger)
        guard !Task.isCancelled, result.committed else { return result }
        var metadata: [String: JSONValue] = [
            "entriesWritten": .int(Int64(result.entriesWritten)),
            "sessionsProcessed": .int(Int64(result.sessionsProcessed)),
            "force": .bool(force),
            "trigger": .string(trigger.rawValue),
        ]
        let feltSummary = try? await makeDreamFeltSummaryProvider(cognitionRuntime: cognitionRuntime)()
        if let feltSummary, !feltSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata["feltDaySummary"] = .string(feltSummary)
        }
        await cognitionRuntime.ingestOrganismSignal(
            kind: .dreamCompleted,
            sourceOrgan: "dream",
            intensity: 0.62,
            valence: 0.35,
            arousal: 0.12,
            metadata: metadata,
            reflectionMaterial: result.reflectionMaterial
        )
        if !Task.isCancelled, let night = result.careNight {
            await passCaresNight(night, dataRoot: dataRoot, cognitionRuntime: cognitionRuntime,
                                 notifications: notifications)
        }
        return result
    }

    /// The night's pass over her cares, after the dream committed. An approved
    /// life card the live observer did not apply lands first; then the
    /// substrate's pass; then one owner-review card for each care it found
    /// ready for life depth and never offered before.
    static func passCaresNight(
        _ night: CognitiveCareNight, dataRoot: URL, cognitionRuntime: NativeCognitionRuntime,
        notifications: any REMProposalNotificationPort
    ) async {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let action = CognitiveSubstrate.careLifeApprovalAction
        let cards: [ApprovalRecord]?
        do { cards = try await inbox.list(filter: ApprovalFilter(action: action)) } catch {
            nativeLog("[cares] life cards unreadable, none offered tonight: %@", error.localizedDescription)
            cards = nil
        }
        for card in cards ?? [] where card.decision == "approved" && card.executedAction == nil {
            await cognitionRuntime.applyCareLifeApproval(card)
        }
        let ready = await cognitionRuntime.substrateForIntegration().passCaresNight(night)
        guard let cards else { return }
        for record in cards where record.status == "pending" {
            do { try await stageCareLifeCard(record, dataRoot: dataRoot, notifications: notifications) }
            catch { nativeLog("[cares] pending life card %@ not staged; the next night retries: %@", record.id, error.localizedDescription) }
        }
        let offered = Set(cards.compactMap(NativeCognitionRuntime.careLifeCardCareID))
        for care in ready where !offered.contains(care.id) {
            let words = "\(care.about) has become part of who I am"
            do {
                let record = try await inbox.create(.object([
                    "title": .string("Part of who I am"),
                    "action": .string(action),
                    "risk": .string("low"),
                    "reason": .string(""),
                    "payload": .object(["kind": .string(action), "careId": .string(care.id.uuidString),
                                        "about": .string(care.about)]),
                    "payloadPreview": .string(words),
                ]))
                try await stageCareLifeCard(record, dataRoot: dataRoot, notifications: notifications)
            } catch {
                nativeLog("[cares] life card for %@ not staged; the next night retries: %@",
                          care.id.uuidString, error.localizedDescription)
            }
        }
    }

    private static func stageCareLifeCard(
        _ record: ApprovalRecord, dataRoot: URL, notifications: any REMProposalNotificationPort
    ) async throws {
        let words = record.payloadPreview
        let card: JSONValue = .object([
            "id": .string(record.id),
            "created_at": .string(record.createdAt),
            "source": .string("cares_night"),
            "presentation": .object(["icon": .string("heart"), "badge": .string("Cares"),
                                     "words": .string("From my night"), "act_label": .string("Go ahead")]),
            "severity": .string("actionable"),
            "title": .string("Part of who I am"),
            "summary": .string(words),
            "detail": .string("Approve and it is part of who I am (life depth); deny and it stays a season care."),
            "related_mission_id": .null,
            "related_approval_id": .string(record.id),
            "related_paths": .array([]),
            "related_groups": .array([]),
            "actions": .array([
                .object(["id": .string("view"), "label": .string("View"), "description": .string("See full detail")]),
                .object(["id": .string("approve"), "label": .string("Approve"),
                         "description": .string("Make it part of who I am")]),
                .object(["id": .string("reject"), "label": .string("Deny"),
                         "description": .string("Keep it a season care")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"), "description": .string("Dismiss this card")]),
            ]),
            "status": .string("unread"),
            "read_at": .null,
        ])
        if try await LiveNotificationInbox.live(dataRoot: dataRoot)
            .appendUnique(card, id: record.id) {
            await notifications.notifyIfAttentionWorthy(
                dataRoot: dataRoot, itemId: record.id, title: "Part of who I am", summary: words,
                source: "cares_night", severity: "actionable")
        }
    }

    public static func runREM(
        dataRoot: URL,
        cycle: SwiftNativeDreamREMCycle,
        cognitionRuntime: NativeCognitionRuntime,
        force: Bool
    ) async throws -> REMReport {
        let result: REMReport
        do { result = try await cycle.runREM(force: force) }
        catch {
            if case DreamREMCycleError.remDecodeFailure(let detail) = error {
                do {
                    try await HarnessQueue.file(HarnessFinding(key: "loop-failure:nativeagent-weekly-rem",
                        title: "REM could not read its model's reply", summary: detail,
                        owner: .agent, refs: [], source: .loop), dataRoot: dataRoot)
                } catch { nativeLog("REM decode finding could not be filed: %@", error.localizedDescription) }
            }
            throw error
        }
        guard result.skipReason == nil else { return result }
        try await HarnessQueue.resolve(key: "loop-failure:nativeagent-weekly-rem",
            note: "REM decoded its next run.", dataRoot: dataRoot)
        let proposals = result.proposalsGenerated
        let archived = result.archivedEntries
        await cognitionRuntime.ingestOrganismSignal(
            kind: .remIntegrated,
            sourceOrgan: "rem",
            intensity: proposals > 0 ? 0.58 : 0.22,
            valence: 0.28,
            arousal: 0.14,
            metadata: [
                "proposalsGenerated": .int(Int64(proposals)),
                "archivedEntries": .int(Int64(archived)),
                "force": .bool(force),
                "feltDaySummary": .string("REM integrated \(proposals) proposal(s) from recent dream evidence."),
            ],
            reflectionMaterial: result.reflectionMaterial
        )
        return result
    }

    // The weekly scheduler owns REM and stages proposals through makeREMProposalStager.

    /// rem.proposal approval stager: ONE ApprovalInbox record per pending
    /// proposal (ApprovalExecution.resolveApproval's rem.proposal executor applies
    /// approve/deny) plus a card in notifications/inbox.jsonl — the store the
    /// Inbox UI actually reads (NOT the dead inbox/items.jsonl). Returns the
    /// approval id; the proposal store stamps it onto the row so a pipeline
    /// re-run can't double-stage. Mirrors WeeklySelfImprovementLoop's
    /// injected-staging shape (module stays ApprovalInbox-free).
    /// Launch catch-up stages a bounded set of pending REM rows without approval IDs.
    ///
    /// It generates NO REM batch — it only hands already-canonical pending rows
    /// to the same stager the weekly job uses. Idempotent: the store stamps the
    /// approval id onto the row, and a stamped row is skipped forever after. The
    /// bound keeps a long-neglected backlog from dumping an unbounded pile of
    /// approval cards on her at once; what is left waits for the next launch or
    /// the weekly job.
    public static let remStagingCatchUpLimit = 10

    @discardableResult
    public static func stagePendingREMProposalsAtLaunch(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        limit: Int = remStagingCatchUpLimit,
        stager: REMApprovalStager? = nil,
        notifications: any REMProposalNotificationPort
    ) async -> Int {
        guard limit > 0 else { return 0 }
        let store = REMProposalStore(dataRoot: dataRoot)
        let inner = stager ?? makeREMProposalStager(dataRoot: dataRoot, notifications: notifications)
        do {
            return try await store.stagePendingApprovals(inner, limit: limit)
        } catch {
            nativeLog("REM approval staging remains owed: %@", error.localizedDescription)
            return 0
        }
    }

    public static func makeREMProposalStager(dataRoot: URL, notifications: any REMProposalNotificationPort) -> REMApprovalStager {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let securityCenter = SwiftNativeSecurityCenter(dataRoot: dataRoot)
        return { row, experiences in
            let yolo = await securityCenter.fullMacYoloAuthority(
                origin: SecurityOriginContext(
                    surface: "desk",
                    source: "rem_proposal_stager",
                    isRemote: false
                )
            )
            // Only an explicit block refuses staging; staging does not apply the proposal.
            if yolo.state == .explicitlyBlocked {
                return nil
            }
            // Reuse pending approvals after a crash; dedupe read failures leave staging owed.
            let pendingREM = try await inbox.list(
                filter: ApprovalFilter(status: "pending", action: "rem.proposal"))
            if let existing = pendingREM.first(where: { rec in
                guard case .object(let p) = rec.payload,
                      case .object(let proposal)? = p["proposal"],
                      case .string(let pid)? = proposal["id"] else { return false }
                return pid == row.id
            }) {
                try await ensureREMProposalInboxCard(
                    dataRoot: dataRoot, approvalId: existing.id, row: row,
                    experiences: experiences, notifications: notifications)
                return existing.id
            }
            let preview = remProposalPreview(row, experiences: experiences)
            let cardTitle = "REM growth lesson"
            let body: JSONValue = .object([
                "title": .string(cardTitle),
                "action": .string("rem.proposal"),
                "risk": .string("medium"),
                // An empty reason hides boilerplate so the preview carries her words verbatim.
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
                        // Preserve support evidence so repeated reflection stays distinct from recurrence.
                        "support": row.support.map { .string($0.rawValue) } ?? .null,
                        "livedDates": .array((row.livedDates ?? []).map { .string($0) }),
                        "supportingPassages": .array((row.supportingPassages ?? []).map {
                            .object([
                                "dreamDate": .string($0.dreamDate),
                                "quote": .string($0.quote),
                                "livedDates": .array($0.livedDates.map { .string($0) }),
                                "sourceRefs": .array($0.sourceRefs.map { .string($0) }),
                            ])
                        }),
                    ]),
                ]),
                "payloadPreview": .string(preview),
            ])
            let rec = try await inbox.create(body)
            try await ensureREMProposalInboxCard(
                dataRoot: dataRoot, approvalId: rec.id, row: row,
                experiences: experiences, notifications: notifications)
            return rec.id
        }
    }

    /// What the row's support REALLY is, in the words the approval row shows.
    /// Agent's rule: a thing dwelt on is offered under its own name and never
    /// presented as a pattern — so `dwelt on · 3 dreams, 1 night` and
    /// `recurring · 3 nights` can never render as the same line. Rows with no
    /// support field (written before it existed) get no label rather than a
    /// guessed one.
    public static func remSupportLabel(_ row: REMProposalRow, experiences: Int?) -> String? {
        guard row.support != .standing, row.support != nil else { return nil }
        guard let experiences else {
            return "provenance unavailable · whether it recurred is not known"
        }
        let dreams = max(row.evidenceDates.count, row.supportingPassages?.count ?? 0)
        func support(_ n: Int) -> String { "\(n) experience" + (n == 1 ? "" : "s") }
        switch row.support {
        case .recurring:
            return "recurring · " + support(experiences)
        case .dweltOn:
            return "dwelt on · \(dreams) dream" + (dreams == 1 ? "" : "s")
                + ", " + support(experiences)
        case .provenanceUnavailable:
            return "provenance unavailable · whether it recurred is not known"
        case .standing, nil:
            return nil
        }
    }

    /// The preview every REM surface prints: the support label on its own line
    /// above her words, so the label travels with the proposal wherever the row
    /// is shown instead of living in one view's formatting.
    public static func remProposalPreview(_ row: REMProposalRow, experiences: Int?) -> String {
        // A standing lesson says what it is before it quotes the line: the
        // card moves a correction into GROWTH, it is not a dream's lesson.
        if row.support == .standing {
            return "Standing lesson, recalled in nearly every conversation. Approve to keep it in GROWTH "
                + "and retire the memory:\n“\(row.proposalText)”"
        }
        // Her words first: a card shows its first line, and the lesson is the point.
        guard let label = remSupportLabel(row, experiences: experiences) else { return row.proposalText }
        return row.proposalText + "\n" + label
    }

    /// Card id == approval id: InboxView's approve/reject buttons route
    /// inboxAction(id) → resolveApproval(id), so the ids MUST match.
    /// Idempotent: scans for an existing card with this id before appending,
    /// so the stager's retry/dedupe path can't duplicate cards. Throws on
    /// IO failure — the caller treats that as stage-failed.
    private static func ensureREMProposalInboxCard(
        dataRoot: URL,
        approvalId: String,
        row: REMProposalRow,
        experiences: Int?,
        notifications: any REMProposalNotificationPort
    ) async throws {
        let preview = remProposalPreview(row, experiences: experiences)
        let card: JSONValue = .object([
            "id": .string(approvalId),
            "created_at": .string(NativeTimestampFormat.fractionalZulu(Date())),
            "source": .string("rem_cycle"),
            "presentation": .object(["icon": .string("sparkles"), "badge": .string("REM"),
                                     "words": .string("From my rest"), "act_label": .string("Go ahead")]),
            "severity": .string("actionable"),
            "title": .string("REM growth lesson"),
            "summary": .string(String(preview.prefix(220))),
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
        let inserted = try await LiveNotificationInbox.live(dataRoot: dataRoot)
            .appendUnique(card, id: approvalId)
        if inserted {
            await notifications.notifyIfAttentionWorthy(
                dataRoot: dataRoot,
                itemId: approvalId,
                title: "REM growth lesson",
                summary: String(preview.prefix(220)),
                source: "rem_cycle",
                severity: "actionable"
            )
        }
    }

    /// Self-half delta provider for the nightly dream prompt. Pulls recent
    /// MemoryV2 records and returns each as one pre-formatted line. The
    /// DreamCycleRunner applies the `_DREAM_DELTA_CHAR_BUDGET` /
    /// `_DREAM_DELTA_COUNT_LIMIT` caps internally.
    ///
    /// Exposed as `static` (not `private`) so the scheduler-driven path
    /// (BackgroundLoopsAssembly.runDream → SwiftNativeDreamREMCycle) can wire the
    /// same provider; otherwise the scheduled nightly bypasses this
    /// assembly entirely and the Self-half is permanently empty.
    public static func makeDreamMemoryDeltaProvider(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> DreamMemoryDeltaProvider {
        let memory = SwiftNativeMemoryV2.resolvedOwner(
            dataRoot: dataRoot,
            alternateRootEmbedder: MockEmbeddingProvider()
        )
        return { @Sendable cutoff in
            // Prefer persona feedback since the cutoff; DreamCycleRunner bounds the volume.
            // DreamCycleRunner owns timestamp parsing.

            let records = try await memory.listMemory(kind: nil)
            // Newest-first.
            let sorted = records.sorted { $0.createdAt > $1.createdAt }

            var tagged: [String] = []
            var general: [String] = []
            for rec in sorted {
                let text = rec.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                // The run's cutoff — only material absorbed since the
                // last dream's high-water mark counts as new.
                if let parsed = ChatSessionRecollections.parseTimestamp(.string(rec.createdAt)),
                   parsed < cutoff {
                    continue
                }
                // Only what recall could speak: active, recall-eligible, admitted.
                guard rec.status == "active", MemoryLifecycle.isRecallEligible(rec.lifecycle),
                      !MemoryStorage.metadataFlag(rec.extras, MemoryStorage.pendingAdmissionKey)
                else { continue }
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
    /// (BackgroundLoopsAssembly.runDream → SwiftNativeDreamREMCycle) can wire the same
    /// provider, mirroring makeDreamMemoryDeltaProvider — otherwise the scheduled
    /// nightly bypasses this assembly and the felt tone is permanently absent.
    public static func makeDreamFeltSummaryProvider(
        cognitionRuntime: NativeCognitionRuntime
    ) -> DreamFeltSummaryProvider {
        let runtime = cognitionRuntime
        return { @Sendable in
            let substrate = await runtime.substrateForIntegration()
            return await substrate.feltDaySummary(at: Date())
        }
    }

    /// Provenance for the felt tone above: where the day's
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
    public static func makeDreamFeltOriginProvider(
        cognitionRuntime: NativeCognitionRuntime
    ) -> DreamFeltOriginProvider {
        let runtime = cognitionRuntime
        return { @Sendable in
            let substrate = await runtime.substrateForIntegration()
            return await substrate.feltDayOrigins(at: Date())
        }
    }

    /// Her cares for the dream prompt, read from the same substrate seam.
    public static func makeDreamCareNightProvider(
        cognitionRuntime: NativeCognitionRuntime
    ) -> DreamCareNightProvider {
        let runtime = cognitionRuntime
        return { @Sendable in
            await runtime.substrateForIntegration().careNightMaterial()
        }
    }

    /// Receipt channel for the dream lane. DreamREMCycle holds no substrate
    /// reference by design, so the receipt it owns is handed out here to whoever
    /// does — the substrate's own best-effort ledger write, which keeps every
    /// existing gate (cognition/persistence off → silent no-op).
    public static func makeDreamReceiptSink(
        cognitionRuntime: NativeCognitionRuntime
    ) -> DreamReceiptSink {
        let runtime = cognitionRuntime
        return { @Sendable kind, payload in
            let substrate = await runtime.substrateForIntegration()
            await substrate.recordReceipt(kind: kind, payload: payload)
        }
    }

    /// Return her explicit dream affect to the existing disposition/residue owner,
    /// after commit, under its existing claims, caps and decay.
    public static func makeDreamMoodSink(
        cognitionRuntime: NativeCognitionRuntime
    ) -> DreamDatedMoodSink {
        let runtime = cognitionRuntime
        return { @Sendable affect, dateKey in
            let substrate = await runtime.substrateForIntegration()
            return await substrate.integrateDreamDisposition(
                tone: affect,
                at: Date(),
                // Claim residue per committed dream using the runner's date key.
                dreamId: "dream:\(dateKey)"
            )
        }
    }
}
