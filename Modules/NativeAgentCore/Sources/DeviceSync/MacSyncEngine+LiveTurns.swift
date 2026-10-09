import ChatOrchestration
import Foundation
import NativeAgentShared
import os
import Transcripts

/// A turn another door started in the anchored conversation reaches the phone
/// as it streams, the way the phone's own turns do (ICloudIncomingTurnForwarder):
/// coalesced `text_delta` records under the turn's run id, then the saved
/// answer, all marked `live` so the phone knows it did not send them. The
/// phone's own turns stay with the forwarder.
extension MacSyncEngine {
    func startLiveTurnRelay() {
        stopLiveTurnRelay()
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let mailbox = OSAllocatedUnfairLock(initialState: (
            turns: [String: (text: String, coalescer: ICloudTextDeltaCoalescer)](),
            pending: [String: BridgeMessage]()
        ))
        // The tap runs deep inside the turn's stack; yielding there overflowed
        // a helper turn's thread (10-07 crash). A serial queue keeps order and
        // gives the yield its own stack.
        let hop = DispatchQueue(label: "nativeagent.live-turn-relay")
        let generation = snapshotLifecycleGeneration
        let dataRoot = sync.dataRoot
        ChatLiveTap.observe { event in
            hop.async {
                guard event.surface != "ios",
                      ConversationAnchor.currentSessionId(dataRoot: dataRoot) == event.sessionId else { return }
                let queued = mailbox.withLock { state -> Bool in
                    let run = event.runId
                    let text: String
                    let kind: String?
                    let sequence: Int?
                    switch event.kind {
                    case .delta(let delta):
                        if state.turns[run] == nil { state.turns[run] = ("", ICloudTextDeltaCoalescer()) }
                        state.turns[run]?.text += delta
                        guard let snapshot = state.turns[run]?.text,
                              let flush = state.turns[run]?.coalescer.push(
                                snapshot: snapshot, nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                              ) else { return false }
                        text = flush.text
                        kind = "text_delta"
                        sequence = flush.sequence
                    case .answered(let answer):
                        state.turns.removeValue(forKey: run)
                        text = answer
                        kind = nil
                        sequence = nil
                    case .incomplete(let answer, _):
                        state.turns.removeValue(forKey: run)
                        text = answer
                        kind = "incomplete"
                        sequence = nil
                    case .failed:
                        state.turns.removeValue(forKey: run)
                        text = event.savedPartial ?? ""
                        kind = "error"
                        sequence = nil
                    case .cancelled:
                        state.turns.removeValue(forKey: run)
                        text = event.savedPartial ?? ""
                        kind = "cancelled"
                        sequence = nil
                    }
                    var metadata = ["live": "true", "transport": "icloud", "source": "mac"]
                    metadata["kind"] = kind
                    if case .failed(let failure) = event.kind { metadata["errorDetail"] = failure }
                    if case .incomplete(_, let status) = event.kind {
                        metadata["status"] = status.prefix(1).uppercased() + status.dropFirst()
                    }
                    metadata["seq"] = sequence.map(String.init)
                    state.pending[run] = BridgeMessage.make(
                        id: "live-\(run)-\(sequence.map(String.init) ?? "terminal")",
                        sender: "mac", text: text, sessionID: event.sessionId,
                        correlationID: run, metadata: metadata
                    )
                    return true
                }
                if queued { continuation.yield(()) }
            }
        }
        // A successful transport operation wakes retained finals without a
        // second retry loop. The signal holds no text; the mailbox owns it.
        sync.bridge.onTransportSucceeded = { continuation.yield(()) }
        liveTurnRelayTask = Task { [weak self] in
            for await _ in signals {
                guard let self, generation == self.snapshotLifecycleGeneration, self.isActive else { break }
                let pending = mailbox.withLock { state in
                    let messages = Array(state.pending.values)
                    state.pending.removeAll()
                    return messages.sorted {
                        ($0.metadata?["kind"] != "text_delta" ? 0 : 1)
                            < ($1.metadata?["kind"] != "text_delta" ? 0 : 1)
                    }
                }
                for message in pending {
                    guard !Task.isCancelled, generation == self.snapshotLifecycleGeneration else { break }
                    guard let run = message.correlationID else { continue }
                    let terminal = message.metadata?["kind"] != "text_delta"
                    if !terminal, mailbox.withLock({ $0.pending[run] != nil }) { continue }
                    do {
                        _ = try await self.sync.bridge.sendChatMessage(
                            text: message.text, sessionID: message.sessionID, correlationID: run,
                            metadata: message.metadata, messageID: message.id, timestamp: message.timestamp
                        )
                    } catch {
                        if terminal {
                            mailbox.withLock { state in
                                if state.pending[run] == nil { state.pending[run] = message }
                            }
                        }
                        nativeLog("[iCloudBridge] live turn %@ not sent: %@", run, "\(error)")
                    }
                }
            }
        }
    }

    func stopLiveTurnRelay() {
        ChatLiveTap.observe(nil)
        sync.bridge.onTransportSucceeded = nil
        liveTurnRelayTask?.cancel()
        liveTurnRelayTask = nil
    }
}
