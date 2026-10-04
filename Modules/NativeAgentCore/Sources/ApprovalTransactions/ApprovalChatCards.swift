import Foundation
import ApprovalInbox
import ChatSessionWork
import NativeAgentCore
import PersistenceCore
import Privacy
import TelegramBot
import Transcripts

/// User, 10-03: "any approval the agent needs should pop right up in chat."
///
/// An approval raised in User's own conversation already shows there: the tool
/// loop writes its card into that transcript, and a Telegram turn's filer sends
/// its buttons. Every other approval — a peer's thread, her wake, background
/// work, a skill install — used to reach only the Inbox and Approvals. This
/// posts ONE card for it into the conversation User is in (the anchor), bound to
/// the approval id; its buttons answer the same row through the shared
/// resolver, so the Inbox, the phone and the Mac panel stay in step, and a card
/// answered anywhere reads settled everywhere. Nothing here decides anything.
public enum ApprovalChatCards {
    public enum Outcome: Sendable, Equatable {
        /// Posted into this conversation.
        case posted(String)
        /// Already shows in User's chat, is hers, was carded, or no conversation.
        case skipped
        /// Delivery failed; the destination is retained for a retry.
        case failed
    }

    /// Post the card for a newly pending approval. `telegram` is the running
    /// bot's filer; `quiet` holds the phone ping.
    @discardableResult
    public static func post(
        _ record: ApprovalRecord,
        dataRoot: URL,
        telegram: TelegramApprovalFiler? = nil,
        quiet: Bool = false
    ) async -> Outcome {
        guard record.status == "pending", !record.chatCardDelivered,
              record.action != "studio.canon",           // hers to decide
              !hasTelegramPrompt(record),                // its turn's chat has buttons
              let anchor = record.chatCardSessionId ?? usersConversation(unless: record.chatOriginSessionId, dataRoot: dataRoot)
        else { return .skipped }
        // Telegram only reaches the bot's verified owner, in his own DM, when
        // that DM is the conversation he is in. A script install gets a line
        // there, never a button: Telegram cannot show the whole script.
        let ownerChat = telegram == nil ? nil : await ownerDM(boundTo: anchor, dataRoot: dataRoot)
        let isScript = record.action == SwiftNativeApprovalInbox.skillScriptInstallAction
        let buttonsChat = record.remoteResolvable && !record.localOnly && !isScript ? ownerChat : nil
        var card: [String: JSONValue] = [
            "sessionId": .string(anchor),
            "at": .string(ISO8601DateFormatter().string(from: Date())),
        ]
        if let buttonsChat { card["telegramChatId"] = .string(String(buttonsChat)) }
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let claimed: ApprovalRecord
        let destination: String
        do {
            guard let saved = try await inbox.claimChatCard(record.id, card: .object(card), deliver: { pending in
                guard let sessionID = pending.chatCardSessionId,
                      NativeAgentChatSessionID.normalizedPathComponent(sessionID) == sessionID else {
                    throw ApprovalInboxError.malformedResponse("invalid chat-card session")
                }
                try await appendCard(pending, sessionID: sessionID, dataRoot: dataRoot)
            }) else { return .skipped }
            guard let sessionID = saved.chatCardSessionId else {
                throw ApprovalInboxError.malformedResponse("invalid chat-card session")
            }
            claimed = saved
            destination = sessionID
        } catch {
            // The strip remains visible until delivery is confirmed.
            NSLog("[approval-chat-card] delivery failed: %@", error.localizedDescription)
            return .failed
        }
        if let telegram, let ownerChat, !quiet, buttonsChat != nil || isScript {
            do {
                try await telegram.promptChatCard(redactedForTelegram(claimed), chatId: ownerChat,
                                                  payload: NativeAppSecretRedactor.redactArguments(decisionPayload(claimed)))
            } catch {
                NSLog("[approval-chat-card] Telegram prompt failed: %@", error.localizedDescription)
            }
        }
        return .posted(destination)
    }

