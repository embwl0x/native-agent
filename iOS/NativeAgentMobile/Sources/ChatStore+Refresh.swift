import SwiftUI
import UIKit
import NativeAgentShared

extension ChatStore {
    func refresh(using client: MacBridgeClient) {
        guard Date().timeIntervalSince(lastRefreshAt) >= refreshThrottleSeconds else { return }
        lastRefreshAt = Date()
        let requestedSessionID = Self.cleanSessionID(selectedSessionID ?? mainSessionID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let read = await client.readChatTranscript(sessionID: requestedSessionID)
            self.applyMacTranscriptRead(read, sessionID: requestedSessionID)
        }
    }

    func applyMacTranscriptRead(_ read: MacTranscriptRead, sessionID: String?) {
        guard Self.cleanSessionID(sessionID) == Self.cleanSessionID(selectedSessionID ?? mainSessionID),
              case .published(let rows, _) = read else { return }
        let publishedIDs = pendingICloudPlaceholders.isEmpty && retiredPendingPlaceholders.isEmpty ? [] : macPublishedMessageIDs
        var repliesByRun: [String: ChatMessage] = [:]
        for row in rows where row.isTerminalReply {
            guard let run = row.runId else { continue }
            liveTurnBubbles.removeValue(forKey: run)
            if publishedIDs.contains(row.id) { repliesByRun[run] = row }
        }
        resolvePendingReplyFromMac(repliesByRun)
        // A sent message the Mac received but moved past without a reply of its own (a quit or a crash ended its turn) will never get one:
        // once an answer follows it in the Mac's transcript, close its wait. The sent words stay in the chat.
        let movedPast = pendingICloudPlaceholders.filter { pendingId, _ in
            guard let received = rows.firstIndex(where: { $0.role == .user && $0.runId == pendingId }) else { return false }
            return !rows.contains { $0.isTerminalReply && $0.runId == pendingId }
                && rows[(received + 1)...].contains { $0.isTerminalReply }
        }
        for (pendingId, placeholderId) in movedPast {
            settlePendingReply(pendingId, placeholderId: placeholderId)
            messages.removeAll { $0.id == placeholderId }
            onTalkReply?(pendingId, "", true, "That turn ended before a reply. Send it again if you still need it.")
        }
    }
}
