import Foundation
import ApprovalInbox
import ChatTurnRuntime
import ChatSessionWork
import NativeAgentCore
import PersistenceCore
import Privacy
import TelegramBot
import Transcripts
import NativeAgentShared
import Experiences
// Blueprint: | `ApprovalChatCards.swift` | A conversation delivers its matter's card, then accepts its conversation door with the transcript row |

/// A conversation named at birth draws the approval's card; every surface resolves the same decision.
public enum ApprovalChatCards {
    public static func canResolve(_ approval: ApprovalRecord) -> Bool {
        !approval.payloadPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static let unavailableText = """
        The details of this request are missing. Refresh approvals to check again. \
        You can decide once the details are available.
        """

    public enum Outcome: Sendable, Equatable {
        case posted(String)
        case skipped
        /// Failed delivery retains its destination for retry.
        case failed
    }

    /// The conversation owns only its card; the router owns the other doors.
    @discardableResult
    public static func post(
        _ record: ApprovalRecord,
        dataRoot: URL
    ) async -> Outcome {
        guard record.status == "pending", !record.isAgentsOwnDecision else { return .skipped }  // the agent's to decide
        return await postCard(record, dataRoot: dataRoot)
    }

    /// Avoid duplicating a card already shown in the person's active conversation.
    private static func postCard(_ record: ApprovalRecord, dataRoot: URL) async -> Outcome {
        do {
            let forPerson = ForPerson.at(dataRoot)
            guard let matter = try await forPerson.matter(record.id),
                  let owed = matter.owes[Door.conversation("").key], !owed.phase.isSettled,
                  let door = Door(address: owed.to), case .conversation(let sessionID) = door else { return .skipped }
            guard NativeAgentChatSessionID.normalizedPathComponent(sessionID) == sessionID else {
                throw ApprovalInboxError.malformedResponse("invalid chat-card session")
            }
            let written: Result<Void, Error> = await settle {
                do {
                    try await appendCard(record, sessionID: sessionID, dataRoot: dataRoot)
                    try await forPerson.accepted(record.id, door,
                        evidence: .init(source: Matter.messages(sessionID), id: "approval-card-" + record.id))
                    return .success(())
                } catch { return .failure(error) }
            }
            try written.get()
            return .posted(sessionID)
        } catch {
            // The strip remains visible until delivery is confirmed.
            nativeLog("[approval-chat-card] delivery failed: %@", error.localizedDescription)
            return .failed
        }
    }

    /// Starting the bot recovers returned sends and edits; the router alone admits new prompts.
    public static func promptPending(dataRoot: URL, telegram: TelegramApprovalFiler) async {
        // The router sends owed prompts; starting the bot only recovers already-returned interaction receipts and button edits.
        await promptPendingInteractions(dataRoot: dataRoot, telegram: telegram)
    }

    /// Exclude the origin conversation because its card already shows there.
    static func usersConversation(unless origin: String?, dataRoot: URL) throws -> String? {
        guard let anchor = try ConversationAnchor.checkedCurrent(dataRoot: dataRoot)?.sessionId,
              NativeAgentChatSessionID.normalizedPathComponent(anchor) == anchor,
              origin != anchor else { return nil }
        return anchor
    }

    /// A private chat id is the configured owner's user id.
    static func ownerDM(dataRoot: URL) throws -> Int? {
        guard let config = try TelegramConfig.loadSavedConfiguration(dataRoot: dataRoot, resolveCredential: false), config.tokenConfigured,
              let owner = config.ownerUserId.flatMap({ Int(exactly: $0) })
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

    private static func decisionPayload(_ record: ApprovalRecord) -> JSONValue {
        guard case .object(let payload) = record.payload,
              payload["kind"] == .string("chat_tool_approval"), let input = payload["input"] else {
            return record.payload
        }
        return input
    }

    /// Attention reuses the prompt transaction, including its in-flight send and receipt-only recovery. It never adds a plain-text approval copy.
    public static func deliverAttentionPrompt(id: String, chatId: Int, dataRoot: URL) async -> NotificationDeliveryOutcome {
        if id.hasPrefix("interaction:") {
            return await deliverInteractionAttentionPrompt(id: String(id.dropFirst("interaction:".count)), chatId: chatId, dataRoot: dataRoot)
        }
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let receipt = "telegram_prompt_delivered:\(chatId)"
        do {
            let record = try await inbox.get(id)
            if record.chatCard?.objectValue?[receipt] == .bool(true) { return .delivered }
            guard record.status == "pending" else { return .notDelivered(reason: "The approval is no longer pending") }
            guard let telegram = runningTelegram else { return .notDelivered(reason: "The Telegram approval sender is not running") }
            try await telegram.promptChatCard(redactedForTelegram(record), chatId: chatId,
                payload: NativeAppSecretRedactor.redactArguments(decisionPayload(record)))
            let saved = try await inbox.get(id)
            if saved.chatCard?.objectValue?[receipt] == .bool(true) { return .delivered }
            return .unknown(sent: true, reason: "The approval prompt has no saved delivery receipt; reconcile its prompt transaction")
        } catch {
            if let failure = error as? NotificationDeliveryFailure { return failure.outcome }
            if TelegramAPIFailure.isKnownNotDelivered(error) { return .notDelivered(reason: error.localizedDescription) }
            return .unknown(sent: true, reason: error.localizedDescription)
        }
    }

    /// The same `approval_pending` row the tool loop writes, so every surface that draws an approval card from a transcript draws this one.
    private static func appendCard(_ record: ApprovalRecord, sessionID: String, dataRoot: URL) async throws {
        let face = record.matter
        let content = [face.title, face.summary, face.words]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let summary = try JSONValue.object([
            "status": .string("waiting_approval"), "approvalId": .string(record.id),
            "tool": .string(record.action), "reason": .string(face.summary),
        ]).serialize(pretty: false)
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

    static func appendRow(_ row: JSONValue, sessionID: String, dataRoot: URL, uniqueRunID: String? = nil) async throws {
        let path = dataRoot.appendingPathComponent("chat/messages", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        try await ContactThread.append(row, to: path, uniqueRunID: uniqueRunID)
        await publishTranscriptChanges(sessionIDs: [sessionID], dataRoot: dataRoot)
    }

    /// Card projections change without a new message. Advance the same version the phone's transcript cache and ordering already consume.
    static func publishTranscriptChanges(sessionIDs: Set<String>, dataRoot: URL) async {
        do {
            try await ChatSessionIndexFile.recordProjectionChanges(
                sessionIDs: sessionIDs, dataRoot: dataRoot)
        } catch {
            nativeLog("[approval-chat-card] transcript generation bump failed: %@", error.localizedDescription)
        }
        for sessionID in sessionIDs {
            NotificationCenter.default.post(name: .nativeAgentChatTranscriptDidChange, object: sessionID)
        }
    }
}
