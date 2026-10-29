import SwiftUI
import UIKit
import NativeAgentShared

extension ChatStore {
    func pendingUserMessage(for pendingId: String) -> ChatMessage? {
        guard let args = pendingExchanges[pendingId]?.request,
              let appendedUserId = args.appendedUserId else {
            return nil
        }
        let summaries = args.attachments.map {
            ChatAttachmentSummary($0, fallbackName: $0.type == "image" ? "Photo" : "Attachment")
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

    func resolvePendingReplyFromMac(_ repliesByRun: [String: ChatMessage]) {
        let matches = pendingICloudPlaceholders.merging(timedOutPendingIds) { current, _ in current }
            .sorted { $0.key < $1.key }.compactMap { pendingId, placeholderId in
                repliesByRun[pendingId].map { (pendingId, placeholderId, $0) }
            }
        guard !matches.isEmpty else { return }
        for (pendingId, placeholderId, _) in matches {
            settlePendingReply(pendingId, placeholderId: placeholderId)
        }
        let placeholders = Set(matches.map { $0.1 })
        messages.removeAll { placeholders.contains($0.id) }
        for (_, _, reply) in matches {
            onReply?(reply.text)
        }
    }
}
