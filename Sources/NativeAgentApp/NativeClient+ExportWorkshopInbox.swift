import Foundation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry

private struct SessionProviderUsageReceipt: Decodable {
    let model: String
    let lastRequestInputTokens: Int
    let previousTurnInputTokens: Int?
    let turnInputDeltaTokens: Int?
}

extension NativeClient {
    func createProductionExport() async throws -> ProductionExport {
        let root = PersistenceCore.defaultDataRoot()
        let now = Self.nativeArtifactTimestamp()
        let id = UUID().uuidString.lowercased()
        let exportRoot = root
            .appendingPathComponent("production", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
        let stageDir = exportRoot.appendingPathComponent(id, isDirectory: true)
        let archiveURL = exportRoot.appendingPathComponent("\(id)-nativeagent-export.tar.gz")

        let fm = FileManager.default
        try fm.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: stageDir)
        try? fm.removeItem(at: archiveURL)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

        try Self.writeCodableJSON(try await getProductionHardening(), to: stageDir.appendingPathComponent("production_hardening.json"))
        try Self.writeCodableJSON(try await getPrivacyMap(), to: stageDir.appendingPathComponent("privacy_map.json"))

        let dataDir = stageDir.appendingPathComponent("data", isDirectory: true)
        let copied = try Self.copySelectedDataPaths(
            root: root,
            destinationRoot: dataDir,
            relativePaths: Self.productionExportRelativePaths
        )
        var scope = Self.scopeNames(for: copied)
        if !scope.contains("diagnostics") { scope.insert("diagnostics", at: 0) }

        let manifest = Self.artifactManifest(
            id: id,
            kind: "export",
            createdAt: now,
            scope: scope,
            copied: copied,
            redactions: Self.productionRedactions
        )
        try Self.writeJSONValue(manifest, to: stageDir.appendingPathComponent("manifest.json"))

        try await Self.createTarGz(sourceDirectory: stageDir, archiveURL: archiveURL)
        let checksum = try await Self.sha256Hex(ofFile: archiveURL, currentDirectory: exportRoot)
        let sizeBytes = try Self.fileSizeBytes(archiveURL)
        let record = ProductionExport(
            id: id,
            kind: "export",
            path: archiveURL.path,
            scope: scope,
            checksum: checksum,
            sizeBytes: sizeBytes,
            createdAt: now
        )
        try await Self.appendProductionExport(record, registryRoot: exportRoot)
        return record
    }

    func createSupportBundle() async throws -> ProductionExport {
        let root = PersistenceCore.defaultDataRoot()
        let now = Self.nativeArtifactTimestamp()
        let id = UUID().uuidString.lowercased()
        let supportRoot = root
            .appendingPathComponent("production", isDirectory: true)
            .appendingPathComponent("support", isDirectory: true)
        let exportRoot = root
            .appendingPathComponent("production", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
        let stageDir = supportRoot.appendingPathComponent(id, isDirectory: true)
        let archiveURL = supportRoot.appendingPathComponent("\(id)-nativeagent-support.tar.gz")

        let fm = FileManager.default
        try fm.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: stageDir)
        try? fm.removeItem(at: archiveURL)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

        try Self.writeCodableJSON(try await getSupportDiagnostics(), to: stageDir.appendingPathComponent("support_diagnostics.json"))
        try Self.writeCodableJSON(try await getHealth(), to: stageDir.appendingPathComponent("health.json"))

        let dataDir = stageDir.appendingPathComponent("data", isDirectory: true)
        let copied = try Self.copySelectedDataPaths(
            root: root,
            destinationRoot: dataDir,
            relativePaths: Self.supportBundleRelativePaths
        )
        var scope = Self.scopeNames(for: copied)
        if !scope.contains("diagnostics") { scope.insert("diagnostics", at: 0) }

        let manifest = Self.artifactManifest(
            id: id,
            kind: "support",
            createdAt: now,
            scope: scope,
            copied: copied,
            redactions: Self.supportRedactions
        )
        try Self.writeJSONValue(manifest, to: stageDir.appendingPathComponent("manifest.json"))

        try await Self.createTarGz(sourceDirectory: stageDir, archiveURL: archiveURL)
        let checksum = try await Self.sha256Hex(ofFile: archiveURL, currentDirectory: supportRoot)
        let sizeBytes = try Self.fileSizeBytes(archiveURL)
        let record = ProductionExport(
            id: id,
            kind: "support",
            path: archiveURL.path,
            scope: scope,
            checksum: checksum,
            sizeBytes: sizeBytes,
            createdAt: now
        )
        try await Self.appendProductionExport(record, registryRoot: exportRoot)
        return record
    }

    // WAVE 40 W07 (§6.220): executions CRUD-admin WRITE seam behind
    // `.missionsWrites` (default OFF). The SwiftNative write impls
    // (SwiftNativeWorkshopRunner.submit / updateWorkshopExecution / cancel) and their
    // cross-process flock on workshop/executions/<id>/{mission.json,timeline.jsonl}
    // were built in waves 33/34/35 W07; this flips the CONSUMER seam so the Mac
    // UI's create/update/cancel land natively without the daemon.
    func createWorkshopTask(
        title: String,
        objective: String,
        projectSpaceId: String? = nil
    ) async throws -> WorkshopExecutionRecord {
        // Native submit mirrors the daemon's `/v1/missions` queue-bridge:
        // runner.submit(title, objective, "manual", "none") — same defaults
        // as the Python handler. submit()
        // validates a non-empty objective (throws WorkshopExecutionError.invalidRequest
        // "missing_objective", parity with the daemon's 400). NOTHING
        // auto-starts in submit itself; the execution lands in `queued` and
        // WorkshopExecutorLoop (executor port, 2026-06-10 — registered via
        // BackgroundLoopsAssembly, gated on enableAutonomy + missionPolicy)
        // claims and runs it on its next drain pass.
        let runner = makeWorkshopExecutionRunner()
        let spec = WorkshopExecution.WorkshopExecutionSpec(
            title: title,
            objective: objective,
            triggerSource: "manual",
            trustRequired: "none",
            projectSpaceId: projectSpaceId
        )
        let result = try await WorkshopExecution.WorkshopDirectedTaskSubmitter(
            dataRoot: PersistenceCore.defaultDataRoot(),
            runner: runner
        ).submit(spec: spec)
        // The daemon's create response is a SUMMARY ({id,mission_id,status,
        // title,plan_steps}); the FULL record is a strict superset that
        // decodes into the (snake_case-tolerant) app WorkshopExecutionRecord just the
        // same. Serialize the asdict-faithful record and decode.
        let data = try result.execution.toJSON().serializedData(pretty: false)
        return try JSONDecoder.nativeAgent.decode(WorkshopExecutionRecord.self, from: data)
    }

