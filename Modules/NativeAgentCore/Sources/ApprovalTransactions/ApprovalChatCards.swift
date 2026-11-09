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
// Blueprint: | `ApprovalChatCards.swift` | The one mirror: an ask whose matter owes the person's conversation gets its card row there, then that door is accepted with the row |

/// The person's conversation named at birth draws the ask's card; every surface resolves the same decision.
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

    /// An approval the person decides is mirrored into the person's conversation when its matter names that door; the router owns the
    /// other doors.
    @discardableResult
    public static func post(
        _ record: ApprovalRecord,
        dataRoot: URL
    ) async -> Outcome {
        guard record.status == "pending", !record.isAgentsOwnDecision else { return .skipped }  // the agent's to decide
        return await mirror(record.id, rowID: "approval-card-" + record.id, dataRoot: dataRoot) { sessionID in
            try cardRow(record, sessionID: sessionID)
        }
    }

    /// The one mirror for every ask: a matter that owes the person's conversation door (`Door.personsConversation`) has its card row
    /// appended there once (the row's run id keeps it to one), and the door is accepted with that row. A failed write leaves the door owed.
    static func mirror(_ matterID: String, rowID: String, dataRoot: URL,
                       row: (_ sessionID: String) throws -> JSONValue) async -> Outcome {
        do {
            let forPerson = ForPerson.at(dataRoot)
            guard let matter = try await forPerson.matter(matterID),
                  let owed = matter.owes[Door.conversation("").key], !owed.phase.isSettled,
                  let door = Door(address: owed.to), case .conversation(let sessionID) = door else { return .skipped }
            guard NativeAgentChatSessionID.normalizedPathComponent(sessionID) == sessionID else {
                throw ApprovalInboxError.malformedResponse("invalid conversation door \(sessionID)")
            }
            let card = try row(sessionID)
            let written: Result<Void, Error> = await settle {
                do {
                    try await appendRow(card, sessionID: sessionID, dataRoot: dataRoot, uniqueRunID: rowID)
                    try await forPerson.accepted(matter.id, door, evidence: .init(source: Matter.messages(sessionID), id: rowID))
                    return .success(())
                } catch { return .failure(error) }
            }
            try written.get()
            return .posted(sessionID)
        } catch {
            nativeLog("[approval-chat-card] mirror into the person's conversation failed: %@", error.localizedDescription)
            return .failed
        }
    }

    /// Starting the bot recovers returned sends and edits; the router alone admits new prompts.
    public static func promptPending(dataRoot: URL, telegram: TelegramApprovalFiler) async {
        // The router sends owed prompts; starting the bot only recovers already-returned interaction receipts and button edits.
        await promptPendingInteractions(dataRoot: dataRoot, telegram: telegram)
    }

    /// A private chat id is the configured owner's user id.
    static func ownerDM(dataRoot: URL) throws -> Int? {
        guard let config = try TelegramConfig.loadSavedConfiguration(dataRoot: dataRoot, resolveCredential: false), config.tokenConfigured,
              let owner = config.ownerUserId.flatMap({ Int(exactly: $0) })
        else { return nil }
        return owner
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
            // Nothing leaves for Telegram unredacted: the prompt's words are its matter's, redacted where they are written.
            try await telegram.promptChatCard(record, chatId: chatId)
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
    private static func cardRow(_ record: ApprovalRecord, sessionID: String) throws -> JSONValue {
        let face = record.matter
        let content = [face.title, face.summary, face.words]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let summary = try JSONValue.object([
            "status": .string("waiting_approval"), "approvalId": .string(record.id),
            "tool": .string(record.action), "reason": .string(face.summary),
        ]).serialize(pretty: false)
        return .object([
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
