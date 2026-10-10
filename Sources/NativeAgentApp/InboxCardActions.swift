import Desk
import ApprovalTransactions
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
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import TrustPersistence
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

/// What a card's buttons do: read/archive/dismiss status writes on the live
/// inbox, approve/reject through the approval coordinator, the heartbeat's
/// controls, and Act's per-kind route (open approvals, the Desk, a chat
/// draft, her message, disk cleanup).
enum InboxCardActions {
    /// Closed executor vocabulary for persisted inbox controls. Heartbeat
    /// controls are imported from their producer contract so a new heartbeat
    /// button cannot be accepted or omitted independently here.
    static let explicitlyHandledInboxActionIDs: Set<String> = Set([
        "read", "archive", "dismiss", "act", "approve", "reject",
    ]).union(HeartbeatCardAction.ids)

    // PATCH-2026-05-07: proactive-inbox-1 Inbox action helper (avoids Sendable Any issue at call site)
    /// `quiet` is the agent's call (the inbox tool): the same writes, but it
    /// never navigates User's window or touches his composer.
    static func perform(
        _ id: String, action: String, metadata: [String: JSONValue] = [:], quiet: Bool = false,
        dataRootOverride: URL?
    ) async throws {
        // Keep the action writer on the same resolved root as the inbox reader.
        // Isolated/recovered app surfaces inject `dataRootOverride`; falling
        // back to the process default here made a visible card's button write
        // a different inbox (or fail) even though its reader was correct.
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let visibleInboxPath = visibleNotificationInboxPath(dataRoot: root)
        // "reply" needs text input the act handler doesn't have. If a caller
        // hits this entry point with `reply`, surface the gap honestly
        // instead of silently mapping to `act`. (gpt-5.5 review HIGH: act
        // could otherwise recurse into reply → infinite loop.)
        let normalizedAction = action == "deny" ? "reject" : action
        if id.hasPrefix("interaction:"), !["read", "archive", "dismiss"].contains(normalizedAction) {
            try await InteractionCardDelivery.act(id: id, action: normalizedAction, dataRoot: root, quiet: quiet)
            return
        }
        if normalizedAction == "reply" {
            throw NSError(
                domain: "NativeAgentSwiftOnly",
                code: -410,
                userInfo: [NSLocalizedDescriptionKey: "Reply requires text input; use inboxReply(id:text:) instead of inboxAction(id:\"reply\")."]
            )
        }
        let nativeActions = explicitlyHandledInboxActionIDs
        guard nativeActions.contains(normalizedAction) else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -410, userInfo: [
                NSLocalizedDescriptionKey: "Unknown inbox action: \(normalizedAction)"
            ])
        }
        let endpointAction = normalizedAction

        // Wave 32 W16 (2026-06-01): consume the SwiftNative NotificationInbox for
        // status-write actions — read / archive / dismiss. archive/dismiss fire
        // the proactive-outcome ledger before the index.json overlay write under
        // the inbox file lock. Other actions are handled below or fail closed.
        if endpointAction == "read" || endpointAction == "archive" || endpointAction == "dismiss" {
            if await updateVisibleStatus(
                id: id, action: endpointAction, inboxPath: visibleInboxPath, metadata: metadata) {
                return
            }
            // A5.2 (2026-07-24): the legacy silo fallback (makeNotificationInbox
            // → items.jsonl/index.json) is GONE — the silo is retired and
            // frozen, so a fallback "success" there updated dead storage while
            // the visible card stayed put, masking the live-store failure. The
            // live store is the only store; a failed write surfaces as the
            // retryable error below (same resurrect-audit rationale, 2026-06-09).
            nativeLog("[inbox] inboxAction(\(endpointAction)) id=\(id): live inbox status write declined")
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
                _ = try await ApprovalTransactionCoordinator.app(dataRootOverride: dataRootOverride)
                    .resolveApproval(id: id, decision: endpointAction)
            } catch ApprovalInboxError.alreadyResolved(let resolvedID, let status) {
                // Idempotent re-tap: the record is already terminal. Treat as
                // success so a double-tap doesn't surface a spurious error.
                nativeLog("[inbox] inboxAction(\(endpointAction)) id=\(resolvedID): already resolved (\(status)); treating as success")
            } catch {
                // Surface real failures to the caller instead of reporting
                // unconditional success over a swallowed error.
                nativeLog("[inbox] inboxAction(\(endpointAction)) id=\(id): \(error)")
                throw error
            }
            return
        }
        if endpointAction == HeartbeatCardAction.openApprovals.rawValue {
            if quiet {
                _ = await updateVisibleStatus(id: id, action: "read", inboxPath: visibleInboxPath)
            } else {
                await openApprovalsFromInboxAction(id: id, inboxPath: visibleInboxPath)
            }
            return
        }
        if endpointAction == HeartbeatCardAction.repair.rawValue {
            let message = try await BackgroundLoopsAssembly.repairHeartbeatInboxItem(id: id, dataRoot: root)
            _ = await updateVisibleStatus(id: id, action: "archive", inboxPath: visibleInboxPath)
            nativeLog("[inbox] inboxAction(repair) id=\(id): \(message)")
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
            let items = try await InboxFacade(dataRoot: root).list()
            guard let item = items.first(where: { $0.id == id }) else {
                throw NSError(
                    domain: "NativeAgentSwiftOnly",
                    code: -410,
                    userInfo: [NSLocalizedDescriptionKey: "Inbox item \(id) not found"]
                )
            }
            let resolution = resolvePrimaryAction(for: item)
            // The approvals path marks the row read inside
            // openApprovalsFromInboxAction; the other resolvable paths mark
            // it here via the resolution's status action ("read", never
            // "archive" — acting on an item is engagement, not disposal).
            if let statusAction = resolution.inboxStatusAction {
                // gpt-5.5 review HIGH: a swallowed failure here would let Act
                // "succeed" while the row stays unread. Nothing else has
                // happened yet, so failing loud with the same retryable -423
                // the read/archive path uses keeps a retry clean.
                guard await updateVisibleStatus(
                    id: id, action: statusAction, inboxPath: visibleInboxPath) else {
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
                if quiet {
                    _ = await updateVisibleStatus(id: id, action: "read", inboxPath: visibleInboxPath)
                } else {
                    await openApprovalsFromInboxAction(id: id, inboxPath: visibleInboxPath)
                }
            case .openDeskExecution:
                if quiet { break }
                // No execution-detail deep link exists yet (DeskItem carries
                // no execution id), so land on the Desk surface via the same
                // coordinator route the command palette uses.
                await MainActor.run {
                    NotificationCenter.default.post(name: .openCommandRouteRequest, object: "desk")
                }
            case .chatDraft(let draft):
                if quiet { break }
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
                // An unresolved duplicate throws without opening the composer.
                // Otherwise, if the seam refuses (rate limit)
                // or the write throws, fall back to the old composer draft so
                // Act still does something and User still lands in chat with the
                // reference — but say which one happened in the log rather than
                // pretending she spoke.
                let spokenSession = try await postSpokenInboxMessage(message: message, itemId: id, dataRoot: root)
                if quiet {
                    guard spokenSession != nil else {
                        throw NSError(domain: "NativeAgentSwiftOnly", code: -423, userInfo: [NSLocalizedDescriptionKey:
                            "Inbox act for \(id): the chat message didn't post (rate limit or write failure) — retry later."])
                    }
                    break
                }
                await MainActor.run {
                    if let spokenSession {
                        NotificationCenter.default.post(name: .openSpokenChatRequest, object: spokenSession)
                    } else {
                        NotificationCenter.default.post(
                            name: .openChatDraftRequest,
                            object: inboxChatDraftText(
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
                let message = try await BackgroundLoopsAssembly.cleanUpDiskHygiene(dataRoot: root)
                nativeLog("[inbox] inboxAction(act) disk_hygiene: \(message)")
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
    /// Every case is a terminal handler — none re-enters `perform`, which is
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
    static func resolvePrimaryAction(for item: InboxItemRecord) -> InboxPrimaryActionResolution {
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
    /// to land in. Returns the original destination on a duplicate; the
    /// caller falls back to the composer draft on nil. An unresolved duplicate
    /// throws instead, keeping the already claimed message suppressed.
    ///
    /// SESSION CHOICE: the session the UI will show. `AppModel` mirrors its
    /// active session into UserDefaults on every selection, which is the only
    /// cross-layer read of that value available here — `AppModel` itself is
    /// MainActor UI state this endpoint cannot reach. If it is missing or
    /// blank (no chat opened yet on a fresh install), there is no session to
    /// speak into and we take the draft fallback rather than minting a stray
    /// one User never opened.
    static func postSpokenInboxMessage(message: String, itemId: String, dataRoot: URL) async throws -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sessionId = (UserDefaults.standard.string(forKey: "activeChatSessionId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else {
            nativeLog("[inbox] act chat_spoken: no active chat session — falling back to draft")
            return nil
        }
        let client = NativeAgentEngine.forRoot(dataRoot).chatClient(profile: .background)
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
            case .posted(let destination, _):
                return destination
            case .duplicate(let destination):
                // Already in the transcript — navigating to it IS the right
                // outcome, and posting again would be the storm this seam
                // exists to prevent.
                return destination
            case .rateLimited(let seconds):
                // Unreachable on the `.userRequested` route (see the seam's
                // header); handled rather than assumed away.
                nativeLog("[inbox] act chat_spoken: rate limited (%ds) — falling back to draft", seconds)
                return nil
            }
        } catch let error as ProactiveSpeechError {
            throw error
        } catch {
            nativeLog("[inbox] act chat_spoken failed: \(error) — falling back to draft")
            return nil
        }
    }

    static func openApprovalsFromInboxAction(id: String, inboxPath: URL) async {
        _ = await updateVisibleStatus(id: id, action: "read", inboxPath: inboxPath)
        await MainActor.run {
            NotificationCenter.default.post(name: .openApprovalsRequest, object: nil)
        }
    }

    static func visibleNotificationInboxPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    @discardableResult
    static func updateVisibleStatus(
        id: String,
        action: String,
        inboxPath: URL,
        metadata: [String: JSONValue] = [:]
    ) async -> Bool {
        let status: String
        let readAt: String?
        switch action {
        case "read":
            status = "read"
            readAt = NotificationInboxClock.nowISO()
        case "archive":
            status = "archived"
            readAt = nil
        case "dismiss":
            status = "dismissed"
            readAt = nil
        default:
            return false
        }

        do {
            return try await LiveNotificationInbox(path: inboxPath).updateStatus(
                id: id, status: status, readAt: readAt, metadata: metadata
            )
        } catch {
            nativeLog("[inbox] updateVisibleNotificationInboxStatus(\(action)) failed for \(id): \(String(describing: error))")
            return false
        }
    }
}
