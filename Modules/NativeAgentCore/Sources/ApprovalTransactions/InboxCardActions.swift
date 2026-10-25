import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
import ChatTurnRuntime
import NotificationInbox

// Blueprint: | `InboxCardActions.swift` | `InboxCardActions`: engagement-before-effect ordering, primary action projection and spoken/draft delivery through one inbox claim |

/// Assembly and presentation bindings; the transaction owns ordering and receipts.
public protocol InboxCardActionEffects: Sendable {
    var heartbeatActionIDs: Set<String> { get }
    var heartbeatOpenApprovalsActionID: String { get }
    var heartbeatRepairActionID: String { get }
    func interactionAction(id: String, action: String, dataRoot: URL, quiet: Bool) async throws
    func resolveApproval(id: String, decision: String, dataRootOverride: URL?) async throws
    func inboxItems(dataRoot: URL) async throws -> [InboxItemRecord]
    func primaryActionProjection(for item: InboxItemRecord) -> (opensApprovals: Bool, isProactive: Bool)
    func repairHeartbeatInboxItem(id: String, dataRoot: URL) async throws -> String
    func cleanUpDiskHygiene(dataRoot: URL) async throws -> String
    func chatClient(dataRoot: URL) -> SwiftNativeChatOrchestrationClient
    func openApprovals() async
    func openDesk() async
    func openChatDraft(_ draft: String) async
    func openSpokenChat(_ sessionID: String) async
}

public enum InboxCardActions {
    private static let explicitlyHandledInboxActionIDs: Set<String> = [
        "read", "archive", "dismiss", "act", "approve", "reject",
    ]

