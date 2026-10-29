import SwiftUI
import UIKit
import NativeAgentShared

extension ChatStore {
    /// Snapshot ingestion owns versions and reconciliation before any surface reads it.
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
        let publishedIDs = pendingICloudPlaceholders.isEmpty && timedOutPendingIds.isEmpty ? [] : macPublishedMessageIDs
        var repliesByRun: [String: ChatMessage] = [:]
        for row in rows where row.isTerminalReply {
            guard let run = row.runId else { continue }
            liveTurnBubbles.removeValue(forKey: run)
            if publishedIDs.contains(row.id) { repliesByRun[run] = row }
        }
        resolvePendingReplyFromMac(repliesByRun)
    }
}
