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
        for run in liveTurnBubbles.keys where rows.contains(where: {
            $0.runId == run && ($0.isTerminalReply || $0.completionState == "failed")
        }) { liveTurnBubbles.removeValue(forKey: run) }
        _ = resolvePendingReplyFromMac(rows)
    }
}
