import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
import ChatTurnRuntime
import Transcripts
import NotificationInbox
import Experiences

// Blueprint: | `InboxCardActions.swift` | Inbox actions change the matter's reading; putting away an open ask first declines through its resolver |

/// Assembly and presentation bindings; the transaction owns ordering and receipts.
public protocol InboxCardActionEffects: Sendable {
    func interactionAction(id: String, action: String, dataRoot: URL, quiet: Bool, turn: Turn) async throws
    func resolveApproval(id: String, decision: String, dataRootOverride: URL?, turn: Turn) async throws
    func inboxItems(dataRoot: URL) async throws -> [InboxItemRecord]
    func cleanUpDiskHygiene(dataRoot: URL) async throws -> String
    func chatClient(dataRoot: URL) -> SwiftNativeChatOrchestrationClient
    @MainActor func openApprovals() async
    @MainActor func openDesk() async
    @MainActor func openChatDraft(_ draft: String) async
    @MainActor func openSpokenChat(_ sessionID: String) async
}

public enum InboxCardActions {
    public static func perform(
        _ id: String, action: String, metadata: [String: JSONValue] = [:], quiet: Bool = false,
        dataRootOverride: URL?, turn: Turn, effects: any InboxCardActionEffects
    ) async throws {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let normalizedAction = InboxActionVocabulary.normalizedAction(action)
        if id.hasPrefix("interaction:"), normalizedAction != "read" {
            let putsAway = ["archive", "dismiss"].contains(normalizedAction)
            do {
                try await effects.interactionAction(id: id, action: putsAway ? "reject" : normalizedAction, dataRoot: root, quiet: quiet, turn: turn)
            } catch InlineInteractionResolver.ResolveError.alreadySettled where putsAway {
                // A decision already settled (or failed) has nothing left to decline; putting its card away is all the person asked.
            }
            // Save the requested inbox disposition after its underlying decision; other card actions own their delivery reconciliation.
            if !putsAway { return }
        }
        if normalizedAction == "reply" {
            throw NSError(
                domain: "NativeAgentSwiftOnly",
                code: -410,
                userInfo: [NSLocalizedDescriptionKey: "Reply requires text input; use inboxReply(id:text:) instead of inboxAction(id:\"reply\")."]
            )
        }
        guard InboxActionVocabulary.nativeActionIDs.contains(normalizedAction) else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -410, userInfo: [
                NSLocalizedDescriptionKey: "Unknown inbox action: \(normalizedAction)"
            ])
        }
        let endpointAction = normalizedAction

        if endpointAction == "archive" || endpointAction == "dismiss",
           let matter = try await ForPerson.at(root).matter(id), matter.owes["decide"]?.phase.isSettled == false,
           let approval = matter.evidence.first(where: { $0.source == Matter.approvals }) {
            do { try await effects.resolveApproval(id: approval.id, decision: "reject", dataRootOverride: root, turn: turn) }
            catch ApprovalInboxError.alreadyResolved { }
        }
        if endpointAction == "read" || endpointAction == "archive" || endpointAction == "dismiss" {
            try await setReading(id: id, action: endpointAction, dataRoot: root)
            return
        }
        if endpointAction == "approve" || endpointAction == "reject" {
            do {
                try await effects.resolveApproval(id: id, decision: endpointAction, dataRootOverride: dataRootOverride, turn: turn)
            } catch ApprovalInboxError.alreadyResolved(let resolvedID, let status) {
                nativeLog("[inbox] inboxAction(\(endpointAction)) id=\(resolvedID): already resolved (\(status)); treating as success")
            } catch {
                nativeLog("[inbox] inboxAction(\(endpointAction)) id=\(id): \(error)")
                throw error
            }
            return
        }
        if endpointAction == "open_approvals" {
            if quiet {
                try await setReading(id: id, action: "read", dataRoot: root)
            } else {
                try await openApprovalsFromInboxAction(id: id, dataRoot: root, effects: effects)
            }
            return
        }
        if endpointAction == "act" {
            let items = try await effects.inboxItems(dataRoot: root)
            guard let item = items.first(where: { $0.id == id }) else {
                throw NSError(
                    domain: "NativeAgentSwiftOnly",
                    code: -410,
                    userInfo: [NSLocalizedDescriptionKey: "Inbox item \(id) not found"]
                )
            }
            let resolution = resolvePrimaryAction(for: item)
            switch resolution {
            case .openApprovals:
                if quiet {
                    try await setReading(id: id, action: "read", dataRoot: root)
                } else {
                    try await openApprovalsFromInboxAction(id: id, dataRoot: root, effects: effects)
                }
            case .chatDraft(let draft):
                if quiet { break }
                await effects.openChatDraft(draft)
            case .chatSpoken(let message):
                let spokenSession = try await postSpokenInboxMessage(message: message, item: item, dataRoot: root, turn: turn, effects: effects)
                if !quiet { await effects.openSpokenChat(spokenSession) }
            case .diskCleanup:
                let message = try await effects.cleanUpDiskHygiene(dataRoot: root)
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
            // A refused effect leaves the card unread. A posted speech is idempotent, so a failed read-marker write can safely be retried.
            if let statusAction = resolution.inboxStatusAction {
                try await setReading(id: id, action: statusAction, dataRoot: root)
            }
            return
        }
        throw NSError(
            domain: "NativeAgentSwiftOnly",
            code: -410,
            userInfo: [NSLocalizedDescriptionKey: "Inbox action \(endpointAction) has no native resolver"]
        )
    }

    public enum InboxPrimaryActionResolution: Equatable, Sendable {
        case openApprovals
        case chatDraft(draft: String)
        case chatSpoken(message: String)
        case diskCleanup
        case unresolved(reason: String)

        var inboxStatusAction: String? {
            switch self {
            case .openApprovals, .diskCleanup, .unresolved: return nil
            case .chatDraft, .chatSpoken: return "read"
            }
        }
    }

    public static func resolvePrimaryAction(for item: InboxItemRecord) -> InboxPrimaryActionResolution {
        if item.isApprovalBacklogCard {
            return .openApprovals
        }
        if item.source == "disk_hygiene" {
            return .diskCleanup
        }
        if item.isProactiveCard {
            return .unresolved(reason: "unmapped proactive card — no approval link")
        }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty && summary.isEmpty {
            return .unresolved(reason: "no linked approval/execution and no referenceable content")
        }
        if isAgentVoiceCard(item) {
            return .chatSpoken(
                message: inboxSpokenMessageText(title: title, summary: summary, detail: item.detail)
            )
        }
        return .chatDraft(draft: inboxChatDraftText(title: title, summary: summary))
    }

    // Only these exact producers author a message in the agent's voice.
    static let agentVoiceCardSources: Set<String> = ["trigger:morning_brief", "idle_checkin"]

    static func isAgentVoiceCard(_ item: InboxItemRecord) -> Bool {
        agentVoiceCardSources.contains(item.source.trimmingCharacters(in: .whitespacesAndNewlines))
    }

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

    static func inboxChatDraftText(title: String, summary: String) -> String {
        var draft = "Re: \(title.isEmpty ? summary : title)"
        if !title.isEmpty && !summary.isEmpty {
            let capped = summary.count > 280 ? String(summary.prefix(280)) + "…" : summary
            draft += " — \(capped)"
        }
        return draft + "\n\n"
    }

    private static func postSpokenInboxMessage(message: String, item: InboxItemRecord, dataRoot: URL,
        turn: Turn, effects: any InboxCardActionEffects) async throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -423, userInfo: [NSLocalizedDescriptionKey: "This inbox message has no content to deliver."])
        }
        let sessionId: String
        if let own = item.chat_session_id {
            guard NativeAgentChatSessionID.normalizedPathComponent(own) == own else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -423, userInfo: [NSLocalizedDescriptionKey:
                    "This inbox card's conversation is invalid. Repair its conversation link before delivering it."])
            }
            sessionId = own
        } else {
            guard let anchor = try ConversationAnchor.checkedCurrent(dataRoot: dataRoot) else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -423, userInfo: [NSLocalizedDescriptionKey:
                    "This inbox card has no conversation and no current conversation is anchored. Open your conversation, then retry this card."])
            }
            sessionId = anchor.sessionId
        }
        let client = effects.chatClient(dataRoot: dataRoot)
        do {
            // Act and scheduled delivery share one inbox claim and destination.
            let outcome = try await client.speakProactively(
                content: trimmed,
                caller: .morningBrief,
                idempotencyKey: SwiftNativeChatOrchestrationClient.proactiveSpeechIdempotencyKey(
                    scope: "inbox:\(item.id)",
                    content: trimmed
                ),
                sessionId: sessionId,
                initiative: .userRequested,
                turn: turn
            )
            switch outcome {
            case .posted(let destination, _):
                return destination
            case .duplicate(let destination):
                return destination
            case .rateLimited(let seconds):
                throw NSError(domain: "NativeAgentSwiftOnly", code: -423,
                    userInfo: [NSLocalizedDescriptionKey: """
                        Inbox delivery is rate limited for \(seconds) seconds. \
                        The same card and message remain available; retry later.
                        """])
            }
        } catch let error as ProactiveSpeechError {
            throw error
        } catch {
            throw error
        }
    }

    private static func openApprovalsFromInboxAction(id: String, dataRoot: URL, effects: any InboxCardActionEffects) async throws {
        try await setReading(id: id, action: "read", dataRoot: dataRoot)
        await effects.openApprovals()
    }

    private static func setReading(id: String, action: String, dataRoot: URL) async throws {
        let forPerson = ForPerson.at(dataRoot)
        guard try await forPerson.matter(id) != nil else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -410,
                userInfo: [NSLocalizedDescriptionKey: "Inbox item \(id) not found. Refresh the inbox before acting."])
        }
        switch action {
        case "read": try await forPerson.read(id)
        case "archive": try await forPerson.putAway(id, .archived)
        case "dismiss": try await forPerson.putAway(id, .dismissed)
        default:
            throw NSError(domain: "NativeAgentSwiftOnly", code: -410,
                userInfo: [NSLocalizedDescriptionKey: "Unknown inbox reading: \(action)"])
        }
    }
}
