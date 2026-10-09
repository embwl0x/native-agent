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
        guard record.status == "pending", !record.isAgentsOwnDecision else { return .skipped }  // hers to decide
        // A Telegram turn's approval: its chat has buttons, and no Mac card.
        let outcome = hasTelegramPrompt(record) ? .skipped : await postCard(record, dataRoot: dataRoot)
        if let telegram, !quiet { await promptTelegram(record, telegram: telegram, dataRoot: dataRoot) }
        return outcome
    }

    /// The card in the conversation User is in, unless it was raised there.
    private static func postCard(_ record: ApprovalRecord, dataRoot: URL) async -> Outcome {
        guard !record.chatCardDelivered,
              let anchor = record.chatCardSessionId ?? usersConversation(unless: record.chatOriginSessionId, dataRoot: dataRoot)
        else { return .skipped }
        let card: JSONValue = .object([
            "sessionId": .string(anchor),
            "at": .string(ISO8601DateFormatter().string(from: Date())),
        ])
        do {
            guard let saved = try await SwiftNativeApprovalInbox(root: dataRoot).claimChatCard(record.id, card: card, deliver: { pending in
                guard let sessionID = pending.chatCardSessionId,
                      NativeAgentChatSessionID.normalizedPathComponent(sessionID) == sessionID else {
                    throw ApprovalInboxError.malformedResponse("invalid chat-card session")
                }
                try await appendCard(pending, sessionID: sessionID, dataRoot: dataRoot)
            }) else { return .skipped }
            guard let sessionID = saved.chatCardSessionId else {
                throw ApprovalInboxError.malformedResponse("invalid chat-card session")
            }
            return .posted(sessionID)
        } catch {
            // The strip remains visible until delivery is confirmed.
            nativeLog("[approval-chat-card] delivery failed: %@", error.localizedDescription)
            return .failed
        }
    }

    /// User, 10-07: every approval reaches his Telegram DM once, wherever it
    /// was raised and whichever conversation he is in. That DM is User, with
    /// the signed phone's authority. A script install gets a line there,
    /// never a button: Telegram cannot show the whole script.
    private static func promptTelegram(_ record: ApprovalRecord, telegram: TelegramApprovalFiler, dataRoot: URL) async {
        guard !telegramPrompted(record), let owner = ownerDM(dataRoot: dataRoot) else { return }
        do {
            try await telegram.promptChatCard(redactedForTelegram(record), chatId: owner,
                                              payload: NativeAppSecretRedactor.redactArguments(decisionPayload(record)))
            var mark: [String: JSONValue] = ["telegramPromptedAt": .string(ISO8601DateFormatter().string(from: Date()))]
            if record.action != SwiftNativeApprovalInbox.skillScriptInstallAction {
                mark["telegramChatId"] = .string(String(owner))
            }
            try await SwiftNativeApprovalInbox(root: dataRoot).markChatCard(record.id, mark)
        } catch {
            nativeLog("[approval-chat-card] Telegram prompt failed: %@", error.localizedDescription)
        }
    }

    /// When the bot starts: each pending approval that never reached User's DM
    /// gets its prompt, once.
    public static func promptPending(dataRoot: URL, telegram: TelegramApprovalFiler) async {
        guard let rows = try? await SwiftNativeApprovalInbox(root: dataRoot).list(filter: ApprovalFilter(status: "pending"))
        else { return }
        for row in rows where !row.isAgentsOwnDecision {
            await promptTelegram(row, telegram: telegram, dataRoot: dataRoot)
        }
    }

    /// Delivered to his DM: marked only after the send succeeded.
    private static func telegramPrompted(_ record: ApprovalRecord) -> Bool {
        guard case .object(let card)? = record.chatCard else { return false }
        return card["telegramPromptedAt"] != nil
    }

    /// The conversation User is in (the anchor), or nil when there is none or
    /// it is `origin` itself — a card raised there already shows there.
    static func usersConversation(unless origin: String?, dataRoot: URL) -> String? {
        guard let anchor = ConversationAnchor.currentSessionId(dataRoot: dataRoot),
              NativeAgentChatSessionID.normalizedPathComponent(anchor) == anchor,
              origin != anchor else { return nil }
        return anchor
    }

    /// The bot's owner DM, when it is the conversation User is in.
    public static func ownerDM(boundTo anchor: String, dataRoot: URL) async -> Int? {
        guard let owner = ownerDM(dataRoot: dataRoot),
              await TelegramSessionStore(dataRoot: dataRoot).boundSessionId(chatId: owner) == anchor
        else { return nil }
        return owner
    }

    /// The bot's single configured owner, whose private chat id is his user id.
    static func ownerDM(dataRoot: URL) -> Int? {
        guard let owner = TelegramConfig.loadFromDisk(dataRoot: dataRoot)?.ownerUserId.flatMap({ Int(exactly: $0) })
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
        await publishTranscriptChanges(sessionIDs: [sessionID], dataRoot: dataRoot)
    }

    /// Card projections change without a new message. Advance the same version
    /// the phone's transcript cache and ordering already consume.
    static func publishTranscriptChanges(sessionIDs: Set<String>, dataRoot: URL) async {
        let path = dataRoot.appendingPathComponent("chat/sessions.json")
        let persistence = SwiftNativePersistenceCore()
        do {
            try await persistence.withFileLock(path) {
                var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: path)
                var changed = false
                for index in rows.indices {
                    guard case .string(let id)? = rows[index]["id"], sessionIDs.contains(id) else { continue }
                    changed = ChatSessionIndexFile.bumpTranscriptGeneration(in: &rows[index]) || changed
                }
                guard changed else { return }
                try await persistence.writeDataAtomicDurable(
                    ChatSessionIndexFile.serializedData(for: rows), to: path)
            }
        } catch {
            nativeLog("[approval-chat-card] transcript generation bump failed: %@", error.localizedDescription)
        }
        for sessionID in sessionIDs {
            NotificationCenter.default.post(name: .nativeAgentChatTranscriptDidChange, object: sessionID)
        }
    }
}