    func getTriggers() async throws -> [TriggerRecord] {
        // SUBSYSTEM #17 cluster C3 (2026-05-31): SwiftNative TriggerScheduler
        // covers list/enable/disable/configure for both schedules behind the
        // .triggerScheduler flag. fire_now for supported inbox/execution cases is
        // native; unsupported cases fail closed.
        return try await swiftListWorkshopTriggers()
    }

    // PATCH-2026-05-07: proactive-inbox-1 Inbox action helper (avoids Sendable Any issue at call site)
    func inboxAction(_ id: String, action: String) async throws {
        // "reply" needs text input the act handler doesn't have. If a caller
        // hits this entry point with `reply`, surface the gap honestly
        // instead of silently mapping to `act`. (gpt-5.5 review HIGH: act
        // could otherwise recurse into reply → infinite loop.)
        let normalizedAction = action == "deny" ? "reject" : action
        if normalizedAction == "reply" {
            throw NSError(
                domain: "NativeAgentSwiftOnly",
                code: -410,
                userInfo: [NSLocalizedDescriptionKey: "Reply requires text input; use inboxReply(id:text:) instead of inboxAction(id:\"reply\")."]
            )
        }
        let nativeActions: Set<String> = ["read", "archive", "dismiss", "act", "approve", "reject", "open_approvals", "repair"]
        let endpointAction = nativeActions.contains(normalizedAction) ? normalizedAction : "act"

        // Wave 32 W16 (2026-06-01): consume the SwiftNative NotificationInbox for
        // status-write actions — read / archive / dismiss. archive/dismiss fire
        // the proactive-outcome ledger before the index.json overlay write under
        // the inbox file lock. Other actions are handled below or fail closed.
        if endpointAction == "read" || endpointAction == "archive" || endpointAction == "dismiss" {
            if await Self.updateVisibleNotificationInboxStatus(id: id, action: endpointAction) {
                return
            }
            // A5.2 (2026-07-24): the legacy silo fallback (makeNotificationInbox
            // → items.jsonl/index.json) is GONE — the silo is retired and
            // frozen, so a fallback "success" there updated dead storage while
            // the visible card stayed put, masking the live-store failure. The
            // live store is the only store; a failed write surfaces as the
            // retryable error below (same resurrect-audit rationale, 2026-06-09).
            NSLog("[NativeClient] inboxAction(\(endpointAction)) id=\(id): live inbox status write declined")
            throw NSError(
                domain: "NativeAgentSwiftOnly",
                code: -423,
                userInfo: [NSLocalizedDescriptionKey:
                    "Inbox \(endpointAction) for \(id) didn't persist (transient lock/IO failure or stale row) — retry."]
            )
        }
        // F6 (eval E06 fix-2): wire approve/reject through the
        // SwiftNativeApprovalInbox actor so the inbox row actually moves out
        // of pending.
        if endpointAction == "approve" || endpointAction == "reject" {
            // Route through resolveApproval so approval-action executors (e.g.
            // self_improvement.apply) actually FIRE. Resolving the inbox actor
            // directly here would mark the record terminal WITHOUT executing,
            // leaving an approved-but-unapplied dead-end.
            do {
                _ = try await resolveApproval(id: id, decision: endpointAction)
            } catch ApprovalInboxError.alreadyResolved(let resolvedID, let status) {
                // Idempotent re-tap: the record is already terminal. Treat as
                // success so a double-tap doesn't surface a spurious error.
                NSLog("[NativeClient] inboxAction(\(endpointAction)) id=\(resolvedID): already resolved (\(status)); treating as success")
            } catch {
                // Surface real failures to the caller instead of reporting
                // unconditional success over a swallowed error.
                NSLog("[NativeClient] inboxAction(\(endpointAction)) id=\(id): \(error)")
                throw error
            }
            return
        }
        if endpointAction == "open_approvals" {
            await Self.openApprovalsFromInboxAction(id: id)
            return
        }
        if endpointAction == "repair" {
            let message = try await BackgroundLoopsAssembly.repairHeartbeatInboxItem(id: id)
            _ = await Self.updateVisibleNotificationInboxStatus(id: id, action: "archive")
            NSLog("[NativeClient] inboxAction(repair) id=\(id): \(message)")
            return
        }
        // DAEMON-KILL (2026-06-06) + gpt-5.5 review-2 BLOCKING, resolver wired
        // 2026-08-11: an earlier attempt picked the first non-"view" entry from
        // the item's `actions` array and recursed into inboxAction with it. But
        // every TriggerScheduler item ships the standard fan-out
        // `[view, act, archive, dismiss]`, so the candidate WAS literally
        // "act" — infinite recursion (TriggerScheduler.swift:750-755).
        //
        // The per-kind resolver below is a pure function returning a closed
        // enum of terminal handlers — it never consults the `actions` array
        // and cannot re-enter inboxAction, so that regression is dead by
        // construction. Archive/dismiss remain housekeeping moves the user
        // did not mean by "Act"; unresolvable shapes still fail closed -410.
        if endpointAction == "act" {
            let items = try await getInboxItems(unreadOnly: false)
            guard let item = items.first(where: { $0.id == id }) else {
                throw NSError(
                    domain: "NativeAgentSwiftOnly",
                    code: -410,
                    userInfo: [NSLocalizedDescriptionKey: "Inbox item \(id) not found"]
                )
            }
            let resolution = Self.resolveInboxPrimaryAction(for: item)
            // The approvals path marks the row read inside
            // openApprovalsFromInboxAction; the other resolvable paths mark
            // it here via the resolution's status action ("read", never
            // "archive" — acting on an item is engagement, not disposal).
            if let statusAction = resolution.inboxStatusAction {
                // gpt-5.5 review HIGH: a swallowed failure here would let Act
                // "succeed" while the row stays unread. Nothing else has
                // happened yet, so failing loud with the same retryable -423
                // the read/archive path uses keeps a retry clean.
                guard await Self.updateVisibleNotificationInboxStatus(id: id, action: statusAction) else {
                    throw NSError(
                        domain: "NativeAgentSwiftOnly",
                        code: -423,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Inbox act for \(id) couldn't mark the item \(statusAction) (transient lock/IO failure or stale row) — retry."]
                    )
                }
            }
            switch resolution {
            case .openApprovals:
                await Self.openApprovalsFromInboxAction(id: id)
            case .openDeskExecution:
                // No execution-detail deep link exists yet (DeskItem carries
                // no execution id), so land on the Desk surface via the same
                // coordinator route the command palette uses.
                await MainActor.run {
                    NotificationCenter.default.post(name: .openCommandRouteRequest, object: "desk")
                }
            case .chatDraft(let draft):
                // ContentView's .openChatDraftRequest receiver switches to
                // Chat and injects via AppModel.injectChatDraft — the S.6
                // suggestion-chip idiom skillBuildRequest already uses.
                await MainActor.run {
                    NotificationCenter.default.post(name: .openChatDraftRequest, object: draft)
                }
            case .chatSpoken(let message):
                // L5 G6/G7. Post her message into the transcript through the
                // narrow proactive-speech seam, THEN navigate. Order matters:
                // navigating first would show User the session a beat before the
                // row exists in it.
                //
                // FAIL-OPEN, LOUDLY: if the seam refuses (rate limit, duplicate)
                // or the write throws, fall back to the old composer draft so
                // Act still does something and User still lands in chat with the
                // reference — but say which one happened in the log rather than
                // pretending she spoke.
                let spoke = await Self.postSpokenInboxMessage(message: message, itemId: id)
                await MainActor.run {
                    if spoke {
                        NotificationCenter.default.post(name: .openSpokenChatRequest, object: nil)
                    } else {
                        NotificationCenter.default.post(
                            name: .openChatDraftRequest,
                            object: Self.inboxChatDraftText(
                                title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                summary: item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        )
                    }
                }
            case .diskCleanup:
                // Re-scan + move current offenders to the Trash (reversible;
                // protected stores refused). cleanUpDiskHygiene rewrites the
                // card with results and marks it read; it throws when there
                // were offenders but nothing could move, so the button never
                // shows a silent green over a failed cleanup.
                let message = try await BackgroundLoopsAssembly.cleanUpDiskHygiene()
                NSLog("[NativeClient] inboxAction(act) disk_hygiene: \(message)")
            case .unresolved(let reason):
                throw NSError(
                    domain: "NativeAgentSwiftOnly",
                    code: -410,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Inbox item \(id): no primary action for this shape (\(reason)). "
                        + "Use the explicit archive/dismiss/approve/reject actions, "
                        + "or open the item for full context."]
                )
            }
            return
        }
        // Unknown action — fail honestly rather than silently no-op.
        throw NSError(
            domain: "NativeAgentSwiftOnly",
            code: -410,
            userInfo: [NSLocalizedDescriptionKey: "Inbox action \(endpointAction) has no native resolver"]
        )
    }