    /// The conversation User is in (the anchor), or nil when there is none or
    /// it is `origin` itself — a card raised there already shows there.
    static func usersConversation(unless origin: String?, dataRoot: URL) -> String? {
        guard let anchor = ConversationAnchor.currentSessionId(dataRoot: dataRoot),
              NativeAgentChatSessionID.normalizedPathComponent(anchor) == anchor,
              origin != anchor else { return nil }
        return anchor
    }

    /// The bot's owner: its one allowlisted Telegram user, whose private chat
    /// (a DM's id is its user's id) must be the conversation User is in. No
    /// single verified owner, no Telegram prompt.
    public static func ownerDM(boundTo anchor: String, dataRoot: URL) async -> Int? {
        guard let owners = TelegramConfig.loadFromDisk(dataRoot: dataRoot)?.allowedUserIds,
              owners.count == 1, let owner = owners.first.flatMap({ Int(exactly: $0) }), owner > 0,
              await TelegramSessionStore(dataRoot: dataRoot).boundSessionId(chatId: owner) == anchor
        else { return nil }
        return owner
    }

    /// Nothing leaves for Telegram unredacted: title and reason scrubbed too.
    private static func redactedForTelegram(_ record: ApprovalRecord) -> ApprovalRecord {
        var copy = record
        copy.title = NativeAppSecretRedactor.redactText(record.title)
        copy.reason = NativeAppSecretRedactor.redactText(record.reason)
        return copy
    }

    /// A Telegram turn's approval: its filer already sent Approve/Deny there.
    private static func hasTelegramPrompt(_ record: ApprovalRecord) -> Bool {
        guard case .object(let payload) = record.payload, case .object? = payload["telegram"] else { return false }
        return true
    }

    /// What is being decided: a tool call's own arguments, else the payload.
    private static func decisionPayload(_ record: ApprovalRecord) -> JSONValue {
        guard case .object(let payload) = record.payload,
              payload["kind"] == .string("chat_tool_approval"), let input = payload["input"] else {
            return record.payload
        }
        return input
    }

    /// The same `approval_pending` row the tool loop writes, so every surface
    /// that draws an approval card from a transcript draws this one.
    private static func appendCard(_ record: ApprovalRecord, sessionID: String, dataRoot: URL) async throws {
        let detail: String = {
            if case .object(let payload) = record.payload, payload["kind"] == .string("chat_tool_approval") {
                let input = (try? NativeAppSecretRedactor.redactArguments(decisionPayload(record))
                    .serialize(pretty: false)) ?? ""
                return String(input.prefix(1_000))
            }
            return record.payloadPreview
        }()
        let content = [record.title, record.reason, detail]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let summary = (try? JSONValue.object([
            "status": .string("waiting_approval"), "approvalId": .string(record.id),
            "tool": .string(record.action), "reason": .string(record.reason),
        ]).serialize(pretty: false)) ?? ""
        let row: JSONValue = .object([
            "id": .string("approval-card-\(record.id)"),
            "sessionId": .string(sessionID),
            "role": .string("tool"),
            "content": .string(content),
            "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
            "source": .string("approval"),
            "runId": .string("approval-card-\(record.id)"),
            "metadata": .object([
                "kind": .string(ChatTranscriptToolMessageKind.approvalPending),
                "toolName": .string(record.action),
                "approvalId": .string(record.id),
                "resultSummary": .string(summary),
            ]),
        ])
        try await appendRow(row, sessionID: sessionID, dataRoot: dataRoot, uniqueRunID: "approval-card-\(record.id)")
    }

    /// One row appended to a conversation's transcript, which then redraws.
    static func appendRow(_ row: JSONValue, sessionID: String, dataRoot: URL, uniqueRunID: String? = nil) async throws {
        let path = dataRoot.appendingPathComponent("chat/messages", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            if let uniqueRunID {
                let rows = try await persistence.readJSONL(path)
                guard !rows.contains(where: {
                    guard case .object(let existing) = $0 else { return false }
                    return existing["runId"] == .string(uniqueRunID)
                }) else { return }
                try await persistence.appendJSONLDurable(row, to: path)
            } else {
                try await persistence.appendJSONL(row, to: path)
            }
        }
        NotificationCenter.default.post(name: .nativeAgentChatTranscriptDidChange, object: sessionID)
    }
}
