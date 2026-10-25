import SwiftUI
import UIKit
import NativeAgentShared

extension ChatStore {
    func pendingUserMessage(for pendingId: String) -> ChatMessage? {
        guard let args = pendingSendArgs[pendingId],
              let appendedUserId = args.appendedUserId else {
            return nil
        }
        let summaries = args.attachments.map {
            ChatAttachmentSummary(
                id: $0.id,
                name: $0.name ?? ($0.type == "image" ? "Photo" : "Attachment"),
                type: $0.type,
                mime: $0.mime,
                base64: $0.base64,
                byteSize: $0.byteSize,
                utterance: $0.utterance
            )
        }
        return ChatMessage(
            id: appendedUserId,
            role: .user,
            text: args.text,
            attachments: summaries,
            awaitingMacTranscript: true,
            runId: pendingId
        )
    }

    func insertPendingUserIfNeeded(pendingId: String, before placeholderId: UUID?) {
        guard let user = pendingUserMessage(for: pendingId) else { return }
        guard !messages.contains(where: { $0.id == user.id }) else { return }
        guard !messages.contains(where: { $0.role == .user && $0.runId == pendingId }) else { return }
        if let placeholderId,
           let placeholderIndex = messages.firstIndex(where: { $0.id == placeholderId }) {
            messages.insert(user, at: placeholderIndex)
        } else {
            messages.append(user)
        }
    }

    private func macAssistantReply(for pendingId: String, in macMessages: [ChatMessage]) -> ChatMessage? {
        macMessages.last {
            $0.runId == pendingId && $0.isTerminalReply && macPublishedMessageIDs.contains($0.id)
                && !regeneratedAwayAssistantIDs.contains($0.id)
        }
    }

    func resolvePendingReplyFromMac(_ macMessages: [ChatMessage]) -> Bool {
        let matches = Set(pendingICloudPlaceholders.keys).union(timedOutPendingIds.keys).sorted().compactMap { pendingId -> (String, UUID, ChatMessage)? in
            guard let placeholderId = pendingICloudPlaceholders[pendingId] ?? timedOutPendingIds[pendingId],
                  let reply = macAssistantReply(for: pendingId, in: macMessages) else { return nil }
            return (pendingId, placeholderId, reply)
        }
        guard !matches.isEmpty else { return false }
        // Retire only matched exchanges. Every other bubble
        // remains owned by its pending record, even if this snapshot has replies.
        for (pendingId, placeholderId, _) in matches {
            markICloudReplyResolved(pendingId)
            pendingICloudPlaceholders.removeValue(forKey: pendingId)
            timedOutPendingIds.removeValue(forKey: pendingId)
            cancelReplyWaits(for: pendingId)
            streamingHintsByMessageId.removeValue(forKey: placeholderId)
            messages.removeAll { $0.id == placeholderId }
        }
        for (_, placeholderId, reply) in matches {
            releaseLoading(for: placeholderId)
            onReply?(reply.text)
        }
        isPollingFallback = false
        return true
    }
}