    static func primaryInboxActionID(for item: InboxItemRecord) -> String? {
        item.fallbackPrimaryAction?.id
    }

    /// What hitting "Act" on an inbox item should DO, resolved per item kind.
    /// Every case is a terminal handler — none re-enters inboxAction, which is
    /// what keeps the 2026-06-06 first-non-view recursion dead by construction.
    enum InboxPrimaryActionResolution: Equatable {
        case openApprovals
        case openDeskExecution(executionId: String)
        case chatDraft(draft: String)
        /// L5 G6 — the inversion. For cards SHE raised (morning brief, idle
        /// check-in), Act posts the card's content into chat AS HER MESSAGE and
        /// navigates there. The composer stays EMPTY: User replies to her
        /// instead of writing a message to himself about a thing she said.
        case chatSpoken(message: String)
        case diskCleanup
        case unresolved(reason: String)

        /// Status write the act handler applies before navigating. Approvals
        /// is nil because openApprovalsFromInboxAction marks the row read
        /// itself. Disk cleanup is nil because cleanUpDiskHygiene rewrites the
        /// card (marked read) with the results — and a thrown cleanup must not
        /// leave the card pre-marked. Resolvable items are marked READ, never
        /// archived — acting is engagement, not disposal. Unresolved writes
        /// nothing.
        var inboxStatusAction: String? {
            switch self {
            case .openApprovals, .diskCleanup, .unresolved: return nil
            case .openDeskExecution, .chatDraft, .chatSpoken: return "read"
            }
        }
    }

    /// Priority order: approvals link > workshop-execution link > chat-shaped
    /// (morning brief, idle check-in, and any informational item with content
    /// worth referencing). Only items with nothing to act on OR reference
    /// stay unresolved and surface the honest -410.
    static func resolveInboxPrimaryAction(for item: InboxItemRecord) -> InboxPrimaryActionResolution {
        if primaryInboxActionID(for: item) == "open_approvals" || item.hasLinkedApproval {
            return .openApprovals
        }
        if let executionId = item.relatedWorkshopExecutionId, !executionId.isEmpty {
            return .openDeskExecution(executionId: executionId)
        }
        // Disk-hygiene card: Act means "clean it up" (move the offenders to
        // the Trash), not "draft a chat about it" — so this outranks the
        // chat-shaped fallback below.
        if item.source == "disk_hygiene" {
            return .diskCleanup
        }
        // gpt-5.5 review MEDIUM: unmapped proactive cards deliberately expose
        // no Act button (fallbackPrimaryAction returns nil for them) — their
        // "Suggested action: X" payloads are structured opportunities, not
        // chat prompts. If an act call reaches one anyway, keep it unresolved
        // rather than contradicting that UI contract with a chat draft.
        if item.isProactiveCard {
            return .unresolved(reason: "unmapped proactive card — no approval link")
        }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty && summary.isEmpty {
            return .unresolved(reason: "no linked approval/execution and no referenceable content")
        }
        // L5 G6: the two cards SHE authored get the inverted route — her words
        // land in the transcript and User answers them. Every OTHER chat-shaped
        // card keeps the composer draft: those are things the SYSTEM noticed,
        // where "Re: <thing>" in the composer is the honest shape because she
        // has not, in fact, said anything about them.
        if isHerVoiceCard(item) {
            return .chatSpoken(
                message: inboxSpokenMessageText(title: title, summary: summary, detail: item.detail)
            )
        }
        return .chatDraft(draft: inboxChatDraftText(title: title, summary: summary))
    }