    public static func perform(
        _ id: String, action: String, metadata: [String: JSONValue] = [:], quiet: Bool = false,
        dataRootOverride: URL?, effects: any InboxCardActionEffects
    ) async throws {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let visibleInboxPath = LiveNotificationInbox.livePath(dataRoot: root)
        let normalizedAction = action == "deny" ? "reject" : action
        if id.hasPrefix("interaction:"), !["read", "archive", "dismiss"].contains(normalizedAction) {
            try await effects.interactionAction(id: id, action: normalizedAction, dataRoot: root, quiet: quiet)
            return
        }
        if normalizedAction == "reply" {
            throw NSError(
                domain: "NativeAgentSwiftOnly",
                code: -410,
                userInfo: [NSLocalizedDescriptionKey: "Reply requires text input; use inboxReply(id:text:) instead of inboxAction(id:\"reply\")."]
            )
        }
        let nativeActions = explicitlyHandledInboxActionIDs.union(effects.heartbeatActionIDs)
        guard nativeActions.contains(normalizedAction) else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -410, userInfo: [
                NSLocalizedDescriptionKey: "Unknown inbox action: \(normalizedAction)"
            ])
        }
        let endpointAction = normalizedAction

        if endpointAction == "read" || endpointAction == "archive" || endpointAction == "dismiss" {
            if await updateVisibleStatus(
                id: id, action: endpointAction, inboxPath: visibleInboxPath, metadata: metadata) {
                return
            }
            nativeLog("[inbox] inboxAction(\(endpointAction)) id=\(id): live inbox status write declined")
            throw NSError(
                domain: "NativeAgentSwiftOnly",
                code: -423,
                userInfo: [NSLocalizedDescriptionKey:
                    "Inbox \(endpointAction) for \(id) didn't persist (transient lock/IO failure or stale row) — retry."]
            )
        }
        if endpointAction == "approve" || endpointAction == "reject" {
            do {
                try await effects.resolveApproval(id: id, decision: endpointAction, dataRootOverride: dataRootOverride)
            } catch ApprovalInboxError.alreadyResolved(let resolvedID, let status) {
                nativeLog("[inbox] inboxAction(\(endpointAction)) id=\(resolvedID): already resolved (\(status)); treating as success")
            } catch {
                nativeLog("[inbox] inboxAction(\(endpointAction)) id=\(id): \(error)")
                throw error
            }
            return
        }
        if endpointAction == effects.heartbeatOpenApprovalsActionID {
            if quiet {
                _ = await updateVisibleStatus(id: id, action: "read", inboxPath: visibleInboxPath)
            } else {
                await openApprovalsFromInboxAction(id: id, inboxPath: visibleInboxPath, effects: effects)
            }
            return
        }
        if endpointAction == effects.heartbeatRepairActionID {
            let message = try await effects.repairHeartbeatInboxItem(id: id, dataRoot: root)
            _ = await updateVisibleStatus(id: id, action: "archive", inboxPath: visibleInboxPath)
            nativeLog("[inbox] inboxAction(repair) id=\(id): \(message)")
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
            let resolution = resolvePrimaryAction(for: item, effects: effects)
            // Persist engagement before its effect; disposal owns its own write.
            if let statusAction = resolution.inboxStatusAction {
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
                    await openApprovalsFromInboxAction(id: id, inboxPath: visibleInboxPath, effects: effects)
                }
            case .openDeskExecution:
                if quiet { break }
                await effects.openDesk()
            case .chatDraft(let draft):
                if quiet { break }
                await effects.openChatDraft(draft)
            case .chatSpoken(let message):
                let spokenSession = try await postSpokenInboxMessage(message: message, itemId: id, dataRoot: root, effects: effects)
                if quiet {
                    guard spokenSession != nil else {
                        throw NSError(domain: "NativeAgentSwiftOnly", code: -423, userInfo: [NSLocalizedDescriptionKey:
                            "Inbox act for \(id): the chat message didn't post (rate limit or write failure) — retry later."])
                    }
                    break
                }
                if let spokenSession {
                    await effects.openSpokenChat(spokenSession)
                } else {
                    await effects.openChatDraft(inboxChatDraftText(
                        title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                        summary: item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
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
        case openDeskExecution(executionId: String)
        case chatDraft(draft: String)
        case chatSpoken(message: String)
        case diskCleanup
        case unresolved(reason: String)

        var inboxStatusAction: String? {
            switch self {
            case .openApprovals, .diskCleanup, .unresolved: return nil
            case .openDeskExecution, .chatDraft, .chatSpoken: return "read"
            }
        }
    }

    public static func resolvePrimaryAction(for item: InboxItemRecord, effects: any InboxCardActionEffects) -> InboxPrimaryActionResolution {
        let projection = effects.primaryActionProjection(for: item)
        if projection.opensApprovals {
            return .openApprovals
        }
        if let executionId = item.relatedWorkshopExecutionId, !executionId.isEmpty {
            return .openDeskExecution(executionId: executionId)
        }
        if item.source == "disk_hygiene" {
            return .diskCleanup
        }
        if projection.isProactive {
            return .unresolved(reason: "unmapped proactive card — no approval link")
        }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty && summary.isEmpty {
            return .unresolved(reason: "no linked approval/execution and no referenceable content")
        }
        if isHerVoiceCard(item) {
            return .chatSpoken(
                message: inboxSpokenMessageText(title: title, summary: summary, detail: item.detail)
            )
        }
        return .chatDraft(draft: inboxChatDraftText(title: title, summary: summary))
    }

    // Only these exact producers author a message in her voice.
    static let herVoiceCardSources: Set<String> = ["trigger:morning_brief", "idle_checkin"]

    static func isHerVoiceCard(_ item: InboxItemRecord) -> Bool {
        herVoiceCardSources.contains(item.source.trimmingCharacters(in: .whitespacesAndNewlines))
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

    private static func postSpokenInboxMessage(message: String, itemId: String, dataRoot: URL, effects: any InboxCardActionEffects) async throws -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sessionId = (UserDefaults.standard.string(forKey: "activeChatSessionId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else {
            nativeLog("[inbox] act chat_spoken: no active chat session — falling back to draft")
            return nil
        }
        let client = effects.chatClient(dataRoot: dataRoot)
        do {
            // Act and scheduled delivery share one inbox claim and destination.
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
                return destination
            case .rateLimited(let seconds):
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

    private static func openApprovalsFromInboxAction(id: String, inboxPath: URL, effects: any InboxCardActionEffects) async {
        _ = await updateVisibleStatus(id: id, action: "read", inboxPath: inboxPath)
        await effects.openApprovals()
    }

    @discardableResult
    public static func updateVisibleStatus(
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