    /// Cards whose content is already written in her voice, addressed to User.
    /// Pinned to the two producers that actually are: the `time` trigger's
    /// morning brief (`trigger:morning_brief`) and the `idle` trigger's
    /// check-in (`idle_checkin`) — the exact pair `TriggerContentBuilder`
    /// builds real content for. Kept as an explicit allowlist, not a heuristic
    /// over severity or kind, so a future producer cannot silently inherit the
    /// right to speak in the transcript.
    /// EXACT equality, not hasPrefix (gpt-5.5 BLOCKING, 2026-08-11): a prefix
    /// match let any row whose source merely STARTS with these strings —
    /// `trigger:morning_brief_test`, `idle_checkin_v2`, or a crafted row —
    /// inherit the right to speak in the transcript. Exact match pins the two
    /// literal strings the fire sites write and nothing else. (A local writer
    /// that can forge inbox rows can already write the transcript JSONL
    /// directly, so this is drift/spoof-surface hardening, not the trust
    /// boundary itself — the boundary is data-root write access.)
    static let herVoiceCardSources: Set<String> = ["trigger:morning_brief", "idle_checkin"]

    static func isHerVoiceCard(_ item: InboxItemRecord) -> Bool {
        herVoiceCardSources.contains(item.source.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The card, rendered as something she said. Title becomes the opening
    /// line, then the summary, then the evidence detail — the same top-down
    /// order the card itself renders, so nothing is added, dropped, or
    /// paraphrased on the way into the transcript.
    static func inboxSpokenMessageText(title: String, summary: String, detail: String?) -> String {
        var parts: [String] = []
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { parts.append("**\(title)**") }
        if !summary.isEmpty, summary != title { parts.append(summary) }
        if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            parts.append(detail)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Composer starter referencing the item, cursor left at the end so the
    /// user continues the sentence. Summary capped so a long brief doesn't
    /// flood the composer.
    static func inboxChatDraftText(title: String, summary: String) -> String {
        var draft = "Re: \(title.isEmpty ? summary : title)"
        if !title.isEmpty && !summary.isEmpty {
            let capped = summary.count > 280 ? String(summary.prefix(280)) + "…" : summary
            draft += " — \(capped)"
        }
        return draft + "\n\n"
    }

    /// L5 G6/G7 — post her card as her message, into the session User is about
    /// to land in. Returns whether a row actually reached the transcript; the
    /// caller falls back to the composer draft on false, so Act is never a
    /// dead button.
    ///
    /// SESSION CHOICE: the session the UI will show. `AppModel` mirrors its
    /// active session into UserDefaults on every selection, which is the only
    /// cross-layer read of that value available here — `AppModel` itself is
    /// MainActor UI state this endpoint cannot reach. If it is missing or
    /// blank (no chat opened yet on a fresh install), there is no session to
    /// speak into and we take the draft fallback rather than minting a stray
    /// one User never opened.
    static func postSpokenInboxMessage(message: String, itemId: String) async -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let sessionId = (UserDefaults.standard.string(forKey: "activeChatSessionId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else {
            NSLog("[NativeClient] inbox act chat_spoken: no active chat session — falling back to draft")
            return false
        }
        let client = makeNativeAgentAppChatOrchestrationClient()
        do {
            // Keyed on the inbox item, so pressing Act twice on the same card
            // is one message — and so an Act on the card the SCHEDULED brief
            // already spoke is a no-op rather than a second copy.
            let outcome = try await client.speakProactively(
                content: trimmed,
                caller: .morningBrief,
                idempotencyKey: SwiftNativeChatOrchestrationClient.proactiveSpeechIdempotencyKey(
                    scope: "inbox:\(itemId)",
                    content: trimmed
                ),
                sessionId: sessionId,
                initiative: .userRequested
            )
            switch outcome {
            case .posted:
                return true
            case .duplicate:
                // Already in the transcript — navigating to it IS the right
                // outcome, and posting again would be the storm this seam
                // exists to prevent.
                return true
            case .rateLimited(let seconds):
                // Unreachable on the `.userRequested` route (see the seam's
                // header); handled rather than assumed away.
                NSLog("[NativeClient] inbox act chat_spoken: rate limited (%ds) — falling back to draft", seconds)
                return false
            }
        } catch {
            NSLog("[NativeClient] inbox act chat_spoken failed: \(error) — falling back to draft")
            return false
        }
    }

    static func openApprovalsFromInboxAction(id: String) async {
        _ = await updateVisibleNotificationInboxStatus(id: id, action: "read")
        await MainActor.run {
            NotificationCenter.default.post(name: .openApprovalsRequest, object: nil)
        }
    }

    // LIVE-ESTIMATE (2026-06-07):
    // Previously read <dataRoot>/chat/sessions/<id>/context.json and zeroed
    // everything when that file was missing. That made the chat composer's
    // context pill show "0 / 0" on Swift-only sessions.
    //
    // New behavior: transcript growth is estimated live from message history,
    // while total request occupancy comes from the latest provider usage
    // receipt written off the LLM return path. This keeps the meter honest:
    // persona, Fluid Context, cognition, and tool schemas no longer disappear
    // from the displayed count. If no matching receipt exists yet, the UI
    // explicitly falls back to a transcript-only estimate.
    func getSessionContext(sessionId: String, model: String? = nil) async throws -> SessionContextStatus {
        try await getSessionContext(
            sessionId: sessionId,
            model: model,
            dataRoot: PersistenceCore.defaultDataRoot(),
            configuredThresholdTokens: nil
        )
    }

    func getSessionContext(
        sessionId: String,
        model: String? = nil,
        dataRoot: URL,
        configuredThresholdTokens: Int?
    ) async throws -> SessionContextStatus {
        // gpt-5.5 review #1 (BLOCKING): The legacy context.json on disk could
        // be stale, and the Swift compactSession() writer below still recorded
        // `auto_compact_threshold: 75` (intended as a percent in the old
        // schema) and a fixed `budget: 200_000`. Honoring that file produced
        // permanently stale data — wrong budget, percent-as-token-threshold,
        // and a model field that read "swift-native-compactor". Live values
        // are now the only source of truth.
        let root = dataRoot

        // Live estimate from messages on disk.
        let messagesPath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        var totalChars = 0
        var messageCount = 0
        if let data = try? Data(contentsOf: messagesPath),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                // gpt-5.5 review #5 (NIT): only count rows that actually
                // decode. A partially-flushed row at the tail was previously
                // inflating messageCount even though its tokens were skipped.
                if let rowData = trimmed.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: rowData) as? [String: Any] {
                    messageCount += 1
                    if let content = obj["content"] as? String {
                        totalChars += content.count
                    } else if let content = obj["content"] {
                        // Tool-result rows store content as a JSON array;
                        // re-serialize to charge for the bytes.
                        if let blob = try? JSONSerialization.data(withJSONObject: content) {
                            totalChars += blob.count
                        }
                    }
                }
            }
        }

        let resolvedModel = (model?.isEmpty == false ? model! : "")
        // gpt-5.5 review #3 (NEEDS_FIX): chars/4 systematically
        // underestimates Anthropic tokenization by ~10–15%. Use ~3.5 for
        // claude-* and 4 for everyone else so the displayed percent is closer
        // to what the provider actually charges. Rounded conservatively
        // (higher token count → bar fills faster → user compacts sooner).
        let divisor: Double = resolvedModel.lowercased().contains("claude") ? 3.5 : 4.0
        let transcriptTokens = max(0, Int((Double(totalChars) / divisor).rounded()))

        let budget = ProviderRouting.contextLength(forModel: resolvedModel)

        let providerUsagePath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("session_state", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("provider_usage.json")
        let providerReceipt: SessionProviderUsageReceipt? = {
            guard let data = try? Data(contentsOf: providerUsagePath),
                  let receipt = try? JSONDecoder().decode(SessionProviderUsageReceipt.self, from: data),
                  receipt.lastRequestInputTokens >= 0,
                  receipt.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    == resolvedModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return nil
            }
            return receipt
        }()
        // A matching provider receipt is the authority even when selective
        // history or compaction makes the real request smaller than the full
        // transcript stored on disk.
        let usedTokens = providerReceipt?.lastRequestInputTokens ?? transcriptTokens
        let promptTokens = max(0, usedTokens - transcriptTokens)

        // The user's preference is the ceiling. The shared compaction policy
        // clamps it to 40% of the selected model's window so a 200k global
        // preference cannot fire too late on a 128k model.
        let configuredThreshold: Int = {
            if let configuredThresholdTokens, configuredThresholdTokens > 0 {
                return configuredThresholdTokens
            }
            let storedThreshold = UserDefaults.standard.integer(
                forKey: "nativeagent.compactionThresholdTokens"
            )
            return storedThreshold > 0
                ? storedThreshold
                : ChatSessionAutocompactionConfig.defaultThresholdTokens
        }()
        let threshold = ChatSessionAutocompactionConfig(
            thresholdTokens: configuredThreshold
        ).effectiveThresholdTokens(forModel: resolvedModel)

        let percent: Double = budget > 0 ? (Double(usedTokens) / Double(budget)) * 100.0 : 0.0
        // gpt-5.5 review #2 (NEEDS_FIX): dropping the `messageCount > 20`
        // gate. compactSession(force: true) bypasses its own >20 guard, and
        // short-but-huge transcripts (heavy tool output across <20 turns)
        // were previously denied the button despite being over budget.
        let compactable = transcriptTokens >= threshold

        return SessionContextStatus(
            session_id: sessionId,
            used_tokens: usedTokens,
            transcript_tokens: transcriptTokens,
            prompt_tokens: promptTokens,
            previous_turn_tokens: providerReceipt?.previousTurnInputTokens,
            turn_delta_tokens: providerReceipt?.turnInputDeltaTokens,
            budget: budget,
            percent: percent,
            message_count: messageCount,
            compactable: compactable,
            auto_compact_threshold: threshold,
            model: resolvedModel,
            context_loaded: providerReceipt != nil,
            context_mode: providerReceipt == nil ? "transcript_estimate" : "provider_receipt",
            context_fingerprint: nil,
            context_prompt_chars: totalChars
        )
    }

    func compactSession(sessionId: String, force: Bool = false) async throws -> CompactionResult {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CompactionResult(
                compacted: false,
                session_id: sessionId,
                messages_before: 0,
                messages_after: 0,
                summary_chars: 0,
                messages_replaced: 0,
                reason: "empty session id",
                percent: nil,
                error: nil
            )
        }
        let root = PersistenceCore.defaultDataRoot()
        let messagesPath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(trimmed).jsonl")
        let sessionDir = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(trimmed, isDirectory: true)
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(messagesPath) {
            // U5 W-A item 1 (:11481): a swallowed read rendered ANY read
            // failure as "nothing to compact". Honesty-only fix (plan-
            // verified NOT data-loss: empty read → replaceCount == 0 →
            // early return, no write, backup taken) — propagate I/O errors
            // and throw on bytes-but-no-rows instead of claiming there is
            // nothing to compact. Missing file (fresh session) still reads
            // as [] → honest "not enough messages".
            let rows = try await Self.readJSONLHonest(
                persistence, path: messagesPath, context: "compactSession")
            let before = rows.count
            // Match the user's old-system continuity preference: keep the last
            // 20 rows hot and uncompacted so short confirmations like
            // "yeah do that" still have the assistant turn they refer to.
            let keepCount = 20
            guard before > keepCount || force else {
                return CompactionResult(
                    compacted: false,
                    session_id: trimmed,
                    messages_before: before,
                    messages_after: before,
                    summary_chars: 0,
                    messages_replaced: 0,
                    reason: "not enough messages to compact",
                    percent: nil,
                    error: nil
                )
            }
            let replaceCount = max(0, before - keepCount)
            guard replaceCount > 0 else {
                return CompactionResult(
                    compacted: false,
                    session_id: trimmed,
                    messages_before: before,
                    messages_after: before,
                    summary_chars: 0,
                    messages_replaced: 0,
                    reason: "nothing to compact",
                    percent: nil,
                    error: nil
                )
            }
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: messagesPath.path) {
                let stamp = Self.fileSafeTimestamp()
                let backup = sessionDir.appendingPathComponent("messages.compact.\(stamp).jsonl")
                try? FileManager.default.copyItem(at: messagesPath, to: backup)
            }
            let replaced = Array(rows.prefix(replaceCount))
            let kept = Array(rows.suffix(keepCount))
            let summary = Self.compactionSummary(for: replaced)
            let nowISO = ISO8601DateFormatter().string(from: Date())
            let summaryRow: JSONValue = .object([
                "id": .string("compact-\(UUID().uuidString.lowercased())"),
                "sessionId": .string(trimmed),
                "role": .string("system"),
                "content": .string(summary),
                "createdAt": .string(nowISO),
                "source": .string("native_compaction"),
                "metadata": .object([
                    "kind": .string("compaction_summary"),
                    "messages_replaced": .int(Int64(replaceCount)),
                ]),
            ])
            let nextRows = [summaryRow] + kept
            var payload = Data()
            for row in nextRows {
                payload.append(Data((try row.serialize(pretty: false)).utf8))
                payload.append(0x0A)
            }
            try FileManager.default.createDirectory(at: messagesPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: messagesPath, options: .atomic)
            // gpt-5.5 review #1 (BLOCKING follow-through): the legacy
            // context.json writer was the source of stale data
            // (`auto_compact_threshold: 75` as a percent, fixed 200k budget,
            // model="swift-native-compactor"). getSessionContext is now
            // entirely live-computed from messages.jsonl, so the writer is
            // gone. The next refresh() pass will reflect the post-compaction
            // state directly.
            return CompactionResult(
                compacted: true,
                session_id: trimmed,
                messages_before: before,
                messages_after: nextRows.count,
                summary_chars: summary.count,
                messages_replaced: replaceCount,
                reason: "swift-native-compaction",
                percent: nil,
                error: nil
            )
        }
    }

    static func visibleNotificationInboxPath(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> URL {
        dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    @discardableResult
    static func updateVisibleNotificationInboxStatus(
        id: String,
        action: String,
        inboxPath: URL = visibleNotificationInboxPath(),
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
    ) async -> Bool {
        let status: String
        let readAt: String?
        switch action {
        case "read":
            status = "read"
            readAt = NotificationInboxStore.nowISO()
        case "archive":
            status = "archived"
            readAt = nil
        case "dismiss":
            status = "dismissed"
            readAt = nil
        default:
            return false
        }

        // U5 W-A item 1 (:11597): the read swallow turned a corrupt/
        // unreadable inbox into rows=[] → "row not found" → false, silently
        // dropping the status write (archived-card-resurrection class). Read
        // failures throw, get LOGGED, and return false without ever treating
        // corrupt-as-empty.
        //
        // 2026-08-11: reads via `InboxRewriteGuard.readLines` so a SINGLE
        // malformed row among valid rows survives the rewrite verbatim
        // instead of being silently dropped (the old lossy-read shape lost
        // it on every status write).
        do {
            return try await persistence.withFileLock(inboxPath) { () async throws -> Bool in
                let lines = try InboxRewriteGuard.readLines(inboxPath)
                guard !lines.isEmpty else { return false }
                var updated = false
                var mutated: [Data] = []
                mutated.reserveCapacity(lines.count)

                for line in lines {
                    guard case .object(var obj)? = line.row,
                          case .string(let rowID)? = obj["id"],
                          rowID == id else {
                        // Other rows AND undecodable lines: verbatim.
                        mutated.append(line.raw)
                        continue
                    }
                    obj["status"] = .string(status)
                    if let readAt {
                        obj["read_at"] = .string(readAt)
                    }
                    mutated.append(Data(try JSONValue.object(obj).serialize(pretty: false).utf8))
                    updated = true
                }
                guard updated else { return false }
                try InboxRewriteGuard.writeLines(mutated, to: inboxPath)
                return true
            }
        } catch {
            NSLog("[inbox] updateVisibleNotificationInboxStatus(\(action)) failed for \(id): \(String(describing: error))")
            return false
        }
    }

    // PATCH-2026-05-07 / DAEMON-DEAD PORT (2026-06-02): read
    // <dataRoot>/notifications/inbox.jsonl directly. Cross-ref NotificationInbox.
    // Lossy per-row decode — one malformed record doesn't nuke the list.
    //
    // 2026-06-06: sort newest-first by created_at. The file is append-only,
    // so without this the just-fired card (e.g. tonight's dream) lands at
    // the BOTTOM of the inbox list and gets buried under older entries —
    // the user sees the push but can't find the card. Both consumers (Mac
    // InboxView's List(displayItems) and MacSyncEngine.nativeInboxSnapshotData
    // → iOS InboxStore) inherit this ordering, so iOS inbox surfaces it
    // the same way without an extra sort there.
    func getInboxItems(unreadOnly: Bool = false) async throws -> [InboxItemRecord] {
        let root = PersistenceCore.defaultDataRoot()
        let inboxPath = root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let persistence = SwiftNativePersistenceCore()
        // U5 W-A item 1 (:11647): the read was swallowed into [] — a
        // corrupt/unreadable inbox file rendered as an EMPTY inbox.
        // readJSONLHonest propagates I/O errors AND throws on
        // bytes-but-no-rows; per-row decode stays lossy (one malformed
        // record doesn't nuke the list) but ALL rows failing to decode
        // throws too (decodeLossyArray's all-fail rule).
        let rows = try await Self.readJSONLHonest(
            persistence, path: inboxPath, context: "getInboxItems")
        let decoder = JSONDecoder()
        var items: [InboxItemRecord] = []
        var decodeFailures = 0
        for row in rows {
            guard let data = try? row.serializedData(pretty: false),
                  let item = try? decoder.decode(InboxItemRecord.self, from: data) else {
                decodeFailures += 1
                continue
            }
            if unreadOnly && !item.isUnread { continue }
            items.append(item)
        }
        if !rows.isEmpty && decodeFailures == rows.count {
            throw NSError(domain: "NativeAgent", code: -3, userInfo: [
                NSLocalizedDescriptionKey:
                    "getInboxItems: all \(rows.count) inbox row(s) failed to decode — "
                    + "refusing to render a corrupt inbox as empty"
            ])
        }
        // Newest-first by created_at. ISO-8601 strings sort lexicographically
        // in chronological order, so a string compare is correct; entries
        // with missing/blank created_at fall to the bottom.
        items.sort { lhs, rhs in
            if lhs.created_at.isEmpty { return false }
            if rhs.created_at.isEmpty { return true }
            return lhs.created_at > rhs.created_at
        }
        return items
    }

    // PATCH-2026-05-07: proactive-inbox-1 Get inbox trigger configs
    func getInboxTriggers() async throws -> [InboxTriggerConfig] {
        // SUBSYSTEM #17 cluster C3 (2026-05-31): SwiftNative TriggerScheduler.
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        return try await swiftListInboxTriggers()
    }

    // PATCH-2026-05-07: proactive-inbox-1 Trigger management helpers (Sendable-safe, discard return)
    func inboxTriggerEnable(_ name: String, enabled: Bool) async throws {
        // SUBSYSTEM #17 cluster C3 (2026-05-31): SwiftNative TriggerScheduler.
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        try await swiftInboxTriggerEnable(name: name, enabled: enabled)
        return
    }

    /// Typed shim for /v1/inbox/triggers/<name>/configure. InboxSettingsView
    /// uses this owner-preserving path instead of bypassing TriggerScheduler.
    /// Body shape: dict of arbitrary per-kind keys
    /// (e.g. {"paths": [...]} for file_watch).
    func inboxTriggerConfigure(_ name: String, body: [String: Any]) async throws {
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        try await swiftInboxTriggerConfigure(name: name, body: body)
        return
    }

    func inboxTriggerFireNow(_ name: String, stub: Bool) async throws -> (itemId: String?, wasStub: Bool) {
        // Wave 12 (2026-05-31): SwiftNative path covers the stub=true canonical
        // kinds (file_watch/idle/time/execution_complete/session_pattern). The
        // non-stub action path now fails closed if the Swift scheduler cannot
        // execute it.
        // FIRE site: carries the paired-device push sender (see
        // TriggerNotifierBinding) so a manual fire pushes exactly like the
        // periodic tick does.
        let client = TriggerNotifierBinding.makeNotifyingTriggerScheduler()
        let result = try await client.fireInboxTrigger(name: name, isStub: stub)
        if let err = result.error, !err.isEmpty {
            throw NSError(domain: "NativeAgent", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: err])
        }
        if result.status == "not_found" {
            // Match HTTP error envelope shape: daemon returns {"error":"not_found"}
            // and HTTP path throws the bare string. Keep behavior symmetric so
            // callers (InboxSettingsView) branch on the same text.
            throw NSError(domain: "NativeAgent", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "not_found"])
        }
        // A fire the notifier did not handle (notify:false) still has to reach
        // the REAL notifications inbox — otherwise "Fire now" reports success
        // and the user's inbox stays empty (board M18). And if that mirror
        // FAILS, say so: a manual fire whose card never landed is an error,
        // not a success with an invisible item (gpt-5.5 review, 2026-07-09).
        if !(await TriggerNotifierBinding.mirrorNonNotifiedFire(result)) {
            throw NSError(domain: "NativeAgent", code: -1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Trigger fired but its card could not be written to the notifications inbox — check disk/logs (trigger_mirror)."
            ])
        }
        // Post-rebuild (2026-07-09): `result.stub` now means "is this a PLACEHOLDER"
        // — time/idle fires carry real content and return stub == false even when
        // requested with isStub: true. Surface the truth to the UI instead of
        // dropping it (gpt-5.5 review MED: the settings panel said "Fired (stub)"
        // for genuinely real briefs).
        return (result.itemId, result.stub ?? true)
    }

    // SUBSYSTEM #17 (2026-05-31): retired diagnostic UI + /v1/inbox/self_test

    func submitWorkshopExecution(
        title: String,
        objective: String,
        triggerSource: String = "manual",
        projectSpaceId: String? = nil
    ) async throws -> WorkshopActionResult {
        // Compatibility seam retained for the live Workshop create consumer.
        // Gate it behind the SAME `.missionsWrites` wire flag as the legacy
        // create route so every create path stays native together. Mirrors the
        // retired `/v1/missions` queue-bridge response while current storage and
        // product ownership remain Workshop. It threads `triggerSource` through;
        // compatibility callers may still pass "trigger:<name>".
        // The daemon's create response is the SUMMARY {id,mission_id,status,title,
        // plan_steps}; build the equivalent WorkshopActionResult from the native
        // submit envelope + record.
        let runner = makeWorkshopExecutionRunner()
        let spec = WorkshopExecution.WorkshopExecutionSpec(
            title: title,
            objective: objective,
            triggerSource: triggerSource,
            trustRequired: "none",
            projectSpaceId: projectSpaceId
        )
        let result = try await WorkshopExecution.WorkshopDirectedTaskSubmitter(
            dataRoot: PersistenceCore.defaultDataRoot(),
            runner: runner
        ).submit(spec: spec)
        return WorkshopActionResult(
            // MINOR STATUS DIVERGENCE (documented §6.220): the daemon's
            // create handler flips status→"running" inside submit() and
            // returns "running"; the SwiftNative submit() persists "queued"
            // and execution is deferred to WorkshopExecutorLoop's next drain
            // pass (executor port, 2026-06-10) rather than a submit-time
            // auto-start. Cosmetic only — this drives the "Execution queued:
            // <id>" toast, not control flow; loadMissions() re-reads the
            // live status from the queue right after. Reporting the enqueue
            // status is honest.
            executionId: result.executionId,
            status: result.execution.status,
            title: result.execution.title,
            plan_steps: result.execution.plan.count,
            id: result.executionId,
            desk_handle: result.deskItem.handle,
            desk_alias: result.deskItem.alias
        )
    }

    // Swift-native execution start. Do not synthesize `running`: the Executions
    // module owns execution state.
    //
    // gpt-5.5 executor-port blocker #1 (2026-06-10): this used to call the
    // WorkshopRunnerClient protocol's start(), which deliberately throws
    // .unavailable (the runner holds no executor closures) — the UI "Start
    // execution" path was dead. Explicit starts now route through the
    // ASSEMBLED WorkshopExecutorLoop instance published at app boot by
    // BackgroundLoopsAssembly.makeMissionExecutorLoopRunner →
    // WorkshopExecutorRef.shared (the AppRestartCoordinator.shared.configure
    // wiring pattern). Unconfigured ref (headless/test process, loops not
    // started yet) → honest "executor not running" error, never a silent
    // no-op; the execution stays durably queued for the next drain pass.
    func startWorkshopExecution(id: String) async throws -> WorkshopActionResult {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentWorkshop", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "startWorkshopExecution: empty id"
            ])
        }
        guard let executor = WorkshopExecutorRef.shared.current() else {
            throw NSError(domain: "NativeAgentWorkshop", code: 503, userInfo: [
                NSLocalizedDescriptionKey: "startWorkshopExecution: Desk executor is not running in this process "
                    + "(background loops have not been assembled) — Desk execution left queued"
            ])
        }
        let record = try await executor.start(executionId: trimmed)
        return WorkshopActionResult(
            executionId: record.id,
            status: record.status,
            title: record.title,
            plan_steps: record.plan.count,
            id: record.id
        )
    }

    // DAEMON-DEAD PORT (2026-06-02): read the approvals file, mark the matching
    // step record approved, write back under a flock. Then return the current
    // execution detail (native read).
    //
    // R5 (eval E06 fix-3): canonical path is `<root>/workflows/approvals/requests.json`
    // — matches the ApprovalInbox list reader source-of-truth
    // (ApprovalInbox.approvalsPath) and the daemon's notification-status reader.
    // Any pre-existing rows at the legacy `<root>/approvals/requests.json` are
    // migrated once: merged into the canonical file (canonical wins on id-conflict),
    // then the legacy file is renamed to `requests.json.migrated` so a second boot
    // skips the merge.
    func approveStep(executionId: String, stepId: String) async throws -> WorkshopExecution.WorkshopExecutionRecord {
        let root = PersistenceCore.defaultDataRoot()
        let approvalsPath = root
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json")
        let legacyApprovalsPath = root
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json")
        let persistence = SwiftNativePersistenceCore()
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        try await persistence.withFileLock(approvalsPath) {
            // One-time migrate: if legacy path exists and has rows, merge into
            // the canonical file (canonical wins on id-conflict), then rename
            // the legacy file so subsequent boots skip the merge.
            if FileManager.default.fileExists(atPath: legacyApprovalsPath.path) {
                let legacyRaw = await persistence.readJSON(legacyApprovalsPath, defaultValue: .array([]))
                if case .array(let legacyRows) = legacyRaw, !legacyRows.isEmpty {
                    let canonicalRaw = await persistence.readJSON(approvalsPath, defaultValue: .array([]))
                    var canonicalRows: [JSONValue] = {
                        if case .array(let a) = canonicalRaw { return a }
                        return []
                    }()
                    func rowKey(_ v: JSONValue) -> String? {
                        guard case .object(let obj) = v else { return nil }
                        let m: String? = { if case .string(let s) = obj["executionId"] ?? obj["execution_id"] ?? obj["missionId"] ?? obj["mission_id"] ?? .null { return s }; return nil }()
                        let s: String? = { if case .string(let s) = obj["stepId"] ?? obj["step_id"] ?? obj["id"] ?? .null { return s }; return nil }()
                        guard let m = m, let s = s else { return nil }
                        return "\(m)#\(s)"
                    }
                    let existing: Set<String> = Set(canonicalRows.compactMap(rowKey))
                    for row in legacyRows {
                        if let k = rowKey(row), !existing.contains(k) {
                            canonicalRows.append(row)
                        }
                    }
                    try await persistence.writeJSON(.array(canonicalRows), to: approvalsPath)
                }
                let migratedPath = legacyApprovalsPath
                    .deletingLastPathComponent()
                    .appendingPathComponent("requests.json.migrated")
                try? FileManager.default.removeItem(at: migratedPath)
                try? FileManager.default.moveItem(at: legacyApprovalsPath, to: migratedPath)
            }
            let raw = await persistence.readJSON(approvalsPath, defaultValue: .array([]))
            var rows: [JSONValue] = {
                if case .array(let a) = raw { return a }
                return []
            }()
            var matched = false
            for i in rows.indices {
                guard case .object(var obj) = rows[i] else { continue }
                let rowWorkshopExecution: String? = { if case .string(let s) = obj["executionId"] ?? obj["execution_id"] ?? obj["missionId"] ?? obj["mission_id"] ?? .null { return s }; return nil }()
                let rowStep: String? = { if case .string(let s) = obj["stepId"] ?? obj["step_id"] ?? obj["id"] ?? .null { return s }; return nil }()
                if rowWorkshopExecution == executionId && rowStep == stepId {
                    obj["status"] = .string("approved")
                    obj["decision"] = .string("approved")
                    obj["resolvedAt"] = .string(nowISO)
                    rows[i] = .object(obj)
                    matched = true
                }
            }
            if !matched {
                rows.append(.object([
                    "executionId": .string(executionId),
                    "stepId": .string(stepId),
                    "status": .string("approved"),
                    "decision": .string("approved"),
                    "resolvedAt": .string(nowISO),
                ]))
            }
            try await persistence.writeJSON(.array(rows), to: approvalsPath)
        }
        guard let record = await makeWorkshopExecutionRunner().getWorkshopExecution(executionId) else {
            throw DaemonError.notFound("workshop execution \(executionId)")
        }
        return record
    }

    func rejectStep(executionId: String, stepId: String, reason: String = "Rejected by user") async throws -> WorkshopExecution.WorkshopExecutionRecord {
        // residue/R6: daemon step-reject route retired. Mirror approveStep's
        // canonical-path R-M-W under flock; flip decision to "rejected" + carry
        // the reason. Same approvals.json file the ApprovalInbox reads.
        let root = PersistenceCore.defaultDataRoot()
        let approvalsPath = root
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json")
        let persistence = SwiftNativePersistenceCore()
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        try await persistence.withFileLock(approvalsPath) {
            let raw = await persistence.readJSON(approvalsPath, defaultValue: .array([]))
            var rows: [JSONValue] = {
                if case .array(let a) = raw { return a }
                return []
            }()
            var matched = false
            for i in rows.indices {
                guard case .object(var obj) = rows[i] else { continue }
                let rowWorkshopExecution: String? = { if case .string(let s) = obj["executionId"] ?? obj["execution_id"] ?? obj["missionId"] ?? obj["mission_id"] ?? .null { return s }; return nil }()
                let rowStep: String? = { if case .string(let s) = obj["stepId"] ?? obj["step_id"] ?? obj["id"] ?? .null { return s }; return nil }()
                if rowWorkshopExecution == executionId && rowStep == stepId {
                    obj["status"] = .string("rejected")
                    obj["decision"] = .string("rejected")
                    obj["reason"] = .string(reason)
                    obj["resolvedAt"] = .string(nowISO)
                    rows[i] = .object(obj)
                    matched = true
                }
            }
            if !matched {
                rows.append(.object([
                    "executionId": .string(executionId),
                    "stepId": .string(stepId),
                    "status": .string("rejected"),
                    "decision": .string("rejected"),
                    "reason": .string(reason),
                    "resolvedAt": .string(nowISO),
                ]))
            }
            try await persistence.writeJSON(.array(rows), to: approvalsPath)
        }
        guard let record = await makeWorkshopExecutionRunner().getWorkshopExecution(executionId) else {
            throw DaemonError.notFound("workshop execution \(executionId)")
        }
        return record
    }

    func setTriggerEnabled(name: String, enabled: Bool) async throws -> WorkshopActionResult {
        // SUBSYSTEM #17 cluster C3 (2026-05-31): SwiftNative TriggerScheduler
        // returns a TriggerStatus envelope ({"name","enabled","status"}); map
        // onto WorkshopActionResult for the remaining settings callers.
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        return try await swiftWorkshopTriggerEnable(name: name, enabled: enabled)
    }

    // SUBSYSTEM #17: retired Swift wrapper for /v1/missions/triggers/<name>/fire_now.

    // SUBSYSTEM #17: retired Swift wrapper missionSelfTest.

    // PATCH-2026-05-06: dev-mode added to JSON body so daemon receives it
}
